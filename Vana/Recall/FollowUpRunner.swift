import Foundation

/// 说好回头看的事到期了,自己先跑一轮。
///
/// 在这之前,到期的 `followUp` 只是让早上那条通知把当初那句话再念一遍。这里把那一轮提前跑掉:
/// 通知里带的是**结论**,点开进去那条结论已经在对话末尾了。
///
/// 「跑过没有」记在线程 meta 的 `derived` 里(条目 id → 什么时候跑的、得出的一句结论),
/// 结论作为一条 `.followUp` 主动消息追加进那条线程。怎么跑在 `BackgroundTurn`;这里只管
/// **该不该跑**和**问什么**。
enum FollowUpRunner {
    /// 同一条待跟进,一天最多自己跑一次。
    static let minimumInterval: TimeInterval = 86_400

    static func key(_ id: UUID) -> String { "followup:\(id.uuidString)" }

    /// 到期的里挑一条还没跑过的。挑不到就返回 nil,让位给别的后台活。
    static func pending(now: Date, memoryStore: MemoryStore, thread: ThreadStore) async -> MemoryItem? {
        guard EngineSettings.memoryEnabled else { return nil }
        let derived = await thread.meta().derived
        // 一次只挑一条。到期三条就连着跑三轮模型,是用户完全没预期的一笔开销。
        for item in await memoryStore.snapshot(now: now).due(at: now) {
            guard let previous = derived[key(item.id)] else { return item }
            if now.timeIntervalSince(previous.at) >= minimumInterval { return item }
        }
        return nil
    }

    @discardableResult
    static func run(
        _ followUp: MemoryItem,
        now: Date = Date(),
        memoryStore: MemoryStore,
        thread: ThreadStore,
        tenant: Tenant,
        engineFactory: (@Sendable (PluginEnvironment) -> any AgentEngine)? = nil
    ) async -> Bool {
        guard let text = await BackgroundTurn.run(
            question: question(for: followUp),
            now: now,
            memoryStore: memoryStore,
            thread: thread,
            tenant: tenant,
            engineFactory: engineFactory
        ) else { return false }
        let conclusion = BackgroundTurn.firstSentence(of: text)
        await thread.updateMeta { $0.derived[key(followUp.id)] = .init(at: now, conclusion: conclusion) }
        await thread.appendAtEnd(ChatMessage(role: .assistant, text: text, origin: .followUp))
        return true
    }

    /// 这条待跟进最近一次自己跑出来的结论,给通知当正文。
    static func conclusion(for followUp: MemoryItem, in thread: ThreadStore) async -> String? {
        await thread.meta().derived[key(followUp.id)]?.conclusion
    }

    /// 记忆是第三人称写的,直接当成用户的问话发出去会很怪。这里把它还原成他当初的意思,
    /// 再说清楚现在要什么。
    static func question(for followUp: MemoryItem) -> String {
        "我们说好这时候回头看的：\(BackgroundTurn.naturalize(followUp.text))。现在怎么样了？"
            + "需要的话查一下数据，结合之后的对话和记忆，两三句话说清楚现在是什么情况、和当初比有没有变化。"
    }
}
