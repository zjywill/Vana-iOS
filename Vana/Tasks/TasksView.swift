import SwiftUI

enum TaskPresentation {
    static func subtitle(_ task: TaskItem) -> String {
        switch task.kind {
        case .reminder:
            var parts: [String] = []
            if let due = task.dueAt { parts.append(ReminderRules.localizedDescription(due)) }
            let every = ReminderRules.localizedRepeat(task.repeatRule, dueAt: task.dueAt)
            if !every.isEmpty { parts.append(every) }
            if !task.isActive { parts.append(task.status.label) }
            return parts.joined(separator: " · ")
        case .goal:
            let progress = task.plan.isEmpty
                ? String(localized: "还没有步骤")
                : String(localized: "步骤 \(task.plan.count(where: \.done))/\(task.plan.count)")
            return task.isActive ? progress : "\(task.status.label) · \(progress)"
        }
    }

    static func icon(_ task: TaskItem) -> String {
        switch task.kind {
        case .reminder: "bell"
        case .goal: "target"
        }
    }
}

/// 加一条提醒:快捷时间 + 日期时间选择 + 重复。
struct ReminderEditor: View {
    let board: TaskBoard

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var due = Date().addingTimeInterval(3_600)
    @State private var repeatRule = TaskItem.Repeat.none
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("提醒我…", text: $title)
                }
                Section {
                    HStack {
                        quick("1 小时后", Date().addingTimeInterval(3_600))
                        quick("今晚 8 点", today(hour: 20))
                        quick("明早 9 点", tomorrow(hour: 9))
                    }
                    .buttonStyle(.bordered)
                    DatePicker("时间", selection: $due, in: Date()...)
                    Picker("重复", selection: $repeatRule) {
                        Text("不重复").tag(TaskItem.Repeat.none)
                        Text("每天").tag(TaskItem.Repeat.daily)
                        Text("每周").tag(TaskItem.Repeat.weekly)
                    }
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("到点只发一条通知，不调用模型。")
                    }
                }
            }
            .navigationTitle("加一条提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            problem = await TaskActions.addReminder(board.environment, title: title, due: due, repeatRule: repeatRule)
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func quick(_ label: LocalizedStringKey, _ date: Date) -> some View {
        Button(label) { due = date }
            .font(.caption)
    }

    private func today(hour: Int) -> Date {
        let calendar = Calendar.current
        let candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
        return candidate > Date() ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }

    private func tomorrow(hour: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: base) ?? base
    }
}

struct GoalEditor: View {
    let board: TaskBoard

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var why = ""
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("比如：备战半马", text: $title)
                    TextField("为什么想做（可选）", text: $why, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(.red)
                    } else {
                        Text("进行中的目标会一直带在 Vana 的上下文里，回答时它会和这件事挂上钩。")
                    }
                }
            }
            .navigationTitle("加一个目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task {
                            problem = await TaskActions.addGoal(board.environment, title: title, why: why)
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// 一条任务的详情:提醒的时间;目标的步骤、进展,和「在侧聊里聊这个目标」。
struct TaskDetailView: View {
    let board: TaskBoard
    let taskId: UUID
    /// 「在侧聊里聊这个目标」。以前是「每周回顾」——后台每七天自动请模型看一眼,写几句放进对话;
    /// 子 agent 撤掉之后改成他想聊的时候自己开一条侧聊(那里的 system 段本来就带着进行中的目标)。
    var onDiscussGoal: ((TaskItem) -> Void)?

    @State private var newStep = ""
    @State private var newNote = ""

    var body: some View {
        Group {
            if let task = board.task(taskId) {
                content(task)
            } else {
                ContentUnavailableView("这一条已经不在了", systemImage: "questionmark.circle")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ task: TaskItem) -> some View {
        let env = board.environment
        Form {
            Section {
                Text(task.title).font(.headline)
                LabeledContent("状态", value: task.status.label)
                if task.kind == .reminder, let due = task.dueAt {
                    LabeledContent("时间", value: ReminderRules.localizedDescription(due))
                    let every = ReminderRules.localizedRepeat(task.repeatRule, dueAt: task.dueAt)
                    if !every.isEmpty { LabeledContent("重复", value: every) }
                }
                if !task.why.isEmpty { Text(task.why).foregroundStyle(.secondary) }
            }

            if task.kind == .goal {
                Section("步骤") {
                    ForEach(task.plan) { item in
                        Button {
                            Task { await TaskActions.togglePlanItem(env, task.id, item: item.id) }
                        } label: {
                            Label(item.text, systemImage: item.done ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(item.done ? .secondary : .primary)
                        }
                        .disabled(!task.isActive)
                    }
                    if task.isActive {
                        TextField("加一个步骤", text: $newStep)
                            .onSubmit {
                                let text = newStep
                                newStep = ""
                                Task { await TaskActions.addPlanItem(env, task.id, text: text) }
                            }
                    }
                }
                Section("进展") {
                    ForEach(Array(task.notes.reversed().enumerated()), id: \.offset) { _, note in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(note.text)
                            Text(note.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if task.isActive {
                        TextField("记一条进展", text: $newNote)
                            .onSubmit {
                                let text = newNote
                                newNote = ""
                                Task { await TaskActions.addNote(env, task.id, text: text) }
                            }
                    }
                }
                if task.isActive, let onDiscussGoal {
                    Section {
                        Button {
                            onDiscussGoal(task)
                        } label: {
                            Label("在侧聊里聊这个目标", systemImage: "bubble.left.and.bubble.right")
                        }
                    } footer: {
                        Text("开一条以这个目标命名的侧聊，回顾进展、商量接下来怎么做。那里说的不挤主对话。")
                    }
                }
            }

            Section {
                if task.isActive {
                    if task.kind == .goal || task.kind == .reminder {
                        Button("完成") { Task { await TaskActions.complete(env, task.id) } }
                    }
                    Button(task.kind == .goal ? "放弃这个目标" : "取消", role: .destructive) {
                        Task { await TaskActions.cancel(env, task.id) }
                    }
                } else if task.kind == .goal {
                    Button("重新开始") { Task { await TaskActions.reopen(env, task.id) } }
                }
                Button("删除", role: .destructive) { Task { await TaskActions.delete(env, task.id) } }
            }
        }
        .navigationTitle(task.kind == .reminder ? "提醒" : "目标")
    }
}
