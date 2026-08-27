import Foundation
import AgentRuntime

struct HealthToolSpec: Sendable {
    let name: String
    let description: String
    /// 这个工具是否接受锻炼类型筛选(只有 workouts 需要)。
    let supportsActivityFilter: Bool
    let run: @Sendable (_ days: Int, _ activity: String?) async throws -> HealthReport

    init(
        name: String,
        description: String,
        supportsActivityFilter: Bool = false,
        run: @escaping @Sendable (_ days: Int, _ activity: String?) async throws -> HealthReport
    ) {
        self.name = name
        self.description = description
        self.supportsActivityFilter = supportsActivityFilter
        self.run = run
    }
}

private extension HealthToolSpec {
    var capabilityDefinition: CapabilityDefinition {
        var properties: [String: RuntimeJSONValue] = [
            "days": .object([
                "type": "integer",
                "description": "查询最近多少天，范围 1–90，默认 7",
                "minimum": 1,
                "maximum": 90
            ])
        ]

        if supportsActivityFilter {
            properties["activity"] = .object([
                "type": "string",
                "description": "只看某一类锻炼时传，留空表示全部",
                "enum": .array(HealthTools.activityNames.map(RuntimeJSONValue.string))
            ])
        }

        return CapabilityDefinition(
            name: name,
            description: description,
            inputSchema: .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array([.string("days")]),
                "additionalProperties": .bool(false)
            ]),
            strictPreferred: false
        )
    }
}

enum HealthTools {
    static let all: [HealthToolSpec] = [
        HealthToolSpec(
            name: "daily_steps",
            description: "当用户问及步数、活动量或久坐情况时调用。"
                + "返回最近若干天的每日步数、步行跑步距离、爬楼层数和运动分钟。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            async let window = HealthStore.shared.dailyActivity(days: dayCount)
            async let history = HealthStore.shared.dailySteps(days: HealthStore.baselineDays)
            return await renderActivity(
                try await window,
                days: dayCount,
                baseline: Baseline(try await history.map(\.value))
            )
        },
        HealthToolSpec(
            name: "sleep_summary",
            description: "当用户问及睡眠时长、入睡起床时间、睡眠分期（深睡/核心/REM）、"
                + "夜间醒来、睡眠效率或睡眠期间心率时调用。返回最近若干晚的逐晚数据。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            async let window = HealthStore.shared.sleepSummary(days: dayCount, includeHeartRate: true)
            async let history = HealthStore.shared.sleepSummary(days: HealthStore.baselineDays)
            return await renderSleep(
                try await window,
                days: dayCount,
                baseline: Baseline(try await history.map(\.asleep))
            )
        },
        HealthToolSpec(
            name: "heart_rate_summary",
            description: "当用户问及静息心率、HRV、全天心率高低、恢复或压力趋势时调用。"
                + "返回最近若干天的静息心率、心率变异性,以及每天心率的最低/最高/平均。"
                + "问「睡觉时心率多少」用 sleep_summary,那里有按每晚统计的睡眠期间心率。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            async let window = HealthStore.shared.heartRateSummary(days: dayCount)
            async let history = HealthStore.shared.heartRateSummary(days: HealthStore.baselineDays)
            let baseline = try await history
            return await renderHeart(
                try await window,
                days: dayCount,
                restingBaseline: Baseline(baseline.compactMap(\.restingHR)),
                hrvBaseline: Baseline(baseline.compactMap(\.hrv))
            )
        },
        HealthToolSpec(
            name: "workouts",
            description: "当用户问及锻炼、运动频率、运动时长、距离或活动消耗时调用。"
                + "返回最近若干天的锻炼记录,含时长、距离、消耗和平均/最高心率。"
                + "只关心某一种运动时传 activity（如“跑步”），筛选在数据层完成，比自己从全部记录里挑更可靠。",
            supportsActivityFilter: true
        ) { days, activity in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.workouts(days: dayCount, activity: activity)
            return renderWorkouts(values, days: dayCount, activity: activity)
        },
        HealthToolSpec(
            name: "body_metrics",
            description: "当用户问及体重、体脂或身体指标变化时调用。返回最近若干天有记录的体重和体脂趋势。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.bodyMetrics(days: dayCount)
            return renderBody(values, days: dayCount)
        },
        HealthToolSpec(
            name: "blood_pressure",
            description: "当用户问及血压、收缩压或舒张压时调用。返回最近若干天有记录的每日血压均值。"
                + "多数人没有这项数据（需要血压计或第三方 app 写入），没有记录时会明确说明。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.bloodPressureSummary(days: dayCount)
            return renderBloodPressure(values, days: dayCount)
        },
        HealthToolSpec(
            name: "vitals",
            description: "当用户问及血氧、呼吸频率或体温时调用。返回最近若干天有记录的每日均值。"
                + "这些项需要支持的 Apple Watch 或体温计，多数人只有部分数据，没有记录时会明确说明。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.vitalsSummary(days: dayCount)
            return renderVitals(values, days: dayCount)
        },
        HealthToolSpec(
            name: "correlations",
            description: "当用户问「什么影响了我的睡眠/心率」「某件事有没有用」「有什么规律」时调用。"
                + "把最近的数据按条件分成两组做对比（如锻炼当晚 vs 其他晚上的睡眠时长），返回每组天数和差值。"
                + "days 建议传 60 以上，样本太少不会有结果。"
        ) { days, _ in
            let dayCount = max(normalizedDays(days), 30)
            async let steps = HealthStore.shared.dailySteps(days: dayCount)
            async let nights = HealthStore.shared.sleepSummary(days: dayCount)
            async let hearts = HealthStore.shared.heartRateSummary(days: dayCount)
            async let sessions = HealthStore.shared.workouts(days: dayCount)

            let comparisons = HealthAnalysis.comparisons(
                steps: try await steps,
                nights: try await nights,
                hearts: try await hearts,
                sessions: try await sessions
            )
            return renderComparisons(comparisons, days: dayCount)
        },
        HealthToolSpec(
            name: "health_records",
            description: "当用户问及化验单、体检报告、血糖血脂等医院检查结果时调用。"
                + "返回「健康」里来自医院或诊所的化验和体征记录。"
                + "只有用户在「健康」App 里连过医疗机构才会有数据，没有时会明确说明。"
        ) { days, _ in
            // 化验单不是每周都有,窗口默认放到一年。
            let dayCount = max(days, 365)
            do {
                let items = try await HealthStore.shared.clinicalRecords(days: dayCount)
                return renderClinical(items, days: dayCount)
            } catch HealthStoreError.healthRecordsUnavailable {
                return healthRecordsUnavailableReport
            }
        }
    ]

