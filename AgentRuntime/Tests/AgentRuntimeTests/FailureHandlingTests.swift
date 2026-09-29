import Foundation
import Testing

@testable import AgentRuntime

/// 失败路径的集成测试。
///
/// 这里每一条都是「本来会让用户白等一场」的场景:基站切换、provider 拥塞、输出被截断、
/// 查询次数用光。agent 循环真正的质量差别在这些地方,不在顺利那条路上。
@Suite("Failure handling")
struct FailureHandlingTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 20_000,
        maxOutputTokens: 8_000
    )

    /// 退避时间设成 0:测的是「重试了没有」,不是「等够了没有」。
    private static let fastRetry = RetryPolicy(maxRetries: 2, baseDelay: .zero, maxDelay: .zero)

    private func loop(
        _ client: ScriptedModelClient,
        capabilities: CapabilityRegistry = stubRegistry(["daily_steps": "9,100 步"]),
        retryPolicy: RetryPolicy = FailureHandlingTests.fastRetry,
        policy: ContextPolicy = .default,
        summarizer: (any AgentSummarizer)? = nil,
        maxToolRounds: Int = 6
    ) -> AgentLoop {
        AgentLoop(
            client: client,
            capabilities: capabilities,
            systemInstruction: "system",
            summarizer: summarizer,
            policy: policy,
            retryPolicy: retryPolicy,
            maxToolRounds: maxToolRounds
        )
    }

    private let question: [AgentChatMessageDTO] = [.init(role: .user, text: "上周走了多少")]

    // MARK: - 重试

    @Test("a transient provider error is retried and the half-finished sentence is rolled back")
    func transientErrorIsRetried() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                // 说了半句,然后 provider 报拥塞。
                .init(
                    textDeltas: ["上周你", "走了"],
                    finishReason: .init(unified: .error),
                    failureMessage: "Error 529: Overloaded, please try again"
                ),
                .init(textDeltas: ["上周日均 9,100 步。"], finishReason: .init(unified: .stop))
            ]
        )

        let (messages, events, error) = await record(loop(client), history: question)

        #expect(error == nil)
        #expect(client.requests.count == 2)
        // 半句话必须撤掉,否则用户看到的是"上周你走了上周日均 9,100 步。"
        #expect(messages.last?.text == "上周日均 9,100 步。")

        #expect(events.rolledBackCharacters == ["上周你走了".count])
        let retry = try! #require(events.retries.first)
        #expect(retry.attempt == 1)
        #expect(retry.reason.contains("Overloaded"))
    }

    @Test("thinking reaches the caller and survives a tool round")
    func reasoningIsStreamed() async {
        // 带工具的一轮里模型思考两次:决定要查什么,再解读查回来的东西。两段都得到手。
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    reasoningDeltas: ["先看", "步数"],
                    toolCalls: [.init(toolCallId: "c1", name: "daily_steps", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(
                    textDeltas: ["日均 9,100 步。"],
                    reasoningDeltas: ["9,100 不算低"],
                    finishReason: .init(unified: .stop)
                )
            ]
        )

        let (messages, _, error) = await record(loop(client), history: question)

        #expect(error == nil)
        #expect(messages.last?.reasoning == "先看步数9,100 不算低")
        // 思考不能混进正文——界面上它们是两块东西。
        #expect(messages.last?.text == "日均 9,100 步。")
    }

    @Test("thinking is rolled back on retry alongside the half-finished sentence")
    func reasoningIsRolledBack() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    textDeltas: ["上周你"],
                    reasoningDeltas: ["先查一下"],
                    finishReason: .init(unified: .error),
                    failureMessage: "Error 529: Overloaded, please try again"
                ),
                .init(
                    textDeltas: ["上周日均 9,100 步。"],
                    reasoningDeltas: ["查到了"],
                    finishReason: .init(unified: .stop)
                )
            ]
        )

        let (messages, events, error) = await record(loop(client), history: question)

        #expect(error == nil)
        // 重跑会把思考从头再说一遍,不撤就是"先查一下查到了"。
        #expect(events.rolledBackReasoningCharacters == ["先查一下".count])
        #expect(messages.last?.reasoning == "查到了")
        #expect(messages.last?.text == "上周日均 9,100 步。")
    }

    @Test("a dropped connection mid-stream is retried too")
    func transportFailureIsRetried() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(throwsAfterText: URLError(.networkConnectionLost)),
                .init(textDeltas: ["接上了"], finishReason: .init(unified: .stop))
            ]
        )

        let (messages, _, error) = await record(loop(client), history: question)

        #expect(error == nil)
        #expect(messages.last?.text == "接上了")
    }

    @Test("a deterministic error fails immediately instead of being retried three times")
    func permanentErrorIsNotRetried() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    finishReason: .init(unified: .error),
                    failureMessage: "invalid_api_key: Incorrect API key provided"
                ),
                .init(textDeltas: ["不该走到这"], finishReason: .init(unified: .stop))
            ]
        )

        let (_, events, error) = await record(loop(client), history: question)

        // 对着"key 不对"重试三次,只是把同一句话说三遍,还把真正的原因往后拖了十几秒。
        #expect(client.requests.count == 1)
        #expect(events.retries.isEmpty)
        #expect(error as? AgentLoopError == .service("invalid_api_key: Incorrect API key provided"))
    }

    @Test("retries stop at the configured budget and the last error surfaces")
    func retryBudgetIsRespected() async {
        let failing = ScriptedModelClient.Turn(
            finishReason: .init(unified: .error),
            failureMessage: "503 service unavailable"
        )
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: Array(repeating: failing, count: 5)
        )

        let (_, events, error) = await record(loop(client), history: question)

        // 首次 + 2 次重试。
        #expect(client.requests.count == 3)
        #expect(events.retries.count == 2)
        #expect(error as? AgentLoopError == .service("503 service unavailable"))
    }

    // MARK: - 被截断的工具调用

    @Test("tool calls from a length-truncated response are reported, never executed")
    func truncatedToolCallsAreNotExecuted() async {
        let executions = Mutex(0)
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                // 参数写到一半就撞上输出上限。JSON 抢救出来能解析,但里面的日期可能是半截的。
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "daily_steps", input: #"{"days":3"#)],
                    finishReason: .init(unified: .length)
                ),
                .init(
                    toolCalls: [.init(toolCallId: "call_2", name: "daily_steps", input: #"{"days":30}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(textDeltas: ["上个月日均 9,100 步。"], finishReason: .init(unified: .stop))
            ]
        )

        let (messages, _, error) = await record(
            loop(client, capabilities: stubRegistry(["daily_steps": "9,100 步"]) { _ in
                executions.increment()
            }),
            history: question
        )

        // 截断的那次没执行,重发的那次执行了。整轮没有失败——这一档是可以自愈的。
        #expect(error == nil)
        #expect(executions.value == 1)
        #expect(messages.last?.text == "上个月日均 9,100 步。")

        let calls = try! #require(messages.last?.toolCalls)
        #expect(calls.count == 2)
        #expect(calls[0].isError)
        #expect(calls[0].output?.text.contains("Re-issue") == true)
        #expect(!calls[1].isError)
    }

    // MARK: - 工具轮数用光

    @Test("running out of tool rounds keeps everything already fetched")
    func toolRoundLimitEndsGracefully() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: (1...4).map { round in
                .init(
                    textDeltas: ["再查一次。"],
                    toolCalls: [.init(toolCallId: "call_\(round)", name: "daily_steps", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                )
            }
        )

        let (messages, events, error) = await record(
            loop(client, maxToolRounds: 3),
            history: question
        )

        // 用光轮数不是错误。把已经查到的三次结果全丢掉去报一个「查询次数过多」,
        // 对用户来说是净损失。
        #expect(error == nil)
        #expect(client.requests.count == 3)
        #expect(events.finishReason?.raw == AgentLoop.toolRoundLimitReason)

        let assistant = try! #require(messages.last)
        #expect(assistant.storedTurn.state == .completed)
        #expect(assistant.toolCalls.count == 3)
        #expect(assistant.toolCalls.allSatisfy { $0.output != nil })
    }

    // MARK: - 工具输出的闸门

    @Test("an oversized tool result is capped before it ever reaches the context")
    func toolOutputIsCapped() async {
        let flood = (1...4_000).map { "第 \($0) 天 9,100 步" }.joined(separator: "\n")
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "daily_steps", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(textDeltas: ["查到了"], finishReason: .init(unified: .stop))
            ]
        )

        let (messages, _, error) = await record(
            loop(
                client,
                capabilities: stubRegistry(["daily_steps": flood]),
                policy: .init(maxToolOutputCharacters: 500)
            ),
            history: question
        )

        #expect(error == nil)
        let output = try! #require(messages.last?.toolCalls.first?.output?.text)
        // 压缩是亡羊补牢:那一轮的原始输出在被压之前得先原样发出去一次。这道闸在源头。
        #expect(output.count < 700)
        #expect(output.contains("第 1 天"))
        #expect(!output.contains("第 4000 天"))
        #expect(output.contains("truncated"))
        // 半行数字比没有数字更危险,截断必须落在行边界上。
        #expect(!output.contains("第 4000 天 9,1\n"))

        let followUp = try! #require(client.requests.last?.prompt)
        #expect(!followUp.contains("第 3000 天"))
    }

    // MARK: - provider 报上下文超限

    @Test("a context-overflow error compacts and re-runs the round instead of failing")
    func contextOverflowRecovers() async {
        let summarizer = RecordingSummarizer(visible: "聊过步数。", replay: "要点：上个月日均 9,100 步。")
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                // 本地估算说放得下,provider 说放不下。以 provider 为准。
                .init(
                    finishReason: .init(unified: .error),
                    failureMessage: "prompt is too long: 210000 tokens > 200000 maximum"
                ),
                .init(textDeltas: ["压完了，接着说"], finishReason: .init(unified: .stop))
            ]
        )

        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "第 1 问"),
            completedAssistant(id: "call_1", text: "第 1 答", output: "上个月日均 9,100 步"),
            .init(role: .user, text: "第 2 问"),
            completedAssistant(id: "call_2", text: "第 2 答", output: "上周日均 8,800 步"),
            .init(role: .user, text: "第 3 问")
        ]

        let (messages, events, error) = await record(
            loop(client, summarizer: summarizer),
            history: history
        )

        #expect(error == nil)
        #expect(client.requests.count == 2)
        #expect(messages.last?.text == "压完了，接着说")
        // 水位线根本没到——是 provider 的拒收把压缩逼出来的。
        #expect(events.compactionReasons == [.overflowRecovery])
        #expect(summarizer.calls.count == 1)
        #expect(client.requests.last?.prompt.allText.contains("要点：上个月日均 9,100 步。") == true)
    }

    @Test("a second overflow reports something the user can act on")
    func repeatedOverflowGivesUpCleanly() async {
        let overflow = ScriptedModelClient.Turn(
            finishReason: .init(unified: .error),
            failureMessage: "prompt is too long: 210000 tokens > 200000 maximum"
        )
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: Array(repeating: overflow, count: 3)
        )

        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "第 1 问"),
            completedAssistant(id: "call_1", text: "第 1 答", output: "上个月日均 9,100 步"),
            .init(role: .user, text: "第 2 问")
        ]

        let (_, _, error) = await record(
            loop(client, summarizer: RecordingSummarizer(visible: "看过了。", replay: "要点。")),
            history: history
        )

        // 压过一次还是超,就别再把 provider 那句 token 数甩给用户了——他能做的是开新对话。
        #expect(client.requests.count == 2)
        #expect(error as? AgentLoopError == .contextWindowExceeded)
    }

    @Test("with an unknown context window an overflow goes straight to the app instead of resending the same prompt")
    func overflowWithUnknownWindowIsNotRetriedInPlace() async {
        let overflow = ScriptedModelClient.Turn(
            finishReason: .init(unified: .error),
            failureMessage: "prompt is too long: 210000 tokens > 200000 maximum"
        )
        let client = ScriptedModelClient(
            profile: AgentModelProfile(providerId: "custom", modelId: "unknown", contextWindow: nil, maxOutputTokens: nil),
            turns: Array(repeating: overflow, count: 3)
        )

        let (_, _, error) = await record(
            loop(client, summarizer: RecordingSummarizer(visible: "看过了。", replay: "要点。")),
            history: [.init(role: .user, text: "第 1 问")]
        )

        // 没有预算就没有水位线,原地恢复重发的是同一份 prompt。
        #expect(client.requests.count == 1)
        #expect(error as? AgentLoopError == .contextWindowExceeded)
    }

    @Test("a summarizer failure is reported instead of vanishing")
    func compactionFailureIsObservable() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    finishReason: .init(unified: .error),
                    failureMessage: "context length exceeded"
                ),
                .init(textDeltas: ["机械压缩之后接着说"], finishReason: .init(unified: .stop))
            ]
        )

        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "第 1 问"),
            completedAssistant(id: "call_1", text: "第 1 答", output: "上个月日均 9,100 步"),
            .init(role: .user, text: "第 2 问"),
            completedAssistant(id: "call_2", text: "第 2 答", output: "上周日均 8,800 步"),
            .init(role: .user, text: "第 3 问")
        ]

        let (_, events, error) = await record(
            loop(client, summarizer: FailingSummarizer()),
            history: history
        )

        // 总结挂了要退回机械压缩继续跑,但不能静默——线上出问题时得查得到。
        #expect(error == nil)
        #expect(events.compactionFailures.count == 1)
        #expect(events.compactionFailures.first?.contains("summarizer down") == true)
    }

    // MARK: -

    private func completedAssistant(id: String, text: String, output: String) -> AgentChatMessageDTO {
        AgentChatMessageDTO(
            role: .assistant,
            text: text,
            toolCalls: [.init(id: id, name: "daily_steps", input: "{}", output: .init(kind: .table, text: output))],
            storedTurn: .init(
                exactTranscript: .init(messages: [
                    .init(role: .assistant, parts: [
                        .text(text),
                        .toolCall(.init(toolCallId: id, toolName: "daily_steps", input: "{}"))
                    ]),
                    .toolResult(toolCallId: id, toolName: "daily_steps", result: .string(output))
                ]),
                state: .completed
            )
        )
    }
}

