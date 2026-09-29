import Foundation
import Testing
import AgentRuntime

@testable import Vana

private func freshTasks() -> TaskStore {
    TaskStore(directory: URL.temporaryDirectory.appending(path: "vana-tasks-\(UUID().uuidString)", directoryHint: .isDirectory))
}

private final class RecordingScheduling: ReminderScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var _scheduled: [UUID] = []
    private var _cancelled: [UUID] = []
    var scheduled: [UUID] { lock.withLock { _scheduled } }
    var cancelled: [UUID] { lock.withLock { _cancelled } }
    func schedule(_ task: TaskItem, tenantId: UUID) async { lock.withLock { _scheduled.append(task.id) } }
    func cancel(_ taskId: UUID) async { lock.withLock { _cancelled.append(taskId) } }
}

private struct FakeJobs: JobControls {
    var autoStart = false
    func start(_ taskId: UUID) async {}
}

private let shanghai: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}()

@Suite("Reminder rules")
struct ReminderRulesTests {
    private static func date(_ text: String, _ calendar: Calendar = shanghai) -> Date {
        ReminderRules.parseLocal(text, calendar: calendar)!
    }

    @Test func localTimesParseInTheirOwnTimeZone() throws {
        let parsed = try #require(ReminderRules.parseLocal("2026-10-01T20:00", calendar: shanghai))
        #expect(shanghai.component(.hour, from: parsed) == 20)
        #expect(ReminderRules.parseLocal("2026-10-01 20:00", calendar: shanghai) == parsed)
        #expect(ReminderRules.parseLocal("2026-10-01T20:00:00", calendar: shanghai) == parsed)
        #expect(ReminderRules.parseLocal("明晚八点", calendar: shanghai) == nil)
        #expect(ReminderRules.parseLocal("2026-02-30T20:00", calendar: shanghai) == nil)
    }

    /// 重复提醒按墙上时间推,不是加 24 小时:夏令时那一天照样是早上 8 点。
    @Test func dailyRepeatKeepsTheWallClockAcrossDaylightSaving() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let due = Self.date("2026-03-07T08:00", newYork)
        let next = try #require(ReminderRules.nextOccurrence(dueAt: due, repeatRule: .daily, after: due.addingTimeInterval(86_400), calendar: newYork))
        #expect(newYork.component(.hour, from: next) == 8)
        #expect(newYork.component(.day, from: next) == 9)
    }

    @Test func weeklyRepeatLandsOnTheSameWeekday() throws {
        let due = Self.date("2026-10-05T09:00")
        let next = try #require(ReminderRules.nextOccurrence(dueAt: due, repeatRule: .weekly, after: due, calendar: shanghai))
        #expect(shanghai.component(.weekday, from: next) == shanghai.component(.weekday, from: due))
        #expect(next.timeIntervalSince(due) == 7 * 86_400)
        #expect(ReminderRules.nextOccurrence(dueAt: due, repeatRule: .none, after: due, calendar: shanghai) == nil)
    }

    @Test func afterFiringARepeatMovesOnAndAOneOffIsDone() {
        var repeating = TaskItem(kind: .reminder, title: "喝水", status: .queued)
        repeating.dueAt = Self.date("2026-10-01T09:00")
        repeating.repeatRule = .daily
        let moved = ReminderRules.afterFiring(repeating, firedAt: Self.date("2026-10-01T09:01"), calendar: shanghai)
        #expect(moved.status == .queued)
        #expect(moved.dueAt == Self.date("2026-10-02T09:00"))

        var once = repeating
        once.repeatRule = .none
        #expect(ReminderRules.afterFiring(once, firedAt: Self.date("2026-10-01T09:01"), calendar: shanghai).status == .done)
    }

    @Test func describeSaysTodayTomorrowOrTheDate() {
        let now = Self.date("2026-10-01T10:00")
        #expect(ReminderRules.describe(Self.date("2026-10-01T20:00"), now: now, calendar: shanghai) == "今天 20:00")
        #expect(ReminderRules.describe(Self.date("2026-10-02T09:05"), now: now, calendar: shanghai) == "明天 09:05")
        #expect(ReminderRules.describe(Self.date("2026-12-24T18:00"), now: now, calendar: shanghai) == "12月24日 18:00")
        #expect(ReminderRules.describe(Self.date("2027-01-03T09:00"), now: now, calendar: shanghai) == "2027年1月3日 09:00")
    }

    /// 到点只补一条主动消息,不调模型;重复的挪到下一次。过点很久才补上的标明「错过的」。
    @Test func catchUpPostsAProactiveMessageAndAdvances() async {
        let tasks = freshTasks()
        let thread = ThreadStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let now = Self.date("2026-10-01T09:30")
        var daily = TaskItem(kind: .reminder, title: "吃早饭", status: .queued)
        daily.dueAt = Self.date("2026-10-01T09:00")
        daily.repeatRule = .daily
        var later = TaskItem(kind: .reminder, title: "晚上的事", status: .queued)
        later.dueAt = Self.date("2026-10-01T20:00")
        await tasks.add(daily)
        await tasks.add(later)

        let fired = await ReminderScheduler.catchUp(tasks: tasks, thread: thread, now: now, calendar: shanghai)
        #expect(fired == 1)
        let messages = await thread.loadTail().messages
        #expect(messages.map(\.text) == ["错过的提醒：吃早饭"])
        #expect(messages.first?.origin == .reminder)
        #expect(await tasks.get(daily.id)?.dueAt == Self.date("2026-10-02T09:00"))
        #expect(await tasks.get(later.id)?.dueAt == later.dueAt)

        // 幂等:再跑一次不会再补一条。
        #expect(await ReminderScheduler.catchUp(tasks: tasks, thread: thread, now: now, calendar: shanghai) == 0)
    }
}