    static func spec(named name: String) -> HealthToolSpec? {
        all.first { $0.name == name }
    }

    static let registry = CapabilityRegistry(
        definitions: all.map(\.capabilityDefinition)
    ) { invocation in
        guard let spec = spec(named: invocation.name) else {
            return CapabilityExecutionResult(
                output: .init(
                    kind: .text,
                    text: "不支持名为 \(invocation.name) 的健康工具。"
                ),
                isError: true
            )
        }

        do {
            let report = try await spec.run(
                days(fromInput: invocation.input),
                activity(fromInput: invocation.input)
            )
            return CapabilityExecutionResult(
                output: .init(
                    kind: .table,
                    text: report.modelText,
                    metadata: HealthReport.encodeForToolMetadata(report)
                ),
                isError: false
            )
        } catch {
            return CapabilityExecutionResult(
                output: .init(
                    kind: .text,
                    text: "健康数据查询失败：\(error.localizedDescription)"
                ),
                isError: true
            )
        }
    }

    /// 从工具参数的 JSON 字符串里取天数。引擎调用工具和界面显示说明都要用。
    static func days(fromInput input: String) -> Int {
        normalizedDays((try? RuntimeJSONValue.decode(from: input))?["days"]?.intValue ?? 7)
    }

    /// 锻炼类型筛选。只认目录里那几个名字,别的一律当没传。
    static func activity(fromInput input: String) -> String? {
        guard let value = (try? RuntimeJSONValue.decode(from: input))?["activity"]?.stringValue,
              activityNames.contains(value) else {
            return nil
        }
        return value
    }

    /// 与 `HealthStore` 给锻炼记录起的名字一致。
    static let activityNames = ["跑步", "骑行", "步行", "力量训练", "游泳", "徒步", "瑜伽", "高强度间歇训练"]

    /// 胶囊上那句「查询了…」。只有界面在读,所以本地化;模型侧一律走 `label(for:)`。
    static func note(for name: String, days: Int, activity: String? = nil) -> String {
        String(localized: "查询了最近 \(normalizedDays(days)) 天\(localizedLabel(for: name, activity: activity))")
    }

