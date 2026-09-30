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
        [{"id":"\(UUID().uuidString)","kind":"fromTheFuture","title":"x","status":"queued"},
         {"id":"\(UUID().uuidString)","kind":"job","title":"以前的后台任务","status":"done","brief":"查一下"}]
        """.utf8).write(to: url)
        let store = TaskStore(directory: directory)
        #expect(await store.all().isEmpty)
        await store.add(TaskItem(kind: .goal, title: "备半马", status: .running))

        let reopened = TaskStore(directory: directory)
        #expect(await reopened.all().map(\.title) == ["备半马"])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("fromTheFuture"))
        // 撤掉子 agent 之前存下来的后台任务:认不出 kind,原样留着,不再显示。
        #expect(try String(contentsOf: url, encoding: .utf8).contains("以前的后台任务"))
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

    private static func environment(_ store: TaskStore, _ scheduling: RecordingScheduling = RecordingScheduling()) -> TasksEnvironment {
        TasksEnvironment(store: store, scheduling: scheduling, tenantId: UUID(), now: { now }, calendar: shanghai)
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

    /// 后台路挂不上写盘的、要用户参与的工具,也没有派后台任务的那个——子 agent 撤掉之后,
    /// 后台只剩待跟进回访和收割那几轮,它们不该在用户不在场时替他设提醒、记东西、问他问题。
    @Test func theBackgroundRouteCannotWrite() {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        var environment = TestAssembly.environment(stores: stores)
        environment.tasks = TasksEnvironment(store: stores.tasks, scheduling: NoReminderScheduling(), tenantId: UUID())
        let engine = AIKitEngine(
            plugins: PluginRegistry.agentPlugins(environment, route: .background),
            pluginContext: PluginRegistry.context(for: environment, route: .background, isPrivate: false)
        )
        let names = engine.capabilityRegistry.definitions.map(\.name)
        for forbidden in ["start_task", "propose_action", TasksTools.createReminderToolName, MemoryTools.rememberToolName, AskUserTools.askToolName] {
            #expect(!names.contains(forbidden))
        }
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
        let goal = TaskItem(kind: .goal, title: "目标", status: .running)

        let cards = PluginRegistry.todayCards(TodayContext(
            now: now,
            tasks: [goal, nextWeek, later, overdue],
            dueFollowUps: [MemoryItem(kind: .followUp, text: "两周后看深睡", dueAt: now)],
            isEnabled: { _ in true }
        ))
        #expect(cards.map(\.title).prefix(2) == ["已过点", "今天晚点"])
        #expect(!cards.contains { $0.title == "下周" })
        // 目标在「今天」页自己那一节里整张列出来,这里再出一行就是同一件事摆两遍。
        #expect(!cards.contains { $0.title == "目标" })
        #expect(TodaySummary.attention(cards) == 2)
        // 那颗图标按类别上色:过点的和到点的不能是同一种颜色。
        let kinds = Dictionary(uniqueKeysWithValues: cards.map { ($0.title, $0.kind) })
        #expect(kinds["已过点"] == .overdue)
        #expect(kinds["今天晚点"] == .reminder)
        #expect(cards.contains { $0.kind == .followUp })
        // 「之后」那一节靠它把今天已经列过的提醒去掉。
        #expect(cards.first { $0.title == "已过点" }?.taskId == overdue.id)
        #expect(cards.first { $0.kind == .followUp }?.taskId == nil)
    }

    /// 「今天」页按 `kind` 把它排进「现在」那一节,点开是状况详情。
    @Test func theHealthStatusCardIsFindable() {
        let cards = PluginRegistry.todayCards(TodayContext(
            now: Date(), tasks: [], dueFollowUps: [], healthSummary: "昨晚睡了 7 小时", isEnabled: { _ in true }
        ))
        #expect(cards.first { $0.id == TodayCard.healthStatusId }?.kind == .health)
        #expect(cards.first { $0.id == TodayCard.healthStatusId }?.action == .openHealthStatus)
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

/// 设置归哪儿:关掉插件就没意义的那几件,归插件自己的详情页。
@Suite("Plugin settings")
struct PluginSettingsTests {
    @Test func healthOwnsItsPermissionCheckInsAndMedications() {
        let ids = HealthVanaPlugin().surfaces.map(\.id)
        #expect(ids == [PluginSurface.appleHealth, PluginSurface.medications, PluginSurface.checkIns, PluginSurface.family])
        #expect(NotesVanaPlugin().surfaces.map(\.id) == [PluginSurface.notes])
    }
}
