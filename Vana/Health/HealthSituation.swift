import Foundation

/// 用户现在打开这个 app 的可能原因。
///
/// 时段是最弱的信号。真正的动机通常已经写在数据里:一小时前刚跑完、昨晚比常态少睡一个
/// 半小时、静息心率比基线高了 5 次、连着三天几乎没动、今天一步没走(多半是没戴表)。
/// 这些都在本地算得出来,不用问模型——模型只负责把它们写成一句人话。
enum HealthTrigger: Sendable, Equatable {
    /// 刚结束一次锻炼(三小时内)。最强的信号:事情刚发生。
    case justTrained(name: String, minutes: Int, endedMinutesAgo: Int)
    case shortSleep(hours: Double, deficitMinutes: Int)
    case longSleepStillLow(hours: Double)
    case missingLastNight
    case elevatedRestingHR(latest: Int, baseline: Int)
    case suppressedHRV(dropPercent: Int)
    case bigActivityDay(steps: Int)
    case sedentaryStreak(days: Int)
    case noWorkouts(days: Int)
    case weightShift(deltaKg: Double, days: Int)
    case lateBedtimeDrift(minutes: Int)
    case noStepsToday
    case weeklyReview

    /// 越靠前越可能是此刻打开 app 的原因。时段会调整排序:早上先问睡眠,晚上先问活动量。
    func rank(in period: DayPeriod) -> Int {
        switch self {
        case .justTrained: return 0
        case .missingLastNight: return period == .morning ? 1 : 7
        case .shortSleep: return period == .morning ? 1 : 5
        case .longSleepStillLow: return period == .morning ? 2 : 8
        case .elevatedRestingHR: return 2
        case .suppressedHRV: return 3
        case .bigActivityDay: return period == .evening ? 2 : 4
        case .sedentaryStreak: return period == .evening ? 3 : 6
        case .noStepsToday: return period == .evening ? 3 : 9
        case .noWorkouts: return 6
        case .lateBedtimeDrift: return 7
        case .weightShift: return 8
        case .weeklyReview: return 9
        }
    }

    var question: SuggestedQuestion {
        switch self {
        case .justTrained(let name, _, _):
            return SuggestedQuestion(icon: "figure.cooldown", text: String(localized: "刚练完\(name)，强度合适吗？"))
        case .shortSleep(let hours, _):
            return SuggestedQuestion(icon: "moon.zzz", text: String(localized: "昨晚只睡 \(hours.oneDecimal) 小时，要紧吗？"))
        case .longSleepStillLow:
            return SuggestedQuestion(icon: "bed.double", text: String(localized: "睡够了还是累，为什么？"))
        case .missingLastNight:
            return SuggestedQuestion(icon: "moon.stars", text: String(localized: "昨晚没有睡眠记录？"))
        case .elevatedRestingHR:
            return SuggestedQuestion(icon: "heart", text: String(localized: "静息心率怎么比平时高？"))
        case .suppressedHRV:
            return SuggestedQuestion(icon: "waveform.path.ecg", text: String(localized: "HRV 掉了，今天该练吗？"))
        case .bigActivityDay:
            return SuggestedQuestion(icon: "figure.walk.motion", text: String(localized: "今天走得多，要注意什么？"))
        case .sedentaryStreak:
            return SuggestedQuestion(icon: "figure.seated.side", text: String(localized: "这几天怎么动得这么少？"))
        case .noStepsToday:
            return SuggestedQuestion(icon: "figure.walk", text: String(localized: "今天怎么一步都没走？"))
        case .noWorkouts(let days):
            return SuggestedQuestion(icon: "flame", text: String(localized: "\(days) 天没练，怎么捡起来？"))
        case .weightShift(let delta, _):
            return SuggestedQuestion(
                icon: "scalemass",
                text: delta < 0 ? String(localized: "体重降了，正常吗？") : String(localized: "体重涨了，正常吗？")
            )
        case .lateBedtimeDrift:
            return SuggestedQuestion(icon: "clock.badge.exclamationmark", text: String(localized: "越睡越晚，有影响吗？"))
        case .weeklyReview:
            return SuggestedQuestion(icon: "chart.line.uptrend.xyaxis", text: String(localized: "上周整体怎么样？"))
        }
    }

