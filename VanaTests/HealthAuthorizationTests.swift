import Foundation
import HealthKit
import Testing

@testable import Vana

/// 授权请求里到底问了哪些类型。
///
/// 盯的是 2026-08-21 那次审核撞上的那条:iPad Air (M4) 上按设置页那颗「请求读取 Apple 健康」,
/// 那一行就一直停在「正在请求…」——面板没弹出来,请求也没回话。启动时那次请求在同一台设备上
/// 照常弹了面板,两次的差别只有一处:设置页那次多带了病历(FHIR)那两个类型,而 SDK 头文件
/// 里明写着 "Call supportsHealthRecords before attempting to request authorization for any
/// clinical types"。
///
/// `supportsHealthRecords` 是真机上的地区/账号状态,测试里造不出那台设备,所以判断被拆成了
/// 一个纯函数,那个 Bool 从外面传进来。
@Suite("Health authorization")
struct HealthAuthorizationTests {

    private func isClinical(_ type: HKObjectType) -> Bool { type is HKClinicalType }

    @Test("这台设备上没有「健康记录」时,病历类型一个都不问")
    func skipsClinicalTypesWhenUnsupported() {
        let requested = HealthStore.requestedTypes(force: true, supportsHealthRecords: false)

        #expect(!requested.contains(where: isClinical))
        // 剩下的照问:少问一个病历类型,不该顺手把血压也丢了——那颗按钮的一半理由就是
        // 「新增的数据类型要重新请求」。
        #expect(requested.contains(HKQuantityType(.bloodPressureSystolic)))
        #expect(requested.contains(HKQuantityType(.stepCount)))
    }

    @Test("支持的设备上照问,这条修的是问不到的那种设备")
    func asksForClinicalTypesWhenSupported() {
        let requested = HealthStore.requestedTypes(force: true, supportsHealthRecords: true)

        #expect(requested.contains(HKClinicalType(.labResultRecord)))
        #expect(requested.contains(HKClinicalType(.vitalSignRecord)))
    }

    @Test("启动时那次不问病历,也不问血压——那两类是按需申请的")
    func launchRequestStaysOnTheEverydayTypes() {
        let requested = HealthStore.requestedTypes(force: false, supportsHealthRecords: true)

        #expect(!requested.contains(where: isClinical))
        #expect(!requested.contains(HKQuantityType(.bloodPressureSystolic)))
        #expect(requested.contains(HKCategoryType(.sleepAnalysis)))
    }

    /// **2026-08-25 那次审核报的是「按了没反应」**,而这一侧唯一能做错的事就是
    /// 一直 await 一个不会回话的系统调用:HealthKit 既没有超时也没有取消 API,悬着的
    /// 那次请求会把设置页那颗按钮永远 disable 在「正在请求…」上。等不到就得把话说出去。
    @Test("系统那一侧不回话时,这一侧自己超时,不永远挂着")
    func authorizationWaitTimesOut() async {
        await #expect(throws: HealthStoreError.authorizationTimedOut) {
            try await HealthStore.withDeadline(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(60))
                return true
            }
        }
    }

    @Test("回得来的那次照常拿到结果")
    func authorizationWaitReturnsTheResult() async throws {
        let didAsk = try await HealthStore.withDeadline(.seconds(5)) { true }

        #expect(didAsk)
    }

    /// 要等的只有那次纯查询;面板那一段人要站在前面做决定,给它设一个短上限就是在
    /// 用户读着面板的时候报「面板没有响应」。两个数不能是同一个,也不能倒过来。
    @Test("查询的上限短，面板的上限宽，界面那层的兜底排在查询后面")
    func deadlinesAreOrdered() {
        #expect(HealthStore.statusTimeout < HealthStore.panelTimeout)
        #expect(HealthStore.panelTimeout <= HealthStore.panelStaleAfter)
    }

    /// 「点一下,面板闪一下就没了」的那条。血压那两类的授权状态永远停在 `shouldRequest`,
    /// 所以不记住「上次问的是哪一组」的话,每次按都会再问一遍同一组,而 iOS 已经没什么可问
    /// 的了——面板推上来当场收回去,屏幕上就是闪了一下。
    @Test("同一组类型的指纹稳定,和顺序无关")
    func fingerprintIsStableAcrossOrder() {
        let a = HealthStore.requestedTypes(force: true, supportsHealthRecords: false)
        let b = HealthStore.requestedTypes(force: true, supportsHealthRecords: false)

        #expect(HealthStore.fingerprint(of: a) == HealthStore.fingerprint(of: b))
    }

    /// 指纹按类型算而不是一个 Bool,为的就是这一条:以后加了新的数据类型,那颗按钮要
    /// 恢复它本来的用处(「新增的数据类型需要重新请求」)。
    @Test("多问一个类型就是另一组，按钮跟着复活")
    func fingerprintChangesWhenTypesChange() {
        let everyday = HealthStore.requestedTypes(force: false, supportsHealthRecords: false)
        let withBloodPressure = HealthStore.requestedTypes(force: true, supportsHealthRecords: false)

        #expect(HealthStore.fingerprint(of: everyday) != HealthStore.fingerprint(of: withBloodPressure))
    }

    /// 「这台设备上没有这个功能」和「没有记录」是两件事。前者让用户去「健康」App 里连医院
    /// 是白跑一趟——这条路上永远连不上,该说的是让他拍一张。
    @Test("读不到病历时说的是拍一张，不是去连医院")
    func unavailableReportPointsAtThePhotoPath() {
        let report = HealthTools.healthRecordsUnavailableReport

        let note = report.notes.joined()
        #expect(note.contains("健康记录"))
        #expect(note.contains("拍一张"))
        #expect(!note.contains("连接医院"))
        #expect(report.isEmpty)
    }
}
