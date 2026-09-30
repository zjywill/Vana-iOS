import SwiftUI
import UserNotifications

/// 「今天」:现在是什么状况、今天有什么要做、之后排着什么、在推进什么。对应 Muse 独立于对话的
/// 那几个标签。
///
/// 以前「今天」是对话那一列里的一张卡,一天之内换了四个位置(悬浮在顶上、横着一排、今天那段的
/// 段头、打开时排在最新那条下面),哪个都不对:它说的是**现在**,而对话那一列是**发生过的事**,
/// 一条线性的时间线上没有它的位置——放上面,回头客一打开就被滚到底、看不见它;放在最新那条下面,
/// 它一直压在输入框上,新的回复又排到它下面去。所以拿出来成一页,和原来的任务页合在一起:那张卡
/// 里的东西本来大半就是从任务算出来的。
///
/// 入口是顶栏那颗带角标的按钮,不是 tab bar:只有「对话」和「今天」两个地方时一条 tab bar 撑
/// 不起来,而且它会一直压在输入框底下。有了第三个同级的地方再包进 `TabView`,这一页不用改。
///
/// 手动添加和模型工具走同一批上限(`TaskActions` 对 `TasksTools`):两条路进来的东西在盘上长得一样。
struct TodayView: View {
    let model: ChatViewModel
    /// 要回到对话那一屏去做的那几种(替他问一句、打开用药表、记忆页)。这一页先收起来,再做。
    var onAction: (TodayAction) -> Void
    /// 目标详情里「在侧聊里聊这个目标」。nil 就不出那颗按钮。
    var onDiscussGoal: ((TaskItem) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []
    @State private var isAddingReminder = false
    @State private var isAddingGoal = false
    @State private var notificationsDenied = false

    /// 在这一页里往下推的那两种。其余的都要回到对话去做。
    private enum Route: Hashable {
        case task(UUID)
        case healthStatus
    }

    private var board: TaskBoard { model.taskBoard }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if notificationsDenied {
                    Section {
                        Label("通知没打开，提醒到点不会弹出来。到「设置 › Vana › 通知」里打开。", systemImage: "bell.slash")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                let cards = model.todayCards
                let status = cards.filter { $0.kind == .health }
                let due = cards.filter { $0.kind != .health }
                // 「今天要做」里已经列过的提醒不再出现在「之后」:按卡片认,不按时间再算一遍——
                // 两处各算一次「今天结束在哪一刻」,过零点那一下就会一条出现两遍或者一条都不见。
                let listed = Set(due.compactMap(\.taskId))
                let upcoming = board.active(.reminder).filter { !listed.contains($0.id) }
                let goals = board.active(.goal)

                if !status.isEmpty {
                    Section("现在") {
                        ForEach(status) { cardRow($0, showsKind: false) }
                    }
                }

                // 有状况、没有要做的事时也说一句:只剩一行状况的一页,看不出提醒和目标该从哪儿来。
                if due.isEmpty && upcoming.isEmpty && goals.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("今天没有要做的事", systemImage: "sun.max")
                        } description: {
                            Text("在对话里说「明天早上八点提醒我带伞」，或者点右上角自己加一条。")
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                if !due.isEmpty {
                    Section("今天要做") {
                        ForEach(due) { cardRow($0, showsKind: true) }
                    }
                }
                if !upcoming.isEmpty {
                    Section("之后") {
                        ForEach(upcoming) { taskRow($0) }
                    }
                }
                if !goals.isEmpty {
                    Section {
                        ForEach(goals) { taskRow($0) }
                    } header: {
                        Text("目标")
                    } footer: {
                        Text("进行中的目标最多 \(TasksTools.maxActiveGoals) 个。Vana 回答时会把它们记在心上。")
                    }
                }
                let finished = board.recentlyFinished
                if !finished.isEmpty {
                    Section("最近完成") {
                        ForEach(finished) { taskRow($0) }
                    }
                }

                Section {
                } footer: {
                    Text("这一页由本机数据拼出来，不调用模型。提醒到点只发一条通知，也不花钱。")
                }
            }
            .navigationTitle("今天")
            .navigationSubtitle(Text(Date.now.formatted(.dateTime.month().day().weekday())))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .task(let id):
                    TaskDetailView(board: board, taskId: id, onDiscussGoal: onDiscussGoal)
                case .healthStatus:
                    HealthStatusView(model: model)
                }
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
                // 打开这一页时重拼一次:上次拼的时候还没到点的提醒,现在可能已经过点了。
                await model.refreshToday()
                let settings = await UNUserNotificationCenter.current().notificationSettings()
                notificationsDenied = settings.authorizationStatus == .denied && !board.active(.reminder).isEmpty
            }
        }
    }

    /// 插件贡献的一行。今天到点的提醒可以直接划掉。
    private func cardRow(_ card: TodayCard, showsKind: Bool) -> some View {
        Button {
            perform(card.action)
        } label: {
            TodayRowLabel(
                icon: card.icon,
                tint: card.kind.tint,
                caption: showsKind ? card.kind.label : nil,
                title: card.title,
                detail: card.body,
                titleLineLimit: card.kind == .health ? 4 : 2
            )
        }
        .swipeActions {
            if let id = card.taskId {
                completeButton(id)
            }
        }
    }

    /// 一条任务:之后的提醒、进行中的目标、最近完成的。
    private func taskRow(_ task: TaskItem) -> some View {
        Button {
            path.append(.task(task.id))
        } label: {
            TodayRowLabel(
                icon: task.isActive ? TaskPresentation.icon(task) : "checkmark",
                tint: task.isActive ? (task.kind == .goal ? .green : .orange) : .secondary,
                caption: nil,
                title: task.title,
                detail: TaskPresentation.subtitle(task),
                titleLineLimit: 2,
                isDimmed: !task.isActive
            )
        }
        .swipeActions {
            if task.isActive {
                completeButton(task.id)
            }
            Button(role: .destructive) {
                Task { await TaskActions.delete(board.environment, task.id) }
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func completeButton(_ id: UUID) -> some View {
        Button {
            Task { await TaskActions.complete(board.environment, id) }
        } label: {
            Label("完成", systemImage: "checkmark")
        }
        .tint(.green)
    }

    private func perform(_ action: TodayAction) {
        switch action {
        case .openTask(let id): path.append(.task(id))
        case .openHealthStatus: path.append(.healthStatus)
        case .ask, .openMemory, .openSurface: onAction(action)
        }
    }
}

/// 「今天」页上的一行:左边一颗按类别上色的图标,右边「类别」小字、标题、进展。
/// 插件贡献的和任务表里的长一个样子——同一页里两种排法,读起来像是拼起来的两页。
private struct TodayRowLabel: View {
    let icon: String
    let tint: Color
    let caption: String?
    let title: String
    let detail: String?
    let titleLineLimit: Int
    var isDimmed = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(tint, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                if let caption {
                    Text(caption)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(tint)
                }
                // 颜色写成 `Color`,不写 `.primary` / `.secondary`:这一行是 `List` 里的一颗按钮,
                // 分层样式在那儿按按钮的 tint 解析,整行字会变成蓝的。
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(isDimmed ? Color.secondary : Color.primary)
                    .lineLimit(titleLineLimit)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // 「现在」那一行是模型一句一句写出来的。
                    .contentTransition(.opacity)
                    .animation(.smooth(duration: 0.2), value: title)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(.tertiaryLabel))
                .padding(.top, 4)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

extension TodayCard {
    /// 这一行指着的那条任务(今天到点的提醒)。「之后」那一节靠它去重,划掉也靠它。
    var taskId: UUID? {
        if case .openTask(let id) = action { id } else { nil }
    }
}

extension TodayCard.Kind {
    var tint: Color {
        switch self {
        case .overdue: .red
        case .reminder: .orange
        case .followUp: .teal
        case .health: .pink
        case .medication: .purple
        }
    }

    var label: String {
        switch self {
        case .overdue: String(localized: "已过点")
        case .reminder: String(localized: "提醒事项")
        case .followUp: String(localized: "回头看")
        case .health: String(localized: "现在的状况")
        case .medication: String(localized: "用药回访")
        }
    }
}
