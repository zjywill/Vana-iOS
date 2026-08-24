import Foundation
import Testing
import AIKit
import AgentRuntime

@testable import Vana

/// 「这台设备配好没有」那一套。盯的是 2026-08-19 那次审核撞上的那条缝:**显示的那份默认值
/// 和发请求时读的那份不是同一份**——设置页照着 `@AppStorage` 的默认值写着「DeepSeek V4
/// Flash」,而 `string(forKey:)` 那一侧读到的是 nil,于是一发消息就是「需要先在设置里选择
/// 云端模型」,屏幕上却没有一处能让他把这个已经选好的模型再选一遍。
///
/// 全部走自己的 `UserDefaults` suite:`UserDefaults.standard` 在 app host 里就是模拟器上
/// 那份真的设置,测试改它等于把开发机上配好的 provider 和模型冲掉(同 `MemoryStore.shared`
/// 那条)。
@Suite("Cloud setup")
struct CloudSetupTests {

    @Test("iOS reads the synced DeepSeek catalog through AIKit")
    func readsSyncedProviderCatalog() throws {
        let model = try #require(
            ProviderCatalog.model("deepseek-v4-flash-vision-exp", provider: "deepseek")?.1
        )

        #expect(model.supportsVision)
        #expect(ProviderCatalog.provider("grok-build") == nil)
    }

    @Test("Google Gemini is a selectable hosted provider")
    func exposesGoogleGeminiProvider() throws {
        let google = try #require(CloudCatalog.provider("google"))
        let model = try #require(
            CloudCatalog.models(for: google.id).first { $0.id == "gemini-3.5-flash" }
        )

        #expect(google.wireProtocol == .googleGenerativeAI)
        #expect(google.api == "https://generativelanguage.googleapis.com")
        #expect(model.supportsTools)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "CloudSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("全新安装:默认 provider 和模型是真的存下来的,不是只显示一下")
    func seedsDefaultsOnFreshInstall() {
        let defaults = freshDefaults()
        #expect(defaults.string(forKey: EngineSettings.modelKey) == nil)

        let selection = EngineSettings.selection(from: defaults)

        #expect(selection.provider == EngineSettings.defaultProvider)
        #expect(selection.model == EngineSettings.defaultModel)
        // 关键的一条:落盘了。设置页那一行读的就是这个值,两边从此是同一份。
        #expect(defaults.string(forKey: EngineSettings.modelKey) == EngineSettings.defaultModel)
        #expect(defaults.string(forKey: EngineSettings.providerKey) == EngineSettings.defaultProvider)
    }

    @Test("存过的那份一个字不动")
    func keepsWhatTheUserPicked() {
        let defaults = freshDefaults()
        defaults.set("anthropic", forKey: EngineSettings.providerKey)
        defaults.set("claude-sonnet-5", forKey: EngineSettings.modelKey)

        let selection = EngineSettings.selection(from: defaults)

        #expect(selection.provider == "anthropic")
        #expect(selection.model == "claude-sonnet-5")
    }

    /// 换到一个目录里没有内置模型的 provider 时,设置页会把模型清成空串。这时候拿
    /// DeepSeek 的模型名去顶,就是拿这把钥匙去敲另一家的门——那正是 2026-08-16 被拒的那次。
    @Test("用户自己清空的模型不拿默认值顶上")
    func doesNotBackfillAnExplicitlyClearedModel() {
        let defaults = freshDefaults()
        defaults.set("openrouter", forKey: EngineSettings.providerKey)
        defaults.set("", forKey: EngineSettings.modelKey)

        let selection = EngineSettings.selection(from: defaults)

        #expect(selection.provider == "openrouter")
        #expect(selection.model.isEmpty, "空模型要一路走到「去设置」那颗按钮，不能被悄悄填上")
    }

    @Test("补种子是幂等的")
    func seedingIsIdempotent() {
        let defaults = freshDefaults()
        EngineSettings.seedDefaultsIfNeeded(defaults)
        defaults.set("deepseek-reasoner", forKey: EngineSettings.modelKey)
        EngineSettings.seedDefaultsIfNeeded(defaults)

        #expect(defaults.string(forKey: EngineSettings.modelKey) == "deepseek-reasoner")
    }

    // MARK: - 报错气泡底下那颗按钮

    /// key 没通过验证的时候按「重试」,发出去的还是同一句话——审核员按了两次,屏幕上就是
    /// 两条一模一样的报错,而他要去的地方是设置页。
    ///
    /// 跑的是真的一轮(假模型按 401 收场),不是手搭一条消息:那颗按钮认的是
    /// `errorDescription`,而那句话是 `userFacingFailure` 翻出来的——两头各写一份的话,
    /// 翻译改一个字这颗按钮就悄悄变回「重试」。
    @MainActor
    @Test("key 没通过验证时那颗按钮是「去设置」,不是「重试」")
    func offersSetupWhenTheKeyIsRejected() async throws {
        let model = try await failedReply(
            "Error code: 401 - {'error': {'message': 'Incorrect API key provided'}}"
        )
        let failed = try #require(model.messages.last)
        #expect(failed.errorDescription == ChatViewModel.authFailureGuidance)
        #expect(model.recovery(for: failed.id) == .openSetup)
    }

    /// 反过来,一次说不清所以然的失败是真的可以重试的。两种失败给同一颗按钮,等于两种
    /// 各答错一半。
    @MainActor
    @Test("认不出所以然的失败照旧给「重试」")
    func keepsRetryForOtherFailures() async throws {
        let model = try await failedReply("模型返回了一个我们不认识的结果")
        let failed = try #require(model.messages.last)
        #expect(model.recovery(for: failed.id) == .retry)
    }

    /// 注入了引擎就是「这台设备配得齐」的那一档,不去读钥匙串——app host 里那份钥匙串是
    /// 开发机上真的那把 key,信它的话这两条用例在别人机器上就是另一个结果。
    @MainActor
    private func failedReply(_ providerMessage: String) async throws -> ChatViewModel {
        let client = ScriptedModelClient(
            profile: AgentModelProfile(
                providerId: "deepseek",
                modelId: "deepseek-v4-flash",
                contextWindow: 20_000,
                maxOutputTokens: 4_000
            ),
            turns: [.init(finishReason: .init(unified: .error), failureMessage: providerMessage)]
        )
        let model = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedSession: false
        )
        model.send("昨晚睡得怎么样？")
        try await waitUntil("这轮以失败收场") { !model.isReplying }
        return model
    }
}