@Suite("Task store")
struct TaskStoreTests {
    @Test func tasksSurviveAFreshInstanceAndUnknownOnesAreKept() async throws {
        let directory = URL.temporaryDirectory.appending(path: "vana-tasks-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: TaskStore.fileName)
        try Data("""
        [{"id":"\(UUID().uuidString)","kind":"fromTheFuture","title":"x","status":"queued"}]
        """.utf8).write(to: url)
        let store = TaskStore(directory: directory)
        #expect(await store.all().isEmpty)
        await store.add(TaskItem(kind: .goal, title: "备半马", status: .running))

        let reopened = TaskStore(directory: directory)
        #expect(await reopened.all().map(\.title) == ["备半马"])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("fromTheFuture"))
    }

    @Test func aHandleFindsExactlyOneOrNothing() async {
        let store = freshTasks()
        let task = await store.add(TaskItem(kind: .reminder, title: "a", status: .queued))
        #expect(await store.find(task.handle)?.id == task.id)
        #expect(await store.find(task.id.uuidString)?.id == task.id)
        #expect(await store.find("") == nil)
        #expect(await store.find("zzzzzzzz") == nil)
    }
}

@Suite("Task tools", .serialized)
struct TasksToolsTests {
    private static let now = ReminderRules.parseLocal("2026-10-01T10:00", calendar: shanghai)!

    private static func environment(_ store: TaskStore, _ scheduling: RecordingScheduling = RecordingScheduling(), jobs: (any JobControls)? = nil) -> TasksEnvironment {
        TasksEnvironment(store: store, scheduling: scheduling, tenantId: UUID(), now: { now }, calendar: shanghai, jobs: jobs)
    }

    private static func call(_ registry: CapabilityRegistry, _ name: String, _ input: String) async -> CapabilityExecutionResult {
        await registry.execute(CapabilityInvocation(toolCallId: "1", name: name, input: input))
    }

