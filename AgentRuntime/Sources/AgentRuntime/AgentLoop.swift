import Foundation

public enum AgentLoopError: Error, Equatable, Sendable {
    /// provider 侧的错误,原文透出。重试用完了才会走到这儿。
    case service(String)
    case contentFilter
    /// 流结束了但没拿到 finish reason。
    case incompleteResponse
    /// 压缩、丢弃、溢出恢复都做完了还是塞不进窗口。
    case contextWindowExceeded
}

/// 通用 agent loop。
///
/// 它只认三样东西:一个能流式跑一轮的 `AgentModelClient`、一组 `CapabilityRegistry` 里的
/// 能力、一份 app 自己的会话历史。HealthKit、Calendar、Files 对它没有区别,AIKit 和别的
/// SDK 也没有区别。
///
/// 失败处理分三层,越靠外越少见:
/// 1. 工具失败 → 变成一条 `isError` 的结果继续跑。模型自己会换个问法。
/// 2. 模型失败 → 按 `ModelFailure` 分类。拥塞和网络抖动退避重试;上下文超限压缩后重跑
///    这一轮;鉴权、额度这些确定性的错误立刻上报,重试只是把同一句话说三遍。
/// 3. 都救不回来 → 抛出去。这时用户看到的是原因,不是一个转圈。
public struct AgentLoop: Sendable {
    public var client: any AgentModelClient
    public var capabilities: CapabilityRegistry
    public var systemInstruction: String
    public var compactor: TranscriptCompactor
    /// 谁来写整段摘要。给 nil 就退回纯机械压缩(还能跑,只是省不了那么多)。
    public var summarizer: (any AgentSummarizer)?
    public var migrationPolicy: HistoryMigrationPolicy
    public var policy: ContextPolicy
    public var retryPolicy: RetryPolicy
    public var maxToolRounds: Int
    /// 用户在这一轮跑的过程中补的话从哪儿来。给 nil 就是老行为:一轮里只有开头那一句。
    ///
    /// 只在**工具轮边界**问,不在流中途问。中途打断要撤掉已经吐出去的半句(用户正读着的
    /// 那段字会当场消失),还得把刚花掉的那次生成整个扔了;而边界处什么都不用撤,模型
    /// 下一句就能改道。真要立刻停下,用户手上一直有停止按钮。
    public var pendingInput: AgentPendingInputProvider?
    /// 模型在吐 tool_use 的中途被输出上限截断时,顶替执行结果的那句话。
    ///
    /// 这句是给模型看的,所以要写清楚「没执行」和「该怎么办」——它读完得知道重发一次,
    /// 而不是以为工具坏了。
    public var truncatedToolCallNotice: String
    /// 生命周期上的旁观者。给 nil 就一次派发都不发生,和没有这套东西时一样贵。
    ///
    /// 宿主由 app 持有(见 `AgentHookDispatcher`):hook 跨轮有状态,而 loop 每次回复现造。
    public var hooks: AgentHookDispatcher?

    public init(
        client: any AgentModelClient,
        capabilities: CapabilityRegistry,
        systemInstruction: String,
        compactor: TranscriptCompactor = .default,
        summarizer: (any AgentSummarizer)? = nil,
        migrationPolicy: HistoryMigrationPolicy = .whenWindowShrinks,
        policy: ContextPolicy = .default,
        retryPolicy: RetryPolicy = .default,
        maxToolRounds: Int = 6,
        pendingInput: AgentPendingInputProvider? = nil,
        truncatedToolCallNotice: String = """
            This tool call was not executed: the response hit the output token limit, so its \
            arguments may be incomplete. Re-issue it with complete arguments.
            """,
        hooks: AgentHookDispatcher? = nil
    ) {
        self.client = client
        self.capabilities = capabilities
        self.systemInstruction = systemInstruction
        self.compactor = compactor
        self.summarizer = summarizer
        self.migrationPolicy = migrationPolicy
        self.policy = policy
        self.retryPolicy = retryPolicy
        self.maxToolRounds = maxToolRounds
        self.pendingInput = pendingInput
        self.truncatedToolCallNotice = truncatedToolCallNotice
        self.hooks = hooks
    }

    /// 工具轮数用光时写进 finish reason 的记号。
    ///
    /// 用光轮数不是错误:该查的多半已经查到了,把已经拿到的东西全部丢掉去报一个「查询次数
    /// 过多」,对用户来说是净损失。这一轮照常收尾,记号留给 app 决定要不要提示。
    public static let toolRoundLimitReason = "tool-round-limit"

