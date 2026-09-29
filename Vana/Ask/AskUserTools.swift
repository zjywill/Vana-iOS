import Foundation
import AgentRuntime

/// 反过来问用户一句,并且把答案做成点得动的东西。
///
/// **它不取数据,它换一种问法。** 这个 app 里别的工具都是「去拿一样模型没有的东西」;
/// 这一条唯一的产出是一张卡片。所以判据也不一样:它值不值得占一个工具槽,取决于
/// **「让他打字」和「让他点一下」的差距**。健康对话里那个差距很大——「你这个头疼是哪一种」
/// 用打字回答要他先想清楚怎么描述,而多数人此刻描述不清楚,于是那一问换回来的是「就是疼」,
/// 模型只好再问一遍。给四个选项,这一来一回就没了。
///
/// **它不阻塞这一轮**。工具当场返回,模型接着把话说完然后停下;他点的那一下变成一条普通的
/// 用户消息,走的是和打字一模一样的那条路(排队、劈开、存盘、召回索引、记忆抽取全都不用动)。
/// 做成"挂起等他点"看着更聪明,代价是一轮回复会停在那儿等一件永远可能不发生的事——他划走了、
/// app 被回收了,那一轮就带着半份 transcript 死在那里,而停止按钮、插话队列、后台抽取全都
/// 要为这个新状态各开一个洞。
enum AskUserTools {
    static let askToolName = "ask_user"

    static func registry() -> CapabilityRegistry {
        CapabilityRegistry(definitions: [askDefinition]) { invocation in
            guard invocation.name == askToolName else {
                return CapabilityExecutionResult(
                    output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                    isError: true
                )
            }
            return ask(invocation)
        }
    }

    // MARK: - 定义

    private static var askDefinition: CapabilityDefinition {
        // 逐条拆开写不是风格问题:整块字面量嵌到三层,编译器就开始超时(同 `MedicationTools`)。
        let question: RuntimeJSONValue = .object([
            "type": "string",
            "description": .string("要问他的那一句，一个问题，不超过 \(AskUserQuestion.maxQuestionCharacters) 个字")
        ])
        let option: RuntimeJSONValue = .object([
            "type": "object",
            "properties": .object([
                "label": .object([
                    "type": "string",
                    "description": .string("按钮上的字，用他会说的说法，不超过 \(AskUserQuestion.maxLabelCharacters) 个字")
                ]),
                "detail": .object([
                    "type": "string",
                    "description": .string(
                        "这条是什么意思，一句话，不超过 \(AskUserQuestion.maxDetailCharacters) 个字。"
                            + "标签本身已经说清楚就别写"
                    )
                ])
            ]),
            "required": .array([.string("label")]),
            "additionalProperties": .bool(false)
        ])
        let options: RuntimeJSONValue = .object([
            "type": "array",
            "description": .string(
                "\(AskUserQuestion.minOptions)–\(AskUserQuestion.maxOptions) 个互不重叠的选项，"
                    + "覆盖常见的几种情况。「其他」和「不想说」不用写，卡片上本来就有"
            ),
            "items": option,
            "minItems": .int(AskUserQuestion.minOptions),
            "maxItems": .int(AskUserQuestion.maxOptions)
        ])
        let allowsMultiple: RuntimeJSONValue = .object([
            "type": "boolean",
            "description": "几条可以同时成立时传 true，比如问他有哪几种情况。只能选一种就别传"
        ])
        let schema: RuntimeJSONValue = .object([
            "type": "object",
            "properties": .object([
                "question": question,
                "options": options,
                "allowsMultiple": allowsMultiple
            ]),
            "required": .array([.string("question"), .string("options")]),
            "additionalProperties": .bool(false)
        ])

        return CapabilityDefinition(
            name: askToolName,
            description: """
            反问用户一句，并把答案做成他点一下就能选的卡片。\
            他的描述里**缺一个会改变你回答方向的条件、而它的取值只有有限几种**时就调用：\
            是哪一种情况、什么时候开始的、想从哪儿入手，\
            或者接下来能帮他的方向有好几个、该挑哪个得他说了算。\
            **先问再答**，不要按最可能的那一种猜着答完。\
            卡片显示在你这条回复下面，他也可以自己写一句或者跳过不答。\
            工具查得到的、他说过的、记忆里已有的**不要问他**。\
            答案本身是开放的（他得讲一段经过）就直接用一句话问，别硬凑几个选项；一次只问一个问题。
            """,
            inputSchema: schema,
            strictPreferred: false
        )
    }

