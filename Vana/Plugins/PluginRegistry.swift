import Foundation
import AgentRuntime

/// 哪条路挂哪些插件。**注册顺序就是工具定义发出去的顺序**,同 order 的提示词块也按它稳定排序。
/// 开关已经兑现在 `PluginEnvironment` 里(关着就没有 store),这里只按整个插件的开关过滤。
/// 隐私会话和后台一轮不在这里分,由 `PluginContext` 按工具声明的副作用统一过滤。
enum PluginRegistry {
    static let all: [any VanaPlugin] = [CorePlugin(), HealthVanaPlugin()]

    static func agentPlugins(_ env: PluginEnvironment, route: PluginRoute) -> [any AgentPlugin] {
        all.filter { env.isEnabled($0.manifest.id) }
            .flatMap { $0.agentPlugins(env, route: route) }
    }

    static func context(for env: PluginEnvironment, route: PluginRoute, isPrivate: Bool) -> PluginContext {
        PluginContext(
            isPrivate: isPrivate,
            isBackground: route == .background,
            isDeviceOwner: env.tenant.isOwner
        )
    }

    /// 记忆抽取器要遵守的、来自各生效插件的规则(排除项加领域补充)。和聊天时实际挂出去的插件
    /// 是同一份,两边对「哪些话题别记」的认识才一致。
    static func memoryPolicy(_ env: PluginEnvironment) -> MemoryPolicy {
        PluginHost.memoryPolicy(
            agentPlugins(env, route: .foreground),
            context: PluginContext(isDeviceOwner: env.tenant.isOwner)
        )
    }

    /// 哪个插件拥有这种记忆。核心的种类返回 nil。
    static func memoryOwner(_ kind: MemoryKind) -> (any VanaPlugin)? {
        all.first { $0.memoryKinds.contains(kind) }
    }

    /// 这种记忆现在该不该带进对话:它的主人关了就不带。
    static func isMemoryVisible(_ kind: MemoryKind, isEnabled: (String) -> Bool) -> Bool {
        memoryOwner(kind).map { isEnabled($0.manifest.id) } ?? true
    }

    /// 只留下现在生效的插件该看到的记忆。聊天和抽取器用同一份,两边对「记着什么」的认识才一致。
    static func visibleMemory(_ snapshot: MemorySnapshot, isEnabled: (String) -> Bool) -> MemorySnapshot {
        snapshot.filtered { isMemoryVisible($0.kind, isEnabled: isEnabled) }
    }

    /// 插件页里列出来的:用户能开关的那些。
    static var togglable: [any VanaPlugin] { all.filter { $0.manifest.togglable } }

    /// 首屏的 `limit` 条建议。**通用优先**:核心先占位,其余插件轮流分剩下的;
    /// 某个插件正处在具体上下文里(聊某样药、替家人问)时,只给它的。
    static func suggestions(_ context: SuggestionContext, limit: Int = 3) -> [SuggestedQuestion] {
        let sets = all.filter { context.isEnabled($0.manifest.id) }.map { $0.suggestions(context) }
        if let exclusive = sets.first(where: { $0.exclusive && !$0.items.isEmpty }) {
            return Array(exclusive.items.prefix(limit))
        }
        return mix(sets.map(\.items), limit: limit)
    }

    /// 通用优先:第一份(核心)占大头,其余各份轮流分**至少一个、约三分之一**的位子
    /// (`limit = 3` 就是 1 个),某一份不够再从别处补。以后多了几个插件也不会把核心挤到一个位子。
    static func mix<T: Equatable>(_ lists: [[T]], limit: Int) -> [T] {
        let core = lists.first ?? []
        let others = lists.dropFirst().filter { !$0.isEmpty }
        let reserved = others.isEmpty ? 0 : max(1, limit / 3)
        let coreSlots = limit - reserved
        var result = Array(core.prefix(coreSlots))
        var round = 0
        while result.count < limit, others.contains(where: { round < $0.count }) {
            for other in others where result.count < limit && round < other.count {
                result.append(other[round])
            }
            round += 1
        }
        if result.count < limit {
            result += core.dropFirst(coreSlots).prefix(limit - result.count)
        }
        var unique: [T] = []
        for item in result where !unique.contains(item) { unique.append(item) }
        return unique
    }

    /// 欢迎语。「我能帮你……」由各生效的插件各贡献一小段,健康关掉就不提健康。
    static func welcomeBody(isEnabled: (String) -> Bool) -> String {
        let blurbs = all.filter { isEnabled($0.manifest.id) }.compactMap(\.welcomeBlurb)
        guard let first = blurbs.first else { return String(localized: "日常的事都可以交给我。") }
        let rest = blurbs.dropFirst()
        var text = String(localized: "日常的事都可以交给我：\(first)。")
        if !rest.isEmpty {
            text += String(localized: "也能\(rest.joined(separator: "、"))。")
        }
        return text
    }
}
