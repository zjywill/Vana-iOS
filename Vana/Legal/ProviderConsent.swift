import Foundation

/// 「把数据发给某一家第三方模型服务」这件事,按 provider 记一次同意。
///
/// 2026-08-29 那次审核判的是 5.1.2(i):app 把个人数据发给第三方 AI 服务,却没有点名对方、
/// 也没有在发送之前征得同意。首启那一屏说清了**发什么**,但「发给谁」全程只有一句
/// 「你配置的模型服务」——而同意必须落在一个具体的名字上才算数。所以第一次真的要向某一家
/// 发送之前,弹一次点名确认(`ChatView` 里那个 alert),同意了记在这里;换 provider 会再问,
/// 同一家只问一次。
///
/// 几条边界:
///
/// - **这道闸挡的是每一条真的会出设备的路**,不只是聊天:首屏那段摘要、三条建议、抽记忆、
///   后台派生、用药说明,全都在同意之前不跑。它们都是锦上添花,各自的本地兜底本来就在;
///   而其中首屏摘要跑在启动时、带着健康结论——那正是「发送之前没问过」最实打实的一条路。
/// - **设备级,不跟着成员走**(同 `DataUseNotice.acceptedKey`、provider、key):它说的是
///   「这台手机怎么连模型」,不是「我和谁在聊」,所以不在 `TenantPaths.perTenantItems` 里。
/// - **只增不撤**。iOS 没有给这类 app 内同意做系统开关,要反悔的出口是删掉 key 或换
///   provider——那两下本来就把发送整个停了,再造一个「撤回同意」开关就是同一件事的第二个
///   说法(同「填了 key 却关着的搜索开关」那条)。
enum ProviderConsent {
    static let consentedKey = "consentedProviderIds"

    static func granted(_ providerId: String, defaults: UserDefaults = .standard) -> Bool {
        let trimmed = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return (defaults.stringArray(forKey: consentedKey) ?? []).contains(trimmed)
    }

    static func record(_ providerId: String, defaults: UserDefaults = .standard) {
        let trimmed = providerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !granted(trimmed, defaults: defaults) else { return }
        var ids = defaults.stringArray(forKey: consentedKey) ?? []
        ids.append(trimmed)
        defaults.set(ids, forKey: consentedKey)
    }
}
