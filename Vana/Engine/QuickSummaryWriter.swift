import Foundation
import AIKit

/// 首屏那段话。
///
/// 本地已经算出了「现在是多少」(`HealthSituation.vitals`)和「有什么变了」
/// (`notableTriggers`),这一步只把它们写成人话。分两级和首屏那三条建议是同一套:本地那句
/// 立刻出、不花钱、没配 key 也有,模型那段回来了原地换掉。所以**失败即放弃**——调用方手里
/// 已经有一句能显示的话了。
///
/// **写现状,不只写波动。** 第一版只把触发点喂进来,于是数据平稳的日子里(多数人多数天)
/// 这段话退化成一句「没读到值得特别留意的波动」:一个数字都没有,用户读完仍然不知道自己
/// 现在怎么样。所以现状那几行是**主料**,触发点是"其中哪几条值得多说一句"。
///
/// 喂的仍然是**结论,不是原始数据**:进来的是「昨晚睡眠 7.2 小时（比最近 7 晚平均多 18
/// 分钟）」这种已经判好的一行,不是十四天的逐日样本。首屏那三条问题要看得见原始数据才写得
/// 具体(`QuestionSuggester.digest()`),这段话不用——多给的每一个数字都是它可以写错的
/// 数字,而这是用户打开 app 读到的第一段。
struct QuickSummaryWriter: Sendable {
    let providerId: String
    let model: String
    /// 本地判定出来的处境:现状 + 触发点。
    let situation: HealthSituation

    /// 首屏那段话的上限。
    ///
    /// 比第一版的 60 字宽:那时候它只说一件事,现在要先把现状说清楚再说要不要在意。卡片上
    /// 仍然只露前几行,读全的地方是点开之后的详情页——所以这里放宽的是"详情页读得到的",
    /// 首屏那一眼的成本没变。
    ///
    /// **按语言分档**:校验数的是字符,同样两到四句话英文占的字符是中文的两倍多。拿 160 去
    /// 卡英文,写得规规矩矩的一段也会整段作废——而作废是静默的,界面上只表现为"本地那句
    /// 一直没换掉"(8-27 记的「首屏那段状态摘要仍是中文」,一半根子就在这:提示词写死了
    /// 中文)。提示词里的数字和这里必须是同一个。
    static var maxCharacters: Int {
        HealthAssistantInstructions.replyLanguage == "English" ? 360 : 160
    }

    /// 语言跟着界面走(`HealthAssistantInstructions.replyLanguage`,和聊天回答同一个判据)。
    /// 不是 `let`:语言要在跑的那一刻读。
    private static var instructions: String {
        """
    你在为一个健康 app 的首屏写一小段话。用户刚打开它，还没开口问任何事，\
    这是他看到的第一段字。

    要求：
    - 先说清楚**他现在是什么状况**，把给出的关键数值说出来；然后才说要不要在意。
    - 用\(HealthAssistantInstructions.replyLanguage)写——无论下面给出的事实用什么语言。\
    两到四句，写成一段，不要换行，总共不超过 \(maxCharacters) 个字符。
    - 只能用下面给出的事实。**不许出现事实里没有的数字**，也不要把给出的数字换算成别的说法。
    - 数据平稳就照实说平稳，不要为了有话说把常态写成异常；也不要反过来宣布「一切正常」——\
    没有给出的项目你并不知道。
    - 不要提问，不要给建议、行动方案或者安慰。
    - 口气平静，像一个刚看过数据的人随口说的第一句，不是播报。不要用「您」。
    - 不做诊断，不提疾病名。
    - 不要编号、不要引号、不要任何解释。
    """
    }

    /// 一边写一边往外送,每次给的是**到此刻为止的全文**(不是增量),调用方直接赋值就行。
    ///
    /// 之所以要流式:详情页那颗刷新按钮按下去之后,非流式的一次调用是十几秒的空白——而这
    /// 段话本来就是一句一句成形的,让它一句一句出现,等待就变成了"正在写"。
    ///
    /// 收尾的校验(写没写超、有没有壳)在调用方按完整文本做一次,见 `parse`。
    func stream() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 现状和触发点都空:让模型为"什么都没读到"写一句,它会为了有话说而开始
                    // 编。顺带省下一次调用。
                    guard situation.hasSummaryFacts else {
                        continuation.finish()
                        return
                    }

                    let stored = try KeychainStore.get(account: KeychainStore.apiKeyAccount)
                    let key = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !key.isEmpty else { throw AgentError.needsAPIKey }

                    let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
                    var text = ""
                    for try await part in try client.stream(CallOptions(
                        model: model,
                        prompt: [
                            .system(Self.instructions),
                            .user(Self.request(for: situation))
                        ],
                        maxOutputTokens: 400,
                        // 比首屏那三条低:这段话要贴着给定的事实写,不需要它发挥。
                        temperature: 0.4,
                        // 同 `FollowUpSuggester`:留空是接受模型的默认,而好几家的默认是
                        // 思考——思考算进 output,这点预算会在写出正文之前就用光。
                        thinking: .off
                    )) {
                        guard case .textDelta(_, let delta, _) = part else { continue }
                        text += delta
                        continuation.yield(text)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 不是 private:发给模型的到底是哪几条事实,得有测试盯着——尤其是"原始数据没跟着进去"。
    static func request(for situation: HealthSituation) -> String {
        var text = "现在是\(situation.period.label)。"

        let readings = situation.vitals.measured.compactMap(\.brief)
        if !readings.isEmpty {
            text += "\n\n他现在的几个值：\n" + readings.map { "- \($0)" }.joined(separator: "\n")
        }

        let facts = situation.notableTriggers.prefix(3).map { "- \($0.brief)" }
        if facts.isEmpty {
            // 明说一句,否则模型会去猜给出的这几行里哪个算异常——它没有基线,只能瞎猜,
            // 而猜出来的那句正好是最不该出现在首屏的一句。
            text += "\n\n数据里没有读到值得特别留意的波动。"
        } else {
            text += "\n\n其中值得说一说的（按重要性排好，第一条最该被说到）：\n"
                + facts.joined(separator: "\n")
        }
        return text
    }

    /// 流式期间显示用:只剥壳,不判长短(还没写完,判了永远是不合格)。
    static func partial(_ text: String) -> String {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined()
    }

    /// 写完之后的校验。写超了整段作废,退回本地那句,不截断——一段话在"要不要在意"之前被
    /// 切断,剩下的正好是最没用的那半段。
    static func parse(_ text: String) -> String? {
        ModelLines.single(text, minCharacters: 8, maxCharacters: maxCharacters)
    }
}
