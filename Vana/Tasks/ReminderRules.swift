import Foundation

/// 提醒的时间规则。纯函数:到点怎么排、重复提醒的下一次在哪、怎么念给用户听。
/// `calendar` 从外面传(带时区),测试里造得出夏令时。
enum ReminderRules {
    /// 一次最多这么多条进行中的提醒。再多就是把提醒当成了别的东西。(iOS 一个 app 最多排 64 条
    /// 本地通知,留出 check-in 那两条和余量。)
    static let maxActiveReminders = 50
    /// 最远能约到多久以后。
    static let maxHorizonDays = 366

    /// 解析模型给的本地时间:`2026-10-01T20:00`、`2026-10-01 20:00`、`2026-10-01T20:00:00`。
    /// 没有时区——这是用户当地的墙上时间,按 `calendar` 的时区落到时间轴上。
    static func parseLocal(_ text: String, calendar: Calendar) -> Date? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "T")
        let pieces = cleaned.split(separator: "T")
        guard pieces.count == 2 else { return nil }
        let date = pieces[0].split(separator: "-").compactMap { Int($0) }
        let time = pieces[1].split(separator: ":").compactMap { Int($0) }
        guard date.count == 3, (2...3).contains(time.count) else { return nil }
        var components = DateComponents()
        components.year = date[0]
        components.month = date[1]
        components.day = date[2]
        components.hour = time[0]
        components.minute = time[1]
        components.second = time.count == 3 ? time[2] : 0
        guard (1...12).contains(date[1]), (1...31).contains(date[2]), (0...23).contains(time[0]), (0...59).contains(time[1]),
              let resolved = calendar.date(from: components),
              calendar.component(.day, from: resolved) == date[2]
        else { return nil }
        return resolved
    }

    /// 重复提醒**下一次**响的时间(严格晚于 `after`),**保持墙上时间不变**——不是加 24 小时,
    /// 夏令时不漂。不重复的返回 nil。
    static func nextOccurrence(dueAt: Date, repeatRule: TaskItem.Repeat, after: Date, calendar: Calendar) -> Date? {
        let component: Calendar.Component
        switch repeatRule {
        case .none: return nil
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        }
        var step = 0
        var next = dueAt
        while next <= after, step < 4_000 {
            step += 1
            guard let candidate = calendar.date(byAdding: component, value: step, to: dueAt, wrappingComponents: false) else {
                return nil
            }
            next = candidate
        }
        return next > after ? next : nil
    }

    /// 该提醒现在应当在哪个时间响。已经过去了、又不重复的返回 nil(那是错过的,由调用方决定补响)。
    static func scheduledFor(_ task: TaskItem, now: Date, calendar: Calendar) -> Date? {
        guard let due = task.dueAt else { return nil }
        if due > now { return due }
        return nextOccurrence(dueAt: due, repeatRule: task.repeatRule, after: now, calendar: calendar)
    }

    /// 响过之后这条提醒变成什么:重复的挪到下一次,不重复的记为完成。
    static func afterFiring(_ task: TaskItem, firedAt: Date, calendar: Calendar) -> TaskItem {
        var next = task
        if let due = task.dueAt,
           let upcoming = nextOccurrence(dueAt: due, repeatRule: task.repeatRule, after: firedAt, calendar: calendar) {
            next.dueAt = upcoming
            next.status = .queued
        } else {
            next.status = .done
        }
        return next
    }

    /// 念给模型听(固定中文):今天 20:00 / 明天 09:00 / 10月5日 09:00 / 2027年1月3日 09:00。
    static func describe(_ at: Date, now: Date, calendar: Calendar) -> String {
        let time = String(format: "%02d:%02d", calendar.component(.hour, from: at), calendar.component(.minute, from: at))
        let day: String
        if calendar.isDate(at, inSameDayAs: now) {
            day = "今天"
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(at, inSameDayAs: tomorrow) {
            day = "明天"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) {
            day = "昨天"
        } else if calendar.component(.year, from: at) == calendar.component(.year, from: now) {
            day = "\(calendar.component(.month, from: at))月\(calendar.component(.day, from: at))日"
        } else {
            day = "\(calendar.component(.year, from: at))年\(calendar.component(.month, from: at))月\(calendar.component(.day, from: at))日"
        }
        return "\(day) \(time)"
    }

    /// 界面上的那一份,跟界面语言走。
    static func localizedDescription(_ at: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = at.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(at) { return String(localized: "今天 \(time)") }
        if calendar.isDateInTomorrow(at) { return String(localized: "明天 \(time)") }
        if calendar.isDateInYesterday(at) { return String(localized: "昨天 \(time)") }
        return at.formatted(.dateTime.month().day().hour().minute())
    }

    static func describeRepeat(_ repeatRule: TaskItem.Repeat, dueAt: Date?, calendar: Calendar) -> String {
        switch repeatRule {
        case .none: return ""
        case .daily: return "每天"
        case .weekly:
            let weekday = dueAt.map { calendar.component(.weekday, from: $0) } ?? 2
            return "每周" + ["日", "一", "二", "三", "四", "五", "六"][weekday - 1]
        }
    }

    static func localizedRepeat(_ repeatRule: TaskItem.Repeat, dueAt: Date?) -> String {
        switch repeatRule {
        case .none: return ""
        case .daily: return String(localized: "每天")
        case .weekly:
            guard let dueAt else { return String(localized: "每周") }
            return String(localized: "每\(dueAt.formatted(.dateTime.weekday(.wide)))")
        }
    }

    /// 今天(按 `calendar`)结束的那一刻。「今天」卡片按它划线。
    static func endOfDay(_ now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }
}