    /// `label(for:)` 的界面版。分成两份是因为 `label` 的另外几个读者是模型
    /// (召回的工具轨迹、兴趣画像)和中文语音词表——那几份跟着界面语言走就错了。
    static func localizedLabel(for name: String, activity: String? = nil) -> String {
        switch name {
        case "daily_steps":
            String(localized: "活动量")
        case "sleep_summary":
            String(localized: "睡眠")
        case "heart_rate_summary":
            String(localized: "静息心率与 HRV")
        case "workouts":
            activity.map(localizedActivityName) ?? String(localized: "锻炼")
        case "body_metrics":
            String(localized: "体重与体脂")
        case "blood_pressure":
            String(localized: "血压")
        case "vitals":
            String(localized: "血氧、呼吸与体温")
        case "correlations":
            String(localized: "数据之间的关联")
        case "health_records":
            String(localized: "化验与体检记录")
        default:
            String(localized: "健康数据")
        }
    }

    /// `activityNames` 是工具参数的取值,必须保持中文;界面显示时在这儿换一次。
    private static func localizedActivityName(_ name: String) -> String {
        switch name {
        case "跑步": String(localized: "跑步")
        case "骑行": String(localized: "骑行")
        case "步行": String(localized: "步行")
        case "力量训练": String(localized: "力量训练")
        case "游泳": String(localized: "游泳")
        case "徒步": String(localized: "徒步")
        case "瑜伽": String(localized: "瑜伽")
        case "高强度间歇训练": String(localized: "高强度间歇训练")
        default: name
        }
    }

    static func label(for name: String, activity: String? = nil) -> String {
        switch name {
        case "daily_steps":
            "活动量"
        case "sleep_summary":
            "睡眠"
        case "heart_rate_summary":
            "静息心率与 HRV"
        case "workouts":
            activity ?? "锻炼"
        case "body_metrics":
            "体重与体脂"
        case "blood_pressure":
            "血压"
        case "vitals":
            "血氧、呼吸与体温"
        case "correlations":
            "数据之间的关联"
        case "health_records":
            "化验与体检记录"
        default:
            "健康数据"
        }
    }

    private static func normalizedDays(_ days: Int) -> Int {
        min(max(days, 1), 90)
    }

    // MARK: - 活动量

    private static func renderActivity(
        _ values: [DayActivity],
        days: Int,
        baseline: Baseline?
    ) async -> HealthReport {
        let recorded = values.filter { $0.steps > 0 }
        guard !recorded.isEmpty else {
            return .empty(
                title: "最近 \(days) 天活动量",
                note: "没有步数记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
            )
        }

        let hasDistance = values.contains { $0.distance != nil }
        let hasFlights = values.contains { $0.flights != nil }
        let hasExercise = values.contains { $0.exerciseMinutes != nil }

        if days > 30 {
            var report = HealthReport(title: "最近 \(days) 天活动量（按周汇总）")
            report.columns = ["区间", "日均步数"]
                + (hasDistance ? ["日均距离 km"] : [])
                + (hasExercise ? ["日均运动 min"] : [])
            report.rows = weeklyGroups(values, date: \.date).map { group in
                let count = Double(group.items.count)
                var row = [formatSteps(group.items.map(\.steps).reduce(0, +) / count)]
                if hasDistance {
                    row.append(formatDecimal(average(group.items.compactMap(\.distance))))
                }
                if hasExercise {
                    row.append(formatInteger(average(group.items.compactMap(\.exerciseMinutes))))
                }
                return HealthReport.Row(group.range, row)
            }
            return report
        }

        var report = HealthReport(title: "最近 \(days) 天活动量")
        report.columns = ["日期", "步数"]
            + (hasDistance ? ["距离 km"] : [])
            + (hasFlights ? ["楼层"] : [])
            + (hasExercise ? ["运动 min"] : [])
        report.rows = values.map { item in
            var row = [formatSteps(item.steps)]
            if hasDistance {
                row.append(formatDecimal(item.distance))
            }
            if hasFlights {
                row.append(formatInteger(item.flights))
            }
            if hasExercise {
                row.append(formatInteger(item.exerciseMinutes))
            }
            return HealthReport.Row(formatDate(item.date), row)
        }

        let dailyAverage = values.map(\.steps).reduce(0, +) / Double(values.count)
        report.summary = ["日均 \(formatSteps(dailyAverage)) 步"]
        if let distance = average(values.compactMap(\.distance)) {
            report.summary.append("日均步行跑步距离 \(formatDecimal(distance)) km")
        }
        if let exercise = average(values.compactMap(\.exerciseMinutes)) {
            report.summary.append("日均运动 \(formatInteger(exercise)) 分钟")
        }
        if let line = baselineLine(baseline, current: dailyAverage, format: { "\(formatSteps($0)) 步" }) {
            report.summary.append(line)
        }

        if let series = await todayStepSeries() {
            report.series = [series]
        }
        return report
    }

