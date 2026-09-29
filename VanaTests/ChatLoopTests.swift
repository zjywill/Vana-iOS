import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// app 侧的 agent loop 集成测试。
///
/// 从 `ChatViewModel.send()` 一路走到发给模型的 prompt:事件归约、会话状态、上下文预算、
/// 压缩、换模型迁移都在里面,只有模型客户端是假的。
@MainActor
@Suite("Chat loop")
struct ChatLoopTests {

    private static func profile(
        _ modelId: String,
        window: Int
    ) -> AgentModelProfile {
        .init(providerId: "anthropic", modelId: modelId, contextWindow: window, maxOutputTokens: 4_000)
    }

    // MARK: - 连接抖一下

    @Test("a transient failure is retried and never leaves half a sentence on screen")
    func transientFailureIsRetried() async throws {
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 200_000),
            turns: [
                // 说了半句,然后 provider 报拥塞。手机上这一类最常见。
                .init(
                    text: "上周你",
                    finishReason: .init(unified: .error),
                    failureMessage: "Error 529: Overloaded"
                ),
                .init(text: "上周日均 9,100 步。")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedSession: false
        )

        viewModel.send("上周走了多少")
        try await waitUntil("重试之后这轮结束") { !viewModel.isReplying }

        let assistant = try #require(viewModel.messages.last)
        #expect(client.requests.count == 2)
        #expect(assistant.turnState == .completed)
        #expect(assistant.errorDescription == nil)
        // 半句必须撤掉,否则用户看到的是"上周你上周日均 9,100 步。"
        #expect(assistant.text == "上周日均 9,100 步。")
        #expect(viewModel.retryNotice == nil)
    }

    // MARK: - 思考

    /// 思考的增量是攒着批量落盘的(见 `ChatViewModel.pendingReasoning`),而撤字报的字数
    /// 里含着还在缓冲区里的那几个。落和撤的先后一旦反过来,第一次尝试想的那半段会在重试
    /// 的完整思考后面又冒出来一遍,而且再也撤不掉。
    @Test("thinking buffered for the next frame is still rolled back correctly on a retry")
    func bufferedReasoningIsRolledBack() async throws {
        let client = ScriptedModelClient(
            profile: Self.profile("deepseek-reasoner", window: 200_000),
            turns: [
                .init(
                    text: "上周你",
                    reasoning: "先看看步数",
                    finishReason: .init(unified: .error),
                    failureMessage: "Error 529: Overloaded"
                ),
                .init(text: "上周日均 9,100 步。", reasoning: "确认一下再说")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedSession: false
        )

        viewModel.send("上周走了多少")
        try await waitUntil("重试之后这轮结束") { !viewModel.isReplying }

        let assistant = try #require(viewModel.messages.last)
        #expect(assistant.reasoning == "确认一下再说")
        #expect(assistant.text == "上周日均 9,100 步。")
    }

    @Test("thinking lands on the message and survives a round trip through the session file")
    func reasoningIsKept() async throws {
        let client = ScriptedModelClient(
            profile: Self.profile("deepseek-reasoner", window: 200_000),
            turns: [
                .init(
                    reasoning: "得先查步数",
                    toolCalls: [.init(toolCallId: "c1", name: "daily_steps", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "日均 9,100 步。", reasoning: "9,100 不算低")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(client: client, capabilities: stubRegistry(["daily_steps": "9,100 步"]))
            },
            loadsPersistedSession: false
        )

        viewModel.send("上周走了多少")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        let assistant = try #require(viewModel.messages.last)
        // 每个工具轮想一次,两段都要在。
        #expect(assistant.reasoning == "得先查步数9,100 不算低")
        // 思考不能混进正文——界面上是两块东西,复制按钮也只该复制答案。
        #expect(assistant.text == "日均 9,100 步。")

        // 存盘再读回来,思考还在:重开一条老会话看到的应该和刚聊完时一样。
        let encoded = try JSONEncoder().encode(assistant)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: encoded)
        #expect(decoded.reasoning == assistant.reasoning)
    }

    @Test("a wrong API key is reported at once instead of after three retries")
    func permanentFailureIsReportedImmediately() async throws {
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 200_000),
            turns: [
                .init(finishReason: .init(unified: .error), failureMessage: "invalid_api_key"),
                .init(text: "不该走到这")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedSession: false
        )

        viewModel.send("上周走了多少")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        #expect(client.requests.count == 1)
        let assistant = try #require(viewModel.messages.last)
        #expect(assistant.turnState == .failed)

        // 屏幕上是一句他能照着做的话,**不是 provider 的原文**。
        //
        // 这条以前断言的正是「原文要出现在错误里」——而那正是 2026-08-16 被 App Store 拒的
        // 东西:审核员没配 key、提了个问题,气泡里回他一个 401(Guideline 2.1(a))。
        // 「invalid_api_key」对写这行代码的人有意义,对拿着手机的人没有。
        let shown = try #require(assistant.errorDescription)
        #expect(!shown.contains("invalid_api_key"))
        #expect(shown.contains("API key"))
        #expect(shown.contains("设置"))
    }

    @Test("每一类失败都翻成一句能照着做的话，认不出来的那一类才给原文")
    func failuresAreTranslatedForTheReader() {
        struct Failure: LocalizedError {
            let text: String
            var errorDescription: String? { text }
        }

        // 光秃秃的 HTTP 401 也要认出来:有的 provider body 里一个英文单词都没有。
        #expect(ChatViewModel.userFacingFailure(Failure(text: "Error code: 401")).contains("API key"))
        #expect(ChatViewModel.userFacingFailure(Failure(text: "insufficient quota")).contains("额度"))
        #expect(ChatViewModel.userFacingFailure(Failure(text: "prompt is too long")).contains("新对话"))

        // 分不出来的照旧给原文:一句编出来的通用错误比原文更没用。
        let odd = "something nobody has seen before"
        #expect(ChatViewModel.userFacingFailure(Failure(text: odd)) == odd)
    }

    // MARK: - 工具跑完之后用户手动停止

    @Test("stopping after a tool has run keeps the result and marks the turn stopped")
    func stopAfterToolRun() async throws {
        let toolOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分"
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 200_000),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                // 工具结果回来之后模型迟迟不说话——用户就是在这个时候按停止的。
                .init(text: "这几晚", beforeResponding: { try await Task.sleep(for: .seconds(30)) }),
                // 停止之后的追问走这一轮。
                .init(text: "深睡还行")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(client: client, capabilities: stubRegistry(["sleep_summary": toolOutput]))
            },
            loadsPersistedSession: false
        )

        viewModel.send("看看最近睡眠")
        try await waitUntil("工具结果回来") {
            viewModel.messages.last?.toolCalls.first?.output != nil
        }

        viewModel.stopReply()
        try await waitUntil("回复结束") { !viewModel.isReplying }

        let assistant = try #require(viewModel.messages.last)
        #expect(assistant.turnState == .stopped)
        #expect(assistant.text == "已停止回复")
        #expect(assistant.textIsPlaceholder)
        // 已经花掉的那次查询要留着:界面上还看得到,追问时也不用重查。
        #expect(assistant.toolCalls.count == 1)
        #expect(assistant.toolCalls.first?.output == toolOutput)

        // 停止之后接着问:上一轮的工具结果照样回放,占位文本不进上下文。
        viewModel.send("那深睡呢")
        try await waitUntil("追问结束") { !viewModel.isReplying }

        #expect(viewModel.messages.last?.text == "深睡还行")
        #expect(client.lastPromptContains(toolOutput))
        #expect(!client.lastPromptText.contains("已停止回复"))
    }

    // MARK: - 长对话触发压缩

    @Test("a long conversation compacts the earlier turn before the next request goes out")
    func longConversationTriggersCompaction() async throws {
        // 窗口刚好装得下一次大查询,装不下两次——第二轮就必须把上一轮压掉。
        let oldOutput = String(repeating: "上个月步数很长。", count: 500)
        let newOutput = String(repeating: "这周锻炼记录。", count: 500)
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 8_000),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "daily_steps", input: #"{"days":30}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "上个月平均一天 9,100 步。"),
                .init(
                    toolCalls: [.init(toolCallId: "call_2", name: "workouts", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "这周略低一点。")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(
                    client: client,
                    capabilities: stubRegistry(["daily_steps": oldOutput, "workouts": newOutput])
                )
            },
            loadsPersistedSession: false
        )

        viewModel.send("上个月走了多少")
        try await waitUntil("第一轮结束") { !viewModel.isReplying }
        viewModel.send("那这周呢")
        try await waitUntil("第二轮结束") { !viewModel.isReplying }

        // 第二轮的 prompt 里,上一轮的原始工具输出被折叠成摘要了;这一轮自己查的还在。
        #expect(!client.lastPromptContains(oldOutput))
        #expect(client.lastPromptContains(newOutput))
        #expect(client.lastPromptText.contains("上个月平均一天 9,100 步。"))
        #expect(client.lastPromptText.contains("折叠了 1 次工具调用"))
        #expect(client.lastPromptText.contains("那这周呢"))

        let context = try #require(viewModel.messages.last?.context)
        #expect(context.compactedAssistantMessages >= 1)
        #expect(context.droppedConversationTurns == 0)

        // 界面上那条回复不受影响:压缩只发生在发给模型的那一份里。
        #expect(viewModel.messages[1].text == "上个月平均一天 9,100 步。")
        #expect(viewModel.messages[1].toolCalls.first?.output == oldOutput)
    }

    // MARK: - 切模型之后继续追问

    @Test("a model switch with room to spare keeps the earlier tool trace intact")
    func harmlessModelSwitchKeepsHistory() async throws {
        let output = "08-01 8,432 步\n08-02 9,120 步"
        let bigModel = ScriptedModelClient(
            profile: Self.profile("claude-opus-4-8", window: 200_000),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "daily_steps", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "上周整体还行。")
            ]
        )
        let smallModel = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 20_000),
            turns: [.init(text: "继续说说。")]
        )
        let clients = ModelSequence(clients: [bigModel, smallModel])
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(client: clients.next(), capabilities: stubRegistry(["daily_steps": output]))
            },
            loadsPersistedSession: false
        )

        viewModel.send("先聊聊上周")
        try await waitUntil("大模型这轮结束") { !viewModel.isReplying }
        viewModel.send("换个模型继续说")
        try await waitUntil("小模型这轮结束") { !viewModel.isReplying }

        // 换模型本身不是丢历史的理由。窗口小了但离满还远,工具轨迹一个字都不该少。
        let context = try #require(viewModel.messages.last?.context)
        #expect(context.requestedModelId == "claude-sonnet-5")
        #expect(context.migrationNotes.isEmpty)
        #expect(context.compactedAssistantMessages == 0)
        #expect(smallModel.lastPromptContains(output))
    }

    @Test("switching to a model that cannot fit the history migrates that turn first")
    func modelSwitchUnderPressureMigratesHistory() async throws {
        // 这一段在新模型的窗口里放不下——这时候才该动它。
        //
        // 一次调用是撑不出这个体量的:单次工具输出有硬上限,压缩之前就截掉了。真正会撑爆
        // 窗口的是「一轮里查了很多次」,所以这里也这么造。
        let detailedOutput = String(repeating: "详细的工具轨迹。", count: 3_000)
        let bigModel = ScriptedModelClient(
            profile: Self.profile("claude-opus-4-8", window: 200_000),
            turns: [
                .init(
                    toolCalls: (1...4).map {
                        .init(toolCallId: "call_\($0)", name: "daily_steps", input: #"{"days":30}"#)
                    },
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "上周整体还行。", usage: .init(inputTokens: .init(total: 900)))
            ]
        )
        let smallModel = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 20_000),
            turns: [.init(text: "继续说说。")]
        )

        let registry = stubRegistry(["daily_steps": detailedOutput])
        let clients = ModelSequence(clients: [bigModel, smallModel])
        let viewModel = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: clients.next(), capabilities: registry) },
            loadsPersistedSession: false
        )

        viewModel.send("先聊聊上周")
        try await waitUntil("大模型这轮结束") { !viewModel.isReplying }

        let firstContext = try #require(viewModel.messages.last?.context)
        #expect(firstContext.requestedModelId == "claude-opus-4-8")
        #expect(firstContext.contextWindow == 200_000)

        viewModel.send("换个模型继续说")
        try await waitUntil("小模型这轮结束") { !viewModel.isReplying }

        let secondContext = try #require(viewModel.messages.last?.context)
        #expect(secondContext.requestedModelId == "claude-sonnet-5")
        // 窗口变小了就主动把老的那轮换成压缩形态,而不是等 provider 报 400。
        #expect(secondContext.migrationNotes.contains(ConversationHistoryPlanner.modelSwitchNote))
        #expect(secondContext.compactedAssistantMessages == 1)
        // 工具轨迹被折叠了。比对开头一段:原文早在进上下文时就被单次输出上限截过一道。
        #expect(!smallModel.lastPromptContains(String(repeating: "详细的工具轨迹。", count: 100)))
        #expect(smallModel.lastPromptText.contains("上周整体还行。"))

        // 旧模型上的估算/实际比例不能带到新模型上:tokenizer 换了,那把尺子就作废了。
        #expect(secondContext.estimatedPromptTokens == smallModel.estimateTokens(for: .init(
            profile: smallModel.profile,
            prompt: try #require(smallModel.requests.last).prompt,
            capabilities: registry.definitions
        )))
    }
}

