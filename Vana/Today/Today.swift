import Foundation

/// 点「今天」页上的一行该去哪儿/做什么。前两种在那一页里往下推,其余的要回到对话那一屏去做。
enum TodayAction: Equatable, Sendable {
    case openTask(UUID)
    case openMemory
    /// 替他发一句话(比如说好回头看的那件事:「现在怎么样了？」)。
    case ask(String)
    /// 打开某个插件的入口页(`PluginSurface.id`)。
    case openSurface(String)
    /// 首屏那段话的详情(`HealthStatusView`)。
    case openHealthStatus
}

/// 「今天」页上的一行。**由本机数据拼出来,一次模型调用都不发**——这是它和「让模型写一段早间
/// 简报」的根本区别:天天打开天天付钱是不该的。谁贡献的、多重要(大的在前)、点了去哪。
///
/// 目标不在这里:那一页的「目标」一节把进行中的整张列出来,这里再放两张就是同一件事摆两遍。
struct TodayCard: Identifiable, Equatable, Sendable {
    /// 这一行是哪一类。决定那颗图标的颜色和那两个字,不影响排序(排序看 `priority`)。
    /// `.health` 排在那一页的「现在」一节,其余都在「今天」一节。
    enum Kind: Sendable {
        case reminder, overdue, followUp, health, medication
    }

    let id: String
    let pluginId: String
    let priority: Int
    let title: String
    var body: String?
    var icon: String
    var action: TodayAction
    var kind: Kind = .reminder
}

/// 各插件拼卡片要看的那点本机数据。
struct TodayContext: Sendable {
    var now: Date
    var calendar: Calendar = .current
    var tasks: [TaskItem]
    var dueFollowUps: [MemoryItem]
    var medications: MedicationSnapshot = .empty
    /// 本地判定出来的那句处境(`HealthSituation.quickSummary`)。只有机主、健康开着时才有。
    var healthSummary: String?
    var isEnabled: @Sendable (String) -> Bool = EngineSettings.isPluginEnabled
}

enum TodayPriority {
    static let overdueReminder = 90
    static let dueTodayReminder = 75
    static let followUpDue = 70
    static let healthStatus = 50
}

/// 核心贡献的「今天」卡片:今天到点/错过的提醒、说好回头看的事。
enum CoreToday {
    static func cards(_ context: TodayContext) -> [TodayCard] {
        var cards: [TodayCard] = []
        let endOfDay = ReminderRules.endOfDay(context.now, calendar: context.calendar)

        for task in context.tasks where task.kind == .reminder && task.isActive {
            guard let due = task.dueAt, due <= endOfDay else { continue }
            let overdue = due < context.now
            cards.append(TodayCard(
                id: "reminder-\(task.id)",
                pluginId: PluginIds.core,
                priority: overdue ? TodayPriority.overdueReminder : TodayPriority.dueTodayReminder,
                title: task.title,
                body: (overdue ? String(localized: "已过点 · ") : "")
                    + ReminderRules.localizedDescription(due, now: context.now, calendar: context.calendar),
                icon: "bell",
                action: .openTask(task.id),
                kind: overdue ? .overdue : .reminder
            ))
        }

        for item in context.dueFollowUps.prefix(2) {
            cards.append(TodayCard(
                id: "followup-\(item.id)", pluginId: PluginIds.core, priority: TodayPriority.followUpDue,
                title: String(localized: "说好回头看：\(item.text)"),
                icon: "clock.arrow.circlepath",
                action: .ask(String(localized: "上次说的「\(BackgroundTurn.naturalize(item.text))」，现在怎么样了？")),
                kind: .followUp
            ))
        }
        return cards
    }
}

/// 健康插件的卡片:那句处境(首屏那段话的本地版,点开是详情页)和到了该回头看的用药。
enum HealthToday {
    static func cards(_ context: TodayContext) -> [TodayCard] {
        var cards: [TodayCard] = []
        if let summary = context.healthSummary, !summary.isEmpty {
            cards.append(TodayCard(
                id: TodayCard.healthStatusId, pluginId: PluginIds.health, priority: TodayPriority.healthStatus,
                title: summary, icon: "waveform.path.ecg", action: .openHealthStatus, kind: .health
            ))
        }
        if context.isEnabled(PluginIds.healthMedications) {
            for item in context.medications.due(at: context.now).prefix(2) {
                cards.append(TodayCard(
                    id: "medication-\(item.id)", pluginId: PluginIds.health, priority: TodayPriority.followUpDue,
                    title: String(localized: "回头看看：\(item.name)"),
                    body: String(localized: "说好这几天回头评价一下效果"),
                    icon: "pills", action: .openSurface(PluginSurface.medications), kind: .medication
                ))
            }
        }
        return cards
    }
}

extension TodayCard {
    /// 健康插件那张「现在的状况」。
    static let healthStatusId = "health-status"
}

enum TodaySummary {
    /// 顶栏「今天」上的角标:需要他看一眼的有几件。
    static func attention(_ cards: [TodayCard]) -> Int {
        cards.count { $0.priority >= TodayPriority.dueTodayReminder }
    }
}