    // MARK: - 睡眠

    private static func renderSleep(
        _ values: [NightSleep],
        days: Int,
        baseline: Baseline?
    ) async -> HealthReport {
        guard !values.isEmpty else {
            return .empty(
                title: "最近 \(days) 晚睡眠",
                note: "没有睡眠记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
            )
        }

        if days > 30 {
            var report = HealthReport(title: "最近 \(days) 天睡眠（按周汇总）")
            report.columns = ["区间", "平均睡着", "有记录"]
            report.rows = weeklyGroups(values, date: \.night).map { group in
                let average = group.items.map(\.asleep).reduce(0, +) / Double(group.items.count)
                return HealthReport.Row(group.range, [formatDuration(average), "\(group.items.count) 晚"])
            }
            return report
        }

        let hasStages = values.contains(where: \.hasStages)
        let hasHeart = values.contains { $0.heartRate != nil }

        // 标题要说的是「问了几天」,不是「查到几晚」。改写成"最近 5 晚"会把缺口洗掉:
        // 问最近 7 天、只有 5 晚有记录,和真的连着睡了 5 晚是两回事。
        var report = HealthReport(
            title: values.count == days
                ? "最近 \(days) 晚睡眠"
                : "最近 \(days) 天睡眠（\(values.count) 晚有记录）"
        )
        report.columns = ["日期", "睡着", "入睡–起床"]
            + (hasStages ? ["深睡 分", "核心 分", "REM 分"] : [])
            + ["清醒 分", "醒来 次", "效率 %"]
            + (hasHeart ? ["心率", "最低心率"] : [])
        report.rows = values.map { item in
            let bedtime = item.bedtime.map(formatTime) ?? "--:--"
            let wake = item.wake.map(formatTime) ?? "--:--"
            var row = [formatDuration(item.asleep), "\(bedtime)–\(wake)"]
            if hasStages {
                row.append(contentsOf: [
                    formatMinutes(item.deep),
                    formatMinutes(item.core),
                    formatMinutes(item.rem)
                ])
            }
            row.append(contentsOf: [
                formatMinutes(item.awake),
                "\(item.wakeCount)",
                formatInteger(item.efficiency)
            ])
            if hasHeart {
                row.append(formatInteger(item.heartRate))
                row.append(formatInteger(item.lowestHeartRate))
            }
            return HealthReport.Row(formatDate(item.night), row)
        }

        let averageAsleep = values.map(\.asleep).reduce(0, +) / Double(values.count)
        report.summary = ["平均睡着 \(formatDuration(averageAsleep))"]
        if hasStages {
            let deep = values.map(\.deep).reduce(0, +)
            let rem = values.map(\.rem).reduce(0, +)
            let total = values.map(\.asleep).reduce(0, +)
            if total > 0 {
                report.summary.append(
                    "深睡占 \(formatInteger(deep / total * 100))%，REM 占 \(formatInteger(rem / total * 100))%"
                )
            }
        } else {
            report.notes.append("这些记录没有分期数据（分期需要 Apple Watch 佩戴入睡），别按深睡不足解读。")
        }
        if let efficiency = average(values.compactMap(\.efficiency)) {
            report.summary.append("平均睡眠效率 \(formatInteger(efficiency))%")
        }
        let wakeCounts = values.map { Double($0.wakeCount) }
        if let wakes = average(wakeCounts), wakes > 0 {
            report.summary.append("平均每晚醒来 \(formatDecimal(wakes)) 次")
        }
        if let heart = average(values.compactMap(\.heartRate)) {
            report.summary.append("睡眠期间平均心率 \(formatInteger(heart)) 次/分")
        }
        if let line = baselineLine(baseline, current: averageAsleep, format: formatDuration) {
            report.summary.append(line)
        }
        if let last = values.last, let note = stalenessNote(latest: last.night, unit: "睡眠记录") {
            report.notes.append(note)
        }

        if let last = values.last,
           let bedtime = last.bedtime,
           let wake = last.wake,
           let series = await heartRateSeries(
               title: "\(formatDate(last.night)) 夜间逐小时心率",
               from: bedtime,
               to: wake
           ) {
            report.series = [series]
        }
        return report
    }

    // MARK: - 心率

