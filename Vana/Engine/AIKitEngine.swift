import Foundation
import AgentRuntime
import AIKit

/// AIKit 在 runtime 眼里的样子。
///
/// 这是 app 里唯一还认识 AIKit 的执行路径:token 怎么估、流怎么拆、一轮结束时拿到什么,
/// 都收在这儿。`AgentLoop` 只看得见 `AgentModelClient`,换 SDK 时不用动 loop。
struct AIKitModelClient: AgentModelClient {
    let profile: AgentModelProfile

    private let client: AIClient
    private let reporter = ContextReporter()
    /// 思考开关。nil 表示这个模型压根没有思考这回事,那就什么都别说。
    ///
    /// 「什么都不说」不等于「不思考」——DeepSeek、Qwen、GLM 默认就是开的,想关必须显式说。
    /// 反过来也一样要小心:对着一个不会思考的模型发 `thinking: {type: enabled}`,
    /// 有些 provider 直接 400。所以只在目录说这个模型支持思考时才发。
    private let thinking: Thinking?

    init(providerId: String, modelId: String, apiKey: String, thinking: Thinking = .on) throws {
        let info = ProviderCatalog.model(modelId, provider: providerId)?.1
        // 目录里没有的模型(自建 endpoint、比目录新)也按"不会思考"处理:发一个它没听过的
        // 字段,比少发一个字段的后果严重得多。
        self.thinking = (info?.supportsReasoning ?? false) ? thinking : nil
        profile = AgentModelProfile(
            providerId: providerId,
            modelId: modelId,
            contextWindow: info?.contextWindow,
            maxOutputTokens: info?.maxOutputTokens
        )
        client = try AIClient(
            providerId: providerId,
            configuration: .init(apiKey: apiKey)
        )
    }

    /// 一张随行原图按多少 token 算。
    ///
    /// AIKit 的估算器对 base64 的 file part 只记一点框架开销,而且**这是对的**——provider
    /// 按尺寸或页数计价,base64 的长度说明不了任何事。但这个 app 的图不是任意尺寸:
    /// `AttachmentImage.maxPixelSize` 把长边压到 1600,最坏是一张 1600×1600。按 Anthropic
    /// 那个 `宽×高/750` 的口径,那就是 3413。
    ///
    /// 取整到 3400 并且**故意往大了算**:估小了的后果是一次撞墙(provider 直接拒收,
    /// 然后走强制总结重跑那条路),估大了只是早一点开始压缩。何况一句话最多带六件,
    /// 六张全带图也就两万——在这些看得了图的模型上都是小头。
    static let tokensPerImage = 3_400

    func estimateTokens(for request: AgentModelRequest) -> Int {
        let text = reporter.report(callOptions(for: request), contextWindow: profile.contextWindow).used
        return text + Self.tokensPerImage * Self.imageCount(in: request.prompt)
    }

    private static func imageCount(in prompt: AgentTranscript) -> Int {
        prompt.messages.reduce(0) { total, message in
            total + message.parts.count { part in
                if case .file(let file) = part { return file.mediaType.hasPrefix("image/") }
                return false
            }
        }
    }

    func stream(_ request: AgentModelRequest) throws -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        let parts = try client.stream(callOptions(for: request))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var collected: [StreamPart] = []
                    for try await part in parts {
                        try Task.checkCancellation()
                        collected.append(part)
                        switch part {
                        case .textDelta(_, let delta, _) where !delta.isEmpty:
                            continuation.yield(.textDelta(delta))
                        case .reasoningDelta(_, let delta, _) where !delta.isEmpty:
                            continuation.yield(.reasoningDelta(delta))
                        default:
                            break
                        }
                    }
                    continuation.yield(.completed(AIResponse(parts: collected).agentModelResponse))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func callOptions(for request: AgentModelRequest) -> CallOptions {
        CallOptions(
            model: request.profile.modelId,
            prompt: request.prompt.aiKitPrompt,
            tools: request.capabilities.map(\.aiKitToolDefinition),
            thinking: thinking
        )
    }
}

/// 云端引擎。
///
/// 到这一步它只剩三件 app 自己的事:拿 key、按插件拼系统提示、把 runtime 的错误翻成中文。
/// 工具循环、上下文预算、压缩、换模型迁移全在 `AgentLoop` 里;挂哪些工具、system 段发哪几块
/// 全由插件决定(`PluginHost.assemble`)——引擎一个领域都不认识。
struct AIKitEngine: AgentEngine {
    let name = "云端模型"

    /// 这一轮真正要跑的那个模型收不收得了图。目录里查不到的(自建 endpoint、比目录新)
    /// 按收不了算:多带一张图是一个 400,少带一张最多是用户接着用文字描述。
    var supportsVision: Bool {
        ProviderCatalog.model(model, provider: providerId)?.1.supportsVision ?? false
    }

    private static let maxToolRounds = 6

