import Foundation
import AgentRuntime

/// 提醒、目标和「现在几点」要用的那点环境。
struct TasksEnvironment: Sendable {
    var store: TaskStore
    var scheduling: any ReminderScheduling = ReminderScheduler.shared
    var tenantId: UUID
    var now: @Sendable () -> Date = { Date() }
    var calendar: Calendar = .current
    /// 这一轮开始时进行中的目标。system 段那一块照它拼(装配是同步的,读盘不是)。
    var activeGoals: [TaskItem] = []
}

/// 提醒、目标和「现在几点」。
///
/// 精确时间**不进 system 段**(每分钟都变,会把请求前缀的缓存整个打掉),要知道现在几点就调
/// `get_current_time`。提醒到点只发通知、**不调模型**,所以这里的工具只管创建和管理,没有「到点
/// 执行」。写的那几个在装配时声明为 `.writeLocal`,不留痕浮层和后台那几轮都不会挂出去。
enum TasksTools {
    static let getTimeToolName = "get_current_time"
    static let createReminderToolName = "create_reminder"
    static let listToolName = "list_tasks"
    static let updateTaskToolName = "update_task"
    static let createGoalToolName = "create_goal"
    static let updateGoalToolName = "update_goal"

    static let readTools: Set<String> = [getTimeToolName, listToolName]

    /// 同时进行中的目标最多这么多:目标多了就没有目标了,system 段里那一小块也放不下。
    static let maxActiveGoals = 5
    static let maxTitleCharacters = 60

    static func registry(_ env: TasksEnvironment) -> CapabilityRegistry {
        CapabilityRegistry(definitions: [
            getTimeDefinition, createReminderDefinition, listDefinition,
            updateTaskDefinition, createGoalDefinition, updateGoalDefinition
        ]) { invocation in
            let input = try? RuntimeJSONValue.decode(from: invocation.input)
            switch invocation.name {
            case getTimeToolName: return getTime(env)
            case createReminderToolName: return await createReminder(env, input)
            case listToolName: return await list(env, input)
            case updateTaskToolName: return await updateTask(env, input)
            case createGoalToolName: return await createGoal(env, input)
            case updateGoalToolName: return await updateGoal(env, input)
            default: return .failure("不支持名为 \(invocation.name) 的工具。")
            }
        }
    }

    // MARK: - 定义