    private static func renderHeart(
        _ values: [DayHeart],
        days: Int,
        restingBaseline: Baseline? = nil,
        hrvBaseline: Baseline? = nil
    ) async -> HealthReport {
        let recorded = values.filter {
            $0.restingHR != nil || $0.hrv != nil || $0.averageHR != nil
        }
        guard !recorded.isEmpty else {
            return .empty(
                title: "最近 \(days) 天心率",
                note: "没有静息心率或 HRV 记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
            )
        }

        if days > 30 {
            var report = HealthReport(title: "最近 \(days) 天心率（按周汇总）")
            report.columns = ["区间", "静息 次/分", "HRV ms"]
            report.rows = weeklyGroups(values, date: \.date).map { group in
                HealthReport.Row(group.range, [
                    formatInteger(average(group.items.compactMap(\.restingHR))),
                    formatInteger(average(group.items.compactMap(\.hrv)))
                ])
            }
            return report
        }

        let hasRange = recorded.contains { $0.lowestHR != nil || $0.highestHR != nil }

        var report = HealthReport(title: "最近 \(days) 天心率")
        report.columns = ["日期", "静息 次/分", "HRV ms"]
            + (hasRange ? ["最低", "最高", "全天平均"] : [])
        report.rows = recorded.map { item in
            var row = [formatInteger(item.restingHR), formatInteger(item.hrv)]
            if hasRange {
                row.append(contentsOf: [
                    formatInteger(item.lowestHR),
                    formatInteger(item.highestHR),
                    formatInteger(item.averageHR)
                ])
            }
            return HealthReport.Row(formatDate(item.date), row)
        }

        let restingValues = recorded.compactMap(\.restingHR)
        let hrvValues = recorded.compactMap(\.hrv)
        if let minimum = restingValues.min(), let maximum = restingValues.max() {
            report.summary.append("静息心率区间 \(formatInteger(minimum))–\(formatInteger(maximum)) 次/分")
        }
        if let minimum = hrvValues.min(), let maximum = hrvValues.max() {
            report.summary.append("HRV 区间 \(formatInteger(minimum))–\(formatInteger(maximum)) ms")
        }
        if let highest = recorded.compactMap(\.highestHR).max() {
            report.summary.append("全天最高心率 \(formatInteger(highest)) 次/分")
        }
        if let current = average(restingValues),
           let line = baselineLine(restingBaseline, current: current, format: { "\(formatInteger($0)) 次/分" }) {
            report.summary.append("静息心率 \(line)")
        }
        if let current = average(hrvValues),
           let line = baselineLine(hrvBaseline, current: current, format: { "\(formatInteger($0)) ms" }) {
            report.summary.append("HRV \(line)")
        }
        if let last = recorded.last, let note = stalenessNote(latest: last.date, unit: "记录") {
            report.notes.append(note)
        }

        let now = Date()
        if let series = await heartRateSeries(
            title: "今天逐小时平均心率",
            from: Calendar.autoupdatingCurrent.startOfDay(for: now),
            to: now
        ) {
            report.series = [series]
        }
        return report
    }

    // MARK: - 锻炼

    private static func renderWorkouts(
        _ values: [WorkoutItem],
        days: Int,
        activity: String? = nil
    ) -> HealthReport {
        guard !values.isEmpty else {
            let note = activity.map {
                "没有\($0)记录（其他类型的锻炼可能有，不带筛选再查一次即可）。"
            } ?? "没有锻炼记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
            return .empty(title: "最近 \(days) 天\(activity ?? "锻炼")", note: note)
        }

        if days > 30 {
            var report = HealthReport(title: "最近 \(days) 天\(activity ?? "锻炼")（按周汇总）")
            report.columns = ["区间", "次数", "时长", "kcal"]
            report.rows = weeklyGroups(values.sorted { $0.date < $1.date }, date: \.date).map { group in
                HealthReport.Row(group.range, [
                    "\(group.items.count)",
                    formatDuration(group.items.map(\.duration).reduce(0, +)),
                    formatInteger(group.items.compactMap(\.activeEnergy).reduce(0, +))
                ])
            }
            return report
        }

        let hasDistance = values.contains { $0.distance != nil }
        let hasHeart = values.contains { $0.averageHeartRate != nil }

        var report = HealthReport(title: "最近 \(days) 天\(activity ?? "锻炼")")
        report.columns = ["日期", "类型", "时长"]
            + (hasDistance ? ["距离 km"] : [])
            + ["kcal"]
            + (hasHeart ? ["平均心率", "最高心率"] : [])
        report.rows = values.map { item in
            var row = [item.typeName, formatDuration(item.duration)]
            if hasDistance {
                row.append(formatDecimal(item.distance))
            }
            row.append(formatInteger(item.activeEnergy))
            if hasHeart {
                row.append(formatInteger(item.averageHeartRate))
                row.append(formatInteger(item.maxHeartRate))
            }
            return HealthReport.Row(formatDate(item.date), row)
        }

        let duration = values.map(\.duration).reduce(0, +)
        report.summary = ["共 \(values.count) 次，合计 \(formatDuration(duration))"]
        if let distance = sum(values.compactMap(\.distance)) {
            report.summary.append("合计距离 \(formatDecimal(distance)) km")
        }
        return report
    }

