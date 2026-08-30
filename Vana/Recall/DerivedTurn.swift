import Foundation

/// 用户不在场时替他问的一轮。
///
/// 「说好回头看的事到期了」和「这条目标该报一次进展了」是两件事,但跑法完全一样:后台跑一轮
/// 完整的 agent,把结果存成那条线上的一段。差别只在**问什么**和**什么时候该问**,那两件留在
/// 各自的 `FollowUpRunner` / `GoalDigest` 里。
///
/// 三条不变量,和 `MemoryExtractor` 同源:
///
/// - **非阻塞**。只跑在 app 切前后台的时候,不在用户等回复的时候跑。
/// - **失败即放弃**。跑不出来是小事(用户点开照样能问),让它把 check-in 排程或者会话保存
///   一起拖垮才是大事。半截会话一个字都不存。
/// - **不给写记忆的口子**。用户看不见「记住了…」那条气泡,也没法当场说一句"别记这个"。
enum DerivedTurn {

    /// 跑一轮,成了就返回存下的那一段。
    ///
    /// - Parameter supersedingUnread: 这条线上如果还挂着一段**同样是机器写的、用户一句话
    ///   都没接**的,就把它顶掉。每周一段进展报告攒一年是五十二段,而用户根本没看过前面那些。
    ///   他一旦回了一句,那段就成了真的对话,下次的报告另起一段。
    static func run(
        question: String,
        thread: SessionThread,
        threadTitle: String? = nil,
        now: Date = Date(),
        supersedingUnread: Bool = true,
        memoryStore: MemoryStore,
        sessionStore: SessionStore
    ) async -> ChatSession? {
        guard let settings = cloudSettings() else { return nil }

        var session = ChatSession(
            threadId: thread.id,
            threadTitle: threadTitle,
            isDerived: true,
            createdAt: now,
            updatedAt: now
        )
        session.messages.append(ChatMessage(role: .user, text: question))
        session.messages.append(ChatMessage(role: .assistant, text: ""))

        let engine = AIKitEngine(
            providerId: settings.provider,
            model: settings.model,
            goal: thread.isGoal ? threadTitle : nil,
            memory: await memoryStore.snapshot(now: now),
            // 读记忆照旧——不认识用户的话,这一轮回答的质量还不如不跑。写的那头堵死。
            capabilityRegistry: .healthChat(
                allowsMemoryWrites: false,
                // 和用户那条走同一把尺子:问的是「这段时间有没有进展」(`GoalDigest.question`)
                // 才挂召回,问「昨晚睡得怎么样」不挂。这一轮没人在等,但多翻一次同样是多花的钱,
                // 而且翻回来的旧数字一样会污染那条通知里的结论。
                allowsRecall: SessionRecallTrigger.mentionsPast(question),
                // 没有人在看这一轮。挂着 `ask_user` 的话它会摆出一张永远等不到人点的卡,
                // 然后自己替他挑一个答案接着往下写——而那份结论会原样进早上那条通知。
                asksUser: false,
                memoryStore: memoryStore,
                sessionStore: sessionStore,
                currentSessionId: session.id
            )
        )

        do {
            for try await event in engine.reply(to: session.messages) {
                // 整段摘要挂在早先某条上,不是正在写的那条。这一轮只有两条消息,压缩基本不会
                // 发生,但照着 `ChatViewModel.apply` 的规矩来,免得哪天真发生了静静地丢掉。
                if case .historyCompacted(let messageID, let artifact) = event {
                    if let index = session.messages.firstIndex(where: { $0.id == messageID }) {
                        session.messages[index].storedTurn.compaction = artifact
                    }
                    continue
                }
                guard let last = session.messages.indices.last else { break }
                session.messages[last].apply(event)
            }
        } catch {
            // 跑不出来就当没跑过。半截会话存下去,用户点开只会看到一条空回复。
            return nil
        }

        guard let reply = session.messages.last,
              !reply.text.isEmpty,
              !reply.textIsPlaceholder
        else { return nil }

        // 顶掉上一份没人看的:**先存新的再删旧的**。反过来的话中间那一瞬如果崩了,
        // 用户手里就一份都没有了。
        session.updatedAt = Date()
        guard (try? await sessionStore.save(session)) != nil else { return nil }
        if supersedingUnread, let stale = await unreadDerived(on: thread, besides: session.id, in: sessionStore) {
            try? await sessionStore.delete(id: stale)
        }
        return session
    }

    /// 这条线上最近一次机器写的结论,给通知当正文。
    ///
    /// 读的是那条会话本身,不另存一份摘要——两份迟早对不上,而且用户点开通知看到的就该是
    /// 通知上那句话的出处。
    static func conclusion(on thread: SessionThread, in sessionStore: SessionStore) async -> String? {
        guard let entry = await sessionStore.latestInThread(thread),
              let session = try? await sessionStore.load(id: entry.id),
              let last = session.messages.last(where: { $0.role == .assistant && !$0.textIsPlaceholder }),
              !last.text.isEmpty
        else { return nil }
        return firstSentence(of: last.text)
    }

    /// 这条线上还挂着的、机器写了但用户一句都没接的那一段。
    ///
    /// 不是 private:顶掉谁、留下谁是这套东西唯一会**删用户数据**的地方,得有测试盯着。
    static func unreadDerived(
        on thread: SessionThread,
        besides keep: UUID,
        in sessionStore: SessionStore
    ) async -> UUID? {
        for entry in await sessionStore.entries(inThread: thread) where entry.id != keep {
            guard entry.isDerived else { continue }
            // 机器写的那一段是「一问一答」。多出来的就是用户自己接的话——那已经是真的对话了,
            // 顶掉它等于把他说过的话删了。
            guard entry.messageCount <= 2 else { continue }
            return entry.id
        }
        return nil
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

    /// 记忆是第三人称写的("他说两周后再看看深睡"),而这句话是用户点开会话第一眼看到的,
    /// 得读起来像句人话。句尾标点也要剥——记忆有的写到句号有的不写。
    static func naturalize(_ promise: String) -> String {
        promise.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "。．.！!？?；;，,、 "))
    }

    /// 云端要齐 key 和 model 才发得出去,而且**这家 provider 要被用户点名同意过**
    /// (`ProviderConsent`)。后台派生跑在用户不在场的时候——同意之前替他发一轮,
    /// 正是 5.1.2(i) 那句「before sharing」要挡的事。
    static func cloudSettings() -> (provider: String, model: String)? {
        let key = (try? KeychainStore.get(account: KeychainStore.apiKeyAccount)) ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let selection = EngineSettings.selection
        guard !selection.model.isEmpty, ProviderConsent.granted(selection.provider) else { return nil }
        return selection
    }
}