    @Test func getCurrentTimeSaysTheLocalTimeAndZone() {
        let text = TasksTools.getTime(Self.environment(freshTasks())).output.text
        #expect(text == "现在是 2026-10-01 10:00 星期四（Asia/Shanghai）。")
    }

    @Test func createReminderStoresAndSchedules() async throws {
        let store = freshTasks()
        let scheduling = RecordingScheduling()
        let registry = TasksTools.registry(Self.environment(store, scheduling))
        let result = await Self.call(registry, TasksTools.createReminderToolName, #"{"text":"给妈妈打电话","at":"2026-10-01T20:00","repeat":"weekly"}"#)
        #expect(!result.isError)
        #expect(result.output.text.contains("今天 20:00"))
        #expect(result.output.text.contains("每周四重复"))
        let task = try #require(await store.all().first)
        #expect(task.repeatRule == .weekly)
        #expect(scheduling.scheduled == [task.id])
    }

    @Test func aTimeInThePastIsRefusedWithAHint() async {
        let registry = TasksTools.registry(Self.environment(freshTasks()))
        let result = await Self.call(registry, TasksTools.createReminderToolName, #"{"text":"x","at":"2026-10-01T09:00"}"#)
        #expect(result.isError)
        #expect(result.output.text.contains("get_current_time"))
        let missing = await Self.call(registry, TasksTools.createReminderToolName, #"{"text":"x"}"#)
        #expect(missing.isError)
    }

    @Test func listUpdateAndCancelGoByHandle() async throws {
        let store = freshTasks()
        let scheduling = RecordingScheduling()
        let registry = TasksTools.registry(Self.environment(store, scheduling))
        _ = await Self.call(registry, TasksTools.createReminderToolName, #"{"text":"带伞","in_minutes":60}"#)
        let task = try #require(await store.all().first)
        let listed = await Self.call(registry, TasksTools.listToolName, "{}")
        #expect(listed.output.text.contains(task.handle))

        let moved = await Self.call(registry, TasksTools.updateTaskToolName, "{\"id\":\"\(task.handle)\",\"action\":\"reschedule\",\"in_minutes\":120}")
        #expect(!moved.isError)
        #expect(await store.get(task.id)?.dueAt == Self.now.addingTimeInterval(120 * 60))

        let cancelled = await Self.call(registry, TasksTools.updateTaskToolName, "{\"id\":\"\(task.handle)\",\"action\":\"cancel\"}")
        #expect(!cancelled.isError)
        #expect(await store.get(task.id)?.status == .cancelled)
        #expect(scheduling.cancelled.contains(task.id))
    }

    @Test func goalsAreCappedAndDeduplicated() async {
        let store = freshTasks()
        let registry = TasksTools.registry(Self.environment(store))
        for index in 0..<TasksTools.maxActiveGoals {
            #expect(!(await Self.call(registry, TasksTools.createGoalToolName, "{\"title\":\"目标\(index)\"}")).isError)
        }
        #expect(await Self.call(registry, TasksTools.createGoalToolName, #"{"title":"再一个"}"#).isError)
        #expect(await Self.call(registry, TasksTools.createGoalToolName, #"{"title":"目标0"}"#).isError)
    }

    @Test func updateGoalTicksStepsAndRecordsProgress() async throws {
        let store = freshTasks()
        let registry = TasksTools.registry(Self.environment(store))
        _ = await Self.call(registry, TasksTools.createGoalToolName, #"{"title":"备半马","plan":["每周跑三次","买双跑鞋"]}"#)
        let goal = try #require(await store.all().first)
        let result = await Self.call(
            registry,
            TasksTools.updateGoalToolName,
            "{\"id\":\"\(goal.handle)\",\"complete_plan\":[\"跑鞋\",\"不存在的\"],\"note\":\"跑了 10 公里\"}"
        )
        #expect(result.output.text.contains("步骤 1/2"))
        #expect(result.output.text.contains("不存在的"))
        let updated = try #require(await store.get(goal.id))
        #expect(updated.notes.map(\.text) == ["跑了 10 公里"])
    }

    /// `start_task` 只放一张确认卡:状态是「等你确认」,工具的回答里明说不要说已经开始了。
    @Test func startTaskOnlyProposes() async throws {
        let store = freshTasks()
        let registry = SubagentTools.startTaskRegistry(Self.environment(store, jobs: FakeJobs()))
        let result = await Self.call(registry, SubagentTools.startToolName, #"{"title":"比较三款净化器","brief":"比较价格、噪音和滤网成本"}"#)
        #expect(!result.isError)
        #expect(result.output.text.contains("不要说已经开始了"))
        let task = try #require(await store.all().first)
        #expect(task.status == .proposed)
        #expect(ToolCallRecord.startedTaskId(fromToolMetadata: result.output.metadata) == task.id)
    }

    @Test func startTaskRespectsTheQueueLimit() async {
        let store = freshTasks()
        for index in 0..<SubagentLimits.maxQueued {
            await store.add(TaskItem(kind: .job, title: "在跑\(index)", status: .queued))
        }
        let registry = SubagentTools.startTaskRegistry(Self.environment(store, jobs: FakeJobs()))
        let result = await Self.call(registry, SubagentTools.startToolName, #"{"title":"又一件","brief":"x"}"#)
        #expect(result.isError)
    }
}

@Suite("Subagent", .serialized)
struct SubagentTests {
    private static let profile = AgentModelProfile(providerId: "anthropic", modelId: "claude-sonnet-5", contextWindow: 200_000, maxOutputTokens: 8_000)

    @Test func resultSplitsSummaryBodyAndSources() throws {
        let result = try #require(SubagentResult.parse("""
        三款里 A 最安静，B 滤网最便宜。

        A：噪音 30 分贝……
        B：滤网一年 200 元……

        来源：
        - example.com/a
        - example.com/b
        """))
        #expect(result.summary == "三款里 A 最安静，B 滤网最便宜。")
        #expect(result.body.contains("噪音 30 分贝"))
        #expect(result.sources == ["example.com/a", "example.com/b"])
        #expect(SubagentResult.parse("   ") == nil)
    }

    @Test func anOverlongFirstParagraphIsClippedButNothingIsLost() throws {
        let long = String(repeating: "很长的结论，", count: 40)
        let result = try #require(SubagentResult.parse(long))
        #expect(result.summary.count <= 160)
        #expect(result.body.contains(long))
    }

    private static func queuedJob(_ store: TaskStore) async -> TaskItem {
        var job = TaskItem(kind: .job, title: "整理资料", status: .queued)
        job.brief = "整理一下 X"
        return await store.add(job)
    }

    @Test func aRunRecordsTheResultAndProposals() async throws {
        let store = freshTasks()
        let job = await Self.queuedJob(store)
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(toolCalls: [CapabilityInvocation(
                toolCallId: "p1",
                name: SubagentTools.proposeToolName,
                input: #"{"kind":"goal","text":"每周读一本书"}"#
            )]),
            .init(text: "整理好了。\n\n细节在这里。")
        ])
        let runner = SubagentRunner(store: store, engineFor: { collector in
            LoopEngine(client: client, capabilities: SubagentTools.proposeRegistry(collector))
        })
        guard case .done(let done) = await runner.run(job.id) else {
            Issue.record("应该做完")
            return
        }
        #expect(done.status == .done)
        #expect(done.result?.summary == "整理好了。")
        #expect(done.result?.proposals.map(\.text) == ["每周读一本书"])
        #expect(done.attempts == 1)
        #expect(!done.steps.isEmpty)
        // 隔离:发出去的只有任务说明,没有主对话。
        #expect(client.requests.first?.prompt.messages.filter { $0.role == .user }.count == 1)
    }

    @Test func aFailingModelFailsTheTaskWithoutRetrying() async throws {
        let store = freshTasks()
        let job = await Self.queuedJob(store)
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(finishReason: .init(unified: .error), failureMessage: "invalid api key")
        ])
        let runner = SubagentRunner(store: store, engineFor: { _ in LoopEngine(client: client, capabilities: .empty) })
        guard case .failed(let failed) = await runner.run(job.id) else {
            Issue.record("应该失败")
            return
        }
        #expect(failed.status == .failed)
        #expect(failed.error?.isEmpty == false)
    }

    @Test func aRunThatTakesTooLongIsStopped() async throws {
        let store = freshTasks()
        let job = await Self.queuedJob(store)
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(text: "慢", beforeResponding: { try await Task.sleep(for: .seconds(5)) })
        ])
        var runner = SubagentRunner(store: store, engineFor: { _ in LoopEngine(client: client, capabilities: .empty) })
        runner.wallClock = .milliseconds(100)
        guard case .failed(let failed) = await runner.run(job.id) else {
            Issue.record("应该超时")
            return
        }
        #expect(failed.error?.contains("5 分钟") == true)
    }

    @Test func onlyQueuedJobsRun() async {
        let store = freshTasks()
        let proposed = await store.add(TaskItem(kind: .job, title: "没点开始", status: .proposed))
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "不该跑")])
        let runner = SubagentRunner(store: store, engineFor: { _ in LoopEngine(client: client, capabilities: .empty) })
        guard case .skipped = await runner.run(proposed.id) else {
            Issue.record("没点开始的不该跑")
            return
        }
        #expect(client.requests.isEmpty)
    }

    /// 后台路挂不上写盘的、要用户参与的工具:后台助手不能再派后台助手,也不能自己设提醒。
    @Test func theBackgroundRouteCannotWriteOrDelegate() {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = TestAssembly.environment(stores: stores)
        environment.tasks = TasksEnvironment(store: stores.tasks, scheduling: NoReminderScheduling(), tenantId: UUID(), jobs: FakeJobs())
        let collector = ProposalCollector()
        let engine = AIKitEngine(
            plugins: PluginRegistry.agentPlugins(environment, route: .background) + [SubagentPlugin(collector: collector)],
            pluginContext: PluginRegistry.context(for: environment, route: .background, isPrivate: false)
        )
        let names = engine.capabilityRegistry.definitions.map(\.name)
        #expect(names.contains(SubagentTools.proposeToolName))
        for forbidden in [SubagentTools.startToolName, TasksTools.createReminderToolName, MemoryTools.rememberToolName, AskUserTools.askToolName] {
            #expect(!names.contains(forbidden))
        }
        #expect(engine.systemInstruction().contains("你现在是 Vana 派出去的后台助手"))
    }

    @Test func limitsCountQueuedAndToday() {
        let now = Date()
        var jobs = (0..<SubagentLimits.maxRunsPerDay).map { index -> TaskItem in
            var job = TaskItem(kind: .job, title: "\(index)", status: .done)
            job.startedAt = now
            return job
        }
        #expect(SubagentLimits.problem(jobs, now: now)?.contains("今天") == true)
        jobs = []
        #expect(SubagentLimits.problem(jobs, now: now) == nil)
    }

    @Test func proposalsAreCapped() async {
        let collector = ProposalCollector()
        let registry = SubagentTools.proposeRegistry(collector)
        for _ in 0..<ProposalCollector.maxProposals {
            _ = await registry.execute(CapabilityInvocation(toolCallId: "1", name: SubagentTools.proposeToolName, input: #"{"kind":"memory","text":"x"}"#))
        }
        let over = await registry.execute(CapabilityInvocation(toolCallId: "1", name: SubagentTools.proposeToolName, input: #"{"kind":"memory","text":"x"}"#))
        #expect(over.isError)
        #expect(collector.all.count == ProposalCollector.maxProposals)
    }

    /// 「照做」才真的写:提醒走手动添加同一条路,记忆按用户自己写的算。
    @Test func decidingAProposalAppliesOrDismissesIt() async throws {
        let store = freshTasks()
        var job = TaskItem(kind: .job, title: "x", status: .done)
        job.result = .init(summary: "s", proposals: [
            .init(kind: "goal", text: "每周读一本书"),
            .init(kind: "memory", text: "他喜欢科幻")
        ])
        await store.add(job)
        let memory = MemoryStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let env = TasksEnvironment(store: store, scheduling: NoReminderScheduling(), tenantId: UUID())
        let goalProposal = try #require(job.result?.proposals[0])
        let memoryProposal = try #require(job.result?.proposals[1])

        #expect(await TaskActions.decide(env, memory: memory, taskId: job.id, proposalId: goalProposal.id, accept: true) == nil)
        #expect(await TaskActions.decide(env, memory: memory, taskId: job.id, proposalId: memoryProposal.id, accept: false) == nil)
        #expect(await store.all().contains { $0.kind == .goal && $0.title == "每周读一本书" })
        #expect(await memory.items().isEmpty)
        let statuses = await store.get(job.id)?.result?.proposals.map(\.status)
        #expect(statuses == [.accepted, .dismissed])
    }

    @Test func weeklyReviewOnlyForGoalsThatAskedForIt() {
        let now = Date()
        var on = TaskItem(kind: .goal, title: "备半马", status: .running, createdAt: now.addingTimeInterval(-8 * 86_400))
        on.digestEnabled = true
        on.updatedAt = now.addingTimeInterval(-86_400)
        var off = on
        off.id = UUID()
        off.digestEnabled = false
        var recent = on
        recent.id = UUID()
        recent.lastDigestAt = now.addingTimeInterval(-86_400)
        #expect(GoalDigest.due([on, off, recent], now: now).map(\.id) == [on.id])
        #expect(GoalDigest.brief(on, now: now).contains("备半马"))
    }
}

@Suite("Today")
struct TodayTests {
    @Test func cardsComeFromLocalDataInPriorityOrder() {
        let now = Date()
        var overdue = TaskItem(kind: .reminder, title: "已过点", status: .queued)
        overdue.dueAt = now.addingTimeInterval(-600)
        var later = TaskItem(kind: .reminder, title: "今天晚点", status: .queued)
        later.dueAt = min(now.addingTimeInterval(60), ReminderRules.endOfDay(now, calendar: .current).addingTimeInterval(-1))
        var nextWeek = TaskItem(kind: .reminder, title: "下周", status: .queued)
        nextWeek.dueAt = now.addingTimeInterval(7 * 86_400)
        let proposed = TaskItem(kind: .job, title: "等你确认的", status: .proposed)
        let goal = TaskItem(kind: .goal, title: "目标", status: .running)

        let cards = PluginRegistry.todayCards(TodayContext(
            now: now,
            tasks: [goal, nextWeek, later, overdue, proposed],
            dueFollowUps: [MemoryItem(kind: .followUp, text: "两周后看深睡", dueAt: now)],
            isEnabled: { _ in true }
        ))
        #expect(cards.map(\.title).prefix(3) == ["已过点", "等你确认的", "今天晚点"])
        #expect(!cards.contains { $0.title == "下周" })
        #expect(cards.contains { $0.title == "目标" })
        #expect(TodaySummary.attention(cards) == 3)
        #expect(TodaySummary.line([]) == nil)
    }

    @Test func aSwitchedOffPluginContributesNoCards() {
        let cards = PluginRegistry.todayCards(TodayContext(
            now: Date(),
            tasks: [],
            dueFollowUps: [],
            healthSummary: "昨晚睡了 7 小时",
            isEnabled: { $0 != PluginIds.health }
        ))
        #expect(cards.isEmpty)
    }
}