@Suite("Failure classification")
struct ModelFailureTests {

    @Test("provider congestion and transport hiccups are retryable")
    func transientPatterns() {
        #expect(ModelFailure.isRetryable("Error 529: Overloaded"))
        #expect(ModelFailure.isRetryable("rate_limit_error: too many requests"))
        #expect(ModelFailure.isRetryable("The request timed out."))
        #expect(ModelFailure.isRetryable("The network connection was lost."))
        #expect(ModelFailure.isRetryable("stream ended without a finish reason"))
        #expect(ModelFailure.isRetryable("502 Bad Gateway"))
    }

    @Test("account state and bad requests are not")
    func permanentPatterns() {
        #expect(!ModelFailure.isRetryable("invalid_api_key"))
        #expect(!ModelFailure.isRetryable("Your credit balance is too low"))
        #expect(!ModelFailure.isRetryable("insufficient_quota"))
        #expect(!ModelFailure.isRetryable("model not found: claude-made-up"))
        #expect(!ModelFailure.isRetryable("content filter"))
    }

    @Test("context overflow is compacted, never retried")
    func overflowIsItsOwnCategory() {
        let overflow = [
            "prompt is too long: 210000 tokens > 200000 maximum",
            "This model's maximum context length is 128000 tokens",
            "context_length_exceeded",
            "Request too large for gpt-4"
        ]
        for message in overflow {
            #expect(ModelFailure.isContextOverflow(message))
            // 原样再发一次还是塞不下。这条路走压缩,不走重试。
            #expect(!ModelFailure.isRetryable(message))
        }
    }