    public func run(history: [AgentChatMessageDTO]) -> AsyncThrowingStream<AgentTurnEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await execute(history: history, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 留给窗口大小未知的 provider:按窗口的十分之一预留输出,夹在 1k–16k 之间,再被窗口的
    /// 四分之一和模型自己的输出上限各压一道。
    ///
    /// 上限从 4k 提到 16k 是有原因的:20 万窗口只留 4k 给输出,意味着可以把 19.6 万塞满,
    /// 然后模型没地方说话——尤其是带 reasoning 的模型,思考本身就要烧掉几千。
    /// 小窗口那边由 `window / 4` 兜着,不会出现「预留比历史还多」。
    public static func reservedOutputTokens(for profile: AgentModelProfile) -> Int? {
        guard let window = profile.contextWindow else { return nil }
        let heuristic = min(max(window / 10, 1_024), 16_384)
        let capped = min(heuristic, max(1, window / 4))
        guard let limit = profile.maxOutputTokens, limit > 0 else { return capped }
        return max(256, min(capped, limit))
    }
}

private extension AgentLoop {
    /// 这一次尝试已经吐出去多少字。重跑之前要按它把半截话撤回来。
    ///
    /// 正文和思考分开记:它们存在两个地方,撤的时候不能拿一个数去减另一个。
    struct EmittedCharacters {
        var text = 0
        var reasoning = 0
    }

    /// 一轮请求的结果。失败也是一种结果——连同已经吐出去的量一起带回来。
    enum RoundOutcome {
        case completed(AgentModelResponse)
        case failed(any Error, emitted: EmittedCharacters)
    }

    /// 这一轮到目前为止攒下来的东西。
    ///
    /// 单独拎出来是为了让**失败和取消也有一份**:被停掉的那一轮同样说过几句话、查过几次
    /// 数据,hook 那条 `turnFinished` 得把它们带上,而不是交一份空的。
    struct TurnProgress {
        var transcript = AgentTranscript()
        var usage: AgentUsage?
        var snapshot: TurnContextSnapshotDTO?
    }

    func execute(
        history: [AgentChatMessageDTO],
        continuation: AsyncThrowingStream<AgentTurnEvent, any Error>.Continuation
    ) async throws {
        guard let hooks else {
            var progress = TurnProgress()
            try await runRounds(history: history, progress: &progress, continuation: continuation)
            return
        }

        let turnId = UUID()
        await hooks.post(.init(turnId: turnId, kind: .turnStarted(.init(
            history: history,
            profile: client.profile
        ))))

        var progress = TurnProgress()
        do {
            try await runRounds(
                history: history,
                progress: &progress,
                turnId: turnId,
                continuation: continuation
            )
        } catch {
            // 出口只有这一个:救不回来的错误和用户按停止都走这儿。少一条出口,hook 就得靠
            // 超时去猜自己在等的那一轮是不是已经不会来了。
            await hooks.post(.init(turnId: turnId, kind: .turnFinished(.init(
                state: error is CancellationError ? .stopped : .failed(Self.describe(error)),
                transcript: progress.transcript,
                usage: progress.usage,
                context: progress.snapshot
            ))))
            throw error
        }
    }