    /// 这个触发点归哪个工具管。用来和「他平时爱问什么」对上号。
    var relatedTool: String? {
        switch self {
        case .justTrained, .noWorkouts:
            return "workouts"
        case .shortSleep, .longSleepStillLow, .missingLastNight, .lateBedtimeDrift:
            return "sleep_summary"
        case .elevatedRestingHR, .suppressedHRV:
            return "heart_rate_summary"
        case .bigActivityDay, .sedentaryStreak, .noStepsToday:
            return "daily_steps"
        case .weightShift:
            return "body_metrics"
        case .weeklyReview:
            return nil
        }
    }

    /// 给模型的事实描述。带上具体数字,它才写得出具体的问题。
    var brief: String {
        switch self {
        case .justTrained(let name, let minutes, let ago):
            return String(localized: "\(ago) 分钟前刚结束一次 \(minutes) 分钟的\(name)")
        case .shortSleep(let hours, let deficit):
            return String(localized: "昨晚只睡了 \(hours.oneDecimal) 小时，比最近常态少 \(deficit) 分钟")
        case .longSleepStillLow(let hours):
            return String(localized: "昨晚睡了 \(hours.oneDecimal) 小时，时长够但恢复指标不好看")
        case .missingLastNight:
            return String(localized: "昨晚没有任何睡眠记录（多半是没戴设备）")
        case .elevatedRestingHR(let latest, let baseline):
            return String(localized: "静息心率 \(latest) 次/分，比最近基线 \(baseline) 高")
        case .suppressedHRV(let drop):
            return String(localized: "HRV 比最近基线低约 \(drop)%")
        case .bigActivityDay(let steps):
            return String(localized: "今天已经走了 \(steps) 步，明显高于平常")
        case .sedentaryStreak(let days):
            return String(localized: "最近 \(days) 天步数只有平常的一半左右")
        case .noStepsToday:
            return String(localized: "今天到现在 0 步")
        case .noWorkouts(let days):
            return String(localized: "已经 \(days) 天没有锻炼记录")
        case .weightShift(let delta, let days):
            return String(localized: "体重在 \(days) 天里变化了 \(delta.oneDecimal) 公斤")
        case .lateBedtimeDrift(let minutes):
            return String(localized: "入睡时间比上周平均晚了约 \(minutes) 分钟")
        case .weeklyReview:
            return String(localized: "周一早上，适合回顾上一周")
        }
    }
}

/// 此刻的处境:时段 + 从数据里读出来的触发点。
struct HealthSituation: Sendable {
    let period: DayPeriod
    /// 已按"最可能是打开原因"排序。
    let triggers: [HealthTrigger]
    /// 此刻的几个关键读数。触发点说「有什么变了」,它说「现在是多少」。
    var vitals: HealthVitals = .empty
    /// 他平时爱问什么。只用来在**同等重要**的触发点之间挑,不用来推翻排序。
    var interests: InterestProfile = .empty

    /// 首屏问题:触发点优先,不够三条用时段默认补齐,去重。
    var questions: [SuggestedQuestion] {
        var picked: [SuggestedQuestion] = []
        for question in triggers.map(\.question) + SuggestedQuestions.defaults(period: period) {
            guard !picked.contains(where: { $0.text == question.text }) else { continue }
            picked.append(question)
            if picked.count == 3 { break }
        }
        return picked
    }

