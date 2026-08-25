import Foundation
import HealthKit

struct DayValue: Sendable, Equatable {
    let date: Date
    let value: Double
}

struct NightSleep: Sendable, Equatable {
    let night: Date
    let asleep: TimeInterval
    let bedtime: Date?
    let wake: Date?
    /// 分期时长。只有 Apple Watch 记的睡眠才分期;iPhone 写的是 asleepUnspecified,
    /// 这三项就都是 0——那种情况下别去解读"深睡不足"。
    var deep: TimeInterval = 0
    var core: TimeInterval = 0
    var rem: TimeInterval = 0
    /// 卧床期间清醒的时长,和入睡后醒来的次数。
    var awake: TimeInterval = 0
    var wakeCount: Int = 0
    /// 睡眠时段的平均心率和最低心率。
    var heartRate: Double?
    var lowestHeartRate: Double?

    /// 睡眠效率:睡着的时间占卧床时间的百分比。
    var efficiency: Double? {
        guard let bedtime, let wake else { return nil }
        let inBed = wake.timeIntervalSince(bedtime)
        guard inBed > 0, asleep > 0 else { return nil }
        return min(asleep / inBed, 1) * 100
    }

    /// 分期数据存在才有意义:三项全 0 说明这晚只有"睡着"没有分期。
    var hasStages: Bool { deep > 0 || core > 0 || rem > 0 }
}

struct DayHeart: Sendable, Equatable {
    let date: Date
    let restingHR: Double?
    let hrv: Double?
    /// 全天心率的低/高/平均。静息心率只有一天一个值,看不出白天冲到过多少。
    var lowestHR: Double?
    var highestHR: Double?
    var averageHR: Double?
}

struct WorkoutItem: Sendable, Equatable {
    let date: Date
    let typeName: String
    let duration: TimeInterval
    let activeEnergy: Double?
    /// 公里。跑步/骑行/游泳各自的距离类型,取到哪个算哪个。
    var distance: Double?
    var averageHeartRate: Double?
    var maxHeartRate: Double?
}

/// 一天的活动量。步数之外还有距离、爬楼和运动分钟——只报步数会把骑行和力量训练
/// 那种"步数不动但练了"的日子说成久坐。
struct DayActivity: Sendable, Equatable {
    let date: Date
    let steps: Double
    /// 公里。
    var distance: Double?
    var flights: Double?
    var exerciseMinutes: Double?
}

struct DayBloodPressure: Sendable, Equatable {
    let date: Date
    let systolic: Double?
    let diastolic: Double?
}

/// 血氧、呼吸频率、体温——都是"有就看看,没有很正常"的项。
struct DayVitals: Sendable, Equatable {
    let date: Date
    /// 百分比,已经乘过 100。
    let oxygen: Double?
    let respiratoryRate: Double?
    /// 睡眠期间的手腕温度(Apple Watch),摄氏度。
    let wristTemperature: Double?
    let bodyTemperature: Double?
}

struct DayBody: Sendable, Equatable {
    let date: Date
    let weight: Double?
    let bodyFat: Double?
}

/// 一条化验/体征记录。来自医院或诊所同步进「健康」的 FHIR 数据。
struct ClinicalItem: Sendable, Equatable {
    let date: Date
    let name: String
    /// "5.4 mmol/L";没有数值的记录(诊断、用药)这里是 nil。
    let value: String?
    let category: String
}

/// HealthKit 读取层,只读不写。所有查询返回按天聚合值(工具输出要紧凑)。
final class HealthStore: Sendable {
    /// 这台设备上的健康数据**只有机主一个人的**(见 `Tenant.Kind`)。
    ///
    /// 归属这件事的真正防线在调用方:健康工具在家人身上一个都不挂,`HealthSituation`、
    /// `SpokenBrief`、check-in 也都不跑。这里这道断言是补网——漏掉其中一条路的后果是把机主的
    /// 数字端到另一个人名下,静默、看着正常、事后查不出来,所以宁可在开发期当场崩掉。
    ///
    /// 只在 DEBUG 崩。线上真漏了一条,让用户看到一个错的数字也好过让 app 挂掉——但那条路
    /// 应该在这之前就被这句断言逼出来了。
    static var shared: HealthStore {
        assert(
            TenantScope.isOwnerActive,
            "当前是家人成员（\(TenantScope.current.displayName)），这台设备的健康数据不属于他。"
                + "调用方应该先按 Tenant.isOwner 挡住这条路。"
        )
        return owner
    }

    /// 不看当前选中的是谁。check-in、Siri 播报、后台派生这几件从头到尾都是机主的事,
    /// 它们要的就是这一份(同 `TenantScope.ownerStores`)。
    static let owner = HealthStore()

    /// 算个人基线用多长的窗口。
    ///
    /// 60 天而不是 14 天:两周里一次熬夜就能把"平常"拉偏一大截。取中位数而不是均值,
    /// 出于同一个理由——异常值不该定义什么叫正常。
    static let baselineDays = 60

