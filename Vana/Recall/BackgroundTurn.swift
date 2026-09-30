import Foundation
import AgentRuntime

/// 用户不在场时替他问的一轮(待跟进到期的回访,以后还有后台任务)。
///
/// 形状:**非阻塞、独立上下文、失败即放弃**。它不碰聊天的窗口——自己造一份两条消息的上下文,
/// 只带记忆(只读)、召回(读线程档案)和机主的 Apple 健康(那几件回访问的多半是数据)。结论
/// **不存成另一条会话**(以前是一个 `isDerived` 的会话文件),由调用方作为一条主动消息追加进
/// 那条线程——他打开 app 就在对话末尾。
///
/// 三条不变量,和 `MemoryExtractor` 同源:
/// - **非阻塞**。只跑在 app 切前后台的时候,不在用户等回复的时候跑。
/// - **失败即放弃**。跑不出来是小事,让它把 check-in 排程一起拖垮才是大事。
/// - **不给写的口子**(`PluginContext.isBackground` 丢掉全部 `.writeLocal` 和 `.needsUser`):
///   用户看不见「记住了…」那条气泡,也没法当场说一句"别记这个";没有人在看那张问题卡。
enum BackgroundTurn {
    /// - Parameter engineFactory: 测试注入一个假引擎。线上按当前设置现造。
    static func run(
        question: String,
        now: Date = Date(),
        memoryStore: MemoryStore,
        thread: ThreadStore,
        tenant: Tenant,
        engineFactory: (@Sendable (PluginEnvironment) -> any AgentEngine)? = nil
    ) async -> String? {
        let environment = await environment(now: now, memoryStore: memoryStore, thread: thread, tenant: tenant)
        let engine: any AgentEngine
        if let engineFactory {
            engine = engineFactory(environment)
        } else {
            guard let settings = CloudAccess.backgroundSettings() else { return nil }
            engine = AIKitEngine(
                providerId: settings.provider,
                model: settings.model,
                environment: environment,
                route: .background,
                // 辅助调用一律显式关掉思考:这一轮用户看不见,省下的是他的钱和电量。
                thinking: false
            )
        }

        var messages = [ChatMessage(role: .user, text: question), ChatMessage(role: .assistant, text: "")]
        do {
            for try await event in engine.reply(to: messages) {
                if case .historyCompacted(let messageID, let artifact) = event {
                    if let index = messages.firstIndex(where: { $0.id == messageID }) {
                        messages[index].storedTurn.compaction = artifact
                    }
                    continue
                }
                messages[messages.count - 1].apply(event)
            }
        } catch {
            return nil
        }
        guard let reply = messages.last, !reply.textIsPlaceholder else { return nil }
        let text = reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// 后台路的装配输入:只读记忆、召回、机主的 Apple 健康。不带搜索和读网页:待跟进回访多挂一样
    /// 就多花一份钱(以前子 agent 在它上面再挂这两样,2026-09-30 撤掉了)。
    static func environment(
        now: Date,
        memoryStore: MemoryStore,
        thread: ThreadStore,
        tenant: Tenant
    ) async -> PluginEnvironment {
        var recall: CapabilityRegistry?
        if let hidden = await thread.meta().windowStartPos, await thread.hasArchiveRows(before: hidden) {
            recall = HistoryRecallTools.registry(store: thread, hiddenBefore: hidden)
        }
        return PluginEnvironment(
            tenant: tenant,
            recall: recall,
            memoryStore: memoryStore,
            // 读记忆照旧——不认识用户的话,这一轮回答的质量还不如不跑。
            memory: EngineSettings.memoryEnabled ? await memoryStore.snapshot(now: now) : .empty,
            includesHealthData: true
        )
    }

    /// 通知那一行放不下一整段,取第一句。
    static func firstSentence(of text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.firstIndex(where: { "。！？!?".contains($0) }) {
            let sentence = String(trimmed[...end])
            if sentence.count >= 8 { return sentence }
        }
        return trimmed.count <= 60 ? trimmed : String(trimmed.prefix(60)) + "…"
    }

    /// 记忆是第三人称写的("他说两周后再看看深睡"),句尾标点也要剥——记忆有的写到句号有的不写。
    static func naturalize(_ promise: String) -> String {
        promise.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。．.！!？?；;，,、 "))
    }
}
