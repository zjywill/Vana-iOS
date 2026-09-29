import Foundation
import AgentRuntime

/// 记忆收割,和窗口**解耦**。
///
/// 以前抽取只在「切会话」时触发,一条永远的对话里没有这个事件;而且每次把整段重发、只留末尾
/// 6000 字,既会把抽过的再看一遍,又会漏掉更早还没抽的。现在线程 meta 里记一个**水位线**
/// (`harvestedUpToPos`):只喂水位线之后的消息,从最旧的开始按转写字符数分块,一次一块;
/// 抽完才把水位线推到这一块的末尾。
///
/// 不阻塞窗口淘汰:档案逐字保留,没来得及抽的以后仍抽得到。失败即放弃、水位线不动,下一个
/// 触发点再来(切到后台、空闲半小时、有原文滑出窗口)。全部走 `BackgroundModelWork` 那把
/// 「同时只准跑一件」的锁,拿不到位子就不排队。每一条会出设备的路都要过 provider 同意的闸。
///
/// **不留痕的那条对话从来不进线程**,所以也永远不会被收割;被删的消息不在线程里,也就收不到。
enum MemoryHarvester {
    enum Outcome: Equatable {
        /// 没到该抽的时候(关着记忆、攒得不够)。
        case notDue
        /// 条件不具备:没配 key、没同意过发给这家。
        case skipped
        /// 别的后台模型活正占着位子。
        case busy
        case done
        case failed
    }

    /// - Parameter extract: 真的去调模型的那一步。测试注入一个假的。
    static func runIfDue(
        thread: ThreadStore,
        memory: MemoryStore,
        environment: PluginEnvironment,
        extract: (@Sendable (MemorySnapshot, MemoryPolicy, [ChatMessage]) async throws -> [MemoryOperation])? = nil
    ) async -> Outcome {
        guard environment.isEnabled(PluginIds.memory) else { return .notDue }
        let settings = CloudAccess.backgroundSettings()
        guard extract != nil || settings != nil else { return .skipped }

        let pending = await thread.messages(after: await thread.meta().harvestedUpToPos)
            .filter { !$0.message.isQueued }
        guard MemoryHarvest.userMessageCount(pending.map(\.message)) >= MemoryHarvest.minimumUserMessages else {
            return .notDue
        }
        let chunk = MemoryHarvest.chunk(pending.map(\.message))
        let reached = pending[chunk.count - 1].pos
        let snapshot = PluginRegistry.visibleMemory(await memory.snapshot(), isEnabled: environment.isEnabled)
        let policy = PluginRegistry.memoryPolicy(environment)

        let result: Bool? = await BackgroundModelWork.shared.run {
            do {
                let operations: [MemoryOperation]
                if let extract {
                    operations = try await extract(snapshot, policy, chunk)
                } else if let settings {
                    operations = try await MemoryExtractor(
                        providerId: settings.provider,
                        model: settings.model,
                        snapshot: snapshot,
                        policy: policy
                    ).operations(from: chunk)
                } else {
                    return false
                }
                _ = try await memory.apply(operations, sessionId: nil)
                await thread.updateMeta { $0.harvestedUpToPos = reached }
                return true
            } catch {
                return false
            }
        }
        guard let result else { return .busy }
        return result ? .done : .failed
    }
}
