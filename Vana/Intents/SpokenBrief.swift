import Foundation

/// Siri 念出来的那一两句话。
///
/// 这条路和 app 里的对话是**两套东西**,故意的。对话交给模型;这里全在本地算完,不联网、
/// 不看 API key。Siri 给一次 intent 的执行时间以秒计,而一轮模型回答要先联网、跑几轮工具、
/// 再流式出字——塞进来只会超时,超时之后用户听到的是"出了点问题",比听到一句朴素但准确
/// 的实话糟得多。而且语音场景下人要的本来就是一句话。
///
/// 所以这里只说**已经发生的事实**加一句本地算得出的对比,不做判断也不给建议。要判断和
/// 建议的走 `AskVanaIntent`:那条会打开 app,让完整的 agent 来答。
///
/// 取数和组句是分开的:组句全是纯函数,吃数据吐字符串,`now` 和 `calendar` 都从外面传。
/// 会写错的是组句那一半("昨晚"到底是几天前、比平均多还是少),它得能在不碰 HealthKit
/// 的情况下测。
enum SpokenBrief {
    /// 今天怎么样:今天的活动量,加最值得说的那一个触发点。
    static func todayStatus() async -> String {
        if let blocked = await blockedReason() { return blocked }

        do {
            let today = try await HealthStore.owner.dailyActivity(days: 1).last
            // 触发点的识别逻辑和 check-in 通知、首屏建议共用一套。同一份数据在三个地方
            // 说出三种结论,用户只会觉得这 app 自己都没想清楚。
            let situation = await HealthSituation.detect(
                interests: await TenantScope.ownerStores.thread.interests()
            )
            return todayLine(activity: today, situation: situation)
        } catch {
            return failureLine(error)
        }
    }

    /// 昨晚睡得怎么样:时长、上下床时间,和最近几晚的差。
    static func lastNightSleep() async -> String {
        if let blocked = await blockedReason() { return blocked }

        do {
            return sleepLine(nights: try await HealthStore.owner.sleepSummary(days: 14))
        } catch {
            return failureLine(error)
        }
    }

    /// 复盘最近那次训练:这次练了什么,和最近两周的同类比起来如何。
    static func lastWorkout() async -> String {
        if let blocked = await blockedReason() { return blocked }

        do {
            return workoutLine(sessions: try await HealthStore.owner.workouts(days: 14))
        } catch {
            return failureLine(error)
        }
    }

    // MARK: - 组句

    static func todayLine(activity: DayActivity?, situation: HealthSituation) -> String {
        let headline = situation.triggers.first(where: isSpeakable)
        return activityLine(activity, situation: situation)
            + (headline.map { "\($0.brief)。" } ?? "其他几项都在最近的常态范围里。")
    }

    static func sleepLine(
        nights: [NightSleep],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let sorted = nights.sorted { $0.night < $1.night }
        guard let latest = sorted.last else { return "最近两周都没有睡眠记录。" }

        // `night` 记的是上床那天(样本时间往前挪 12 小时再取整日),所以昨晚是 1 不是 0。
        let nightsAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latest.night),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        guard nightsAgo <= 1 else {
            return "昨晚没有睡眠记录，多半是没戴设备。最近一次是 \(dayLabel(latest.night, calendar: calendar))，"
                + "睡了 \(spokenDuration(latest.asleep))。"
        }

        var line = "昨晚睡了 \(spokenDuration(latest.asleep))"
        if let bedtime = latest.bedtime, let wake = latest.wake {
            line += "，\(clockLabel(bedtime, calendar: calendar)) 睡的，\(clockLabel(wake, calendar: calendar)) 醒"
        }
        line += "。"