    // MARK: - 身体指标与体征

    private static func renderBody(_ values: [DayBody], days: Int) -> HealthReport {
        guard !values.isEmpty else {
            return .empty(
                title: "最近 \(days) 天体重与体脂",
                note: "没有体重或体脂记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
            )
        }

        let rendered: [DayBody]
        if days > 30 {
            rendered = weeklyGroups(values, date: \.date).compactMap { group in
                let weights = group.items.compactMap(\.weight)
                let bodyFat = group.items.compactMap(\.bodyFat)
                guard !weights.isEmpty || !bodyFat.isEmpty else { return nil }
                return DayBody(
                    date: group.items.last?.date ?? group.items[0].date,
                    weight: average(weights),
                    bodyFat: average(bodyFat)
                )
            }
        } else {
            rendered = values
        }

        var report = HealthReport(
            title: days > 30 ? "最近 \(days) 天体重与体脂（按周均值）" : "最近 \(days) 天体重与体脂"
        )
        report.columns = ["日期", "体重 kg", "体脂 %"]
        report.rows = rendered.map { item in
            HealthReport.Row(formatDate(item.date), [
                formatDecimal(item.weight),
                formatDecimal(item.bodyFat)
            ])
        }

        if let first = values.compactMap(\.weight).first, let last = values.compactMap(\.weight).last {
            report.summary.append("体重变化 \(formatSigned(last - first, suffix: " kg"))")
        }
        if let first = values.compactMap(\.bodyFat).first, let last = values.compactMap(\.bodyFat).last {
            report.summary.append("体脂变化 \(formatSigned(last - first, suffix: " 个百分点"))")
        }
        return report
    }

    private static func renderBloodPressure(_ values: [DayBloodPressure], days: Int) -> HealthReport {
        let recorded = values.filter { $0.systolic != nil || $0.diastolic != nil }
        guard !recorded.isEmpty else {
            // 没数据是常态而不是故障,说清楚原因,别让模型把它当成"读取失败"。
            return .empty(
                title: "最近 \(days) 天血压",
                note: "没有血压记录。血压需要血压计或第三方 app 写入“健康”，Apple Watch 不测血压。"
                    + "如果确认记过，请在“健康”App > 共享 > App 里确认已允许 Vana 读取。"
            )
        }

        var report = HealthReport(title: "最近 \(days) 天血压（每日均值，mmHg）")
        report.columns = ["日期", "收缩压", "舒张压"]
        report.rows = recorded.map { item in
            HealthReport.Row(formatDate(item.date), [
                formatInteger(item.systolic),
                formatInteger(item.diastolic)
            ])
        }

        if let systolic = average(recorded.compactMap(\.systolic)),
           let diastolic = average(recorded.compactMap(\.diastolic)) {
            report.summary.append(
                "均值 \(formatInteger(systolic))/\(formatInteger(diastolic)) mmHg，共 \(recorded.count) 天有记录"
            )
        }
        return report
    }

    private static func renderVitals(_ values: [DayVitals], days: Int) -> HealthReport {
        let recorded = values.filter {
            $0.oxygen != nil || $0.respiratoryRate != nil
                || $0.wristTemperature != nil || $0.bodyTemperature != nil
        }
        guard !recorded.isEmpty else {
            return .empty(
                title: "最近 \(days) 天体征",
                note: "没有血氧、呼吸频率或体温记录。血氧和睡眠手腕温度需要支持的 Apple Watch 并开启对应功能，"
                    + "体温需要体温计写入。如果确认记过，请在“健康”App > 共享 > App 里确认已允许 Vana 读取。"
            )
        }

        let hasOxygen = recorded.contains { $0.oxygen != nil }
        let hasBreathing = recorded.contains { $0.respiratoryRate != nil }
        let hasWrist = recorded.contains { $0.wristTemperature != nil }
        let hasTemperature = recorded.contains { $0.bodyTemperature != nil }

        var report = HealthReport(title: "最近 \(days) 天体征（每日均值）")
        report.columns = ["日期"]
            + (hasOxygen ? ["血氧 %"] : [])
            + (hasBreathing ? ["呼吸 次/分"] : [])
            + (hasWrist ? ["手腕温度 ℃"] : [])
            + (hasTemperature ? ["体温 ℃"] : [])
        report.rows = recorded.map { item in
            var row: [String] = []
            if hasOxygen {
                row.append(formatDecimal(item.oxygen))
            }
            if hasBreathing {
                row.append(formatDecimal(item.respiratoryRate))
            }
            if hasWrist {
                row.append(formatDecimal(item.wristTemperature))
            }
            if hasTemperature {
                row.append(formatDecimal(item.bodyTemperature))
            }
            return HealthReport.Row(formatDate(item.date), row)
        }

        if let oxygen = average(recorded.compactMap(\.oxygen)) {
            report.summary.append("血氧均值 \(formatDecimal(oxygen))%")
        }
        if let breathing = average(recorded.compactMap(\.respiratoryRate)) {
            report.summary.append("呼吸频率均值 \(formatDecimal(breathing)) 次/分")
        }
        return report
    }