    private let providerId: String
    private let model: String
    private let plugins: [any AgentPlugin]
    private let pluginContext: PluginContext
    /// 思考开关。nil 就跟着设置走;后台那几轮显式传 false(辅助调用的规矩)。
    private let thinking: Bool?
    /// 生命周期上的旁观者。引擎每轮现造,而 hook 跨轮有状态,所以宿主由 app 传进来,
    /// 不在这儿造(见 `AgentHookDispatcher`)。
    ///
    /// 后台那几轮默认不挂:没有用户在场,答完之后要生成的那点东西没人会看。
    private let hooks: AgentHookDispatcher?

    init(
        providerId: String = "anthropic",
        model: String = "claude-sonnet-5",
        plugins: [any AgentPlugin] = [],
        pluginContext: PluginContext = PluginContext(),
        thinking: Bool? = nil,
        hooks: AgentHookDispatcher? = nil
    ) {
        self.providerId = providerId
        self.model = model
        self.plugins = plugins
        self.pluginContext = pluginContext
        self.thinking = thinking
        self.hooks = hooks
    }

    /// 按一份装配环境造。前台、后台、测试都走这一条,不各拼一遍插件。
    init(
        providerId: String = "anthropic",
        model: String = "claude-sonnet-5",
        environment: PluginEnvironment,
        route: PluginRoute = .foreground,
        isPrivate: Bool = false,
        thinking: Bool? = nil,
        hooks: AgentHookDispatcher? = nil
    ) {
        self.init(
            providerId: providerId,
            model: model,
            plugins: PluginRegistry.agentPlugins(environment, route: route),
            pluginContext: PluginRegistry.context(for: environment, route: route, isPrivate: isPrivate),
            thinking: thinking,
            hooks: hooks
        )
    }

    /// 这一轮挂出去的工具和发出去的 system 段。**同一次装配**:工具说明照着真的挂出去的工具拼,
    /// 拼两次的话两边可能对不上。
    func assembly(acceptsInterjections: Bool = false) -> PluginAssembly {
        PluginHost.assemble(plugins, context: pluginContext, coreBlocks: coreBlocks(acceptsInterjections: acceptsInterjections))
    }

    var capabilityRegistry: CapabilityRegistry { assembly().registry }

    /// system 段加工具定义占的位子。工具的参数说明按**发出去的 JSON** 算。当前全开时这份开销
    /// 大约七八千 token,所以 32k 上下文的模型窗口基本就是保底的 6 轮。
    func requestOverheadTokens() -> Int {
        let assembly = assembly(acceptsInterjections: true)
        return TokenEstimate.text(assembly.instruction())
            + assembly.registry.definitions.reduce(0) { $0 + TokenEstimate.definition($1) }
    }

    /// 核心那几块:身份与规则、插话、人格(静态区),今天(易变区)。
    private func coreBlocks(acceptsInterjections: Bool) -> [PromptBlock] {
        var blocks = [
            PromptBlock(order: PromptOrder.base, text: CoreInstructions.text()),
            PromptBlock(order: PromptOrder.today, text: CoreInstructions.today())
        ]
        // 后台那几轮没有用户在场,那段话对它们只是白占 token。
        if acceptsInterjections {
            blocks.append(PromptBlock(order: PromptOrder.interjection, text: CoreInstructions.interjection))
        }
        let persona = EngineSettings.persona.instruction
        if !persona.isEmpty {
            blocks.append(PromptBlock(order: PromptOrder.persona, text: persona))
        }
        return blocks
    }

    func reply(
        to history: [ChatMessage],
        pendingInput: AgentPendingInputProvider? = nil
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let assembly = assembly(acceptsInterjections: pendingInput != nil)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try AIKitModelClient(
                        providerId: providerId,
                        modelId: model,
                        apiKey: try resolvedAPIKey(),
                        thinking: (thinking ?? EngineSettings.thinkingEnabled) ? .on : .off
                    )
                    let loop = AgentLoop(
                        client: client,
                        capabilities: assembly.registry,
                        systemInstruction: assembly.instruction(),
                        compactor: .vana,
                        // **聊天路径不主动摘要**:历史 = 窗口 + 记忆 + 可检索的档案。递归摘要会漂
                        // (摘要的摘要把最早的细节磨平),还多花一路钱;窗口之外的原文逐字留在档案里,
                        // 要用就检索。撞上上限时由 `ChatViewModel` 强制淘汰到最近两轮再跑。
                        summarizer: nil,
                        policy: .vana,
                        maxToolRounds: Self.maxToolRounds,
                        pendingInput: pendingInput,
                        truncatedToolCallNotice: truncatedToolCallNotice,
                        hooks: hooks
                    )
                    // 隔得久的补时间标记,主动消息折进下一条用户消息开头(`HistoryMarkers`)。
                    for try await event in loop.run(history: HistoryMarkers.apply(history)) {
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

    private func resolvedAPIKey() throws -> String {
        guard let stored = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }
        return key
    }

    /// 不是 private:记忆有没有真的进到 system 段,得有测试盯着。
    ///
    /// - Parameter acceptsInterjections: 这一轮有可能被用户中途插话(前台对话都是)。
    func systemInstruction(acceptsInterjections: Bool = false) -> String {
        assembly(acceptsInterjections: acceptsInterjections).instruction()
    }
}