extension ChatLoopTests {

    /// 每轮的工具输出各不相同,才分得清哪一轮被压掉了、哪一轮被保住了。
    static let turnOutput: @Sendable (Int) -> String = { turn in
        String(repeating: "第\(turn)轮的原始数据。", count: 400)
    }

    // MARK: - 整段摘要:生成一次,存下来,复用

    @Test("crossing the threshold summarizes older turns and persists the artifact for reuse")
    func summarizationIsGeneratedOnceAndPersisted() async throws {
        let output = Self.turnOutput
        let summarizer = StubSummarizer(
            visible: "聊过前两轮的步数。",
            replay: "要点：第 1 轮日均 9,100 步；第 2 轮日均 8,400 步。已调用 daily_steps。"
        )
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 12_000),
            turns: (1...4).flatMap { turn in
                [
                    ScriptedModelClient.Turn(
                        toolCalls: [.init(
                            toolCallId: "call_\(turn)",
                            name: "daily_steps",
                            input: #"{"days":30}"#
                        )],
                        finishReason: .init(unified: .toolCalls)
                    ),
                    ScriptedModelClient.Turn(text: "第 \(turn) 答")
                ]
            } + [
                // 第 5 轮不查数据:摘要已经把远处压下去了,这一轮不该再触发一次总结。
                ScriptedModelClient.Turn(text: "第 5 答")
            ]
        )
        let registry = CapabilityRegistry(
            definitions: [.init(name: "daily_steps", description: "stub", inputSchema: ["type": "object"])]
        ) { invocation in
            let turn = Int(invocation.toolCallId.dropFirst("call_".count)) ?? 1
            return CapabilityExecutionResult(output: .init(kind: .table, text: output(turn)))
        }
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(client: client, capabilities: registry, summarizer: summarizer)
            },
            loadsPersistedSession: false
        )

        for turn in 1...4 {
            viewModel.send("第 \(turn) 问")
            try await waitUntil("第 \(turn) 轮结束") { !viewModel.isReplying }
        }

        #expect(summarizer.calls == 1)

        // artifact 落在会话里了,而不是只活在这一轮的内存中。
        let owner = try #require(viewModel.messages.first {
            $0.storedTurn.compaction?.kind == .modelGenerated
        })
        let artifact = try #require(owner.storedTurn.compaction)
        #expect(artifact.visibleSummary == "聊过前两轮的步数。")
        #expect(artifact.sourceMessageIDs.count > 1)
        // 界面上要在这条下面画一条折叠线,告诉用户模型的记忆到哪儿为止。
        #expect(owner.foldedSpan == artifact)
        // 逐轮压缩是发请求时的临时决定,不该在界面上留痕。
        #expect(viewModel.messages.last?.foldedSpan == nil)

        // 存下来的东西要能原样读回来——否则重开 app 就得再花一次钱重算。
        let restored = try JSONDecoder().decode(
            ChatMessage.self,
            from: try JSONEncoder().encode(owner)
        )
        #expect(restored.storedTurn.compaction == artifact)

        #expect(client.lastPromptText.contains("要点：第 1 轮日均 9,100 步"))
        #expect(!client.lastPromptContains(output(1)))
        // 最近一轮的原始数据还在。
        #expect(client.lastPromptContains(output(3)))

        // 再问一轮:已经压下去的那段不该被重新总结一遍。
        viewModel.send("第 5 问")
        try await waitUntil("第 5 轮结束") { !viewModel.isReplying }
        #expect(summarizer.calls == 1)
        #expect(viewModel.messages.last?.text == "第 5 答")
    }
}

/// 一次会话里换模型:每次要引擎就给下一个客户端。
@MainActor
final class ModelSequence {
    private var clients: [ScriptedModelClient]
    private var index = 0

    init(clients: [ScriptedModelClient]) {
        self.clients = clients
    }

    func next() -> ScriptedModelClient {
        defer { index = min(index + 1, clients.count - 1) }
        return clients[index]
    }
}