    /// 首屏那句话:打开 app 先说**发生了什么、要不要在意**,而不是先问用户一个问题。
    ///
    /// 只取排在最前面的两条。`triggers` 已经按"最可能是打开原因"排过序了,再往下就是把首屏
    /// 写成一份日报——而剩下那几条本来就会以问题的形式出现在下面那三颗 chip 上
    /// (`questions` 取的是同一个序列)。一句话说结论,几颗 chip 给去处,两边不重复。
    ///
    /// `.weeklyReview` 不进这里:它说的是"今天是周一",不是数据里发生的事。它排最后一名,
    /// 只有别的什么都没有时才轮得到第一——而那时候该说的是现状。
    ///
    /// 没有触发点时**退到现状,不退到一句空话**。「最近几天没有读到值得特别留意的波动」
    /// 一个数字都没有,而多数人多数天里数据本来就是平稳的——那句话于是成了大多数人打开
    /// app 读到的第一行字,读完仍然不知道自己现在怎么样。没有波动不等于没有现状。
    var quickSummary: String {
        let facts = notableTriggers.prefix(2).map(\.brief)
        if !facts.isEmpty {
            return Self.sentence(facts, separator: String(localized: "；"))
        }

        // 三项打住。首屏这句话是"几秒钟看完"的东西,再往下就是一份日报——剩下那几项
        // 点开详情页全都在。
        let readings = vitals.measured.prefix(3).compactMap(\.phrase)
        if !readings.isEmpty {
            return Self.sentence(readings, separator: String(localized: "，"))
        }

        return Self.calmSummary
    }

    /// 把几个短句接成一句话。**分隔号、句号和首字母大小写都跟着语言走**:中文那句是
    /// 「A；B。」,英文那句是「A; B.」,而英文还要把第一个字母大写——每一条 brief 都是
    /// 半句话(「no sleep recorded last night」),它们各自都可能排在最前面。
    static func sentence(_ parts: some Sequence<String>, separator: String = String(localized: "；")) -> String {
        let joined = parts.joined(separator: separator) + String(localized: "。")
        guard let first = joined.first else { return joined }
        return String(first).localizedUppercase + joined.dropFirst()
    }

    /// 有没有东西可写。两样都空的时候连模型都不叫。
    var hasSummaryFacts: Bool { !notableTriggers.isEmpty || !vitals.isEmpty }

    /// 值得写进那句话的触发点。空的话连模型都不用叫——让它为"没什么可说"写一句,
    /// 它会为了有话说而把常态写成异常。
    var notableTriggers: [HealthTrigger] {
        triggers.filter { $0 != .weeklyReview }
    }

    /// 连一个读数都拿不到时那一句。
    ///
    /// 走到这里说明的不是「他很平稳」,而是**这台设备上什么都没读到**——没授权、刚装上、
    /// 或者没戴表。所以话要说在这上面,而不是「没读到值得留意的波动」:那句话听起来像
    /// 一份体检结论,实际上一个数字都没看过。更不能写成「一切正常」。
    static let calmSummary = String(localized: "还没有读到最近的健康数据。")

    /// 给模型的场景说明。没有触发点时只有时段,让它写通用的三条。
    var brief: String {
        var text = period.context
        if !triggers.isEmpty {
            let lines = triggers.prefix(4).map { "- \($0.brief)" }.joined(separator: "\n")
            text += "\n\n从数据里读到的情况：\n\(lines)"
        }
        if let interests = interests.summary {
            text += "\n\n他平时的关注点：\(interests)"
        }
        return text
    }
}

