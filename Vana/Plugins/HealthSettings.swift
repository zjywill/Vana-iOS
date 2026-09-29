import SwiftUI
import UIKit

// 健康插件自己的设置:Apple 健康授权和每日 check-in。原来摆在「设置」页里,现在归插件详情页
// (`PluginDetailView`)——关掉健康,这两件事都没有意义了:授权读的是只有健康插件在用的数据,
// check-in 的正文是 `HealthSituation.detect()` 写的。

/// 「请求读取 Apple 健康」那颗按钮背后的状态和逻辑。整段从设置页原样搬来——每一行注释都是审核
/// 打回来过的教训,别在搬家时顺手简化。
///
/// 做成一个对象而不是散在视图里的几个 `@State`:提示框要挂在整页的 `Form` 上(挂在行上会撞上
/// 懒加载的重建,悄悄地不 present),而按钮在其中一个 section 里,两处要读同一份状态。
@MainActor
@Observable
final class HealthAuthorizationModel {
    private(set) var isRequesting = false
    private(set) var isInFlight = false
    private(set) var status: HealthAuthStatus?
    /// 面板没弹出来的那几次,那句话要挡在他面前。
    var alert: HealthAuthStatus?
    /// 这一次按的是哪一下。超时放行之后回来晚了的那次靠它闭嘴。
    private var requestToken = UUID()

    /// 授权面板是系统的,推上来之后这一侧只能等它回话——而**等不到的时候必须还有下一步**。
    ///
    /// 2026-08-21 审核在 iPad 上按了这颗按钮,那一行就一直停在「正在请求…」:按钮自己
    /// disable 着,屏幕上没有一句话解释,也没有第二次机会。2026-08-25 又报了一次,措辞
    /// 是「按了没有反应」。根因修在 `HealthStore`(悬着的启动请求不再堵住这条路,
    /// 那个 await 自己也会超时),但「一个永远转下去的指示器」这种形状本身不能留:
    /// 系统那一侧回不回话不归我们管,但这一行不能永远显示成正在加载。
    ///
    /// 比 `HealthStore.statusTimeout` 长一点:底层先超时,说出来的话才是准的(超时是一种
    /// 结果,不是「界面自己放弃了」)。这一层只是它没做到时的兜底。
    ///
    /// **它不再需要覆盖面板那一段**——这一侧根本不等面板了(见
    /// `HealthStore.requestAuthorizationIfNeeded`)。这一点很要紧:上一版把整条路径压在
    /// 12 秒里,而用户读着面板做决定的第 12 秒,屏幕上会冒出一句「系统的授权面板没有响应」,
    /// 指着他眼前那张面板说它不存在。
    private static let healthRequestTimeout = Duration.seconds(8)

