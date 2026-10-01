import Foundation
import Testing

@testable import Vana

/// 首屏那句话。
///
/// 两头各盯一件事:本地那句(`HealthSituation.quickSummary`)得永远说得出口,模型那句
/// (`QuickSummaryWriter`)得**拿不到原始数据**——多给一个数字就是多一个它可以写错的数字,
/// 而这句话是用户打开 app 读到的第一行。
@Suite("Quick summary")
struct QuickSummaryTests {

    // MARK: - 本地那句

    @Test("说的是最要紧那件事,不是时段套话")
    func leadsWithTheTopTrigger() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92)]
        )

        #expect(situation.quickSummary.contains("5.4"))
        #expect(situation.quickSummary.contains("92"))
    }

    @Test("最多两条。第三条往下该由那几颗 chip 去问")
    func staysAtTwoFacts() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [
                .shortSleep(hours: 5.4, deficitMinutes: 92),
                .elevatedRestingHR(latest: 61, baseline: 56),
                .weightShift(deltaKg: -1.4, days: 12)
            ]
        )

        #expect(situation.quickSummary.contains("5.4"))
        #expect(situation.quickSummary.contains("61"))
        // 第三条不进这句话,否则首屏就成了一份日报。
        #expect(!situation.quickSummary.contains("1.4"))
    }

    /// 排序是 `ordered` 的事,这句话只负责照着序列取。传进来的顺序就是要说的顺序。
    @Test("顺序跟着 triggers 走")
    func followsTriggerOrder() {
        let situation = HealthSituation(
            period: .afternoon,
            triggers: [
                .justTrained(name: "跑步", minutes: 42, endedMinutesAgo: 20),
                .shortSleep(hours: 5.4, deficitMinutes: 92)
            ]
        )

        let summary = situation.quickSummary
        let trained = summary.range(of: "跑步")
        let slept = summary.range(of: "5.4")
        #expect(trained != nil && slept != nil)
        #expect(trained!.lowerBound < slept!.lowerBound)
    }

    /// 「今天是周一」不是数据里发生的事。它排最后一名,只有别的什么都没有时才轮得到第一,
    /// 而那时候该说的是现状——不是"周一早上,适合回顾上一周"。
    @Test("周一那条不算一件发生过的事")
    func weeklyReviewIsNotAnObservation() {
        let situation = HealthSituation(period: .morning, triggers: [.weeklyReview])

        #expect(situation.quickSummary == HealthSituation.calmSummary)
        #expect(situation.notableTriggers.isEmpty)
    }

    /// **这条是这套东西存在的理由。** 没有波动不等于没有现状:多数人多数天里数据本来就是
    /// 平稳的,第一版在那些天里说的是一句「没读到值得特别留意的波动」——一个数字都没有,
    /// 用户读完仍然不知道自己现在怎么样。
    @Test("没有波动时说现状,不说一句空话")
    func fallsBackToCurrentReadings() {
        let situation = HealthSituation(
            period: .evening,
            triggers: [],
            vitals: Self.vitals
        )

        let summary = situation.quickSummary
        #expect(summary != HealthSituation.calmSummary)
        #expect(summary.contains("7.2"))
        #expect(summary.contains("6,240"))
    }

    /// 现状也是三项打住。首屏这段话是"几秒钟看完"的东西,剩下的在详情页里一项不少。
    @Test("现状最多三项")
    func readingsStopAtThree() {
        let situation = HealthSituation(period: .evening, triggers: [], vitals: Self.vitals)

        #expect(!situation.quickSummary.contains("70.4"))
    }

    /// 有触发点时仍然由触发点开头:那才是他此刻打开 app 的原因,现状点开就在下一页。
    @Test("有波动时波动优先")
    func triggersOutrankReadings() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92)],
            vitals: Self.vitals
        )

        #expect(situation.quickSummary.contains("92"))
        #expect(!situation.quickSummary.contains("6,240"))
    }

    /// 一个读数都拿不到时那一句说的**不是**「他很平稳」,而是这台设备上什么都没读到。
    /// 更不能写成「一切正常」:没看过的项目没有资格替用户下结论。
    @Test("什么都没读到时照实说没读到,不宣布一切正常")
    func calmSummaryDoesNotOverclaim() {
        let situation = HealthSituation(period: .evening, triggers: [])

        #expect(situation.quickSummary == HealthSituation.calmSummary)
        #expect(!situation.quickSummary.contains("正常"))
        #expect(!situation.quickSummary.contains("一切"))
        #expect(!situation.hasSummaryFacts)
    }

    // MARK: - 发给模型的那份

    /// **这条最要紧。** 喂进去的只有本地判定好的一行行结论(现状 + 触发点),没有十四天的
    /// 逐日样本——多给的每一个数字都是它可以写进句子里的数字。同 `MemoryExtractor` 不喂
    /// 工具输出。
    @Test("只喂结论,不喂原始数据")
    func requestCarriesConclusionsOnly() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92)]
        )
        let request = QuickSummaryWriter.request(for: situation)

        #expect(request.contains("5.4"))
        #expect(request.contains("早上"))
        // 首屏那三条问题要看原始数据才写得具体,这段话不看。工具名出现在这儿就说明
        // 有人把 `QuestionSuggester.digest()` 那套接过来了。
        #expect(!request.contains("sleep_summary"))
        #expect(!request.contains("daily_steps"))
    }

    /// 现状是主料:平稳的日子里它是模型手上**唯一**的材料,没有它那次调用只能写空话。
    @Test("现状带着对比一起喂进去")
    func requestCarriesReadings() {
        let situation = HealthSituation(period: .evening, triggers: [], vitals: Self.vitals)
        let request = QuickSummaryWriter.request(for: situation)

        #expect(request.contains("7.2 小时"))
        #expect(request.contains("比最近 6 晚平均多 18 分钟"))
        // 没有波动时要明说一句。不说的话模型会去猜这几行里哪个算异常——它没有基线,
        // 只能瞎猜,而猜出来的那句正好是最不该出现在首屏的一句。
        #expect(request.contains("没有读到值得特别留意的波动"))
    }

    /// 读不到的项目不进 prompt。「昨晚没有记录」写进去,模型多半会把它当成一件值得说的事
    /// 摆到句子开头,而那只是他昨晚没戴表。
    @Test("没读到的项目不喂给模型")
    func requestSkipsMissingReadings() {
        let vitals = HealthVitals(items: [
            VitalItem(kind: .sleep, title: "昨晚睡眠", icon: "moon.zzz", value: nil, note: "昨晚没有记录")
        ])
        let situation = HealthSituation(period: .evening, triggers: [], vitals: vitals)

        #expect(!QuickSummaryWriter.request(for: situation).contains("没有记录"))
        #expect(!situation.hasSummaryFacts)
    }

    @Test("周一那条不进发给模型的事实")
    func requestSkipsWeeklyReview() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92), .weeklyReview]
        )

        #expect(!QuickSummaryWriter.request(for: situation).contains("回顾上一周"))
    }

    // MARK: - 收模型那句

    @Test("两句写成两行也要拼回一句")
    func joinsMultipleLines() {
        let parsed = QuickSummaryWriter.parse("昨晚只睡了 5.4 小时，比平时少了一个半小时。\n今天别安排大强度。")

        #expect(parsed == "昨晚只睡了 5.4 小时，比平时少了一个半小时。今天别安排大强度。")
    }

    @Test("剥掉编号和引号那层壳")
    func stripsShell() {
        #expect(QuickSummaryWriter.parse("「昨晚睡得比平时短一些，白天注意点。」")
            == "昨晚睡得比平时短一些，白天注意点。")
    }

    /// 写超了就整句作废,退回本地那句。截断更糟:一句话在"要不要在意"之前被切断,
    /// 剩下的半句正好是最没用的那半句。
    @Test("写超了就作废,不截断")
    func rejectsOverlongText() {
        let long = String(repeating: "睡", count: QuickSummaryWriter.maxCharacters + 1)

        #expect(QuickSummaryWriter.parse(long) == nil)
    }

    @Test("一个字没写也作废")
    func rejectsEmptyText() {
        #expect(QuickSummaryWriter.parse("\n\n") == nil)
        #expect(QuickSummaryWriter.parse("好的") == nil)
    }

    /// 流式期间显示的是半截文本,那时候按长度判永远不合格——只剥壳,别的等写完再说。
    @Test("写到一半也显示得出来")
    func partialKeepsWhatIsWrittenSoFar() {
        #expect(QuickSummaryWriter.partial("昨晚睡了 7.2 小") == "昨晚睡了 7.2 小")
        #expect(QuickSummaryWriter.partial("\n昨晚睡了") == "昨晚睡了")
    }

    // MARK: - 固定材料

    /// 一份平稳的现状。四项,第四项用来盯"最多说三项"。
    static let vitals = HealthVitals(items: [
        VitalItem(
            kind: .sleep, title: "昨晚睡眠", icon: "moon.zzz",
            value: "7.2 小时", note: "比最近 6 晚平均多 18 分钟"
        ),
        VitalItem(
            kind: .steps, title: "今天步数", icon: "figure.walk",
            value: "6,240 步", note: "最近平常 8,100 步"
        ),
        VitalItem(
            kind: .restingHR, title: "静息心率", icon: "heart",
            value: "58 次/分", note: "和最近基线 57 差不多"
        ),
        VitalItem(
            kind: .weight, title: "体重", icon: "scalemass",
            value: "70.4 公斤", note: "14 天里基本没变"
        )
    ])
}