        // 基线用这一晚**之前**的那些。把自己算进平均里,差值会被自己稀释掉。
        let earlier = sorted.dropLast().map(\.asleep)
        if earlier.count >= 3 {
            let average = earlier.reduce(0, +) / Double(earlier.count)
            let delta = Int((latest.asleep - average) / 60)
            line += abs(delta) >= 20
                ? "比最近几晚平均\(delta > 0 ? "多" : "少") \(abs(delta)) 分钟。"
                : "和最近几晚差不多。"
        }
        return line
    }

    static func workoutLine(sessions: [WorkoutItem], now: Date = Date()) -> String {
        guard let latest = sessions.max(by: { $0.date < $1.date }) else {
            return "最近两周没有锻炼记录。"
        }

        let ended = latest.date.addingTimeInterval(latest.duration)
        var line = "\(elapsedLabel(since: ended, now: now))那次\(latest.typeName)，"
            + "练了 \(spokenDuration(latest.duration))"
        if let distance = latest.distance, distance > 0 {
            line += "，\(oneDecimal(distance)) 公里"
        }
        if let heartRate = latest.averageHeartRate {
            line += "，平均心率 \(Int(heartRate.rounded()))"
        }
        if let energy = latest.activeEnergy {
            line += "，消耗 \(Int(energy.rounded())) 千卡"
        }
        line += "。"

        // 只和同类比。拿一次跑步去比一次瑜伽,得出的"比平常短 20 分钟"没有意义。
        let peers = sessions.filter { $0.typeName == latest.typeName && $0.date != latest.date }
        if peers.count >= 3 {
            let average = peers.map(\.duration).reduce(0, +) / Double(peers.count)
            let delta = Int((latest.duration - average) / 60)
            line += abs(delta) >= 5
                ? "比最近两周同类训练的平均时长\(delta > 0 ? "长" : "短") \(abs(delta)) 分钟。"
                : "和最近两周的同类训练时长差不多。"
        }
        return line
    }

    private static func activityLine(_ day: DayActivity?, situation: HealthSituation) -> String {
        guard let day else { return "今天还没读到活动量。" }
        guard day.steps > 0 else { return "今天到现在还没有步数记录。" }

        var line = "今天走了 \(Int(day.steps.rounded())) 步"
        if let minutes = day.exerciseMinutes, minutes >= 1 {
            line += "，运动 \(Int(minutes.rounded())) 分钟"
        }
        if situation.triggers.contains(where: { if case .bigActivityDay = $0 { true } else { false } }) {
            line += "，明显多于平常"
        }
        return line + "。"
    }

    /// 能当"事实"念出来的触发点。
    ///
    /// 挡掉两类:今天步数那两条已经在活动量那句里说过了,再说一遍是复读;`weeklyReview`
    /// 根本不是从数据里读出来的事实,只是"今天周一"。
    private static func isSpeakable(_ trigger: HealthTrigger) -> Bool {
        switch trigger {
        case .bigActivityDay, .noStepsToday, .weeklyReview: false
        default: true
        }
    }

    // MARK: - 说得出口的前提

    /// 查之前先确认读得到。读不到的几种原因分开说——用户能据此知道下一步该干什么。
    private static func blockedReason() async -> String? {
        switch await HealthStore.owner.readAccess() {
        case .ready:
            return nil
        case .notRequested:
            return "还没拿到健康数据的读取权限。先打开 Vana 授权一次，之后就能直接问我了。"
        case .unavailable:
            return "这台设备上没有健康数据。"
        }
    }

    private static func failureLine(_ error: any Error) -> String {
        HealthStore.isDatabaseLocked(error)
            ? "手机锁着的时候读不到健康数据，解锁之后再问我一次。"
            : "读健康数据的时候出了点问题，打开 Vana 看看吧。"
    }

    // MARK: - 数字念法

    /// "6 小时 12 分" / "42 分钟"。语音里读小数点很别扭,一律拆成整数。
    private static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = max(Int((seconds / 60).rounded()), 0)
        let hours = total / 60
        let minutes = total % 60
        if hours == 0 { return "\(minutes) 分钟" }
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
    }

    /// "23 点 40 分"。冒号在语音里会被读成别的东西。
    private static func clockLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return "" }
        return minute == 0 ? "\(hour) 点" : "\(hour) 点 \(minute) 分"
    }

    private static func dayLabel(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard let month = parts.month, let day = parts.day else { return "那天" }
        return "\(month) 月 \(day) 日那晚"
    }

    /// "刚刚" / "40 分钟前" / "3 小时前" / "昨天" / "5 天前"。
    private static func elapsedLabel(since date: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(date) / 60)
        switch minutes {
        case ..<10: return "刚刚"
        case ..<60: return "\(minutes) 分钟前"
        case ..<(60 * 24): return "\(minutes / 60) 小时前"
        case ..<(60 * 48): return "昨天"
        default: return "\(minutes / (60 * 24)) 天前"
        }
    }

    private static func oneDecimal(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