    // MARK: - 关联与病历

    private static func renderComparisons(_ comparisons: [Comparison], days: Int) -> HealthReport {
        guard !comparisons.isEmpty else {
            return .empty(
                title: "最近 \(days) 天的分组对比",
                note: "数据还不足以做对比（每组至少要有 3 天）。多记录一段时间再看。"
            )
        }

        var report = HealthReport(title: "最近 \(days) 天的分组对比")
        report.columns = ["对比项", "满足条件", "其余", "差值", "天数"]
        report.rows = comparisons.map { item in
            HealthReport.Row(item.label, [
                formatDecimal(item.withCondition),
                formatDecimal(item.withoutCondition),
                formatSigned(item.difference, suffix: ""),
                "\(item.withCount) / \(item.withoutCount)"
            ])
        }
        report.notes = [
            "单位跟随各项：睡眠为分钟，心率为次/分，HRV 为 ms。",
            "这是相关不是因果，样本量也小，只能当线索。"
        ]
        return report
    }

    /// 这台设备上根本没有「健康记录」时的那份输出。
    ///
    /// **和「没有记录」是两件事**,分开说(同没授权和没数据要分开说):那边该让用户去
    /// 「健康」App 里连医院,这边连都没得连,该说的是让他拍一张。也**不是错误**——
    /// 报成错误模型会以为工具坏了,换个说法再调一次,白花一轮。
    static let healthRecordsUnavailableReport = HealthReport.empty(
        title: "化验与体检记录",
        note: "这台设备上没有「健康记录」功能（它按地区开放，并非所有设备和地区都有），"
            + "所以这条路上读不到任何化验或体检数据。"
            + "要看化验单的话，请用户在输入框那颗「+」里拍一张、或者选一份报告文件。"
    )

    private static func renderClinical(_ items: [ClinicalItem], days: Int) -> HealthReport {
        guard !items.isEmpty else {
            return .empty(
                title: "化验与体检记录",
                note: "没有找到化验或体检记录。这类数据要先在“健康”App > 浏览 > 健康记录里"
                    + "连接医院或诊所才会有；国内多数机构尚未接入。"
            )
        }

        var report = HealthReport(title: "最近约 \(days) 天的化验与体征记录，共 \(items.count) 条")
        report.columns = ["日期", "类别", "项目", "结果"]
        report.rows = items.prefix(40).map { item in
            HealthReport.Row(formatFullDate(item.date), [
                item.category,
                item.name,
                item.value ?? HealthReport.missing
            ])
        }
        if items.count > 40 {
            report.notes.append("只列出最近 40 条。")
        }
        report.notes.append("这些是医疗机构的原始记录，解读请以出具报告的医生为准。")
        return report
    }

    // MARK: - 日内分布

    /// 今天到此刻为止的逐小时步数。只画给人看,不进 `modelText`。
    private static func todayStepSeries() async -> HealthReport.Series? {
        let now = Date()
        let start = Calendar.autoupdatingCurrent.startOfDay(for: now)
        guard let values = try? await HealthStore.shared.hourlySteps(from: start, to: now) else {
            return nil
        }
        return series(
            title: "今天逐小时步数",
            unit: "步",
            values: values,
            from: start,
            to: now,
            // 缺的那一小时是真的没走。
            fillsGapsWithZero: true
        )
    }

    private static func heartRateSeries(
        title: String,
        from start: Date,
        to end: Date
    ) async -> HealthReport.Series? {
        guard let values = try? await HealthStore.shared.hourlyHeartRate(from: start, to: end) else {
            return nil
        }
        // 缺的那一小时只是没测,不能画成 0。
        return series(title: title, unit: "次/分", values: values, from: start, to: end, fillsGapsWithZero: false)
    }

