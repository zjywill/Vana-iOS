import Foundation

/// 用户不在场时能不能替他发一次模型请求。
///
/// 云端要齐 key 和 model 才发得出去,而且**这家 provider 要被用户点名同意过**
/// (`ProviderConsent`)。后台那几件跑在用户不在场的时候——同意之前替他发一轮,
/// 正是 5.1.2(i) 那句「before sharing」要挡的事。抽记忆、待跟进回访、后台任务、目标回顾都走这一道。
enum CloudAccess {
    static func backgroundSettings() -> (provider: String, model: String)? {
        let key = (try? KeychainStore.get(account: KeychainStore.apiKeyAccount)) ?? ""
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        let selection = EngineSettings.selection
        guard !selection.model.isEmpty, ProviderConsent.granted(selection.provider) else { return nil }
        return selection
    }
}
