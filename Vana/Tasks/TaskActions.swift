import Foundation

/// 用户在「任务」页上手动做的事。和模型那边的工具(`TasksTools`)守同一批上限——两条路进来的
/// 东西在盘上长得一样,也一样会被排上通知。返回 nil 表示成功,否则是要给用户看的原因。
enum TaskActions {
    static let maxPlanItems = 30

    static func addReminder(_ env: TasksEnvironment, title: String, due: Date, repeatRule: TaskItem.Repeat) async -> String? {
        let text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return String(localized: "写一下要提醒什么") }
        let now = env.now()
        guard due >= now.addingTimeInterval(30) else { return String(localized: "这个时间已经过了，选一个之后的时间") }
        guard due <= now.addingTimeInterval(Double(ReminderRules.maxHorizonDays) * 86_400) else {
            return String(localized: "最远只能约到一年以内")
        }
        guard await env.store.active().count(where: { $0.kind == .reminder }) < ReminderRules.maxActiveReminders else {
            return String(localized: "进行中的提醒已经有 \(ReminderRules.maxActiveReminders) 条了，先清理一些")
        }
        var task = TaskItem(kind: .reminder, title: String(text.prefix(TasksTools.maxTitleCharacters * 2)), status: .queued, createdAt: now)
        task.dueAt = due
        task.repeatRule = repeatRule
        await env.store.add(task)
        await env.scheduling.schedule(task, tenantId: env.tenantId)
        return nil
    }

    static func addGoal(_ env: TasksEnvironment, title: String, why: String) async -> String? {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return String(localized: "写一下目标是什么") }
        guard name.count <= TasksTools.maxTitleCharacters else { return String(localized: "名称太长了，短一点") }
        let active = await env.store.active().filter { $0.kind == .goal }
        guard active.count < TasksTools.maxActiveGoals else {
            return String(localized: "进行中的目标已经有 \(TasksTools.maxActiveGoals) 个了，先完成或放弃一个")
        }
        guard !active.contains(where: { $0.title == name }) else { return String(localized: "已经有同名的目标了") }
        var task = TaskItem(kind: .goal, title: name, status: .running, createdAt: env.now())
        task.why = why.trimmingCharacters(in: .whitespacesAndNewlines)
        await env.store.add(task)
        return nil
    }

    static func complete(_ env: TasksEnvironment, _ id: UUID) async {
        await env.scheduling.cancel(id)
        await env.store.update(id) { $0.status = .done }
    }

    /// 放弃(目标、提醒、任务通用):通知一并撤掉。
    static func cancel(_ env: TasksEnvironment, _ id: UUID) async {
        await env.scheduling.cancel(id)
        await env.store.update(id) { $0.status = .cancelled }
    }

    static func delete(_ env: TasksEnvironment, _ id: UUID) async {
        await env.scheduling.cancel(id)
        await env.store.delete(id)
    }

    static func togglePlanItem(_ env: TasksEnvironment, _ id: UUID, item: UUID) async {
        await env.store.update(id) { task in
            if let index = task.plan.firstIndex(where: { $0.id == item }) { task.plan[index].done.toggle() }
        }
    }

    static func addPlanItem(_ env: TasksEnvironment, _ id: UUID, text: String) async {
        let step = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !step.isEmpty else { return }
        await env.store.update(id) { task in
            guard task.plan.count < maxPlanItems else { return }
            task.plan.append(.init(text: String(step.prefix(120))))
        }
    }

    static func addNote(_ env: TasksEnvironment, _ id: UUID, text: String) async {
        let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        let now = env.now()
        await env.store.update(id, now: now) { $0.notes.append(.init(at: now, text: String(note.prefix(400)))) }
    }

    /// 打开「每周回顾」的这一刻起算:第一次回顾在七天之后,不是马上。
    static func setDigest(_ env: TasksEnvironment, _ id: UUID, enabled: Bool) async {
        let now = env.now()
        await env.store.update(id, now: now) {
            $0.digestEnabled = enabled
            if enabled { $0.lastDigestAt = now }
        }
    }

    static func reopen(_ env: TasksEnvironment, _ id: UUID) async {
        await env.store.update(id) { $0.status = .running }
    }

    /// 用户对后台助手的一条提议做了决定。「照做」才真的写:提醒走和手动添加同一条路(同样的
    /// 上限和排程),记忆是用户亲手点了才存的,所以按「自己写的」算(不会被容量挤掉)。
    /// 返回没能照做的原因,nil 表示成功或只是略过。
    static func decide(
        _ env: TasksEnvironment,
        memory: MemoryStore?,
        taskId: UUID,
        proposalId: UUID,
        accept: Bool
    ) async -> String? {
        guard let task = await env.store.get(taskId),
              let proposal = task.result?.proposals.first(where: { $0.id == proposalId }),
              proposal.status == .pending
        else { return nil }

        var problem: String?
        if accept {
            switch proposal.kind {
            case "reminder":
                if let at = proposal.at {
                    problem = await addReminder(env, title: proposal.text, due: at, repeatRule: .none)
                } else {
                    problem = String(localized: "这条提醒没有时间")
                }
            case "goal":
                problem = await addGoal(env, title: proposal.text, why: proposal.why ?? "")
            case "memory":
                if let memory {
                    _ = try? await memory.add(kind: .profile, text: proposal.text, origin: .manual)
                } else {
                    problem = String(localized: "记忆现在是关着的")
                }
            default:
                problem = String(localized: "不认识这种提议")
            }
        }
        let next: TaskItem.Proposal.Status = accept && problem == nil ? .accepted : .dismissed
        await env.store.update(taskId) { current in
            guard let index = current.result?.proposals.firstIndex(where: { $0.id == proposalId }) else { return }
            current.result?.proposals[index].status = next
        }
        return problem
    }
}