    private static func series(
        title: String,
        unit: String,
        values: [DayValue],
        from start: Date,
        to end: Date,
        fillsGapsWithZero: Bool
    ) -> HealthReport.Series? {
        let calendar = Calendar.autoupdatingCurrent
        guard end > start, !values.isEmpty else { return nil }

        let byHour = Dictionary(
            values.map { (calendar.dateInterval(of: .hour, for: $0.date)?.start ?? $0.date, $0.value) },
            uniquingKeysWith: { first, _ in first }
        )

        var points: [HealthReport.Series.Point] = []
        var cursor = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        while cursor < end, points.count < 48 {
            let hour = calendar.component(.hour, from: cursor)
            points.append(HealthReport.Series.Point(
                label: String(format: "%02d", hour),
                // 步数缺的那一小时是真的没走;心率缺的那一小时只是没测,不能画成 0。
                value: byHour[cursor] ?? (fillsGapsWithZero ? 0 : nil)
            ))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor) else { break }
            cursor = next
        }

        guard points.contains(where: { ($0.value ?? 0) > 0 }) else { return nil }
        return HealthReport.Series(title: title, unit: unit, points: points)
    }

    // MARK: - 公共计算

    /// "60 天基线 8,120 步（中位数，58 天有记录），本段比基线低 12%"
    ///
    /// 让模型跟"这个人平常什么样"比,而不是跟人群平均值或者它自己的印象比。
    private static func baselineLine(
        _ baseline: Baseline?,
        current: Double,
        format: (Double) -> String
    ) -> String? {
        guard let baseline else { return nil }
        var line = "\(HealthStore.baselineDays) 天基线 \(format(baseline.median))"
            + "（中位数，\(baseline.sampleCount) 天有记录）"
        if let deviation = baseline.deviation(of: current), abs(deviation) >= 5 {
            line += "，本段比基线\(deviation > 0 ? "高" : "低") \(Int(abs(deviation).rounded()))%"
        }
        return line
    }

    /// 最新一条比昨天还旧的时候明说。工具只返回有记录的那几行,断掉的那几天在表格里
    /// 是看不见的——模型会把最后一行当成昨天,于是拿三天前的数据讲「昨晚睡得怎么样」。
    ///
    /// 昨天(gap == 1)不算旧:昨晚的睡眠本来就标在昨天,今天的静息心率也常常要到晚上才出。
    private static func stalenessNote(latest: Date, unit: String) -> String? {
        let calendar = Calendar.autoupdatingCurrent
        let gap = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: latest),
            to: calendar.startOfDay(for: Date())
        ).day
        guard let gap, gap >= 2 else { return nil }
        return "最新的一条是 \(formatDate(latest))，距今 \(gap) 天，这之后没有\(unit)——不要当成昨天的数据。"
    }

    private static func weeklyGroups<Item>(
        _ items: [Item],
        date: KeyPath<Item, Date>
    ) -> [(range: String, items: [Item])] {
        stride(from: 0, to: items.count, by: 7).map { start in
            let end = min(start + 7, items.count)
            let group = Array(items[start..<end])
            let firstDate = group[0][keyPath: date]
            let lastDate = group[group.count - 1][keyPath: date]
            return ("\(formatDate(firstDate))–\(formatDate(lastDate))", group)
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func sum(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +)
    }

    // MARK: - 格式

    /// 化验单可能是几个月前的,只写月-日会看不出年份。
    private static func formatFullDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func formatDate(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", components.month ?? 0, components.day ?? 0)
    }

    private static func formatTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func formatSteps(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval.rounded()) / 60, 0)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 {
            return "\(remainingMinutes) 分钟"
        }
        if remainingMinutes == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(remainingMinutes) 分"
    }

    /// 分期时长在表格里只放分钟数,单位写在列名上——一列上下对齐才看得出哪晚深睡少。
    private static func formatMinutes(_ interval: TimeInterval) -> String {
        guard interval > 0 else { return HealthReport.missing }
        return "\(Int((interval / 60).rounded()))"
    }

    private static func formatInteger(_ value: Double?) -> String {
        guard let value else { return HealthReport.missing }
        return "\(Int(value.rounded()))"
    }

    private static func formatDecimal(_ value: Double?) -> String {
        guard let value else { return HealthReport.missing }
        return value.formatted(.number.precision(.fractionLength(1)))
    }

    private static func formatSigned(_ value: Double, suffix: String) -> String {
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }
}