    func runRounds(
        history: [AgentChatMessageDTO],
        progress: inout TurnProgress,
        turnId: UUID? = nil,
        continuation: AsyncThrowingStream<AgentTurnEvent, any Error>.Continuation
    ) async throws {
        let profile = client.profile
        let definitions = capabilities.definitions
        let reserved = Self.reservedOutputTokens(for: profile)

        var calibration = ContextCalibration(history: history, profile: profile)
        // 本轮用的历史。整段摘要生成后就地写进去,同时通过事件让 app 存下来。
        var history = history
        // 一轮里最多总结一次。工具轮之间再压也只能压历史,压不动这一轮刚拿到的大结果,
        // 白花调用。溢出恢复会把它放开一次——那时候是 provider 说了算,不是水位线。
        var didSummarize = false
        var overflowRecoveryUsed = false
        var isRecoveringFromOverflow = false
        var attempt = 0
        var round = 0

        while round < maxToolRounds {
            try Task.checkCancellation()

            // 用户在上一次请求跑的时候补的话,在这儿接进来。
            //
            // 排在总结前面:这几句也要占预算,压缩得按包含它们的那份 prompt 来算。接在
            // `runtimeTranscript` 尾部而不是 `history` 里,因为它到得比这一轮已经发生的
            // 工具调用还晚——放进 history 会让模型看成「他先追问、我才去查」,而实际顺序
            // 正相反。
            if let pendingInput {
                let pending = await pendingInput()
                if !pending.isEmpty {
                    progress.transcript.messages.append(contentsOf: pending.map { .user($0.text) })
                    continuation.yield(.pendingInputAccepted(pending))
                }
            }

            // 过了水位线就叫模型把远处的对话总结掉,再去发这一轮。
            // 放在发请求之前,而不是撞墙之后——撞墙时已经没有从容处理的余地了。
            if !didSummarize, let compacted = try await summarize(
                history: history,
                runtimeTranscript: progress.transcript,
                profile: profile,
                definitions: definitions,
                reserved: reserved,
                calibrationScale: calibration.scale,
                isRecoveringFromOverflow: isRecoveringFromOverflow,
                continuation: continuation
            ) {
                didSummarize = true
                if let index = history.firstIndex(where: { $0.id == compacted.messageID }) {
                    history[index].storedTurn.compaction = compacted.artifact
                }
                continuation.yield(.historyCompacted(
                    messageID: compacted.messageID,
                    artifact: compacted.artifact
                ))
            }

            let prepared = plan(
                history: history,
                runtimeTranscript: progress.transcript,
                profile: profile,
                definitions: definitions,
                reserved: reserved,
                calibrationScale: calibration.scale,
                isRecoveringFromOverflow: isRecoveringFromOverflow
            )
            guard !prepared.exceedsBudget else {
                throw AgentLoopError.contextWindowExceeded
            }

            let request = AgentModelRequest(
                profile: profile,
                prompt: prepared.prompt,
                capabilities: definitions
            )

            let response: AgentModelResponse
            switch await streamRound(request, continuation: continuation) {
            case .completed(let completed):
                response = completed
            case .failed(let error, let emitted):
                if error is CancellationError { throw error }
                try Task.checkCancellation()
                let description = Self.describe(error)

                // 上下文超限走压缩,不走重试:原样再发一次还是塞不下。
                if ModelFailure.isContextOverflow(description) {
                    // 压过一次还是超,那就是真的放不下了。把它交给上层,而不是把 provider 那句
                    // "prompt is too long: 210000 tokens" 甩给用户——一条永远的对话里没有「开新对话」
                    // 可劝,聊天层会把窗口砍到最近两轮再跑一次,砍不动才报出来。
                    //
                    // 不知道上下文多大时,这一层的恢复是空转:没有预算就没有水位线,规划器和摘要
                    // 都无从压起,重发的是同一份 prompt——白花一次整轮的钱再撞一次墙。直接交给上层。
                    guard !overflowRecoveryUsed, profile.contextWindow != nil else {
                        throw AgentLoopError.contextWindowExceeded
                    }
                    overflowRecoveryUsed = true
                    isRecoveringFromOverflow = true
                    // provider 说装不下,那就是我们估小了。信 provider 的,把尺子放大,
                    // 让这一轮和后面几轮都压得更狠。
                    calibration.inflate(by: 1.25)
                    didSummarize = false
                    rollBack(emitted, continuation: continuation)
                    continue
                }

                guard retryPolicy.allowsRetry(attempt: attempt + 1),
                      ModelFailure.isRetryable(error, description: description) else {
                    throw error
                }
                attempt += 1
                let delay = retryPolicy.delay(forAttempt: attempt)
                rollBack(emitted, continuation: continuation)
                continuation.yield(.retryScheduled(.init(
                    attempt: attempt,
                    maxAttempts: retryPolicy.maxRetries,
                    delay: delay,
                    reason: description
                )))
                try await Task.sleep(for: delay)
                continue
            }

            attempt = 0
            isRecoveringFromOverflow = false

            if let assistant = response.assistantMessage, !assistant.parts.isEmpty {
                progress.transcript.messages.append(assistant)
            }

            calibration.note(
                actual: response.usage?.inputTokens.total,
                estimated: prepared.estimatedPromptTokens
            )
            let snapshot = prepared.snapshot(
                servedModelId: response.servedModelId,
                actualPromptTokens: response.usage?.inputTokens.total
            )
            progress.usage = response.usage
            progress.snapshot = snapshot

            guard !response.pendingCalls.isEmpty else {
                continuation.yield(.turnCompleted(
                    transcript: progress.transcript,
                    finishReason: response.finishReason,
                    usage: response.usage,
                    context: snapshot
                ))
                await finish(
                    turnId,
                    state: .completed,
                    progress: progress,
                    finishReason: response.finishReason
                )
                return
            }

            // 被输出上限截断的那一轮,每个 tool_use 的参数都可能是半截的——JSON 抢救出来
            // 能解析不代表它完整。一个都不执行,原样报回去让模型重发,比执行一次错的查询
            // 再让用户看着不对劲的数字强。
            let wasTruncated = response.finishReason?.unified == .length

            for call in response.pendingCalls {
                try Task.checkCancellation()
                continuation.yield(.toolCallStarted(.init(
                    id: call.toolCallId,
                    name: call.name,
                    input: call.input
                )))

                let startedAt = ContinuousClock.now
                let result = wasTruncated
                    ? CapabilityExecutionResult(
                        output: .init(kind: .text, text: truncatedToolCallNotice),
                        isError: true
                    )
                    : await execute(call)

                continuation.yield(.toolCallFinished(
                    id: call.toolCallId,
                    output: result.output,
                    isError: result.isError
                ))
                progress.transcript.messages.append(.toolResult(
                    toolCallId: call.toolCallId,
                    toolName: call.name,
                    result: .string(result.output.text),
                    isError: result.isError
                ))
                if let turnId, let hooks {
                    await hooks.post(.init(turnId: turnId, kind: .toolFinished(.init(
                        toolCallId: call.toolCallId,
                        name: call.name,
                        isError: result.isError,
                        outputCharacters: result.output.text.count,
                        duration: ContinuousClock.now - startedAt
                    ))))
                }
            }

            round += 1
        }

        // 轮数用光。已经查到的东西照常交出去——丢掉它们去报一个错,对用户是净损失。
        let limitReason = AgentFinishReason(unified: .other, raw: Self.toolRoundLimitReason)
        continuation.yield(.turnCompleted(
            transcript: progress.transcript,
            finishReason: limitReason,
            usage: progress.usage,
            context: progress.snapshot
        ))
        // 轮数用光对 hook 也**不是**失败,和答完走同一个 state:该查的多半已经查到了。要区分
        // 的看 `finishReason.raw`。
        await finish(turnId, state: .completed, progress: progress, finishReason: limitReason)
    }