extension HealthSituation {
    /// 查一遍最近两周的数据,把能识别的触发点都挑出来。
    ///
    /// 全是本地查询,没有网络,失败的那一项直接跳过——识别不出触发点只是少了个性化,
    /// 不该让首屏出不来。
    static func detect(
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        interests: InterestProfile = .empty
    ) async -> HealthSituation {
        let period = DayPeriod(at: now, calendar: calendar)
        let store = HealthStore.owner

        async let steps = try? store.dailySteps(days: 14)
        async let nights = try? store.sleepSummary(days: 14)
        async let hearts = try? store.heartRateSummary(days: 14)
        async let sessions = try? store.workouts(days: 14)
        async let body = try? store.bodyMetrics(days: 14)

        // 各查一次,喂两个消费者:判触发点,顺带留下现状。多解一遍是零成本的——重查一遍
        // 才是。
        let steps14 = await steps ?? []
        let nights14 = await nights ?? []
        let hearts14 = await hearts ?? []
        let sessions14 = await sessions ?? []
        let body14 = await body ?? []

        var triggers: [HealthTrigger] = []
        triggers.append(contentsOf: workoutTriggers(sessions14, now: now, calendar: calendar))
        triggers.append(contentsOf: sleepTriggers(nights14, now: now, calendar: calendar))
        triggers.append(contentsOf: heartTriggers(hearts14))
        triggers.append(contentsOf: stepTriggers(steps14, now: now, calendar: calendar))
        triggers.append(contentsOf: bodyTriggers(body14))

        if period == .morning, calendar.component(.weekday, from: now) == 2 {
            triggers.append(.weeklyReview)
        }

        return HealthSituation(
            period: period,
            triggers: ordered(triggers, period: period, interests: interests),
            vitals: HealthVitals.read(
                steps: steps14,
                nights: nights14,
                hearts: hearts14,
                sessions: sessions14,
                body: body14,
                now: now,
                calendar: calendar
            ),
            interests: interests
        )
    }

    /// 排序:先按「最可能是打开原因」,同名次之间才看他平时爱问什么。
    ///
    /// 兴趣**只做同级裁决**,不做加权。刚练完永远排在体重变化前面——哪怕他这半年一次锻炼
    /// 都没问过。数据里刚发生的事比历史偏好强,把「他爱问什么」做成能翻盘的权重,第一条
    /// 建议就会开始答非所问。
    static func ordered(
        _ triggers: [HealthTrigger],
        period: DayPeriod,
        interests: InterestProfile
    ) -> [HealthTrigger] {
        triggers
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.rank(in: period)
                let right = rhs.element.rank(in: period)
                if left != right { return left < right }

                let leftWeight = interests.weight(forTool: lhs.element.relatedTool)
                let rightWeight = interests.weight(forTool: rhs.element.relatedTool)
                if leftWeight != rightWeight { return leftWeight > rightWeight }

                // 权重也一样时按原顺序,别让 sort 的不稳定把首屏变成每次刷新都不一样。
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    // MARK: - 各项判定

    private static func workoutTriggers(
        _ sessions: [WorkoutItem],
        now: Date,
        calendar: Calendar
    ) -> [HealthTrigger] {
        guard let latest = sessions.max(by: { $0.date < $1.date }) else {
            return [.noWorkouts(days: 14)]
        }

        let ended = latest.date.addingTimeInterval(latest.duration)
        let minutesAgo = Int(now.timeIntervalSince(ended) / 60)
        if minutesAgo >= 0, minutesAgo <= 180 {
            return [.justTrained(
                name: latest.typeName,
                minutes: max(Int(latest.duration / 60), 1),
                endedMinutesAgo: minutesAgo
            )]
        }

        let idleDays = calendar.dateComponents([.day], from: ended, to: now).day ?? 0
        return idleDays >= 5 ? [.noWorkouts(days: idleDays)] : []
    }

    private static func sleepTriggers(
        _ nights: [NightSleep],
        now: Date,
        calendar: Calendar
    ) -> [HealthTrigger] {
        let sorted = nights.sorted { $0.night < $1.night }
        guard let lastNight = sorted.last else { return [.missingLastNight] }

        // 记录得是"昨晚"才算数,三天前的睡眠说明中间断了。
        let nightsAgo = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: lastNight.night),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        guard nightsAgo <= 1 else { return [.missingLastNight] }

        var triggers: [HealthTrigger] = []
        let hours = lastNight.asleep / 3600
        let baseline = sorted.dropLast().map(\.asleep)
        if !baseline.isEmpty {
            let average = baseline.reduce(0, +) / Double(baseline.count)
            let deficit = Int((average - lastNight.asleep) / 60)
            if deficit >= 45 {
                triggers.append(.shortSleep(hours: hours, deficitMinutes: deficit))
            }
        } else if hours < 6.5 {
            triggers.append(.shortSleep(hours: hours, deficitMinutes: 0))
        }

        // 入睡时间往后漂:最近三晚 vs 更早那几晚。
        let bedMinutes = sorted.compactMap { night -> Double? in
            guard let bedtime = night.bedtime else { return nil }
            let parts = calendar.dateComponents([.hour, .minute], from: bedtime)
            guard let hour = parts.hour, let minute = parts.minute else { return nil }
            // 凌晨入睡记成 24 点之后,否则 00:30 会被当成"最早入睡"。
            return Double(hour < 12 ? hour + 24 : hour) * 60 + Double(minute)
        }
        if bedMinutes.count >= 6 {
            let recent: [Double] = Array(bedMinutes.suffix(3))
            let earlier: [Double] = Array(bedMinutes.dropLast(3))
            let recentAverage: Double = recent.reduce(0, +) / Double(recent.count)
            let earlierAverage: Double = earlier.reduce(0, +) / Double(earlier.count)
            let drift = Int(recentAverage - earlierAverage)
            if drift >= 40 {
                triggers.append(.lateBedtimeDrift(minutes: drift))
            }
        }

        return triggers
    }