    /// 再请求一次授权。iOS 只会为"还没问过"的类型弹窗——新增数据类型后靠这个补上,
    /// 已经拒过的项它不会再问,那种情况只能去「健康」App 改。
    func requestHealthAuthorization() {
        guard !isInFlight else { return }
        isInFlight = true
        isRequesting = true
        status = nil
        // 看门狗放行之后他可以再按一次,而上一次那个 await 仍然可能在几分钟后回话。
        // 认号:回来晚了的那次一个字都不许往屏幕上写,否则他看到的是上一次按的结果。
        let token = UUID()
        self.requestToken = token
        // 按下去之前屏幕最上面是谁。面板上来的话,这个位置会换人。
        let topBefore = Self.topPresentedController

        // `.owner` 而不是 `.shared`:设置页说的是「这台设备怎么工作」(provider、
        // model、key、通知时间全是这一类),而 HealthKit 授权本来就是这台设备机主的
        // 授权,和此刻正在看哪位成员没关系。这一节也因此不随成员消失——切到妈妈就少
        // 一节设置,用户只会以为设置丢了。
        let request = Task { @MainActor () -> HealthAuthStatus in
            do {
                let didAsk = try await HealthStore.owner.requestAuthorizationIfNeeded(force: true)
                return HealthAuthStatus(
                    // 「已弹出」改成「已请求」:这一侧不等面板的结果,也就没有资格说它出来了。
                    // 后半句是给面板没出来的那次留的——他此刻正盯着一块没有变化的屏幕。
                    message: didAsk
                        ? String(localized: "已请求授权面板。没有出现的话，请到“健康”App > 共享 > App > Vana 里管理。")
                        : String(localized: "这些数据类型都已经问过了。要打开或关闭，请到“健康”App 里改。"),
                    icon: didAsk ? "checkmark.circle.fill" : "info.circle",
                    isError: false,
                    // 面板扔出去的那次不弹 alert:它多半正盖在屏幕上,而排在它后面的
                    // alert 会在他按完之后突然冒出来。没弹面板那次才要挡在他面前——
                    // 那时候屏幕上唯一的变化是一行灰色小字。
                    needsAttention: !didAsk
                )
            } catch {
                return HealthAuthStatus(
                    message: String(localized: "请求失败：\(error.localizedDescription)。请到“健康”App > 共享 > App > Vana 里管理。"),
                    icon: "exclamationmark.triangle.fill",
                    isError: true,
                    needsAttention: true
                )
            }
        }

        Task { @MainActor in
            // 看门狗**不取消那次请求**:HealthKit 没有取消 API。它只停止显示加载,
            // 请求按钮在底层调用真正结束前仍然禁用,避免超时后反复点击叠出并发请求。
            // 旁边「在“健康”App 中管理」那颗按钮始终可用。
            let watchdog = Task { @MainActor in
                try? await Task.sleep(for: Self.healthRequestTimeout)
                guard !Task.isCancelled, isRequesting, requestToken == token else { return }
                isRequesting = false
                isInFlight = false
                let timedOut = HealthAuthStatus(
                    // 下面就是「在“健康”App 中管理」那一行,这句话指的是它。
                    message: String(localized: "系统的授权面板没有响应。请直接到“健康”App > 共享 > App > Vana 里管理。"),
                    icon: "exclamationmark.triangle.fill",
                    isError: true,
                    needsAttention: true
                )
                self.status = timedOut
                alert = timedOut
            }

            let status = await request.value
            watchdog.cancel()
            guard requestToken == token else { return }
            isRequesting = false
            isInFlight = false
            self.status = status

            if status.needsAttention {
                alert = status
                return
            }

            // 面板已经扔出去了,但**它到底有没有上来**,HealthKit 一个字都不说。
            // UIKit 说得出来:面板是 present 上来的,真在屏幕上时根视图挂着一个
            // presented view controller。等一下再看——present 有一段动画。
            //
            // 判错的两边代价都很小(多一张 alert / 少一张 alert);判对的那次正好是
            // 审核两次都撞上的那一种:按了,屏幕上什么都没发生。**这颗按钮上,一次
            // 静默的失败比一张多余的 alert 贵得多。**
            try? await Task.sleep(for: .milliseconds(900))
            guard requestToken == token,
                  Self.topPresentedController === topBefore else { return }

            // 到这儿就确定了:面板没上来。说得比那句「没有出现的话」更实在一点——
            // 他不用再自己判断有没有出现过。
            let notPresented = HealthAuthStatus(
                message: String(localized: "系统没有把授权面板推上来。已经做过选择的数据类型 iOS 不会再问——要打开或关闭，请到“健康”App > 共享 > App > Vana。"),
                icon: "info.circle",
                isError: false
            )
            self.status = notPresented
            alert = notPresented
        }
    }

    /// 此刻站在最上面的那个 view controller。
    ///
    /// 用来判断「刚扔出去的那张授权面板上来了没有」:按之前记一个,900 毫秒之后再看一次,
    /// **换人了才算面板真的上来了**。
    ///
    /// 不能只问「有没有 presented view controller」——SwiftUI 这一屏上它**恒为非 nil**
    /// (模拟器上实测,五次全是 true),那样写出来的是一段永远不会触发的代码,而它守的
    /// 恰恰是审核两次报的那种失败。比身份,不比有无。
    private static var topPresentedController: UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }?
            .rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}

/// Apple 健康那一节:授权按钮、状态、去「健康」App 管理。
struct AppleHealthSection: View {
    let auth: HealthAuthorizationModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            Button {
                auth.requestHealthAuthorization()
            } label: {
                Label(
                    auth.isRequesting ? String(localized: "正在请求…") : HealthKitAttribution.authorizeAction,
                    systemImage: "heart.text.square"
                )
            }
            .disabled(auth.isInFlight)

            if let healthStatus = auth.status {
                Label(healthStatus.message, systemImage: healthStatus.icon)
                    .font(.footnote)
                    .foregroundStyle(healthStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityElement(children: .combine)
            }

            Button {
                openURL(URL(string: "x-apple-health://")!)
            } label: {
                Label("在“健康”App 中管理", systemImage: "arrow.up.forward.app")
            }
        } header: {
            // 界面上要说得出这些数字是从哪儿来的(Guideline 2.5.1),
            // 见 `HealthKitAttribution`。
            Text(HealthKitAttribution.settingsSection)
        } footer: {
            // iOS 从不告诉 app 读取权限被拒了(拒绝和"没数据"长得一样),所以这里
            // 不假装能显示授权状态,只说清楚该去哪儿改。
            Text(HealthKitAttribution.settingsFooter)
        }
    }
}