    /// 这一轮的收尾通知。`turnId` 为 nil 就是没挂 hook,一次派发都不发生。
    func finish(
        _ turnId: UUID?,
        state: AgentHookTurnOutcome.State,
        progress: TurnProgress,
        finishReason: AgentFinishReason?
    ) async {
        guard let turnId, let hooks else { return }
        await hooks.post(.init(turnId: turnId, kind: .turnFinished(.init(
            state: state,
            transcript: progress.transcript,
            finishReason: finishReason,
            usage: progress.usage,
            context: progress.snapshot
        ))))
    }

    /// 跑一次能力,并把进上下文的那段输出截到预算之内。
    func execute(_ call: CapabilityInvocation) async -> CapabilityExecutionResult {
        var result = await capabilities.execute(call)
        result.output = result.output.limited(
            to: policy.maxToolOutputCharacters,
            notice: policy.toolOutputTruncationNotice
        )
        return result
    }

    /// 流式跑一轮,顺带把 provider 报的错折成 `AgentLoopError`。
    ///
    /// 不抛错而是返回 `RoundOutcome`:调用方要按「已经吐了多少字」来撤回半截话,而这个数
    /// 只有这里知道。
    /// 把这一次尝试吐出去的东西撤回来。重跑会从头再说一遍,不撤就是半句接整句。
    func rollBack(
        _ emitted: EmittedCharacters,
        continuation: AsyncThrowingStream<AgentTurnEvent, any Error>.Continuation
    ) {
        if emitted.text > 0 {
            continuation.yield(.textRolledBack(characterCount: emitted.text))
        }
        if emitted.reasoning > 0 {
            continuation.yield(.reasoningRolledBack(characterCount: emitted.reasoning))
        }
    }

    func streamRound(
        _ request: AgentModelRequest,
        continuation: AsyncThrowingStream<AgentTurnEvent, any Error>.Continuation
    ) async -> RoundOutcome {
        var emitted = EmittedCharacters()
        do {
            var response: AgentModelResponse?
            for try await event in try client.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    guard !delta.isEmpty else { continue }
                    emitted.text += delta.count
                    continuation.yield(.textDelta(delta))
                case .reasoningDelta(let delta):
                    guard !delta.isEmpty else { continue }
                    emitted.reasoning += delta.count
                    continuation.yield(.reasoningDelta(delta))
                case .completed(let completed):
                    response = completed
                }
            }