    private static func schema(_ properties: [String: RuntimeJSONValue], required: [String] = []) -> RuntimeJSONValue {
        .object([
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false)
        ])
    }

    private static func string(_ description: String) -> RuntimeJSONValue {
        .object(["type": "string", "description": .string(description)])
    }

    private static func integer(_ description: String, min: Int, max: Int) -> RuntimeJSONValue {
        .object(["type": "integer", "description": .string(description), "minimum": .int(min), "maximum": .int(max)])
    }

    private static func choice(_ description: String, _ values: [String]) -> RuntimeJSONValue {
        .object(["type": "string", "description": .string(description), "enum": .array(values.map { .string($0) })])
    }

    private static func strings(_ description: String) -> RuntimeJSONValue {
        .object(["type": "array", "description": .string(description), "items": .object(["type": "string"])])
    }

    private static let getTimeDefinition = CapabilityDefinition(
        name: getTimeToolName,
        description: "读取现在的日期、星期、时间和用户所在的时区。要把「明晚 8 点」「三天后」这类说法换算成具体时间之前先调用它。",
        inputSchema: schema([:])
    )

    private static let createReminderDefinition = CapabilityDefinition(
        name: createReminderToolName,
        description: "设一条提醒：到点手机会发一条通知。给 at（用户当地时间，形如 2026-10-01T20:00）或 in_minutes（多少分钟以后）二选一。"
            + "重复提醒用 repeat。提醒到点只发通知，不会再调用你。",
        inputSchema: schema([
            "text": string("提醒的内容，一句话，比如「给妈妈打电话」"),
            "at": string("用户当地时间，形如 2026-10-01T20:00"),
            "in_minutes": integer("多少分钟以后", min: 1, max: 60 * 24 * 30),
            "repeat": choice("重复方式，默认不重复", ["none", "daily", "weekly"])
        ], required: ["text"])
    )

    private static let listDefinition = CapabilityDefinition(
        name: listToolName,
        description: "列出进行中的提醒和目标，带短编号。要改或取消某一条之前先用它拿编号。",
        inputSchema: schema(["kind": choice("只看某一种，默认全部", ["all", "reminder", "goal"])])
    )

    private static let updateTaskDefinition = CapabilityDefinition(
        name: updateTaskToolName,
        description: "对一条提醒或目标做：complete 完成、cancel 取消、reschedule 改期（只有提醒能改期，给 at 或 in_minutes）。"
            + "按 list_tasks 给的短编号指到那一条。",
        inputSchema: schema([
            "id": string("短编号，来自 list_tasks"),
            "action": choice("要做什么", ["complete", "cancel", "reschedule"]),
            "at": string("改期用：用户当地时间，形如 2026-10-01T20:00"),
            "in_minutes": integer("改期用：多少分钟以后", min: 1, max: 60 * 24 * 30)
        ], required: ["id", "action"])
    )

    private static let createGoalDefinition = CapabilityDefinition(
        name: createGoalToolName,
        description: "把用户想长期坚持的一件事记成目标（备半马、学吉他、把作息调回来）。只在用户表示要长期做这件事时才建；"
            + "同时进行中的目标最多 \(maxActiveGoals) 个。",
        inputSchema: schema([
            "title": string("目标名称，短一点"),
            "why": string("他为什么要做这件事，一句话，可选"),
            "plan": strings("初步的几个步骤，可选")
        ], required: ["title"])
    )

    private static let updateGoalDefinition = CapabilityDefinition(
        name: updateGoalToolName,
        description: "更新一个目标：改名、改原因、加步骤、勾掉做完的步骤、记一条进展。按 list_tasks 或系统提示里给的短编号指到目标。",
        inputSchema: schema([
            "id": string("目标的短编号"),
            "title": string("新名称，可选"),
            "why": string("新的原因，可选"),
            "add_plan": strings("要加的步骤，可选"),
            "complete_plan": strings("做完了的步骤（写步骤原文的一部分即可），可选"),
            "note": string("一条进展记录，可选")
        ], required: ["id"])
    )

    // MARK: - 执行

    private static let weekdays = ["日", "一", "二", "三", "四", "五", "六"]

    static func getTime(_ env: TasksEnvironment) -> CapabilityExecutionResult {
        let now = env.now()
        let calendar = env.calendar
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let stamp = String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
        return .success("现在是 \(stamp) 星期\(weekdays[(parts.weekday ?? 1) - 1])（\(calendar.timeZone.identifier)）。")
    }

    /// 从 at / in_minutes 里取出目标时间;取不出来就给出该说的错话。
    private static func resolveTime(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) -> (Date?, String?) {
        let at = (input?["at"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = input?["in_minutes"]?.intValue
        let now = env.now()
        let due: Date
        if !at.isEmpty {
            guard let parsed = ReminderRules.parseLocal(at, calendar: env.calendar) else {
                return (nil, "看不懂这个时间「\(at)」。用用户当地时间，形如 2026-10-01T20:00。")
            }
            due = parsed
        } else if let minutes {
            due = now.addingTimeInterval(Double(minutes) * 60)
        } else {
            return (nil, "需要 at（具体时间）或 in_minutes（多少分钟以后）二选一。")
        }
        if due < now.addingTimeInterval(30) {
            return (nil, "这个时间已经过了或太近了（\(ReminderRules.describe(due, now: now, calendar: env.calendar))）。"
                + "先用 get_current_time 看现在几点，再给一个之后的时间。")
        }
        if due > now.addingTimeInterval(Double(ReminderRules.maxHorizonDays) * 86_400) {
            return (nil, "最远只能约到一年以内。")
        }
        return (due, nil)
    }

    private static func createReminder(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let text = (input?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .failure("create_reminder 需要提醒的内容 text。") }
        guard text.count <= maxTitleCharacters * 2 else { return .failure("提醒的内容太长了，压成一句话。") }
        let (due, error) = resolveTime(env, input)
        guard let due else { return .failure(error ?? "时间不对。") }
        let repeatRule = TaskItem.Repeat(rawValue: input?["repeat"]?.stringValue ?? "") ?? .none
        if await env.store.active().count(where: { $0.kind == .reminder }) >= ReminderRules.maxActiveReminders {
            return .failure("进行中的提醒已经有 \(ReminderRules.maxActiveReminders) 条了。先让用户清理一下。")
        }
        var task = TaskItem(kind: .reminder, title: text, status: .queued, createdAt: env.now())
        task.dueAt = due
        task.repeatRule = repeatRule
        await env.store.add(task)
        await env.scheduling.schedule(task, tenantId: env.tenantId)
        let when = ReminderRules.describe(due, now: env.now(), calendar: env.calendar)
        let every = ReminderRules.describeRepeat(repeatRule, dueAt: due, calendar: env.calendar)
        return .success("已设好提醒：\(text)，\(when)\(every.isEmpty ? "" : "，\(every)重复")。")
    }

    private static func kindLabel(_ kind: TaskItem.Kind) -> String {
        switch kind {
        case .reminder: "提醒"
        case .goal: "目标"
        }
    }

    private static func line(_ task: TaskItem, _ env: TasksEnvironment) -> String {
        switch task.kind {
        case .reminder:
            let due = task.dueAt.map { ReminderRules.describe($0, now: env.now(), calendar: env.calendar) } ?? ""
            let every = ReminderRules.describeRepeat(task.repeatRule, dueAt: task.dueAt, calendar: env.calendar)
            return "- \(task.handle) · \(due)\(every.isEmpty ? "" : "（\(every)）") · \(task.title)"
        case .goal:
            return "- \(task.handle) · \(task.title) · \(task.planProgress)"
        }
    }

    private static func list(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let kind = TaskItem.Kind(rawValue: input?["kind"]?.stringValue ?? "")
        let active = await env.store.active().filter { kind == nil || $0.kind == kind }
        guard !active.isEmpty else { return .success("现在没有进行中的提醒或目标。") }
        var lines: [String] = []
        for group in [TaskItem.Kind.reminder, .goal] {
            let items = active.filter { $0.kind == group }
            guard !items.isEmpty else { continue }
            lines.append("\(kindLabel(group))：")
            lines += items.sorted { ($0.dueAt ?? $0.createdAt) < ($1.dueAt ?? $1.createdAt) }.map { line($0, env) }
        }
        return .success(lines.joined(separator: "\n"))
    }

    private static func updateTask(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let handle = (input?["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let task = await env.store.find(handle) else {
            return .failure("没有找到编号为 \(handle) 的项。先用 list_tasks 拿编号。")
        }
        guard task.isActive else { return .failure("「\(task.title)」已经\(task.status.promptLabel)了。") }
        switch input?["action"]?.stringValue {
        case "complete":
            await env.scheduling.cancel(task.id)
            await env.store.update(task.id) { $0.status = .done }
            return .success("已完成：\(task.title)")
        case "cancel":
            await env.scheduling.cancel(task.id)
            await env.store.update(task.id) { $0.status = .cancelled }
            return .success("已取消：\(task.title)")
        case "reschedule":
            guard task.kind == .reminder else { return .failure("只有提醒能改期。") }
            let (due, error) = resolveTime(env, input)
            guard let due else { return .failure(error ?? "时间不对。") }
            guard let updated = await env.store.update(task.id, { $0.dueAt = due; $0.status = .queued }) else {
                return .failure("这一条已经不在了。")
            }
            await env.scheduling.cancel(task.id)
            await env.scheduling.schedule(updated, tenantId: env.tenantId)
            return .success("已改到 \(ReminderRules.describe(due, now: env.now(), calendar: env.calendar))：\(task.title)")
        default:
            return .failure("action 要是 complete、cancel 或 reschedule。")
        }
    }

    private static func createGoal(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let title = (input?["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .failure("create_goal 需要目标名称 title。") }
        guard title.count <= maxTitleCharacters else { return .failure("目标名称太长了，短一点。") }
        let active = await env.store.active().filter { $0.kind == .goal }
        guard active.count < maxActiveGoals else {
            return .failure("进行中的目标已经有 \(maxActiveGoals) 个了。先完成或取消一个，再建新的。")
        }
        guard !active.contains(where: { $0.title == title }) else {
            return .failure("已经有一个叫「\(title)」的目标了，用 update_goal 更新它。")
        }
        let plan = (input?["plan"]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var task = TaskItem(kind: .goal, title: title, status: .running, createdAt: env.now())
        task.why = (input?["why"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        task.plan = plan.prefix(12).map { TaskItem.PlanItem(text: $0) }
        await env.store.add(task)
        return .success("已记成目标：\(title)（编号 \(task.handle)，\(task.planProgress)）。")
    }

    private static func updateGoal(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        let handle = (input?["id"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let goal = await env.store.find(handle), goal.kind == .goal else {
            return .failure("没有找到编号为 \(handle) 的目标。先用 list_tasks 拿编号。")
        }
        guard goal.isActive else { return .failure("「\(goal.title)」已经\(goal.status.promptLabel)了。") }
        let newTitle = input?["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let newTitle, newTitle.count > maxTitleCharacters { return .failure("目标名称太长了，短一点。") }
        let why = input?["why"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        func list(_ key: String) -> [String] {
            (input?[key]?.arrayValue ?? []).compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let add = list("add_plan"), complete = list("complete_plan")
        let note = input?["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let now = env.now()
        var plan = goal.plan + add.map { TaskItem.PlanItem(text: $0) }
        var unmatched: [String] = []
        for key in complete {
            if let index = plan.firstIndex(where: { !$0.done && $0.text.contains(key) }) {
                plan[index].done = true
            } else {
                unmatched.append(key)
            }
        }
        let finalPlan = Array(plan.prefix(30))
        guard let updated = await env.store.update(goal.id, now: now, { current in
            current.title = newTitle ?? current.title
            current.why = why ?? current.why
            current.plan = finalPlan
            if let note { current.notes.append(.init(at: now, text: note)) }
        }) else { return .failure("这个目标已经不在了。") }
        let tail = unmatched.isEmpty ? "" : "（没找到这几个步骤：\(unmatched.joined(separator: "、"))）"
        return .success("已更新目标「\(updated.title)」：\(updated.planProgress)\(tail)")
    }
}

extension CapabilityExecutionResult {
    static func success(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text))
    }

    static func failure(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text), isError: true)
    }
}