    // MARK: - 执行

    private static func ask(_ invocation: CapabilityInvocation) -> CapabilityExecutionResult {
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let question = clipped(input?["question"]?.stringValue, AskUserQuestion.maxQuestionCharacters)
        guard !question.isEmpty else {
            return failure("参数不全：需要 question。")
        }

        var seen = Set<String>()
        let options = (input?["options"]?.arrayValue ?? [])
            .map { raw -> AskUserQuestion.Option in
                AskUserQuestion.Option(
                    label: clipped(raw["label"]?.stringValue, AskUserQuestion.maxLabelCharacters),
                    detail: clipped(raw["detail"]?.stringValue, AskUserQuestion.maxDetailCharacters)
                )
            }
            // 重复的标签在卡上是两颗一模一样的按钮,而它们发出去的是同一句话——看起来就是坏的。
            .filter { !$0.label.isEmpty && seen.insert($0.label).inserted }
            .prefix(AskUserQuestion.maxOptions)

        // 少于两条**报错**,不是悄悄画一张只有一颗按钮的卡。一个选项的"选择"不是选择,
        // 那本来就该是正文里的一句话——把它说清楚,模型下次自己就用一句话问了。
        guard options.count >= AskUserQuestion.minOptions else {
            return failure(
                "至少要 \(AskUserQuestion.minOptions) 个不重复的选项，这次只有 \(options.count) 个。"
                    + "本来就只有一种可能的追问，直接在正文里用一句话问他，不用调这个工具。"
            )
        }

        let payload = AskUserQuestion(
            question: question,
            options: Array(options),
            allowsMultiple: input?["allowsMultiple"]?.boolValue ?? false
        )

        return CapabilityExecutionResult(
            output: .init(
                kind: .text,
                text: modelText(payload),
                metadata: AskUserQuestion.encodeForToolMetadata(payload)
            )
        )
    }

    private static func failure(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text), isError: true)
    }

    private static func clipped(_ value: String?, _ limit: Int) -> String {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(limit))
    }

    // MARK: - 渲染

    /// 给模型的那一份。
    ///
    /// **把问题和选项原样写回去**,不只回一句「已显示」。这一段会跟着 transcript 一路留在
    /// 上下文里,几轮之后模型要凭它知道当初问的是什么——他下一句只回了「半夜醒」三个字,
    /// 没有这段的话那三个字接不上任何东西。
    ///
    /// 不是 private:输出格式有测试盯着。
    static func modelText(_ question: AskUserQuestion) -> String {
        var lines = ["已经把这个问题做成选项卡片，显示在你这条回复下面："]
        lines.append("")
        lines.append("问：\(question.question)")
        lines.append(contentsOf: question.options.map { option in
            option.detail.isEmpty ? "- \(option.label)" : "- \(option.label)（\(option.detail)）"
        })
        lines.append(
            question.allowsMultiple
                ? "他可以勾选其中几条，也可以自己写一句，或者跳过不答。"
                : "他可以点其中一条，也可以自己写一句，或者跳过不答。"
        )
        lines.append("")
        lines.append(footer)
        return lines.joined(separator: "\n")
    }

    /// 这三句是这个工具真正的产出,不是免责声明。有测试盯着。
    ///
    /// 少第一句,正文会把卡上已经有的选项再抄一遍——同一组词在屏幕上出现两次,而下面那份
    /// 是点得动的,上面那份不是。少第二句,它会问完之后自己挑一个答案接着分析下去,那这张卡
    /// 就成了摆设。少第三句,他按「跳过」等于什么都没发生:模型下一轮换个说法再问一遍,
    /// 而这颗按钮存在的全部意义就是他不必回答。
    static let footer = """
        接下来：正文里不要把上面的选项再列一遍——卡片上已经有了，最多用一句话说清你为什么要问。\
        也不用告诉他去哪儿点：卡片排在你这段话的**下面**，别写成「上面的选项」。\
        说完就停下等他回答，不要替他假设一个答案接着往下分析。\
        他跳过了、或者答得含糊，就按已有的信息继续，同一个问题不要再问第二遍。
        """
}
