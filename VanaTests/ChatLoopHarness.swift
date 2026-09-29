import Foundation
import AgentRuntime

@testable import Vana

/// 脚本化的假模型。不发网络请求,但把每一轮实际发出去的 prompt 记下来——app 侧的 loop
/// 测试要验的正是"这一轮到底发了什么给模型",光看界面上剩下什么是看不出来的。
final class ScriptedModelClient: AgentModelClient, @unchecked Sendable {
    struct Turn: Sendable {
        var text: String = ""
        /// 模型这一轮的思考。真模型先思考再说话,脚本也按这个顺序发。
        var reasoning: String = ""
        var toolCalls: [CapabilityInvocation] = []
        var finishReason: AgentFinishReason = .init(unified: .stop)
        var usage: AgentUsage?
        /// provider 在流里报的错。
        var failureMessage: String?
        /// 这一轮开口之前先跑一下。用来把某一轮挂住,好在模型还没说话时按停止。
        var beforeResponding: (@Sendable () async throws -> Void)?
    }

    let profile: AgentModelProfile

    private let lock = NSLock()
    private var turns: [Turn]
    private var _requests: [AgentModelRequest] = []
    private let tokensPerCharacter: Double

    var requests: [AgentModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var lastPromptText: String {
        requests.last?.prompt.messages.map(\.text).joined(separator: "\n") ?? ""
    }

    /// 工具调用的参数和结果不在 `text` 里,判断"原始输出还在不在上下文里"要连它一起看。
    func lastPromptContains(_ needle: String) -> Bool {
        guard let prompt = requests.last?.prompt else { return false }
        if lastPromptText.contains(needle) { return true }
        return prompt.messages.contains { message in
            message.parts.contains { part in
                switch part {
                case .toolResult(let result):
                    return (result.result.stringValue ?? "").contains(needle)
                case .toolCall(let call):
                    return call.input.contains(needle) || call.toolName.contains(needle)
                default:
                    return false
                }
            }
        }
    }

    init(profile: AgentModelProfile, turns: [Turn], tokensPerCharacter: Double = 1) {
        self.profile = profile
        self.turns = turns
        self.tokensPerCharacter = tokensPerCharacter
    }

    func estimateTokens(for request: AgentModelRequest) -> Int {
        let characters = request.prompt.messages.reduce(0) { total, message in
            total + message.parts.reduce(0) { partial, part in
                switch part {
                case .text(let text): return partial + text.count
                case .reasoning(let text, _): return partial + text.count
                case .toolCall(let call): return partial + call.toolName.count + call.input.count
                case .toolResult(let result):
                    return partial + ((try? result.result.encodedString().count) ?? 0)
                case .file: return partial
                }
            }
        }
        return Int((Double(characters) * tokensPerCharacter).rounded())
    }

    func stream(_ request: AgentModelRequest) throws -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        lock.lock()
        _requests.append(request)
        let turn = turns.isEmpty ? Turn() : turns.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await turn.beforeResponding?()
                    try Task.checkCancellation()

                    if !turn.reasoning.isEmpty {
                        continuation.yield(.reasoningDelta(turn.reasoning))
                    }
                    if !turn.text.isEmpty {
                        continuation.yield(.textDelta(turn.text))
                    }
                    var parts: [AgentTranscript.Part] = []
                    if !turn.reasoning.isEmpty {
                        parts.append(.reasoning(turn.reasoning))
                    }
                    if !turn.text.isEmpty {
                        parts.append(.text(turn.text))
                    }
                    parts.append(contentsOf: turn.toolCalls.map {
                        .toolCall(.init(toolCallId: $0.toolCallId, toolName: $0.name, input: $0.input))
                    })

                    continuation.yield(.completed(AgentModelResponse(
                        assistantMessage: parts.isEmpty ? nil : .init(role: .assistant, parts: parts),
                        pendingCalls: turn.toolCalls,
                        finishReason: turn.finishReason,
                        usage: turn.usage,
                        failureMessage: turn.failureMessage
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 走真实 `AgentLoop` 的测试引擎。
///
/// 和 `AIKitEngine` 的差别只有一处:模型客户端是脚本化的。工具循环、预算、压缩、换模型
/// 迁移、事件归约全都是线上那一套。
struct LoopEngine: AgentEngine {
    let name = "测试引擎"
    /// 假引擎默认认得图:带不带图由用例自己在 draft 上决定,不该再被一个全局设置挡一道。
    var supportsVision = true

    let client: ScriptedModelClient
    var capabilities: CapabilityRegistry
    var systemInstruction = "你是测试助手"
    var summarizer: (any AgentSummarizer)?
    /// 退避时间设成 0:测的是「重试了没有」,不是「等够了没有」。次数和线上一致。
    var retryPolicy = RetryPolicy(baseDelay: .zero, maxDelay: .zero)
    /// 和线上同一个位置挂:hook 是 loop 发的通知,不是引擎自己造的。
    var hooks: AgentHookDispatcher?

    func reply(
        to history: [ChatMessage],
        pendingInput: AgentPendingInputProvider? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let loop = AgentLoop(
                        client: client,
                        capabilities: capabilities,
                        systemInstruction: systemInstruction,
                        compactor: .vana,
                        summarizer: summarizer,
                        policy: .vana,
                        retryPolicy: retryPolicy,
                        pendingInput: pendingInput,
                        truncatedToolCallNotice: truncatedToolCallNotice,
                        hooks: hooks
                    )
                    for try await event in loop.run(history: history.map(\.agentDTO)) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AgentError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

func stubRegistry(_ outputs: [String: String]) -> CapabilityRegistry {
    CapabilityRegistry(
        definitions: outputs.keys.sorted().map {
            CapabilityDefinition(
                name: $0,
                description: "stub",
                inputSchema: ["type": "object"]
            )
        }
    ) { invocation in
        guard let text = outputs[invocation.name] else {
            return CapabilityExecutionResult(output: .init(kind: .text, text: "unknown"), isError: true)
        }
        return CapabilityExecutionResult(output: .init(kind: .table, text: text))
    }
}

/// 固定输出的假 summarizer,顺便记下被叫了几次。
final class StubSummarizer: AgentSummarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let visible: String
    private let replay: String

    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    init(visible: String, replay: String) {
        self.visible = visible
        self.replay = replay
    }

    func summarize(_ plan: SummarizationPlan) async throws -> CompactionArtifact {
        record()
        return CompactionArtifact(
            kind: .modelGenerated,
            visibleSummary: visible,
            replaySummary: .assistantSummary(replay, sourceIDs: plan.sourceMessageIDs),
            sourceMessageIDs: plan.sourceMessageIDs
        )
    }

    private func record() {
        lock.lock()
        _calls += 1
        lock.unlock()
    }
}

struct WaitTimeout: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimeout(description: "等 \(what) 超时")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