    @Test("backoff doubles and stays under the ceiling")
    func backoffGrows() {
        let policy = RetryPolicy(maxRetries: 5, baseDelay: .seconds(1), maxDelay: .seconds(4))
        #expect(policy.delay(forAttempt: 1) == .seconds(1))
        #expect(policy.delay(forAttempt: 2) == .seconds(2))
        #expect(policy.delay(forAttempt: 3) == .seconds(4))
        #expect(policy.delay(forAttempt: 4) == .seconds(4))
        #expect(!RetryPolicy.disabled.allowsRetry(attempt: 1))
    }
}

@Suite("Context calibration")
struct ContextCalibrationTests {

    @Test("one cache-skewed turn cannot drag the ruler off")
    func medianResistsOutliers() {
        var calibration = ContextCalibration()
        calibration.note(actual: 1_100, estimated: 1_000)
        calibration.note(actual: 1_200, estimated: 1_000)
        // 这一轮命中了缓存,provider 只报了没走缓存的那部分。
        calibration.note(actual: 300, estimated: 1_000)

        // 只信最近一次的话,下一轮就拿 0.3 这把废尺子去量,预算凭空多出三倍。
        let scale = try! #require(calibration.scale)
        #expect(scale > 1 && scale < 1.3)
    }

    @Test("ratios that could only come from a unit mismatch are dropped")
    func absurdSamplesAreIgnored() {
        var calibration = ContextCalibration()
        calibration.note(actual: 100_000, estimated: 100)
        #expect(calibration.scale == nil)
    }

    @Test("a provider overflow inflates the ruler so the next plan compacts harder")
    func overflowInflatesScale() {
        var calibration = ContextCalibration(scale: 1)
        calibration.inflate(by: 1.25)
        #expect(calibration.apply(to: 1_000) == 1_250)
    }
}
