import Foundation
import AIKit

/// 刚答完的这一轮里,够写几条追问的那点材料。
///
/// 三样都不含数字之外的东西:问句、回答、查过哪些工具。**工具的原始输出一条都不给**——
/// 追问要的是"往哪个方向接着问",不是那几个数字;而喂进去就是让这一次生成多付一整段
/// 上下文的钱(同 `MemoryExtractor.transcript(of:)` 只喂人说过的话)。
struct FollowUpContext: Sendable, Equatable {
    /// 用户这一轮问的,含他中途插的那几句。
    var question: String
    /// 助手说出来的话。不含思考。
    var answer: String
    /// 这一轮查过哪些工具,按调用顺序去重。只留名字不留数字:名字说明这段结论建立在哪些
    /// 数据上,而那正是"接着问什么"的依据。
    var toolNames: [String] = []
}

/// 答完一轮之后,让模型写三条「接着问」。
///
/// 和 `QuestionSuggester`(首屏那三条)是同一套做法:一次不带工具的便宜调用,失败即放弃,
/// 界面那边永远有兜底文案。区别只在时机——首屏那次跑在启动时,这次跑在回答刚落地时。
struct FollowUpSuggester: Sendable {
    let providerId: String
    let model: String

    /// 答案太长时保头保尾。
    ///
    /// 头是他在问什么,尾是结论和建议——追问接的正是这两头;丢掉的中段多半是把数据一天天
    /// 念过去,那部分对"接着问什么"没有贡献。
    static let maxAnswerCharacters = 1_600

    /// 每行的字符上限。英文一档放宽,理由同 `QuestionSuggester.maxLineCharacters`:
    /// 拿 12 去卡英文,两条都凑不齐,英文界面上追问 chip 就永远只剩固定那几颗。
    /// 提示词里的数字和校验必须是同一个。
    static var maxLineCharacters: Int {
        HealthAssistantInstructions.replyLanguage == "English" ? 36 : 12
    }

    /// 语言跟着界面走,和聊天回答同一个判据。不是 `let`:语言要在跑的那一刻读。
    private static var instructions: String {
        """
    你在为一个健康分析 app 写「接着问」的快捷按钮。用户刚问完一个健康问题，助手刚答完，\
    你要写三条他最可能接着问的话，每条会直接显示成一个可点的小按钮。

    要求：
    - 只输出三行，每行一句，不要编号、不要引号、不要任何解释。
    - 用\(HealthAssistantInstructions.replyLanguage)写——无论下面的对话用什么语言。\
    口语，每行不超过 \(maxLineCharacters) 个字符——放不进按钮的等于没写。
    - 必须是接着刚才那段回答问下去的，而且能用步数、睡眠、静息心率与 HRV、锻炼、\
    体重体脂这几类数据回答。
    - 三条问向不同的方向，比如：换个时间范围看看、追问原因、看一个相关的别的指标。
    - 不要重复助手刚说过的结论，也不要写成建议、安慰或提醒。
    - 用第一人称，像用户自己在问，不是像 app 在提示。
    - 不做诊断。
    """
    }

    /// 最多三条,**够两条就算成过**;少于两条返回空,调用方用兜底那几条顶上。
    ///
    /// 门槛不设在"恰好三条":中文追问写到十一二个字很常见,一条超长就把另外两条也带走,
    /// 而这条失败路径是静默的——界面上只表现为"没生成",线上根本查不出来(第一版就是这么
    /// 一直不出 chip 的)。
    ///
    /// 但也**不和兜底混排**:少的那颗位置就空着(界面上是「详细一点」加两颗)。混着排的话
    /// 一半是贴着这段回答的话、一半是泛泛的套话,长短语气都不一样,看着比少一颗更像坏了。
    func suggestions(for context: FollowUpContext) async throws -> [String] {
        guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }

        let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
        let response = try await client.generate(CallOptions(
            model: model,
            prompt: [
                .system(Self.instructions),
                .user(Self.request(for: context))
            ],
            maxOutputTokens: 120,
            temperature: 0.7,
            // 写三行短句不是推理问题。这里更要紧的是**留空不等于关**:DeepSeek、Qwen、GLM
            // 这些模型的默认就是思考,而思考算进 output——120 个 token 会在写出三行之前
            // 就用光,然后 parse 不到三条整体作废,界面上只表现为"没生成"。
            thinking: .off
        ))
        let questions = Self.parse(response.text)
        #if DEBUG
        // 作废是这套东西唯一的静默失败:界面上只表现为"没生成",而原因(写长了、带了壳、
        // 只写了一条)只有原文说得清。
        if questions.isEmpty {
            print("[追问] 这次一条能用的都没凑够，模型原样输出：\n\(response.text)")
        }
        #endif
        return questions
    }

    /// 不是 private:发给模型的到底是什么,得有测试盯着——尤其是"工具输出没跟着进去"这条。
    static func request(for context: FollowUpContext) -> String {
        var lines = [
            "用户问的：\(context.question)",
            "",
            "助手答的：\(clipped(context.answer))"
        ]
        if !context.toolNames.isEmpty {
            lines.append("")
            lines.append("这一轮查了：\(context.toolNames.joined(separator: "、"))")
        }
        return lines.joined(separator: "\n")
    }

    static func parse(_ text: String) -> [String] {
        let lines = ModelLines.parse(text, minCharacters: 3, maxCharacters: maxLineCharacters, limit: 3)
        return lines.count >= 2 ? lines : []
    }

    private static func clipped(_ answer: String) -> String {
        guard answer.count > maxAnswerCharacters else { return answer }
        let head = answer.prefix(600)
        let tail = answer.suffix(maxAnswerCharacters - 600)
        return "\(head)\n…\n\(tail)"
    }
}