/// 现状是怎么从那五份数据里读出来的。
///
/// 盯的都是**"读不到"和"是 0"分得开**这一类:昨晚没戴表和昨晚睡了两小时,在健康数据里
/// 差得很远,而在一张摊平的卡片上看着一模一样。
@Suite("Health vitals")
struct HealthVitalsTests {
    /// 2026-03-10 20:00,一个固定的晚上。
    static let now = Date(timeIntervalSince1970: 1_773_144_000)
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return calendar
    }

    private static func read(
        steps: [DayValue] = [],
        nights: [NightSleep] = [],
        hearts: [DayHeart] = [],
        sessions: [WorkoutItem] = [],
        body: [DayBody] = []
    ) -> HealthVitals {
        HealthVitals.read(
            steps: steps, nights: nights, hearts: hearts, sessions: sessions, body: body,
            now: now, calendar: calendar
        )
    }

    private static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: -offset, to: now)!
    }

    @Test("昨晚的睡眠算现状")
    func readsLastNight() {
        let vitals = Self.read(nights: [
            NightSleep(night: Self.day(1), asleep: 7.2 * 3600, bedtime: nil, wake: nil),
            NightSleep(night: Self.day(0), asleep: 7 * 3600, bedtime: nil, wake: nil)
        ])
        let sleep = vitals.items.first { $0.kind == .sleep }

        #expect(sleep?.value == "7 小时")
        #expect(sleep?.phrase == "昨晚睡了 7 小时")
    }

    /// 三天前那条不是"现状"。拿它当昨晚,报出来的是一个过期的数——而中间断掉的那两晚
    /// 恰恰是他该知道的事。
    @Test("三天前的睡眠不算,照实说昨晚没有记录")
    func staleSleepIsNotCurrent() {
        let vitals = Self.read(nights: [
            NightSleep(night: Self.day(3), asleep: 7 * 3600, bedtime: nil, wake: nil)
        ])
        let sleep = vitals.items.first { $0.kind == .sleep }

        #expect(sleep?.value == nil)
        #expect(sleep?.note == "昨晚没有记录")
        // 读不到的项目一行都不进句子,也不进 prompt。
        #expect(vitals.measured.isEmpty)
        #expect(vitals.isEmpty)
    }

    /// 差得不多就说差不多,不报那个数。静息心率日间本来就晃一两次,把「比基线高 1 次」
    /// 写进去,模型会认真解释一个纯噪声。
    @Test("噪声大小的差别说成差不多")
    func smallDeltasReadAsUnchanged() {
        let hearts = (0...4).map { offset in
            DayHeart(date: Self.day(4 - offset), restingHR: offset == 4 ? 58 : 57, hrv: nil)
        }
        let resting = Self.read(hearts: hearts).items.first { $0.kind == .restingHR }

        #expect(resting?.value == "58 次/分")
        #expect(resting?.note?.contains("差不多") == true)
    }

    @Test("差得多就报差多少")
    func realDeltasCarryTheNumber() {
        let hearts = (0...4).map { offset in
            DayHeart(date: Self.day(4 - offset), restingHR: offset == 4 ? 64 : 57, hrv: nil)
        }
        let resting = Self.read(hearts: hearts).items.first { $0.kind == .restingHR }

        #expect(resting?.note == "比最近基线 57 多 7 次")
    }

    /// 步数是攒了一天的量,不是一个瞬时值。上午八点两千步远低于日均,那是时间还早,
    /// 不是他今天动得少——所以只报平常是多少,不替它下"偏少"的判断。
    @Test("步数只报常态,不判偏多偏少")
    func stepsReportBaselineWithoutJudging() {
        let steps = (0...3).map { DayValue(date: Self.day(3 - $0), value: $0 == 3 ? 2_000 : 8_000) }
        let item = Self.read(steps: steps).items.first { $0.kind == .steps }

        #expect(item?.value == "2,000 步")
        #expect(item?.note == "最近平常 8,000 步")
        #expect(item?.note?.contains("少") == false)
    }

    @Test("今天没有步数记录时那一项是空的,不是 0 步")
    func missingStepsAreNotZero() {
        let steps = [DayValue(date: Self.day(2), value: 8_000)]
        let item = Self.read(steps: steps).items.first { $0.kind == .steps }

        #expect(item?.value == nil)
        #expect(item?.note == "今天还没有记录")
    }

    /// 一步都没记过的设备上,「0 步（最近平常 0 步）」是一行纯噪声——那不是他没动,是没在记。
    /// 反过来有基线时的"今天 0 步"是真的有话要说,不能一起挡掉。
    @Test("从来没记过步和今天 0 步是两件事")
    func allZeroStepsReadAsNoRecord() {
        let silent = (0...3).map { DayValue(date: Self.day($0), value: 0) }
        #expect(Self.read(steps: silent).items.first { $0.kind == .steps }?.value == nil)

        let idleToday = (0...3).map { DayValue(date: Self.day($0), value: $0 == 0 ? 0 : 8_000) }
        #expect(Self.read(steps: idleToday).items.first { $0.kind == .steps }?.value == "0 步")
    }

    @Test("锻炼说清是几天前的事")
    func workoutCarriesHowLongAgo() {
        let item = Self.read(sessions: [
            WorkoutItem(date: Self.day(2), typeName: "跑步", duration: 42 * 60, activeEnergy: nil)
        ]).items.first { $0.kind == .workout }

        #expect(item?.value == "2 天前的跑步 42 分钟")
    }

    /// 一项都没读到时,那几行仍然在列表里(带着「没有记录」)——直接不显示的话,用户只会
    /// 以为 app 没看那一项。
    @Test("读不到也留在列表里")
    func missingItemsStayVisible() {
        let vitals = Self.read()

        #expect(vitals.items.count == 6)
        #expect(vitals.items.allSatisfy { $0.value == nil })
        #expect(vitals.items.allSatisfy { $0.note != nil })
    }
}