/// 每日 check-in 那一节。
struct CheckInSection: View {
    @AppStorage(EngineSettings.checkInsEnabledKey) private var checkInsEnabled = false
    @AppStorage(EngineSettings.morningCheckInHourKey) private var morningHour = EngineSettings.defaultMorningHour
    @AppStorage(EngineSettings.eveningCheckInHourKey) private var eveningHour = EngineSettings.defaultEveningHour
    @State private var checkInStatus: HealthAuthStatus?

    var body: some View {
        Section {
            Toggle("每日 check-in", isOn: $checkInsEnabled)

            if checkInsEnabled {
                Picker("早上", selection: $morningHour) {
                    ForEach(5...11, id: \.self) { hour in
                        Text("\(hour):00").tag(hour)
                    }
                }
                Picker("晚上", selection: $eveningHour) {
                    ForEach(18...23, id: \.self) { hour in
                        Text("\(hour):00").tag(hour)
                    }
                }
            }

            if let checkInStatus {
                Label(checkInStatus.message, systemImage: checkInStatus.icon)
                    .font(.footnote)
                    .foregroundStyle(checkInStatus.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .accessibilityElement(children: .combine)
            }
        } footer: {
            // 说明写在 surface 上(插件详情页里每一节同一个来源),这里不另写一份。
            Text(HealthVanaPlugin().surfaces.first { $0.id == PluginSurface.checkIns }?.subtitle ?? "")
        }
        .onChange(of: checkInsEnabled) { _, enabled in
            Task { await applyCheckInSettings(enabled: enabled) }
        }
        .onChange(of: morningHour) { _, _ in
            Task { await CheckInScheduler.reschedule() }
        }
        .onChange(of: eveningHour) { _, _ in
            Task { await CheckInScheduler.reschedule() }
        }
    }

    /// 打开开关时先要通知权限;用户拒了就把开关拨回去,而不是留着一个不会响的开关。
    private func applyCheckInSettings(enabled: Bool) async {
        guard enabled else {
            await CheckInScheduler.reschedule()
            checkInStatus = nil
            return
        }

        guard await CheckInScheduler.requestAuthorization() else {
            checkInsEnabled = false
            checkInStatus = HealthAuthStatus(
                message: String(localized: "系统通知权限没有打开，请到「设置 > Vana > 通知」里允许。"),
                icon: "exclamationmark.triangle.fill",
                isError: true
            )
            return
        }

        await CheckInScheduler.reschedule()
        checkInStatus = HealthAuthStatus(
            message: String(localized: "已排程，每天 \(morningHour):00 和 \(eveningHour):00 各一条。"),
            icon: "checkmark.circle.fill",
            isError: false
        )
    }
}

extension View {
    /// 授权没弹面板时挡在他面前的那句话。挂在整页的 `Form` 上,原因见 `HealthAuthorizationModel`。
    func healthAuthorizationAlert(_ auth: HealthAuthorizationModel) -> some View {
        modifier(HealthAuthorizationAlert(auth: auth))
    }
}

private struct HealthAuthorizationAlert: ViewModifier {
    @Bindable var auth: HealthAuthorizationModel
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content
        // 面板真的弹出来的那次不打扰他——他刚在上面做完选择。**没弹**的那几次才要挡在
        // 他面前:那时候屏幕上唯一的变化是一行灰色小字,而他刚按下的那颗按钮看起来什么
        // 都没做(2026-08-25 审核报的正是这个)。这句话还得带着下一步走——「健康」App
        // 是这条路上唯一能改的地方。
        //
        // **挂在 `Form` 上,不挂在那颗按钮所在的行上。** 这句话弹出来的那一刻,同一个
        // section 里正好多出一行状态小字,而 `Form` 的行是懒的、会被重建——挂在行上的
        // alert 撞上那一次重建就悄悄地不present了。而这颗按钮上「一次静默的失败」正是
        // 被打回两次的那件事,不值得为省一层缩进去赌它。
        .alert(
            HealthKitAttribution.authorizeAction,
            isPresented: Binding(
                get: { auth.alert != nil },
                set: { if !$0 { auth.alert = nil } }
            ),
            presenting: auth.alert
        ) { _ in
            Button("打开“健康”App") {
                openURL(URL(string: "x-apple-health://")!)
            }
            Button("好", role: .cancel) {}
        } message: { status in
            Text(status.message)
        }
    }
}