    private static func heartTriggers(_ days: [DayHeart]) -> [HealthTrigger] {
        var triggers: [HealthTrigger] = []
        let sorted = days.sorted { $0.date < $1.date }

        let resting = sorted.compactMap(\.restingHR)
        if let latest = resting.last, resting.count >= 4 {
            let baseline = resting.dropLast()
            let average = baseline.reduce(0, +) / Double(baseline.count)
            if latest - average >= 3 {
                triggers.append(.elevatedRestingHR(latest: Int(latest), baseline: Int(average)))
            }
        }

        let hrv = sorted.compactMap(\.hrv)
        if let latest = hrv.last, hrv.count >= 4 {
            let baseline = hrv.dropLast()
            let average = baseline.reduce(0, +) / Double(baseline.count)
            if average > 0, latest < average * 0.85 {
                triggers.append(.suppressedHRV(dropPercent: Int((1 - latest / average) * 100)))
            }
        }

        return triggers
    }

    private static func stepTriggers(
        _ days: [DayValue],
        now: Date,
        calendar: Calendar
    ) -> [HealthTrigger] {
        let sorted = days.sorted { $0.date < $1.date }
        guard sorted.count >= 4 else { return [] }

        let today = sorted.last { calendar.isDate($0.date, inSameDayAs: now) }
        let history = sorted.filter { !calendar.isDate($0.date, inSameDayAs: now) }
        guard !history.isEmpty else { return [] }
        let baseline = history.map(\.value).reduce(0, +) / Double(history.count)
        guard baseline > 0 else { return [] }

        // 一步没走:早上还说明不了什么,过了中午就值得问一句。
        if let today, today.value == 0, DayPeriod(at: now, calendar: calendar) != .morning {
            return [.noStepsToday]
        }
        if let today, today.value >= baseline * 1.5, today.value >= 12_000 {
            return [.bigActivityDay(steps: Int(today.value))]
        }

        let recent = history.suffix(3).map(\.value)
        if recent.count == 3 {
            let average = recent.reduce(0, +) / 3
            if average < baseline * 0.6 {
                return [.sedentaryStreak(days: 3)]
            }
        }

        return []
    }

    private static func bodyTriggers(_ days: [DayBody]) -> [HealthTrigger] {
        let weights = days.sorted { $0.date < $1.date }.compactMap { day -> (Date, Double)? in
            guard let weight = day.weight else { return nil }
            return (day.date, weight)
        }
        guard let first = weights.first, let last = weights.last, weights.count >= 4 else {
            return []
        }

        let delta = last.1 - first.1
        guard abs(delta) >= 1.0 else { return [] }

        let spanDays = Calendar.autoupdatingCurrent
            .dateComponents([.day], from: first.0, to: last.0).day ?? 14
        return [.weightShift(deltaKg: delta, days: max(spanDays, 1))]
    }
}

private extension Double {
    /// "5.2";整数就不带小数点。
    var oneDecimal: String {
        self == rounded() ? String(Int(self)) : String(format: "%.1f", self)
    }
}
