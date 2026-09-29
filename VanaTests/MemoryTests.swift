import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 记忆:存、抽、注入。
///
/// 盯的是这几件事——用户手改过的不会被后台悄悄改回去、说好回头看的到点会被提起、抽取器
/// 看不到工具输出(所以记不下数字)、刚发生的事排在历史偏好前面。
///
/// 每条测试都开自己的临时 store。app 侧的测试跑在 app host 里,`MemoryStore.shared`
/// 就是模拟器上那份真的 `memory.json`——测试写它等于把用户记住的东西删了。
@Suite("Memory")
struct MemoryTests {

    private static func freshStore() -> MemoryStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MemoryStore(directory: directory)
    }

    // MARK: - 存

    @Test("a user-written memory survives a round trip through the file")
    func manualMemoryPersists() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = MemoryStore(directory: directory)
        try await store.add(kind: .profile, text: "他上夜班，白天补觉")

        // 换一个实例读同一个文件:测的是盘上那份,不是 actor 里的缓存。
        let reopened = MemoryStore(directory: directory)
        let items = await reopened.items()
        #expect(items.count == 1)
        #expect(items.first?.text == "他上夜班，白天补觉")
        // 手写的一律 pinned,否则会被后台抽取挤掉。
        #expect(items.first?.origin == .manual)
        #expect(items.first?.pinned == true)
    }

    @Test("extraction never overwrites or deletes what the user edited by hand")
    func pinnedItemsResistExtraction() async throws {
        let store = Self.freshStore()
        let mine = try await store.add(kind: .preference, text: "他不想被反复提醒去看医生")
        let id = try #require(mine.first?.id)

        let after = try await store.apply(
            [.update(id: id, text: "他很在意医生的建议"), .delete(id: id)],
            sessionId: UUID()
        )

        // 他改成那样就是不认同模型的说法。跑一遍抽取又被改回去,等于那个设置页是假的。
        #expect(after.count == 1)
        #expect(after.first?.text == "他不想被反复提醒去看医生")
    }

    @Test("extraction updates and deletes its own items")
    func extractionEditsItsOwnItems() async throws {
        let store = Self.freshStore()
        let sessionId = UUID()
        var items = try await store.apply(
            [
                .add(kind: .profile, text: "他在备半马", expiresInDays: nil),
                .add(kind: .interpretation, text: "他的静息心率基线约 52", expiresInDays: nil)
            ],
            sessionId: sessionId
        )
        #expect(items.count == 2)

        let profileId = try #require(items.first { $0.kind == .profile }?.id)
        let staleId = try #require(items.first { $0.kind == .interpretation }?.id)

        items = try await store.apply(
            [.update(id: profileId, text: "他在备全马"), .delete(id: staleId)],
            sessionId: sessionId
        )

        #expect(items.count == 1)
        #expect(items.first?.text == "他在备全马")
    }

    @Test("re-adding the same fact does not pile up duplicates")
    func duplicateAddsAreIgnored() async throws {
        let store = Self.freshStore()
        try await store.apply([.add(kind: .profile, text: "他上夜班", expiresInDays: nil)], sessionId: nil)
        let items = try await store.apply(
            [.add(kind: .profile, text: "他上夜班", expiresInDays: nil)],
            sessionId: nil
        )
        #expect(items.count == 1)
    }

    @Test("a due follow-up sticks around long enough to be surfaced, then goes")
    func dueFollowUpsSurviveUntilTheyAreUsed() async throws {
        let store = Self.freshStore()
        let now = Date()
        try await store.apply(
            [
                .add(kind: .followUp, text: "两周后看戒咖啡有没有效果", expiresInDays: 14),
                .add(kind: .profile, text: "他上夜班", expiresInDays: nil)
            ],
            sessionId: nil,
            now: now
        )

        // 到期那一刻正是它要派上用场的时候(进 check-in、进 system 段),当场删掉等于永远用不上。
        let due = now.addingTimeInterval(15 * 86_400)
        let stillThere = await store.snapshot(now: due)
        #expect(stillThere.items.count == 2)
        #expect(stillThere.due(at: due).map(\.text) == ["两周后看戒咖啡有没有效果"])

        // 过了宽限期才真的消失。
        let wayLater = due.addingTimeInterval(MemoryStore.followUpGrace + 60)
        let items = await store.items(now: wayLater)
        #expect(items.count == 1)
        #expect(items.first?.kind == .profile)
    }

    @Test("eviction drops the stalest automatic memory and never a hand-written one")
    func evictionSparesPinnedItems() async throws {
        let store = Self.freshStore()
        try await store.add(kind: .preference, text: "手写的这条不许动")

        // 一次灌满:上限是条数和字数一起卡的,这里撞的是条数。
        let flood = (0..<MemoryStore.maxItems).map {
            MemoryOperation.add(kind: .profile, text: "自动记的第 \($0) 条", expiresInDays: nil)
        }
        let items = try await store.apply(flood, sessionId: nil)

        #expect(items.count <= MemoryStore.maxItems)
        #expect(items.contains { $0.text == "手写的这条不许动" })
        // 淘汰从最久没更新的自动记忆开始,所以最早那条先走。
        #expect(!items.contains { $0.text == "自动记的第 0 条" })
        #expect(items.contains { $0.text == "自动记的第 \(MemoryStore.maxItems - 1) 条" })
    }

    // MARK: - 注入 prompt

    @Test("the prompt block groups by kind and keeps the tools-win guard")
    func promptBlockCarriesTheGuard() throws {
        let snapshot = MemorySnapshot(items: [
            MemoryItem(kind: .profile, text: "他上夜班"),
            MemoryItem(kind: .preference, text: "他要数字，不要鼓励")
        ])
        let text = try #require(snapshot.instructionBlock)

        #expect(text.contains("[长期情况] 他上夜班"))
        #expect(text.contains("[表达偏好] 他要数字，不要鼓励"))
        // 少了这句,模型会拿三个月前记下的一句话当今天的数据讲。
        #expect(text.contains("以本次工具返回的为准"))
    }

    @Test("the snapshot handed to the engine lands in the system prompt")
    func engineInjectsMemory() {
        let engine = TestAssembly.engine(TestAssembly.environment(memory: MemorySnapshot(items: [
            MemoryItem(kind: .profile, text: "他上夜班")
        ])))
        let instructions = engine.systemInstruction()

        #expect(instructions.contains("[长期情况] 他上夜班"))
        // 记忆排在易变区,而且不能把原本那份提示挤掉。
        #expect(instructions.contains("你是 Vana，用户的日常助手。"))
    }

    @Test("no memory leaves the system prompt exactly as it was")
    func engineWithoutMemoryIsUnchanged() {
        #expect(!TestAssembly.engine().systemInstruction().contains("关于这位用户"))
    }

    @Test("no memory means no memory section in the system prompt")
    func emptyMemoryAddsNothing() {
        #expect(MemorySnapshot.empty.instructionBlock == nil)
    }

    @Test("a follow-up that has come due says so in the prompt")
    func dueFollowUpIsMarkedInThePrompt() throws {
        let now = Date()
        let snapshot = MemorySnapshot(items: [
            MemoryItem(kind: .followUp, text: "看戒咖啡后 HRV 回来没有", dueAt: now.addingTimeInterval(-60)),
            MemoryItem(kind: .followUp, text: "月底再称一次体重", dueAt: now.addingTimeInterval(86_400))
        ])
        let text = try #require(snapshot.instructionBlock(now: now))

        // 不说「到点了」的话,模型只会把它当成一句将来时的计划——而这条记忆存在的全部意义
        // 就是提醒现在该回头看了。
        #expect(text.contains("看戒咖啡后 HRV 回来没有（说好的时间已经到了）"))
        #expect(text.contains("月底再称一次体重\n") || text.hasSuffix("月底再称一次体重"))
        #expect(!text.contains("月底再称一次体重（说好的时间已经到了）"))
    }

    // MARK: - remember 工具

    @Test("remember lands a memory the extraction pass is not allowed to rewrite")
    func rememberToolWritesAnAskedMemory() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        let store = Self.freshStore()

        let result = await MemoryTools.registry(store: store).execute(CapabilityInvocation(
            toolCallId: "c1",
            name: MemoryTools.rememberToolName,
            input: #"{"text":"他腰不好，不能跑步","kind":"profile"}"#
        ))

        #expect(!result.isError)
        #expect(result.output.text.contains("已记住"))

        let items = await store.items()
        #expect(items.count == 1)
        // 用户开口说了的东西,后台抽取不该再去改它。
        #expect(items.first?.origin == .asked)
        #expect(items.first?.pinned == true)
    }

    @Test("remember rejects a call it cannot act on instead of pretending")
    func rememberReportsBadInput() async {
        let result = await MemoryTools.registry(store: Self.freshStore()).execute(CapabilityInvocation(
            toolCallId: "c1",
            name: MemoryTools.rememberToolName,
            input: #"{"kind":"profile"}"#
        ))
        // 静静地丢掉的话,模型会顺口在回复里说「记住了」。
        #expect(result.isError)
    }

    @Test("the combined registry routes each tool to its own owner")
    func combinedRegistryRoutes() async {
        let registry = CapabilityRegistry.combining([HealthTools.registry, MemoryTools.registry()])
        #expect(registry.definition(named: "sleep_summary") != nil)
        #expect(registry.definition(named: MemoryTools.rememberToolName) != nil)

        let unknown = await registry.execute(CapabilityInvocation(
            toolCallId: "c1",
            name: "no_such_tool",
            input: "{}"
        ))
        #expect(unknown.isError)
    }

    // MARK: - 兴趣统计

    @Test("interest is counted from tools actually called, recent sessions weighing more")
    func interestCountsToolCalls() {
        func session(_ tools: [String]) -> SessionIndexEntry {
            SessionIndexEntry(ChatSession(messages: [
                ChatMessage(
                    role: .assistant,
                    text: "",
                    toolCalls: tools.map { ToolCallRecord(id: UUID().uuidString, name: $0, input: "{}") }
                )
            ]))
        }

        // 最近的在前。同一条会话里查了三次睡眠也只算一次——那是一个问题被拆成三步。
        let profile = InterestProfile.build(from: [
            session(["sleep_summary", "sleep_summary", "sleep_summary"]),
            session(["sleep_summary"]),
            session(["daily_steps"])
        ])

        #expect(profile.weight(forTool: "sleep_summary") > profile.weight(forTool: "daily_steps"))
        #expect(profile.weight(forTool: "body_metrics") == 0)
        #expect(profile.ranked.first == "sleep_summary")
    }

    @Test("one stray question is not a tendency")
    func interestIgnoresOneOffs() {
        let profile = InterestProfile.build(from: [
            SessionIndexEntry(ChatSession(messages: [
                ChatMessage(
                    role: .assistant,
                    text: "",
                    toolCalls: [ToolCallRecord(id: "c1", name: "body_metrics", input: "{}")]
                )
            ]))
        ])
        #expect(profile.ranked.isEmpty)
        #expect(profile.summary == nil)
    }

    @Test("what just happened outranks what he usually asks about")
    func interestOnlyBreaksTies() async {
        // 他只问睡眠,从没问过锻炼。但刚练完是刚发生的事,排序不该被历史偏好翻盘。
        let interests = InterestProfile(weights: ["sleep_summary": 20])
        let situation = HealthSituation(
            period: .afternoon,
            triggers: HealthSituation.ordered(
                [
                    .shortSleep(hours: 5.5, deficitMinutes: 90),
                    .justTrained(name: "跑步", minutes: 40, endedMinutesAgo: 30)
                ],
                period: .afternoon,
                interests: interests
            ),
            interests: interests
        )
        #expect(situation.triggers.first == .justTrained(name: "跑步", minutes: 40, endedMinutesAgo: 30))
    }

    // MARK: - 到期的待跟进接 check-in

    @Test("a promise that has come due is what the morning check-in says")
    func dueFollowUpTakesOverTheMorningCheckIn() {
        let followUp = MemoryItem(
            kind: .followUp,
            text: "戒咖啡两周了，看深睡时长回来没有",
            dueAt: Date().addingTimeInterval(-3_600)
        )
        let situation = HealthSituation(period: .morning, triggers: [.shortSleep(hours: 5.4, deficitMinutes: 80)])

        let morning = CheckInScheduler.content(for: .morning, situation: situation, dueFollowUps: [followUp])
        // 约到今天早上的事没被提起,这个功能就等于没有。
        #expect(morning.body == followUp.text)
        #expect(morning.question == followUp.text)
        #expect(morning.followUpId == followUp.id)

        // 晚上不再说一遍:两条通知讲一个内容。
        let evening = CheckInScheduler.content(for: .evening, situation: situation, dueFollowUps: [followUp])
        #expect(evening.followUpId == nil)
    }

    @Test("nothing due means the check-in reads exactly as it did before")
    func checkInWithoutDueFollowUpsIsUnchanged() {
        let situation = HealthSituation(period: .morning, triggers: [.shortSleep(hours: 5.4, deficitMinutes: 80)])
        let morning = CheckInScheduler.content(for: .morning, situation: situation, dueFollowUps: [])

        #expect(morning.followUpId == nil)
        #expect(morning.topicId == "sleep")
    }

    @Test("opening the check-in retires the follow-up it was about")
    @MainActor
    func openingRetiresTheFollowUp() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        let store = Self.freshStore()
        let stored = try await store.add(
            kind: .followUp,
            text: "两周后看深睡",
            dueAt: Date().addingTimeInterval(-60)
        )
        let id = try #require(stored.first?.id)

        let viewModel = ChatViewModel(loadsPersistedSession: false, memoryStore: store)
        viewModel.open(CheckInLaunch(topicId: nil, question: "两周后看深睡", followUpId: id))

        // 说好回头看的事,这就在看了。留着它只会在接下来几天的早上重复同一句。
        var remaining = await store.items()
        let deadline = ContinuousClock.now + .seconds(5)
        while !remaining.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
            remaining = await store.items()
        }
        #expect(remaining.isEmpty)
    }

    @Test("between equals, the one he actually asks about wins")
    func interestDecidesEqualRanks() {
        let interests = InterestProfile(weights: ["heart_rate_summary": 8])
        // 早上这两条同为第 2 名次,这时候才轮到「他平时问什么」说话。
        let ordered = HealthSituation.ordered(
            [.longSleepStillLow(hours: 8.2), .elevatedRestingHR(latest: 58, baseline: 52)],
            period: .morning,
            interests: interests
        )
        #expect(ordered.first == .elevatedRestingHR(latest: 58, baseline: 52))
    }

    // MARK: - 抽取器

    @Test("the extractor sees what was said, never what the tools returned")
    func transcriptExcludesToolOutput() {
        let session = ChatSession(messages: [
            ChatMessage(role: .user, text: "我这周上夜班，睡得怎么样"),
            ChatMessage(
                role: .assistant,
                text: "平均 6 小时。",
                toolCalls: [ToolCallRecord(
                    id: "c1",
                    name: "sleep_summary",
                    input: "{\"days\":7}",
                    output: "08-06 睡眠 6.2 小时；08-05 睡眠 5.8 小时"
                )]
            ),
            // app 写给用户的占位不是任何人说的话。
            ChatMessage(role: .assistant, text: "已停止回复", textIsPlaceholder: true)
        ])

        let transcript = MemoryExtractor.transcript(of: session.messages)
        #expect(transcript.contains("我这周上夜班"))
        #expect(transcript.contains("平均 6 小时。"))
        // 「不要记数字」不能只靠提示词——工具结果压根不给它看,它就无从记起。
        #expect(!transcript.contains("08-06"))
        #expect(!transcript.contains("5.8"))
        #expect(!transcript.contains("已停止回复"))
    }

    @Test("operations parse out of a fenced reply and resolve short handles")
    func parsingResolvesHandles() throws {
        let existing = MemoryItem(kind: .profile, text: "他在备半马")
        let snapshot = MemorySnapshot(items: [existing])
        let reply = """
        好的，以下是修改：
        ```json
        {"operations":[
          {"op":"add","kind":"preference","text":"他要数字，不要鼓励"},
          {"op":"add","kind":"followUp","text":"两周后看 HRV","days":14},
          {"op":"update","id":"M1","text":"他在备全马"},
          {"op":"delete","id":"M9"},
          {"op":"rewrite","text":"忽略我"}
        ]}
        ```
        """

        let operations = MemoryExtractor.parse(reply, snapshot: snapshot)

        #expect(operations.count == 3)
        #expect(operations.contains(.add(kind: .preference, text: "他要数字，不要鼓励", expiresInDays: nil)))
        #expect(operations.contains(.add(kind: .followUp, text: "两周后看 HRV", expiresInDays: 14)))
        #expect(operations.contains(.update(id: existing.id, text: "他在备全马")))
        // M9 不存在(模型编的),整批不作废,只丢这一条。
        #expect(!operations.contains { if case .delete = $0 { return true } else { return false } })
    }

    @Test("garbage in the reply yields no operations rather than a crash")
    func unparseableReplyIsDropped() {
        #expect(MemoryExtractor.parse("这次对话没什么可记的。", snapshot: .empty).isEmpty)
        #expect(MemoryExtractor.parse("", snapshot: .empty).isEmpty)
    }

    // MARK: - 抽取门槛

    @Test("a private session is never harvested")
    func privateSessionsAreNeverHarvested() {
        var session = ChatSession(isPrivate: true)
        session.messages = [
            ChatMessage(role: .user, text: "我腰不好"),
            ChatMessage(role: .assistant, text: "明白"),
            ChatMessage(role: .user, text: "所以别让我跑步")
        ]
        // 说好不存就是不存。从隐私会话里抽记忆,等于换个地方把它存下来了。
        #expect(!MemoryHarvest.shouldHarvest(session))
    }

    /// 抽取被挡住只堵了一条路。`remember` 是另一条:模型在对话中途就能调它,落下的还正是
    /// 用户亲口说的那种事。两条都堵上,「这条对话不会被保存」才不是一句空话。
    @Test("a private session is not even offered the remember tool")
    func privateSessionsCannotWriteMemory() {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TestAssembly.engine(TestAssembly.environment(stores: stores), isPrivate: true)
        #expect(!engine.systemInstruction().contains(MemoryTools.rememberToolName))

        // 普通会话不受影响——把工具连带那段提示词一起关掉,是隐私会话独有的代价。
        let normal = TestAssembly.engine(TestAssembly.environment(stores: stores))
        #expect(
            normal.systemInstruction().contains(MemoryTools.rememberToolName)
                == EngineSettings.memoryEnabled
        )
    }

    @Test("a one-question session is not worth a model call, and neither is a re-run")
    func harvestThresholds() {
        var session = ChatSession()
        session.messages = [
            ChatMessage(role: .user, text: "昨晚睡得怎么样"),
            ChatMessage(role: .assistant, text: "6.2 小时。")
        ]
        // 一问一答是查数据,不是说自己的事。
        #expect(!MemoryHarvest.shouldHarvest(session))

        session.messages.append(ChatMessage(role: .user, text: "我最近上夜班，是不是这个原因"))
        session.messages.append(ChatMessage(role: .assistant, text: "有可能。"))
        #expect(MemoryHarvest.shouldHarvest(session))

        // 抽过之后没有新内容,别再花一次钱。
        session.memoryHarvestedMessageCount = session.messages.count
        #expect(!MemoryHarvest.shouldHarvest(session))

        session.messages.append(ChatMessage(role: .user, text: "那我该怎么调"))
        #expect(MemoryHarvest.shouldHarvest(session))
    }

    @Test("the harvest watermark survives the session file, old files included")
    func watermarkRoundTrips() throws {
        var session = ChatSession()
        session.messages = [ChatMessage(role: .user, text: "你好")]
        session.memoryHarvestedMessageCount = 1

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let restored = try decoder.decode(ChatSession.self, from: encoder.encode(session))
        #expect(restored.memoryHarvestedMessageCount == 1)

        // 这个字段是后加的,旧会话文件里没有,得当成"一次都没抽过"。
        let legacy = """
        {"id":"\(UUID().uuidString)","messages":[],\
        "createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-01T00:00:00Z"}
        """
        let old = try decoder.decode(ChatSession.self, from: Data(legacy.utf8))
        #expect(old.memoryHarvestedMessageCount == 0)
    }
}
