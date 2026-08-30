import Foundation
import AIKit

/// 给一条药或补剂写一句「这东西一般是干什么的」。
///
/// 功效有两层,别混:
/// - **他自己的效果**(`MedicationItem.outcome`)——他记的。值钱得多,界面和工具输出里永远排前面。
/// - **一般功效**(`MedicationItem.brief`)——这一层。网上到处都是,模型随时能重写一遍。
///
/// 和 `QuestionSuggester` / `FollowUpSuggester` 同一套做法:一次不带工具的便宜调用,加一条时
/// 跑一次,**结果存在那一条上**,不每次渲染重算。失败即放弃——列表照常用,那一行只是少一句话。
struct MedicationBriefer: Sendable {
    let providerId: String
    let model: String

    static let maxCharacters = 60

    private static let instructions = """
    你在为一个健康 app 的用药清单写一句「这东西一般是干什么的」。用户会在他自己的清单里看到这句话，\
    旁边标着「自动生成，不是给你的建议」。

    要求：
    - 只输出一句话，中文，不超过 40 个字，不要引号、不要编号、不要任何解释。
    - 只说这类药或补剂**通常**用于什么，需要的话补一句最常见的注意点。
    - 绝对不要写剂量、用法、疗程，也不要写该不该吃、什么时候吃——那是医生和药师的事。
    - 不要针对这位用户说话（不要出现「你」「建议你」），这是一句通用说明。
    - 不认识这个名字，就只输出「无」这一个字，不要猜。
    """

    func brief(for name: String) async throws -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }

        let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
        let response = try await client.generate(CallOptions(
            model: model,
            prompt: [.system(Self.instructions), .user(trimmed)],
            maxOutputTokens: 120,
            // 说明一件通用的事,不是写文案。
            temperature: 0.2,
            // 同 `FollowUpSuggester`:留空是接受模型的默认,而好几家的默认是思考——思考算进
            // output,120 个 token 会在写出那一句之前就用光。
            thinking: .off
        ))
        return Self.parse(response.text)
    }

    /// 不是 private:「模型说不认识就别写」这条有测试盯着。写一句它自己也不确定的话,
    /// 比空着糟得多——用户看不出那一行是猜的。
    static func parse(_ text: String) -> String? {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'。 "))
        guard !cleaned.isEmpty, cleaned != "无", cleaned.count <= maxCharacters else { return nil }
        return cleaned
    }

    /// 用当前云端设置跑一次,写回 store。缺 key、缺模型、生成失败都不抛——那一行只是少一句话,
    /// 列表照常用(同首屏建议的兜底逻辑)。
    ///
    /// 但**要说清有没有写成**。加一条药时是后台顺手跑的,没写成就算了;而详情页那颗「重新生成」
    /// 是用户自己点的——他点了、等了、什么都没变,屏幕上却没有一个字解释为什么,那比僵硬更糟。
    /// 返回值就是给那一颗用的。
    ///
    /// 不走 `BackgroundModelWork`:那把锁管的是用户**看不见**的几件事(抽记忆、待跟进、目标
    /// 进展),而这一次是他刚点完按钮、正盯着那一行等它变。让它去排一个后台队列,等的人就在
    /// 屏幕前面。
    @discardableResult
    static func fill(_ item: MedicationItem, store: MedicationStore = .shared) async -> Bool {
        guard !item.briefIsUserWritten else { return false }
        let selection = EngineSettings.selection
        // 同意之前不发(`ProviderConsent`):药名也是他的个人数据,而这一步可能在他一句话
        // 都还没发过的时候就跑(录完第一条药顺手生成说明)。
        guard !selection.model.isEmpty, ProviderConsent.granted(selection.provider) else { return false }
        let briefer = MedicationBriefer(providerId: selection.provider, model: selection.model)
        // `try?` 把「抛错」和「模型说不认识」都压成 nil。这里两者的处置本来就一样:都不写。
        guard let text = try? await briefer.brief(for: item.name) else { return false }
        _ = try? await store.setGeneratedBrief(id: item.id, text: text)
        return true
    }
}
