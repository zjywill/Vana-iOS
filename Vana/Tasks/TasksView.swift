import SwiftUI
import UserNotifications

/// 「任务」页:提醒、目标、最近完成。对应 Muse 的 Goals 标签。
///
/// 手动添加和模型工具走同一批上限(`TaskActions` 对 `TasksTools`):两条路进来的东西在盘上长得一样。
struct TasksView: View {
    let board: TaskBoard
    /// 目标详情里「在侧聊里聊这个目标」。nil 就不出那颗按钮。
    var onDiscussGoal: ((TaskItem) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var isAddingReminder = false
    @State private var isAddingGoal = false
    @State private var notificationsDenied = false

    var body: some View {
        NavigationStack {
            List {
                if notificationsDenied {
                    Section {
                        Label("通知没打开，提醒到点不会弹出来。到「设置 › Vana › 通知」里打开。", systemImage: "bell.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                let reminders = board.active(.reminder)
                let goals = board.active(.goal)

                if reminders.isEmpty && goals.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没有要做的事", systemImage: "checklist")
                        } description: {
                            Text("在对话里说「明天早上八点提醒我带伞」，或者点右上角自己加一条。")
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                if !reminders.isEmpty {
                    Section {
                        ForEach(reminders) { row($0) }
                    } header: {
                        Text("提醒")
                    } footer: {
                        Text("提醒到点只发一条通知，不调用模型，也不花钱。")
                    }
                }
                if !goals.isEmpty {
                    Section {
                        ForEach(goals) { row($0) }
                    } header: {
                        Text("目标")
                    } footer: {
                        Text("进行中的目标最多 \(TasksTools.maxActiveGoals) 个。Vana 回答时会把它们记在心上。")
                    }
                }
                let finished = board.recentlyFinished
                if !finished.isEmpty {
                    Section("最近完成") {
                        ForEach(finished) { row($0) }
                    }
                }
            }
            .navigationTitle("任务")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                TaskDetailView(board: board, taskId: id, onDiscussGoal: onDiscussGoal)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            isAddingReminder = true
                        } label: {
                            Label("加一条提醒", systemImage: "bell")
                        }
                        Button {
                            isAddingGoal = true
                        } label: {
                            Label("加一个目标", systemImage: "target")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加")
                }
            }
            .sheet(isPresented: $isAddingReminder) {
                ReminderEditor(board: board)
            }
            .sheet(isPresented: $isAddingGoal) {
                GoalEditor(board: board)
            }
            .task {
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsDenied = settings.authorizationStatus == .denied && !board.active(.reminder).isEmpty
            }
        }
    }

    private func row(_ task: TaskItem) -> some View {
        NavigationLink(value: task.id) {
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .foregroundStyle(task.isActive ? .primary : .secondary)
                Text(TaskPresentation.subtitle(task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .swipeActions {
            if task.isActive {
                Button {
                    Task { await TaskActions.complete(board.environment, task.id) }
                } label: {
                    Label("完成", systemImage: "checkmark")
                }
                .tint(.green)
            }
            Button(role: .destructive) {
                Task { await TaskActions.delete(board.environment, task.id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

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
private struct ReminderEditor: View {
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

private struct GoalEditor: View {
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

/// 「今天」:聊天顶上可折叠的一条。折叠时一行概览,展开最多三张;为空时整条不显示。
struct TodayStrip: View {
    let cards: [TodayCard]
    var onAction: (TodayAction) -> Void

    /// 一张卡里最多列几件。再多就是把对话写成一份日报,剩下的在任务页里。
    private static let maxRows = 5

    /// 一张普通的卡:头上一行「今天 · 日期」,下面一件事一行。**不折叠**——它每次打开只出现一次,
    /// 就排在最新的位置上,没有需要收起来腾地方的时候。
    var body: some View {
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "sun.max.fill").foregroundStyle(.orange)
                    Text("今天").font(.subheadline.weight(.semibold))
                    Text(Date.now.formatted(.dateTime.month().day().weekday()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)

                let shown = Array(cards.prefix(Self.maxRows))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, card in
                    if index > 0 {
                        Divider().padding(.leading, 52)
                    }
                    TodayCardView(card: card) { onAction(card.action) }
                }

                if cards.count > Self.maxRows {
                    Divider().padding(.leading, 52)
                    Button {
                        onAction(.openTasks)
                    } label: {
                        Text("还有 \(cards.count - Self.maxRows) 件，去任务页看")
                            .font(.footnote)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 52)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.bottom, 6)
            .background(
                Color(.secondarySystemGroupedBackground),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
        }
    }
}

/// 「今天」里的一张卡:角标说是哪一类,标题说是什么事,底下一行说到了哪一步。
private struct TodayCardView: View {
    let card: TodayCard
    let action: () -> Void

    /// 一行:左边一颗按类别上色的图标,右边「类别」小字、标题、进展。
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: card.icon)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(tint, in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(kindLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                    Text(card.title)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(card.kind == .health ? 3 : 2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    if let body = card.body {
                        Text(body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(.rect)
            .animation(.smooth(duration: 0.2), value: card.title)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch card.kind {
        case .overdue: .red
        case .reminder: .orange
        case .goal: .green
        case .followUp: .teal
        case .health: .pink
        case .medication: .purple
        }
    }

    private var kindLabel: String {
        switch card.kind {
        case .overdue: String(localized: "已过点")
        case .reminder: String(localized: "提醒事项")
        case .goal: String(localized: "在推进的目标")
        case .followUp: String(localized: "回头看")
        case .health: String(localized: "现在的状况")
        case .medication: String(localized: "用药回访")
        }
    }
}
