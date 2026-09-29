import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 跨会话召回:翻得到、编号不乱、不该看到的看不到。
///
/// 这套东西的胜负手是**召回精度不是召回广度**。模型说「我们上次说过…」而用户根本不记得
/// 说过,或者把三个月前的数字当成本周的讲,那一瞬间信任掉得比从没记住过还快。所以这里盯的
/// 大半是"不该发生什么":编号不许错位、删掉的不许还在、当前会话不许被当成历史读回来、
/// 读出来的每一段都得带着日期和那句「数值以本次工具为准」。
///
/// 每条测试都开自己的临时目录。app 侧测试跑在 app host 里,`SessionStore.shared` 就是
/// 模拟器上那份真的会话——测试写它等于动用户的对话。
@Suite("SessionRecall")
struct SessionRecallTests {

    private static func freshStore() -> SessionStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionStore(parent: directory)
    }

    private static func session(
        _ userText: String,
        reply: String = "",
        tools: [String] = [],
        topicId: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) -> ChatSession {
        var messages = [ChatMessage(role: .user, text: userText)]
        if !reply.isEmpty || !tools.isEmpty {
            messages.append(ChatMessage(
                role: .assistant,
                text: reply,
                toolCalls: tools.map {
                    ToolCallRecord(id: UUID().uuidString, name: $0, input: "{}", output: "…")
                }
            ))
        }
        return ChatSession(
            messages: messages,
            topicId: topicId,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt
        )
    }

    private static let day: TimeInterval = 86_400

    // MARK: - 编号

    @Test("handles follow creation order, so a later save never renumbers anything")
    func handlesSurviveASave() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = Self.session("三月那次出差", createdAt: base)
        var newest = Self.session("这周睡得不好", createdAt: base + 2 * Self.day)
        try await store.save(oldest)
        try await store.save(newest)

        let before = await store.recallIndex()
        #expect(before.digest(handle: "S1")?.id == oldest.id)
        #expect(before.digest(handle: "S2")?.id == newest.id)

        // 把新的那条更新一下。按 `updatedAt` 发号的话这里就该错位了——而上一句里模型说的
        // 「S1」会突然指到另一条对话去。
        newest.messages.append(ChatMessage(role: .user, text: "那前天呢"))
        newest.updatedAt = base + 10 * Self.day
        try await store.save(newest)

        let after = await store.recallIndex()
        #expect(after.digest(handle: "S1")?.id == oldest.id)
        #expect(after.digest(handle: "S2")?.id == newest.id)
    }

    @Test("excluding the current session does not shift the other handles")
    func excludingCurrentKeepsHandles() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.session("一", createdAt: base)
        let second = Self.session("二", createdAt: base + Self.day)
        let third = Self.session("三", createdAt: base + 2 * Self.day)
        for one in [first, second, third] { try await store.save(one) }

        // 排除放在发号之前的话,S3 会变成第三条之外的另一条。
        let index = await store.recallIndex(excluding: second.id)
        #expect(index.digest(handle: "S1")?.id == first.id)
        #expect(index.digest(handle: "S3")?.id == third.id)
        #expect(index.digest(handle: "S2") == nil)
    }

    // MARK: - 不该看到的

    @Test("the session in progress is not recallable as history")
    func currentSessionIsExcluded() async throws {
        let store = Self.freshStore()
        let current = Self.session("我现在问的这句", createdAt: Date())
        try await store.save(current)

        let index = await store.recallIndex(excluding: current.id)
        // 不排掉的话模型会把自己刚说过的话当成「上次」读回来。
        #expect(index.search(query: "现在").isEmpty)
    }

    @Test("a deleted session leaves the index immediately")
    func deletedSessionDisappears() async throws {
        let store = Self.freshStore()
        let doomed = Self.session("这段我不想留着", createdAt: Date())
        try await store.save(doomed)
        // 先读一次把索引缓存住,再删——缓存没被清掉的话下面这条会挂。
        #expect(await store.recallIndex().digests.count == 1)

        try await store.delete(id: doomed.id)

        // 用户刚把这段对话删了,下一句还能被模型引用出来,是这套东西最难解释的一种失灵。
        #expect(await store.recallIndex().isEmpty)
    }

    @Test("an empty session is not something to recall")
    func emptySessionsAreSkipped() async throws {
        let store = Self.freshStore()
        try await store.save(ChatSession(createdAt: Date()))
        try await store.save(Self.session("真的聊了点什么", createdAt: Date()))

        // 空会话占一个编号,后面每条的编号就跟着它的存亡漂移;而它本身也没什么可读的。
        let index = await store.recallIndex()
        #expect(index.digests.count == 1)
        #expect(index.digest(handle: "S1")?.title == "真的聊了点什么")
    }

    // MARK: - 检索

    @Test("search matches the user's own words, not the assistant's catch-all replies")
    func searchScoresUserWords() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let aboutSleep = Self.session(
            "我最近老是三四点醒，是不是加班太多",
            reply: "看下来主要落在周三。",
            tools: ["sleep_summary"],
            createdAt: base
        )
        // 助手那段什么都提一句。把它算进打分,每条会话都能匹配上任何查询,检索就退化成了
        // 按时间倒序。
        let aboutSteps = Self.session(
            "今天走了多少步",
            reply: "睡眠、心率、活动量看下来都还行，加班那几天也没什么异常。",
            tools: ["daily_steps"],
            createdAt: base + Self.day
        )
        for one in [aboutSleep, aboutSteps] { try await store.save(one) }

        let index = await store.recallIndex()
        let hits = index.search(query: "加班 睡眠")
        #expect(hits.first?.id == aboutSleep.id)
    }

    @Test("a barely-related session is dropped when a clearly better match exists")
    func searchDropsWeakMatches() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let onPoint = Self.session("最近加班熬夜，睡眠是不是被拖垮了", createdAt: base)
        // 只沾上「睡眠」两个字。健康 app 里这种会话有的是,而 `score > 0` 会把它们全端回去
        // ——模型分不出哪条才是用户说的那次,只好挨条 read_session 读过去,一次试探性检索
        // 就变成了三四轮。
        let barelyRelated = Self.session("昨晚睡眠多少小时", createdAt: base + Self.day)
        for one in [onPoint, barelyRelated] { try await store.save(one) }

        let hits = await store.recallIndex().search(query: "加班 熬夜 睡眠")
        #expect(hits.map(\.id) == [onPoint.id])
    }

    @Test("a one-word query keeps every session that matches it")
    func searchKeepsTiesForAThinQuery() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = Self.session("睡眠一直不太好", createdAt: base)
        let newer = Self.session("睡眠有改善吗", createdAt: base + Self.day)
        for one in [older, newer] { try await store.save(one) }

        // 相对门槛在这里必须自动失效:用户就给了这么一个词,再挑就是瞎挑。
        let hits = await store.recallIndex().search(query: "睡眠")
        #expect(hits.count == 2)
        #expect(hits.first?.id == newer.id)
    }

    @Test("an empty query returns the most recent conversations")
    func emptyQueryReturnsRecent() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = Self.session("很久以前", createdAt: base)
        let newer = Self.session("最近", createdAt: base + 5 * Self.day)
        for one in [older, newer] { try await store.save(one) }

        // 「上次我们聊到哪了」是个合法的问法,不该被当成"没有查询词"挡回去。
        let hits = await store.recallIndex().search(query: "")
        #expect(hits.first?.id == newer.id)
        #expect(hits.count == 2)
    }

    // MARK: - 读回来的样子

    @Test("a recalled transcript carries its date and the numbers-are-stale line")
    func transcriptCarriesDateAndDisclaimer() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let session = Self.session(
            "上周睡得怎么样",
            reply: "平均 6 小时 10 分，比你平时少。",
            tools: ["sleep_summary"],
            createdAt: when
        )
        let now = when + 90 * Self.day
        let text = SessionRecallTranscript.text(for: session, now: now)

        #expect(text.contains(SessionRecall.dateLabel(when, now: now)))
        #expect(text.contains("上周睡得怎么样"))
        #expect(text.contains("平均 6 小时 10 分"))
        // 当时查了什么要留着(结论建立在哪些数据上),但这一行不许带数字回来。
        #expect(text.contains("当时查了：睡眠"))
        // 这是整套召回最要紧的防线。没有它,模型会拿三个月前的 6 小时 10 分当本周讲。
        #expect(text.contains(SessionRecallTranscript.footer))
    }

    @Test("the chip's date comes from the same line the model reads")
    func chipDateComesFromTheOutput() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let text = SessionRecallTranscript.text(
            for: Self.session("上周睡得怎么样", reply: "还行。", createdAt: when),
            now: when
        )

        // 一轮里常常连着回顾好几次,三个一模一样的胶囊等于没说。日期从输出里取,
        // 胶囊上那天和点开看到的那天就不可能对不上。
        #expect(SessionRecallTranscript.dateLabel(inOutput: text) == SessionRecall.dateLabel(when, now: when))
        #expect(SessionRecallTranscript.dateLabel(inOutput: nil) == nil)
        #expect(SessionRecallTranscript.dateLabel(inOutput: "没有编号为 S99 的对话。") == nil)
    }

    @Test("app-written placeholders are not read back as things the model said")
    func placeholdersAreNotRecalled() throws {
        var stopped = ChatMessage(role: .assistant, text: "已停止回复")
        stopped.textIsPlaceholder = true
        let session = ChatSession(
            messages: [ChatMessage(role: .user, text: "帮我看看心率"), stopped],
            createdAt: Date()
        )

        let text = SessionRecallTranscript.text(for: session)
        // 「已停止回复」是 app 写给用户的,不是模型说过的话。读回来只会让它去解释一句
        // 自己没说过的话。
        #expect(!text.contains("已停止回复"))
        #expect(text.contains("帮我看看心率"))
    }

    @Test("an over-long conversation keeps the question and the conclusion")
    func longTranscriptKeepsHeadAndTail() throws {
        var messages: [ChatMessage] = [ChatMessage(role: .user, text: "帮我分析一下这三个月的睡眠")]
        for index in 0..<40 {
            messages.append(ChatMessage(role: .assistant, text: String(repeating: "中间的过程\(index)", count: 12)))
            messages.append(ChatMessage(role: .user, text: "那第\(index)周呢"))
        }
        messages.append(ChatMessage(role: .assistant, text: "结论是周三最差。"))
        let session = ChatSession(messages: messages, createdAt: Date())

        let text = SessionRecallTranscript.text(for: session)
        #expect(text.count < SessionRecallTranscript.maxCharacters + SessionRecallTranscript.footer.count + 200)
        // 开头是他当时在问什么,结尾是聊出来的结论。被丢掉的中间那段是查数据的过程——
        // 而过程恰恰是最该现查一遍、最不值得读回来的。
        #expect(text.contains("帮我分析一下这三个月的睡眠"))
        #expect(text.contains("结论是周三最差。"))
        #expect(text.contains("中间"))
    }

    // MARK: - 什么时候才挂出去

    @Test("the recall tools stay off the table until the user brings up the past")
    func recallIsGatedOnTheUsersOwnWords() {
        // 问的是眼前的数据。留着工具的话,模型每轮都要判一次「这算不算接着一段历史」,
        // 而健康对话句句连着上一句,那个判断天然偏向"算"。
        let asking = [ChatMessage(role: .user, text: "今天走了多少步")]
        #expect(!SessionRecallTrigger.unlocksRecall(in: asking))

        let referring = asking + [
            ChatMessage(role: .assistant, text: "8000 步。"),
            ChatMessage(role: .user, text: "上次你说的那个方法还算数吗")
        ]
        #expect(SessionRecallTrigger.unlocksRecall(in: referring))

        // 一旦提过就粘住:后面几轮多半还在同一件事上,而工具集一轮挂一轮撤会把 prompt
        // 缓存的前缀反复打掉。
        #expect(SessionRecallTrigger.unlocksRecall(in: referring + [
            ChatMessage(role: .user, text: "那我今晚早点睡")
        ]))
    }

    @Test("a time word about data is not a reference to a past conversation")
    func timeWordsDoNotUnlockRecall() {
        // 「上周步数」现查就有。把时间词也算进来,一半的健康问题都会把工具挂出去,等于没做。
        for text in ["上周步数怎么样", "前几天的睡眠", "这个月体重变化"] {
            #expect(!SessionRecallTrigger.mentionsPast(text))
        }
        for text in ["我们之前聊过这个", "你还记得我说的加班吗", "上回分析的结果", "what did we discuss earlier"] {
            #expect(SessionRecallTrigger.mentionsPast(text))
        }
    }

    @Test("a locked conversation carries no recall tools at all")
    func lockedRegistryHasNoRecallTools() {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = TestAssembly.environment(stores: stores, recall: true)
        let locked = TestAssembly.engine(environment, unlocked: []).capabilityRegistry
        #expect(locked.definition(named: SessionRecallTools.searchToolName) == nil)
        #expect(locked.definition(named: SessionRecallTools.readToolName) == nil)

        let unlocked = TestAssembly.engine(environment).capabilityRegistry
        // 记忆开关仍然管着它:关掉记忆的人不会指望 Vana 还在引用他上个月说过的话。
        #expect(unlocked.definition(named: SessionRecallTools.searchToolName) != nil
            || !EngineSettings.memoryEnabled)
    }

    // MARK: - 工具

    @Test("read_session refuses a handle that search never handed out")
    func readRejectsUnknownHandle() async throws {
        let store = Self.freshStore()
        try await store.save(Self.session("一次对话", createdAt: Date()))

        let registry = SessionRecallTools.registry(store: store)
        let result = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.readToolName,
            input: #"{"id":"S99"}"#
        ))
        // 报成错误,模型才会退回去先 search 一次;悄悄返回空的话它会当作"那次对话没内容"。
        #expect(result.isError)
    }

    @Test("finding nothing is an answer, not a tool failure")
    func emptySearchIsNotAnError() async throws {
        let store = Self.freshStore()
        try await store.save(Self.session("今天走了多少步", createdAt: Date()))

        let registry = SessionRecallTools.registry(store: store)
        let result = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.searchToolName,
            input: #"{"query":"膝盖 手术"}"#
        ))
        // 「以前没聊过这个」是有效答案,模型据此就该老老实实去查数据。报成错误它会以为工具
        // 坏了,换个说法再试一次,白花一轮。
        #expect(!result.isError)
        #expect(result.output.text.contains("没有找到"))
    }

    @Test("the search listing does not order a read")
    func searchListingLeavesReadingOptional() async throws {
        let store = Self.freshStore()
        try await store.save(Self.session("我睡眠差是不是因为加班", createdAt: Date()))

        let registry = SessionRecallTools.registry(store: store)
        let result = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.searchToolName,
            input: #"{"query":"加班"}"#
        ))
        // 写成祈使句的话,检索结果本身就成了下一次调用的指令:哪怕列出来的这几条明显不是
        // 用户说的那次,模型也会挨个读下去。
        #expect(!result.output.text.contains("用 read_session 读其中一条"))
        #expect(result.output.text.contains("都对不上就别读了"))
    }

    @Test("search then read walks the same handle end to end")
    func searchThenReadRoundTrip() async throws {
        let store = Self.freshStore()
        let target = Self.session(
            "我睡眠差是不是因为加班",
            reply: "对上了，差的那几天都是周三。",
            tools: ["sleep_summary"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.save(target)

        let registry = SessionRecallTools.registry(store: store)
        let found = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.searchToolName,
            input: #"{"query":"加班"}"#
        ))
        let handle = try #require(await store.recallIndex().digests.first?.handle)
        #expect(found.output.text.contains(handle))

        let read = await registry.execute(CapabilityInvocation(
            toolCallId: "2",
            name: SessionRecallTools.readToolName,
            input: #"{"id":"\#(handle)"}"#
        ))
        #expect(!read.isError)
        #expect(read.output.text.contains("差的那几天都是周三"))
    }
}
