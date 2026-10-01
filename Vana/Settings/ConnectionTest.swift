import Foundation
import AIKit
import AgentRuntime

/// 拿当前这套 key + provider + 模型真发一次请求,看通不通。
///
/// **这是给 2026-08-16 那次审核补的一道岗。** 审核员按备注粘了一把 DeepSeek 的 key,而
/// Provider 停在当时的默认值 Anthropic 没动——两个字段各自都填得好好的,合起来必然失败,
/// 而在他按下发送之前,屏幕上没有任何一处说过这件事。Anthropic 回了
/// `401 authentication_error`,App 被判 Guideline 2.1(a)。
///
/// ## 为什么是真发一次,不是看 key 长什么样
///
/// 第一版写的是前缀判定(`sk-ant-` 只可能是 Anthropic 的,诸如此类)。那是启发式,而且是
/// 错的方向:
///
/// - provider 会改格式(OpenAI 一家就有 `sk-`、`sk-proj-`、`sk-svcacct-`,还在加);
/// - 一堆兼容 OpenAI 协议的网关、代理、中转站,key 长什么样完全随意;
/// - `sk-` 是 OpenAI、DeepSeek、Mistral 共用的开头,最常见的那几种组合恰恰判不出来。
///
/// 而**误报的代价比漏报大得多**:一句「这把 key 不对」会让一个其实填对了的人去反复检查
/// 一个没有问题的地方,真正的错误还在后面等着。
///
/// 发一次请求没有这些毛病:它回答的是用户真正想知道的那个问题——「我现在这套配置,能用
/// 吗」——而且一次把 key 填错、provider 选错、模型选错、额度用完、网络不通全覆盖了。
/// 代价是一次真实调用,而这一次由用户自己按下,不是我们替他花的。
enum ConnectionTest {
    enum Result: Equatable {
        case ok
        case failed(String)
    }

    /// 一次尽可能小的调用。
    ///
    /// - `maxOutputTokens` 压到 4:这次要的是「有没有回话」,不是回了什么。
    /// - `thinking: .off`:DeepSeek、Qwen、GLM 这些默认就思考,而思考算进 output——
    ///   不关的话这几个 token 会在模型开口之前就用光,一次本该成功的测试报成失败
    ///   (同 `QuestionSuggester` 那处)。
    @MainActor
    static func run(providerId: String, model: String, apiKey: String) async -> Result {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .failed(String(localized: "先填一把 API key。")) }
        guard !model.isEmpty else { return .failed(String(localized: "先选一个模型。")) }

        do {
            let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
            _ = try await client.generate(CallOptions(
                model: model,
                prompt: [.user("hi")],
                maxOutputTokens: 4,
                thinking: .off
            ))
            return .ok
        } catch {
            // 翻译走和聊天气泡同一套(`ModelFailure.kind`),两处说法必须一致:同一个
            // 「key 不对」在设置页和对话里各写一句自己的话,用户会以为是两件事。
            return .failed(ChatViewModel.userFacingFailure(error))
        }
    }
}