    private let store = HKHealthStore()
    private let calendar = Calendar.autoupdatingCurrent

    private static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.distanceCycling),
        HKQuantityType(.distanceSwimming),
        HKQuantityType(.flightsClimbed),
        HKQuantityType(.appleExerciseTime),
        HKQuantityType(.restingHeartRate),
        // 逐次心率。静息心率是一天一个汇总值,睡眠期间心率、白天峰值都得从这里来。
        HKQuantityType(.heartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.bodyMass),
        HKQuantityType(.bodyFatPercentage),
        HKCategoryType(.sleepAnalysis),
        HKObjectType.workoutType(),
        // 下面这几项多数人没有数据(血压要血压计、血氧和手腕温度要够新的 Apple Watch)。
        // 照样申请:授权本身不要求有数据,等用户以后真的记了就直接能读到。
        HKQuantityType(.oxygenSaturation),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.bodyTemperature),
        HKQuantityType(.appleSleepingWristTemperature)
    ]

    /// 真的要读的时候才申请的类型。
    ///
    /// 血压和病历都有同一个毛病:授权状态永远停在 `shouldRequest`。血压在 HealthKit 里
    /// 是一对关联数据,授权面板上只有"血压"一行,给了之后两个数量类型各自查仍然算没决定;
    /// 病历在模拟器上根本给不了。于是只要它们在启动请求里,每次启动都会弹一次面板又被
    /// 立刻收回去——就是那个闪屏,而且永远闪不完。
    ///
    /// 挪到按需申请还顺带解决了另一件事:用户还没问任何问题,就弹窗要读化验单,本来
    /// 就过界了。
    private static let bloodPressureReadTypes: Set<HKObjectType> = [
        HKQuantityType(.bloodPressureSystolic),
        HKQuantityType(.bloodPressureDiastolic)
    ]

    private static let clinicalReadTypes: Set<HKObjectType> = [
        HKClinicalType(.labResultRecord),
        HKClinicalType(.vitalSignRecord)
    ]

    /// 病历(FHIR)那套东西**不是每台设备上都存在的**。Health Records 按地区开放,
    /// 设备和账号的状态也算数,SDK 头文件里那句话写得很直白:
    /// "Call supportsHealthRecords before attempting to request authorization for any
    /// clinical types."
    ///
    /// **2026-08-21 那次审核就栽在这条上**:iPad Air (M4) 上按设置页那颗
    /// 「请求读取 Apple 健康」,那一行就一直停在「正在请求…」——面板没弹出来,请求也没回话。
    /// 启动时那次请求(只有普通数据类型)在同一台设备上照常弹了面板,两次的差别只有一处:
    /// 设置页那次多带了这两个病历类型。要读的东西不在这台设备上,就不要去问——问了连
    /// 「问不到」都不会告诉你。
    ///
    /// 每次现问,不缓存:文档里明说它会随着账号在恢复、同步过程中被改动而变化。
    var supportsHealthRecords: Bool { store.supportsHealthRecords() }

    /// 同一件事,但**不在主线程上问,而且带一个头**。
    ///
    /// 它是同步 API,而它要读的是地区和账号状态(账号正在恢复/同步时尤其)。授权那条路
    /// 跑在 `@MainActor` 上,用户此刻刚按下按钮——这里卡一下就是界面卡一下。问不出来时
    /// 按 false 走:少问病历那两类,总好过为一个 Bool 把这颗按钮拖住(而 false 恰好是
    /// 2026-08-21 那次拒绝要的那一侧)。
    private static func supportsHealthRecords(_ store: HKHealthStore) async -> Bool {
        let supports = try? await withDeadline(statusTimeout) { store.supportsHealthRecords() }
        return supports ?? false
    }

    /// 这一次请求要问哪些类型。
    ///
    /// force 时把按需那几类也一起问了:设置页那个按钮是用户主动点的,一次问全比让他们
    /// 各点一遍强。**但病历那两类得先问这台设备有没有**——`supportsHealthRecords` 从外面
    /// 传进来,因为它是真机上的地区/账号状态,测试里造不出那台设备,而这条判断恰恰是
    /// 2026-08-21 那次审核卡住的地方(见 `supportsHealthRecords`)。
    static func requestedTypes(force: Bool, supportsHealthRecords: Bool) -> Set<HKObjectType> {
        guard force else { return readTypes }
        var requested = readTypes.union(bloodPressureReadTypes)
        if supportsHealthRecords {
            requested.formUnion(clinicalReadTypes)
        }
        return requested
    }

    /// 一次运行里只自动问一次。
    ///
    /// 从设置返回时 SwiftUI 会让根视图重新 appear,挂在上面的 `.task` 跟着重跑;
    /// 每跑一次就请求一次授权,面板就闪一次。设置页那个按钮传 `force: true` 绕开它。
    @MainActor private static var hasRequestedThisLaunch = false

    /// 查询类调用的上限。这几个(`statusForAuthorizationRequest`)不弹任何 UI,该立刻回话
    /// ——**没有一个正当理由让它花掉 5 秒**,所以超了就是系统那边不回话了。
    static let statusTimeout = Duration.seconds(5)

    /// 面板类调用的上限。人站在面板前做决定要几秒到十几秒,所以放得宽:它挡的不是"用户慢",
    /// 是"面板压根没出现,而这一侧还在 await"。只有回复中途那条路(`requestOnDemand`)会等它。
    static let panelTimeout = Duration.seconds(30)

    /// 面板请求发出去多久之后就当它没成。超过这个数,下一次按按钮可以再发一次——
    /// 面板真在屏幕上的时候用户根本碰不到那颗按钮。
    static let panelStaleAfter = Duration.seconds(60)

    /// 上一次真的问出去的是哪一组类型(它们标识符的指纹)。
    ///
    /// **这是「点一下,面板闪一下就没了」的解药。** 血压那两个类型的授权状态永远停在
    /// `shouldRequest`(见 `bloodPressureReadTypes`),所以
    /// `statusForAuthorizationRequest` 每次都说「还要问」;而 iOS 那边其实已经没有什么
    /// 好问的了,于是 `requestAuthorization` 把面板推上来、当场再收回去。**用户看到的
    /// 就是屏幕闪了一下,什么都没发生**——2026-08-25 审核报的「按了没反应」,极可能就是
    /// 这一下(那台设备上启动时已经问过一轮了)。
    ///
    /// 所以记住上一次问的是哪一组:同一组不再问第二遍,照实说「都已经问过了」并把用户
    /// 指到「健康」App(那才是能改的地方)。**指纹按类型算,不是一个 Bool**——以后版本
    /// 里加了新的数据类型,这一组就变了,那颗按钮立刻恢复它本来的用处
    /// (「新增的数据类型需要重新请求」)。
    static let askedTypesKey = "healthAuthorizationAskedTypes"

    static func fingerprint(of types: Set<HKObjectType>) -> String {
        types.map(\.identifier).sorted().joined(separator: "|")
    }

    /// 上一次把面板扔出去是什么时候。**只用来防重复,不用来阻塞任何人**。
    @MainActor private var panelRequestedAt: ContinuousClock.Instant?

    @MainActor
    private var isPanelInFlight: Bool {
        guard let panelRequestedAt else { return false }
        return ContinuousClock.now - panelRequestedAt < Self.panelStaleAfter
    }

    /// 需要问的时候才问,返回**这次有没有把面板扔出去**。
    ///
    /// ## 这一侧不 await 面板
    ///
    /// 这是整块东西的关键判断,推翻了原来那版(以及第一次修它的那版)。
    ///
    /// `requestAuthorization` 那次 await 的结果**这一侧本来就用不上**:iOS 从不告诉 app
    /// 读取权限被拒了(拒绝和「没有数据」长得一模一样),所以等它回来,界面上能多说的
    /// 只有一句「你的选择已保存」——而用户刚在面板上按完,他比谁都清楚。
    ///
    /// 拿一句零信息的话去换「这颗按钮可能永远 disable 在正在请求上」,是这两次被拒的
    /// 共同根源(2026-08-21 / 2026-08-25)。所以现在:**要等的只有那次纯查询**(它不弹
    /// UI、该立刻回话、有 5 秒上限),面板扔出去就返回。
    ///
    /// 顺带修掉了第一版超时的一处反噬:给整条路径设 8 秒上限,会在用户正读着面板的第 8 秒
    /// 报一句「系统的授权面板没有响应」——而它明明就在他眼前。**唯一能等的东西,是那个
    /// 不需要人参与的东西。**
    @MainActor
    @discardableResult
    func requestAuthorizationIfNeeded(force: Bool = false) async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthStoreError.healthDataUnavailable
        }
        if !force {
            guard !Self.hasRequestedThisLaunch else { return false }
        }
        Self.hasRequestedThisLaunch = true

        // 已经有一张面板在飞:不叠第二次(HealthKit 对着自己弹两张的行为没有保证)。
        // 但也**不等它**——照实说面板已经请求过了,界面那边照旧有下一句话。
        guard !isPanelInFlight else { return true }

        let requested = Self.requestedTypes(
            force: force,
            supportsHealthRecords: await Self.supportsHealthRecords(store)
        )
        let status = try await Self.withDeadline(Self.statusTimeout) { [store] in
            try await store.statusForAuthorizationRequest(toShare: [], read: requested)
        }
        guard status == .shouldRequest else { return false }

        // 同一组类型问过一次就不再问:再问一次换来的只是面板闪一下(见 `askedTypesKey`)。
        let fingerprint = Self.fingerprint(of: requested)
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.askedTypesKey) != fingerprint else { return false }
        defaults.set(fingerprint, forKey: Self.askedTypesKey)

        present(requested)
        return true
    }

    /// 把面板扔出去,不等它。
    @MainActor
    private func present(_ types: Set<HKObjectType>) {
        panelRequestedAt = ContinuousClock.now
        Task { @MainActor [store] in
            // 失败了也没有人在等这个结果:面板出不来的那次,界面上那句话已经说过了。
            try? await store.requestAuthorization(toShare: [], read: types)
            panelRequestedAt = nil
        }
    }

    /// 给一次可能不回话的系统调用套一个上限。
    ///
    /// HealthKit 既没有超时也没有取消 API,所以**每一处 await 都必须自己带一个头**。
    /// 超时不代表那次调用停了(停不了),它只代表这一侧不再等——而这一侧不等,用户才有下一步。
    static func withDeadline<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw HealthStoreError.authorizationTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw HealthStoreError.authorizationTimedOut
            }
            return first
        }
    }

    /// 后台读数据之前能问清楚的三种状态。
    enum ReadAccess: Sendable {
        case ready
        /// 还没问过授权。后台弹不出面板,只能让用户先打开 app。
        case notRequested
        case unavailable
    }

    /// 现在能不能直接读,**不弹任何 UI**。
    ///
    /// Siri 那条路跑在后台,授权面板推不上来。所以在查之前先问一句:没问过授权就照实说
    /// "先打开 Vana",而不是查出一片空然后报"最近没有数据"——后者是在撒谎。
    ///
    /// 那条路**自己也有超时**:这一句悬住,用户听到的是「出了点问题」,连一句能照着做的话
    /// 都没有。所以它也带一个头(`statusTimeout`)。问不出来时按 `.ready`
    /// 走下去——真没授权的话下一步查出来是空,而查询那一侧分得清锁屏和没数据;反过来报
    /// `.notRequested`,是让一个早就授权过的用户白跑一趟「先打开 Vana」。
    func readAccess() async -> ReadAccess {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }
        let status = try? await Self.withDeadline(Self.statusTimeout) { [store] in
            try await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        }
        return status == .shouldRequest ? .notRequested : .ready
    }

    /// 锁屏时整个 HealthKit 库都读不了。这不是"没有数据",得分开说。
    static func isDatabaseLocked(_ error: any Error) -> Bool {
        let error = error as NSError
        return error.domain == HKError.errorDomain
            && error.code == HKError.errorDatabaseInaccessible.rawValue
    }

    /// 按需授权:第一次真的要读的时候才问,一次运行只问一次。
    @MainActor private static var requestedOnDemand: Set<String> = []

    /// **这一条跑在用户正等着回复的时候**(血压、化验单那两个工具里),所以它是这块东西里
    /// 最不能悬住的一处:这里 await 一个不回话的系统调用,屏幕上就是一条永远转下去的回复。
    ///
    /// 和设置页那条不同,这里**要等面板**:等到了才查得到数据,不等就必然查出一片空。
    /// 所以给的是宽的那个上限(`panelTimeout`,够一个人读完面板做决定),它挡的只是
    /// 「面板压根没出现」那一种。超时就照常往下查——那一步本来就允许查出空,而
    /// 「血压没有数据」在这个 app 里是一句正常的话。
    @MainActor
    private func requestOnDemand(_ types: Set<HKObjectType>, key: String) async {
        guard !Self.requestedOnDemand.contains(key) else { return }
        Self.requestedOnDemand.insert(key)

        let status = try? await Self.withDeadline(Self.statusTimeout) { [store] in
            try await store.statusForAuthorizationRequest(toShare: [], read: types)
        }
        guard status == .shouldRequest else { return }

        _ = try? await Self.withDeadline(Self.panelTimeout) { [store] in
            try await store.requestAuthorization(toShare: [], read: types)
        }
    }

    func dailySteps(days: Int) async throws -> [DayValue] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        let samplePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(.stepCount),
                predicate: samplePredicate
            ),
            options: .cumulativeSum,
            anchorDate: today,
            intervalComponents: DateComponents(day: 1)
        )
        let collection = try await descriptor.result(for: store)

        return (0..<dayCount).compactMap { offset -> DayValue? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let value = collection
                .statistics(for: date)?
                .sumQuantity()?
                .doubleValue(for: .count()) ?? 0
            return DayValue(date: date, value: value)
        }
    }

    /// 每日活动量:步数、步行跑步距离、爬楼层数、运动分钟。
    ///
    /// 后三项没有记录时是 nil 而不是 0——"没有 Apple Watch 所以没有运动分钟"和
    /// "今天一分钟都没动"是两回事。
    func dailyActivity(days: Int) async throws -> [DayActivity] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let stepCollection = dailyCollection(
            type: HKQuantityType(.stepCount),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let distanceCollection = dailyCollection(
            type: HKQuantityType(.distanceWalkingRunning),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let flightCollection = dailyCollection(
            type: HKQuantityType(.flightsClimbed),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let exerciseCollection = dailyCollection(
            type: HKQuantityType(.appleExerciseTime),
            options: .cumulativeSum,
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let steps = try await stepCollection
        // 距离、楼层、运动分钟没授权就当没有,不该让整个活动量查询失败。
        let distance = try? await distanceCollection
        let flights = try? await flightCollection
        let exercise = try? await exerciseCollection

        return (0..<dayCount).compactMap { offset -> DayActivity? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return DayActivity(
                date: date,
                steps: steps.statistics(for: date)?.sumQuantity()?.doubleValue(for: .count()) ?? 0,
                distance: distance?
                    .statistics(for: date)?
                    .sumQuantity()?
                    .doubleValue(for: .meterUnit(with: .kilo)),
                flights: flights?.statistics(for: date)?.sumQuantity()?.doubleValue(for: .count()),
                exerciseMinutes: exercise?
                    .statistics(for: date)?
                    .sumQuantity()?
                    .doubleValue(for: .minute())
            )
        }
    }

    /// `includeHeartRate` 为真时,额外查每一晚睡眠时段的心率(每晚一次查询)。
    /// 算基线的那趟不要开——60 晚就是 60 次查询,而基线只用得上时长。
    func sleepSummary(days: Int, includeHeartRate: Bool = false) async throws -> [NightSleep] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startBoundary = calendar.date(
            byAdding: .hour,
            value: 12,
            to: calendar.date(byAdding: .day, value: -dayCount, to: today) ?? today
        ),
        let endBoundary = calendar.date(byAdding: .hour, value: 12, to: today) else {
            return []
        }

        let sleepType = HKCategoryType(.sleepAnalysis)
        let datePredicate = HKQuery.predicateForSamples(
            withStart: startBoundary,
            end: endBoundary,
            options: []
        )
        let descriptor = HKSampleQueryDescriptor<HKCategorySample>(
            predicates: [
                .categorySample(type: sleepType, predicate: datePredicate)
            ],
            sortDescriptors: [
                SortDescriptor(\.startDate)
            ]
        )
        let samples = try await descriptor.result(for: store)
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue,
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
        ]

        var nights: [Date: SleepAccumulator] = [:]
        for sample in samples {
            guard let shiftedDate = calendar.date(byAdding: .hour, value: -12, to: sample.startDate) else {
                continue
            }
            guard sample.endDate > sample.startDate else { continue }
            let night = calendar.startOfDay(for: shiftedDate)
            let interval = DateInterval(start: sample.startDate, end: sample.endDate)
            var accumulator = nights[night, default: SleepAccumulator()]
            accumulator.bedtime = minDate(accumulator.bedtime, sample.startDate)
            accumulator.wake = maxDate(accumulator.wake, sample.endDate)

            if asleepValues.contains(sample.value) {
                accumulator.asleepIntervals.append(interval)
            }
            switch sample.value {
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
                accumulator.deepIntervals.append(interval)
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
                accumulator.coreIntervals.append(interval)
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
                accumulator.remIntervals.append(interval)
            case HKCategoryValueSleepAnalysis.awake.rawValue:
                accumulator.awakeIntervals.append(interval)
            default:
                break
            }
            nights[night] = accumulator
        }

        var result: [NightSleep] = []
        for night in nights.keys.sorted().suffix(dayCount) {
            guard let value = nights[night] else { continue }
            let asleepStart = value.asleepIntervals.map(\.start).min()
            let awake = merged(value.awakeIntervals)

            var item = NightSleep(
                night: night,
                asleep: totalDuration(of: value.asleepIntervals),
                bedtime: value.bedtime,
                wake: value.wake,
                deep: totalDuration(of: value.deepIntervals),
                core: totalDuration(of: value.coreIntervals),
                rem: totalDuration(of: value.remIntervals),
                awake: awake.reduce(0) { $0 + $1.duration },
                // 躺下还没睡着那段不算"醒来";只数入睡之后的,而且掐掉一两分钟的翻身。
                wakeCount: awake.filter { segment in
                    segment.duration >= 60 && asleepStart.map { segment.start > $0 } == true
                }.count
            )

            if includeHeartRate, let bedtime = item.bedtime, let wake = item.wake, wake > bedtime {
                let heart = try? await heartRateStatistics(from: bedtime, to: wake)
                item.heartRate = heart?.average
                item.lowestHeartRate = heart?.lowest
            }
            result.append(item)
        }
        return result
    }

    /// 一段时间内的心率统计。睡眠时段心率就是拿这个按每晚的卧床区间去问的。
    func heartRateStatistics(
        from start: Date,
        to end: Date
    ) async throws -> (average: Double?, lowest: Double?, highest: Double?) {
        let descriptor = HKStatisticsQueryDescriptor(
            predicate: .quantitySample(
                type: HKQuantityType(.heartRate),
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            ),
            options: [.discreteAverage, .discreteMin, .discreteMax]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())

        do {
            let statistics = try await descriptor.result(for: store)
            return (
                statistics?.averageQuantity()?.doubleValue(for: unit),
                statistics?.minimumQuantity()?.doubleValue(for: unit),
                statistics?.maximumQuantity()?.doubleValue(for: unit)
            )
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            return (nil, nil, nil)
        }
    }

    /// 逐小时步数。给面板画日内分布用,不进模型上下文。
    func hourlySteps(from start: Date, to end: Date) async throws -> [DayValue] {
        try await hourlyValues(
            type: HKQuantityType(.stepCount),
            unit: .count(),
            options: .cumulativeSum,
            from: start,
            to: end
        )
    }

    /// 逐小时平均心率。夜间那段就是拿睡眠的卧床区间来问的。
    func hourlyHeartRate(from start: Date, to end: Date) async throws -> [DayValue] {
        try await hourlyValues(
            type: HKQuantityType(.heartRate),
            unit: HKUnit.count().unitDivided(by: .minute()),
            options: .discreteAverage,
            from: start,
            to: end
        )
    }

    private func hourlyValues(
        type: HKQuantityType,
        unit: HKUnit,
        options: HKStatisticsOptions,
        from start: Date,
        to end: Date
    ) async throws -> [DayValue] {
        guard end > start else { return [] }
        let anchor = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(
                type: type,
                predicate: HKQuery.predicateForSamples(withStart: start, end: end, options: [])
            ),
            options: options,
            anchorDate: anchor,
            intervalComponents: DateComponents(hour: 1)
        )

        let collection: HKStatisticsCollection
        do {
            collection = try await descriptor.result(for: store)
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            return []
        }

        var values: [DayValue] = []
        collection.enumerateStatistics(from: anchor, to: end) { statistics, _ in
            let quantity = options.contains(.cumulativeSum)
                ? statistics.sumQuantity()
                : statistics.averageQuantity()
            guard let value = quantity?.doubleValue(for: unit) else { return }
            values.append(DayValue(date: statistics.startDate, value: value))
        }
        return values
    }

    func heartRateSummary(days: Int) async throws -> [DayHeart] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let restingCollection = dailyAverageCollection(
            type: HKQuantityType(.restingHeartRate),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let hrvCollection = dailyAverageCollection(
            type: HKQuantityType(.heartRateVariabilitySDNN),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        // 全天心率的低/高/平均一次查完:三个统计量共用一个 collection。
        async let heartCollection = dailyCollection(
            type: HKQuantityType(.heartRate),
            options: [.discreteAverage, .discreteMin, .discreteMax],
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let (resting, hrv) = try await (restingCollection, hrvCollection)
        let heart = try? await heartCollection
        let restingUnit = HKUnit.count().unitDivided(by: .minute())
        let hrvUnit = HKUnit.secondUnit(with: .milli)

        return (0..<dayCount).compactMap { offset -> DayHeart? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let daily = heart?.statistics(for: date)
            return DayHeart(
                date: date,
                restingHR: resting
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: restingUnit),
                hrv: hrv
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: hrvUnit),
                lowestHR: daily?.minimumQuantity()?.doubleValue(for: restingUnit),
                highestHR: daily?.maximumQuantity()?.doubleValue(for: restingUnit),
                averageHR: daily?.averageQuantity()?.doubleValue(for: restingUnit)
            )
        }
    }

    /// `activity` 传了就只返回那一类锻炼。名字用 `workoutName(for:)` 那套中文名。
    func workouts(days: Int, activity: String? = nil) async throws -> [WorkoutItem] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        let datePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let descriptor = HKSampleQueryDescriptor<HKWorkout>(
            predicates: [.workout(datePredicate)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)]
        )
        let energyType = HKQuantityType(.activeEnergyBurned)
        let heartUnit = HKUnit.count().unitDivided(by: .minute())
        let kilometer = HKUnit.meterUnit(with: .kilo)

        return try await descriptor.result(for: store).compactMap { workout in
            let typeName = workoutName(for: workout.workoutActivityType)
            guard activity == nil || activity == typeName else { return nil }

            // 距离按运动类型分了三个数量类型,哪个有值算哪个(游泳那个单位也是米)。
            let distance = [
                HKQuantityType(.distanceWalkingRunning),
                HKQuantityType(.distanceCycling),
                HKQuantityType(.distanceSwimming)
            ].lazy.compactMap {
                workout.statistics(for: $0)?.sumQuantity()?.doubleValue(for: kilometer)
            }.first { $0 > 0 }

            let heart = workout.statistics(for: HKQuantityType(.heartRate))
            return WorkoutItem(
                date: workout.startDate,
                typeName: typeName,
                duration: workout.duration,
                activeEnergy: workout
                    .statistics(for: energyType)?
                    .sumQuantity()?
                    .doubleValue(for: .kilocalorie()),
                distance: distance,
                averageHeartRate: heart?.averageQuantity()?.doubleValue(for: heartUnit),
                maxHeartRate: heart?.maximumQuantity()?.doubleValue(for: heartUnit)
            )
        }
    }

    func bloodPressureSummary(days: Int) async throws -> [DayBloodPressure] {
        await requestOnDemand(Self.bloodPressureReadTypes, key: "bloodPressure")

        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let systolicCollection = dailyAverageCollection(
            type: HKQuantityType(.bloodPressureSystolic),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let diastolicCollection = dailyAverageCollection(
            type: HKQuantityType(.bloodPressureDiastolic),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let systolic: HKStatisticsCollection
        let diastolic: HKStatisticsCollection
        do {
            (systolic, diastolic) = try await (systolicCollection, diastolicCollection)
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            // 没授权和没数据对用户是一回事:渲染层会提示去检查授权,不该抛成"查询失败"。
            return []
        }
        let unit = HKUnit.millimeterOfMercury()

        return (0..<dayCount).compactMap { offset -> DayBloodPressure? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            return DayBloodPressure(
                date: date,
                systolic: systolic.statistics(for: date)?.averageQuantity()?.doubleValue(for: unit),
                diastolic: diastolic.statistics(for: date)?.averageQuantity()?.doubleValue(for: unit)
            )
        }
    }

    func vitalsSummary(days: Int) async throws -> [DayVitals] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let oxygenCollection = dailyAverageCollection(
            type: HKQuantityType(.oxygenSaturation),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let breathingCollection = dailyAverageCollection(
            type: HKQuantityType(.respiratoryRate),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let wristCollection = dailyAverageCollection(
            type: HKQuantityType(.appleSleepingWristTemperature),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let bodyTemperatureCollection = dailyAverageCollection(
            type: HKQuantityType(.bodyTemperature),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let oxygen: HKStatisticsCollection
        let breathing: HKStatisticsCollection
        let wrist: HKStatisticsCollection
        let temperature: HKStatisticsCollection
        do {
            (oxygen, breathing, wrist, temperature) = try await (
                oxygenCollection, breathingCollection, wristCollection, bodyTemperatureCollection
            )
        } catch let error as HKError where Self.isAuthorizationIssue(error) {
            return []
        }
        let breathingUnit = HKUnit.count().unitDivided(by: .minute())
        let celsius = HKUnit.degreeCelsius()

        return (0..<dayCount).compactMap { offset -> DayVitals? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let saturation = oxygen
                .statistics(for: date)?
                .averageQuantity()?
                .doubleValue(for: .percent())

            return DayVitals(
                date: date,
                // HealthKit 的血氧是 0–1 的比例,展示要的是 96 不是 0.96。
                oxygen: saturation.map { $0 * 100 },
                respiratoryRate: breathing
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: breathingUnit),
                wristTemperature: wrist
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: celsius),
                bodyTemperature: temperature
                    .statistics(for: date)?
                    .averageQuantity()?
                    .doubleValue(for: celsius)
            )
        }
    }

    func bodyMetrics(days: Int) async throws -> [DayBody] {
        let dayCount = min(max(days, 1), 90)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today),
              let endDate = calendar.date(byAdding: .day, value: 1, to: today) else {
            return []
        }

        async let weightCollection = dailyAverageCollection(
            type: HKQuantityType(.bodyMass),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )
        async let bodyFatCollection = dailyAverageCollection(
            type: HKQuantityType(.bodyFatPercentage),
            startDate: startDate,
            endDate: endDate,
            anchorDate: today
        )

        let (weights, bodyFat) = try await (weightCollection, bodyFatCollection)
        return (0..<dayCount).compactMap { offset -> DayBody? in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else {
                return nil
            }
            let weight = weights
                .statistics(for: date)?
                .averageQuantity()?
                .doubleValue(for: .gramUnit(with: .kilo))
            let fat: Double?
            if let quantity = bodyFat.statistics(for: date)?.averageQuantity() {
                fat = quantity.doubleValue(for: .percent()) * 100
            } else {
                fat = nil
            }

            guard weight != nil || fat != nil else { return nil }
            return DayBody(date: date, weight: weight, bodyFat: fat)
        }
    }

    /// 「健康」里的体检报告和化验单(FHIR)。
    ///
    /// 只有用户在「健康」App 里连过医院或诊所才会有;没连过就是空的,跟血压一样属于
    /// "没有很正常"。这里只取化验结果和体征两类——诊断和用药涉及的解读责任太重。
    func clinicalRecords(days: Int) async throws -> [ClinicalItem] {
        // 这台设备上根本没有「健康记录」这套东西时直接说清楚,不去问授权也不去查:
        // 对着一个不存在的功能请求授权,那次请求可能一句话都不回(见 `supportsHealthRecords`)。
        guard supportsHealthRecords else {
            throw HealthStoreError.healthRecordsUnavailable
        }

        // 用户真的问到化验单了,这时候申请授权才说得过去。
        await requestOnDemand(Self.clinicalReadTypes, key: "clinical")

        let dayCount = min(max(days, 1), 3650)
        let today = calendar.startOfDay(for: Date())
        guard let startDate = calendar.date(byAdding: .day, value: -dayCount, to: today) else {
            return []
        }

        let types: [(HKClinicalType, String)] = [
            (HKClinicalType(.labResultRecord), "化验"),
            (HKClinicalType(.vitalSignRecord), "体征")
        ]

        var items: [ClinicalItem] = []
        for (type, category) in types {
            let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: [])
            let descriptor = HKSampleQueryDescriptor<HKClinicalRecord>(
                predicates: [.clinicalRecord(type: type, predicate: predicate)],
                sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
                limit: 100
            )

            let records: [HKClinicalRecord]
            do {
                records = try await descriptor.result(for: store)
            } catch let error as HKError where Self.isAuthorizationIssue(error) {
                continue
            }

            items.append(contentsOf: records.map { record in
                ClinicalItem(
                    date: record.startDate,
                    name: record.displayName,
                    value: Self.fhirValue(from: record),
                    category: category
                )
            })
        }

        return items.sorted { $0.date > $1.date }
    }

    /// 从 FHIR 里挖出数值。
    ///
    /// 只认 Observation 的 `valueQuantity`——真正想比较的是"血糖 5.4 mmol/L"这种。
    /// 其他形状(区间、编码值、组合观测)一律不猜,留空让模型只报名称和日期。
    private static func fhirValue(from record: HKClinicalRecord) -> String? {
        guard let data = record.fhirResource?.data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quantity = json["valueQuantity"] as? [String: Any],
              let value = quantity["value"] as? Double else {
            return nil
        }
        let unit = (quantity["unit"] as? String) ?? ""
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    /// 用户没授权某个类型时,统计查询会抛错而不是返回空。血压、血氧这些多数人本来就
    /// 没有,更常见的是压根没允许读——那不该表现成"查询失败"。
    private static func isAuthorizationIssue(_ error: HKError) -> Bool {
        error.code == .errorAuthorizationNotDetermined || error.code == .errorAuthorizationDenied
    }

    private func dailyAverageCollection(
        type: HKQuantityType,
        startDate: Date,
        endDate: Date,
        anchorDate: Date
    ) async throws -> HKStatisticsCollection {
        try await dailyCollection(
            type: type,
            options: .discreteAverage,
            startDate: startDate,
            endDate: endDate,
            anchorDate: anchorDate
        )
    }

    private func dailyCollection(
        type: HKQuantityType,
        options: HKStatisticsOptions,
        startDate: Date,
        endDate: Date,
        anchorDate: Date
    ) async throws -> HKStatisticsCollection {
        let samplePredicate = HKQuery.predicateForSamples(
            withStart: startDate,
            end: endDate,
            options: .strictStartDate
        )
        let descriptor = HKStatisticsCollectionQueryDescriptor(
            predicate: .quantitySample(type: type, predicate: samplePredicate),
            options: options,
            anchorDate: anchorDate,
            intervalComponents: DateComponents(day: 1)
        )
        return try await descriptor.result(for: store)
    }

    private func workoutName(for activity: HKWorkoutActivityType) -> String {
        switch activity {
        case .running:
            "跑步"
        case .cycling:
            "骑行"
        case .walking:
            "步行"
        case .traditionalStrengthTraining, .functionalStrengthTraining:
            "力量训练"
        case .swimming:
            "游泳"
        case .hiking:
            "徒步"
        case .yoga:
            "瑜伽"
        case .highIntensityIntervalTraining:
            "高强度间歇训练"
        default:
            "其他"
        }
    }

    /// 睡眠样本会重叠:iPhone 和 Apple Watch 同时记录、同一份数据被写入两次、
    /// 或分期样本(核心/深度/REM)与一条 asleepUnspecified 并存。逐条累加时长会
    /// 因此翻倍——曾经算出一晚睡 28 小时。合并重叠区间后再求和。
    private func merged(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        var running: DateInterval?

        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            guard let current = running else {
                running = interval
                continue
            }
            if interval.start <= current.end {
                running = DateInterval(start: current.start, end: max(current.end, interval.end))
            } else {
                result.append(current)
                running = interval
            }
        }

        if let running {
            result.append(running)
        }
        return result
    }

    private func totalDuration(of intervals: [DateInterval]) -> TimeInterval {
        merged(intervals).reduce(0) { $0 + $1.duration }
    }

    private func minDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return min(lhs, rhs)
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }
}

enum HealthStoreError: LocalizedError, Equatable {
    case healthDataUnavailable
    /// 这台设备(或这个地区)上没有「健康记录」。和「没有记录」是两件事,得分开说。
    case healthRecordsUnavailable
    /// 系统那一侧没有在上限之内回话。见 `HealthStore.withDeadline`。
    case authorizationTimedOut

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            String(localized: "此设备不支持健康数据")
        case .healthRecordsUnavailable:
            String(localized: "此设备上没有「健康记录」功能")
        case .authorizationTimedOut:
            String(localized: "系统的授权面板没有响应")
        }
    }
}

private struct SleepAccumulator {
    var asleepIntervals: [DateInterval] = []
    var deepIntervals: [DateInterval] = []
    var coreIntervals: [DateInterval] = []
    var remIntervals: [DateInterval] = []
    var awakeIntervals: [DateInterval] = []
    var bedtime: Date?
    var wake: Date?
}
