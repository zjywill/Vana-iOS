import Foundation
import UserNotifications

/// 提醒落到系统通知上。`create_reminder` 之类的工具经它排程,而不直接认识 UserNotifications。
protocol ReminderScheduling: Sendable {
    func schedule(_ task: TaskItem, tenantId: UUID) async
    func cancel(_ taskId: UUID) async
}

struct NoReminderScheduling: ReminderScheduling {
    func schedule(_ task: TaskItem, tenantId: UUID) async {}
    func cancel(_ taskId: UUID) async {}
}

/// 提醒怎么排、到点之后怎么收尾。
///
/// **到点不调模型**:响的时候系统发一条本地通知(`UNCalendarNotificationTrigger`,时刻由系统保证,
/// 不像 Android 那边只能用非精确闹钟);app 下次在前台时往那条对话末尾补一条 Vana 主动说的话
/// (`.reminder`,模型下次看得到),重复的挪到下一次、不重复的记为完成(`catchUp`)。
/// 提醒因此不花用户一分钱。
///
/// iOS 不会在通知送达的那一刻唤起 app,所以「补那条主动消息」发生在:app 在前台时通知到了、
/// 用户点开了通知、或者下一次回到前台。过点很久才补上的那条标明「错过的」。
struct ReminderScheduler: ReminderScheduling {
    static let shared = ReminderScheduler()

    static let identifierPrefix = "reminder."
    static let taskKey = "reminderTaskId"
    static let tenantKey = "reminderTenantId"
    /// 过点这么久才补上的,算「错过的」——那时候通知多半已经被划掉了。
    static let missedAfter: TimeInterval = 5 * 60

    static func identifier(for id: UUID) -> String { identifierPrefix + id.uuidString }

    func schedule(_ task: TaskItem, tenantId: UUID) async {
        guard task.kind == .reminder, task.isActive, let due = task.dueAt else { return }
        let center = UNUserNotificationCenter.current()
        // 第一次设提醒时顺手要一次通知权限。没权限的提醒排上去也不会响,而他要的正是那一下。
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let calendar = Calendar.current
        let components: DateComponents
        let repeats: Bool
        switch task.repeatRule {
        case .none:
            components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            repeats = false
        case .daily:
            components = calendar.dateComponents([.hour, .minute], from: due)
            repeats = true
        case .weekly:
            components = calendar.dateComponents([.weekday, .hour, .minute], from: due)
            repeats = true
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "提醒")
        content.body = task.title
        content.sound = .default
        content.userInfo = [Self.taskKey: task.id.uuidString, Self.tenantKey: tenantId.uuidString]
        let request = UNNotificationRequest(
            identifier: Self.identifier(for: task.id),
            content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: repeats)
        )
        try? await center.add(request)
    }

    func cancel(_ taskId: UUID) async {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.identifier(for: taskId)])
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(for: taskId)])
    }

    // MARK: - 收尾

    /// 到点了的提醒:往对话末尾补一条主动消息,重复的挪到下一次、不重复的记为完成。
    ///
    /// 启动、回到前台、通知在前台送达、用户点开通知时都跑一次。幂等:同一条提醒只在它的
    /// `dueAt` 已经过了时才处理,处理完 `dueAt` 就往后挪了(或者状态变成完成)。
    @discardableResult
    static func catchUp(
        tasks: TaskStore,
        thread: ThreadStore,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async -> Int {
        var fired = 0
        for task in await tasks.active() where task.kind == .reminder {
            guard let due = task.dueAt, due <= now else { continue }
            let missed = now.timeIntervalSince(due) > missedAfter
            let text = missed ? "错过的提醒：\(task.title)" : "提醒：\(task.title)"
            await thread.appendAtEnd(ChatMessage(role: .assistant, text: text, createdAt: now, origin: .reminder, refTaskId: task.id))
            let advanced = ReminderRules.afterFiring(task, firedAt: now, calendar: calendar)
            await tasks.update(task.id, now: now) { $0 = advanced }
            fired += 1
        }
        return fired
    }

    /// 每位成员都过一遍。重装、恢复备份之后系统里的待发通知没了,也借这一趟按盘上的提醒重新排。
    static func catchUpAll(now: Date = Date()) async {
        let tenants = (try? TenantStore.shared.tenants()) ?? [TenantScope.owner]
        let pending = Set(await UNUserNotificationCenter.current().pendingNotificationRequests().map(\.identifier))
        for tenant in tenants {
            let stores = TenantScope.stores(for: tenant)
            await catchUp(tasks: stores.tasks, thread: stores.thread, now: now)
            for task in await stores.tasks.active() where task.kind == .reminder {
                guard !pending.contains(identifier(for: task.id)) else { continue }
                await shared.schedule(task, tenantId: tenant.id)
            }
        }
    }
}