            guard let response else {
                return .failed(AgentLoopError.incompleteResponse, emitted: emitted)
            }
            if let failure = validate(response) {
                return .failed(failure, emitted: emitted)
            }
            return .completed(response)
        } catch {
            return .failed(error, emitted: emitted)
        }
    }

    /// 跨过水位线就叫 summarizer 写一份整段摘要。
    ///
    /// 失败不上抛:总结只是省 token 的手段,它挂了应该退回机械压缩,而不是让用户这一句
    /// 问不出去。但要留下一个事件——静默降级等于线上出问题时无从查起。
    func summarize(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript,
        profile: AgentModelProfile,
        definitions: [CapabilityDefinition],
        reserved: Int?,
        calibrationScale: Double?,
        isRecoveringFromOverflow: Bool,
        continuation: AsyncThrowingStream<AgentTurnEvent, any Error>.Continuation
    ) async throws -> (messageID: UUID, artifact: CompactionArtifact)? {
        guard let summarizer else { return nil }
        let planner = makePlanner(
            profile: profile,
            definitions: definitions,
            reserved: reserved,
            calibrationScale: calibrationScale,
            isRecoveringFromOverflow: isRecoveringFromOverflow
        )
        guard let plan = planner.summarizationPlan(
            history: history,
            runtimeTranscript: runtimeTranscript,
            force: isRecoveringFromOverflow
        ) else {
            return nil
        }

        let reason: AgentCompactionReason = isRecoveringFromOverflow ? .overflowRecovery : .threshold
        continuation.yield(.compactionStarted(reason))
        do {
            return (plan.ownerMessageID, try await summarizer.summarize(plan))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            continuation.yield(.compactionFailed(
                reason: reason,
                message: Self.describe(error)
            ))
            return nil
        }
    }

    func plan(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript,
        profile: AgentModelProfile,
        definitions: [CapabilityDefinition],
        reserved: Int?,
        calibrationScale: Double?,
        isRecoveringFromOverflow: Bool
    ) -> ConversationHistoryPlanner.PreparedHistory {
        makePlanner(
            profile: profile,
            definitions: definitions,
            reserved: reserved,
            calibrationScale: calibrationScale,
            isRecoveringFromOverflow: isRecoveringFromOverflow
        ).prepare(history: history, runtimeTranscript: runtimeTranscript)
    }

    func makePlanner(
        profile: AgentModelProfile,
        definitions: [CapabilityDefinition],
        reserved: Int?,
        calibrationScale: Double?,
        isRecoveringFromOverflow: Bool
    ) -> ConversationHistoryPlanner {
        let client = client
        let calibration = ContextCalibration(scale: calibrationScale)
        return ConversationHistoryPlanner(
            systemInstruction: systemInstruction,
            profile: profile,
            reservedOutputTokens: reserved,
            compactor: compactor,
            migrationPolicy: migrationPolicy,
            policy: policy,
            isRecoveringFromOverflow: isRecoveringFromOverflow,
            // 逐条计价用不带工具的那份:工具 schema 每次请求只算一遍,不该跟着每条消息
            // 重新序列化。
            estimateMessageTokens: { transcript in
                calibration.apply(to: client.estimateTokens(for: AgentModelRequest(
                    profile: profile,
                    prompt: transcript,
                    capabilities: []
                )))
            }
        ) { transcript in
            calibration.apply(to: client.estimateTokens(for: AgentModelRequest(
                profile: profile,
                prompt: transcript,
                capabilities: definitions
            )))
        }
    }

    /// 这一轮算不算失败。算的话返回该报的错——注意 `.length` + 工具调用不在这里,
    /// 那一档是可以自愈的,由主流程降级成一条 error 结果。
    func validate(_ response: AgentModelResponse) -> (any Error)? {
        if let failure = response.failureMessage {
            return AgentLoopError.service(failure)
        }
        guard let reason = response.finishReason else {
            return AgentLoopError.incompleteResponse
        }
        switch reason.unified {
        case .error:
            return AgentLoopError.service(reason.raw ?? "model execution failed")
        case .contentFilter:
            return AgentLoopError.contentFilter
        default:
            return nil
        }
    }

    /// 拿去给分类器看的那段字符串。
    ///
    /// provider 的原文最有信息量,所以 `.service` 直接透出原文。其余几个是 runtime 自己造的
    /// 错误,翻成分类器认得的英文描述——它只会看字符串,不认识 Swift 类型。
    static func describe(_ error: any Error) -> String {
        switch error {
        case let loopError as AgentLoopError:
            switch loopError {
            case .service(let message): return message
            case .contentFilter: return "content filter"
            case .incompleteResponse: return "stream ended without a finish reason"
            case .contextWindowExceeded: return "context window exceeded"
            }
        default:
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
