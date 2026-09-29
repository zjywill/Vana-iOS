import Foundation
import Testing

@testable import Vana

/// 目标线:用户自己开的一件长期的事。
///
/// 和 check-in 那条内置线的区别全在"这是他的东西":名字他起、断得更宽、删要整条删。
/// 这里盯的就是这几处,外加一条最容易写坏的——**按线合并**。一条「减脂」分成三段之后,
/// 列表里排出三条「减脂计划」,正是这个功能要消掉的那种碎片。
@Suite("GoalThread")
struct GoalThreadTests {

    private static func freshStore() -> SessionStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionStore(parent: directory)
    }

    private static let day: TimeInterval = 86_400

    private static func segment(
        _ thread: SessionThread,
        title: String,
        messages: Int = 2,
        updatedAt: Date
    ) -> ChatSession {
        ChatSession(
            messages: (0..<messages).map {
                ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "第\($0)条")
            },
            threadId: thread.id,
            threadTitle: title,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - 身份

    @Test("a goal thread id round trips like the built-in ones")
    func goalThreadIdRoundTrips() {
        let thread = SessionThread.goal(UUID())
        #expect(SessionThread(id: thread.id) == thread)
        #expect(thread.isGoal)
        #expect(SessionThread.checkIn.isGoal == false)
        // 内置线和目标线的前缀不能互相认。认错了,check-in 会被当成一条能改名能整条删的目标。
        #expect(SessionThread(id: "goal:不是uuid") == nil)
    }

    @Test("the user's own name wins over the built-in fallback")
    func userNameWinsOverFallback() {
        let named = ChatSession(
            messages: [ChatMessage(role: .user, text: "这周怎么样")],
            threadId: SessionThread.goal(UUID()).id,
            threadTitle: "减脂",
            createdAt: Date()
        )
        #expect(named.title.contains("减脂"))
        // 名字丢了也不能露出首条消息当标题——那正是延续线要消掉的东西。
        var unnamed = named
        unnamed.threadTitle = nil
        #expect(unnamed.title.contains(SessionThread.goal(UUID()).title))
        #expect(!unnamed.title.contains("这周怎么样"))
    }

    // MARK: - 合并

    @Test("three segments of one goal are one row, not three")
    func segmentsMergeIntoOneGoal() async throws {
        let store = Self.freshStore()
        let thread = SessionThread.goal(UUID())
        let now = Date()
        var newest: ChatSession?
        for offset in [40, 20, 0] {
            let segment = Self.segment(
                thread,
                title: "减脂",
                messages: 4,
                updatedAt: now - Double(offset) * Self.day
            )
            if offset == 0 { newest = segment }
            try await store.save(segment)
        }

        let goals = await store.goals()
        #expect(goals.count == 1)
        let goal = try #require(goals.first)
        #expect(goal.title == "减脂")
        #expect(goal.segmentCount == 3)
        // 条数是整条线的,不是最新那一段的——那是这件事聊了多久的度量。
        #expect(goal.messageCount == 12)
        // 时间和"点进去落在哪一段"都取最新那段,不是最早开的那段。
        #expect(goal.latestSessionId == newest?.id)
        #expect(abs(goal.updatedAt.timeIntervalSince(now)) < 1)
    }

    @Test("check-in and follow-up threads are not goals")
    func builtInThreadsAreNotGoals() async throws {
        let store = Self.freshStore()
        let now = Date()
        try await store.save(Self.segment(.checkIn, title: "不该出现", updatedAt: now))
        try await store.save(Self.segment(.followUp(UUID()), title: "也不该", updatedAt: now))

        // 目标区是"他自己开的那几件事"。把 check-in 混进去,那个区就没意义了。
        #expect(await store.goals().isEmpty)
    }

    // MARK: - 断得比 check-in 宽

    @Test("a goal survives a week away; the daily check-in does not")
    func goalsAreMorePatientThanCheckIns() async throws {
        let store = Self.freshStore()
        let now = Date()
        let goal = SessionThread.goal(UUID())
        try await store.save(Self.segment(goal, title: "备半马", updatedAt: now - 7 * Self.day))
        try await store.save(Self.segment(.checkIn, title: "", updatedAt: now - 7 * Self.day))

        // 「减脂」这件事请一周假回来还是同一件事;而每天的 check-in 隔一周就是新的一段了。
        #expect(await store.openThread(goal, now: now) != nil)
        #expect(await store.openThread(.checkIn, now: now) == nil)
    }

    @Test("a goal left alone for a month starts a new segment, keeping the old one")
    func staleGoalStartsANewSegment() async throws {
        let store = Self.freshStore()
        let now = Date()
        let goal = SessionThread.goal(UUID())
        try await store.save(Self.segment(goal, title: "备半马", updatedAt: now - 30 * Self.day))

        #expect(await store.openThread(goal, now: now) == nil)
        // 另起一段不是丢历史:上一段一条不少地留着,`search_sessions` 翻得回去。
        #expect(await store.goals().count == 1)
    }

    // MARK: - 改名与整条删

    @Test("renaming reaches every segment, not just the latest")
    func renameReachesEverySegment() async throws {
        let store = Self.freshStore()
        let thread = SessionThread.goal(UUID())
        let now = Date()
        for offset in [30, 0] {
            try await store.save(Self.segment(thread, title: "减脂", updatedAt: now - Double(offset) * Self.day))
        }

        try await store.renameThread(thread, to: "减脂 · 第二轮")

        // 只改最新那段的话,旧的几段会以旧名字留在召回结果里——模型翻到的和用户看到的
        // 就成了两件事。
        let goals = await store.goals()
        #expect(goals.first?.title == "减脂 · 第二轮")
        #expect(goals.first?.segmentCount == 2)
    }

    @Test("deleting a goal takes all of its segments with it")
    func deletingTakesEverySegment() async throws {
        let store = Self.freshStore()
        let thread = SessionThread.goal(UUID())
        let now = Date()
        for offset in [30, 0] {
            try await store.save(Self.segment(thread, title: "减脂", updatedAt: now - Double(offset) * Self.day))
        }
        try await store.save(ChatSession(
            messages: [ChatMessage(role: .user, text: "无关的一条")],
            createdAt: now
        ))

        try await store.deleteThread(thread)

        // 只删最新那段的话,剩下那段会以「减脂 · 7月10日起」的样子留在列表里,像没删干净。
        #expect(await store.goals().isEmpty)
        #expect(await store.summaries().count == 1)
        // 删掉的对话必须立刻从召回里消失。
        #expect(await store.recallIndex().search(query: "减脂").isEmpty)
    }

    // MARK: - 模型知不知道自己在哪条线里

    @Test("the goal is named in the system prompt, with a nudge to look further back")
    func goalReachesTheSystemPrompt() {
        let instructions = TestAssembly.engine(TestAssembly.environment(goals: ["把作息掰回来"])).systemInstruction()

        // 不说这一句,模型会把它当成今天临时想问的一件事,而不是已经聊了三个星期的那件事。
        #expect(instructions.contains("把作息掰回来"))
        // 普通会话里不该多这一段。
        #expect(!TestAssembly.engine().systemInstruction().contains("几件长期的事"))
    }

    // MARK: - view model

    @Test("starting a goal does not leave an empty shell behind")
    @MainActor
    func startingAGoalPersistsNothingYet() async throws {
        let store = Self.freshStore()
        let viewModel = ChatViewModel(loadsPersistedSession: false, sessionStore: store)

        viewModel.startGoal(named: "  减脂  ")

        #expect(viewModel.session.thread?.isGoal == true)
        #expect(viewModel.session.threadTitle == "减脂")
        // 空会话不落盘那条规矩没有例外。用户问出第一句这条线才真正存在——比在列表里
        // 先摆一条什么都没有的「减脂」诚实。
        #expect(await store.summaries().isEmpty)
    }

    @Test("reopening a goal lands back in the segment it left off in")
    @MainActor
    func reopeningContinuesTheSegment() async throws {
        let store = Self.freshStore()
        let thread = SessionThread.goal(UUID())
        let existing = Self.segment(thread, title: "减脂", messages: 4, updatedAt: Date() - Self.day)
        try await store.save(existing)

        let viewModel = ChatViewModel(loadsPersistedSession: false, sessionStore: store)
        let goal = try #require(await store.goals().first)
        viewModel.openGoal(goal)
        try await waitUntil("接上那一段") { viewModel.session.id == existing.id }

        #expect(viewModel.messages.count == 4)
        #expect(viewModel.session.threadTitle == "减脂")
    }
}
