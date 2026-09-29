import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 到期的「说好回头看的事」自己先跑一轮。
///
/// 这里盯的主要是**闸**:这一轮是用户不在场时花的钱,跑错了他事后才看得到账单。所以
/// 「什么时候不跑」比「跑出来什么」更要紧。跑成了之后的形状也要盯:结论落成对话末尾的一条
/// 主动消息,「跑过没有」记在线程 meta 里,不再是一个另存的会话文件。
@Suite("FollowUpRunner", .serialized)
struct FollowUpRunnerTests {

    private static func freshDirectory() -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func freshMemory() -> MemoryStore { MemoryStore(directory: freshDirectory()) }
    private static func freshThread() -> ThreadStore { ThreadStore(directory: freshDirectory()) }

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 200_000,
        maxOutputTokens: 8_000
    )

    // MARK: - 闸

    @Test("an incomplete cloud setup means no background spend")
    func incompleteSetupMeansNoRun() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey)
        // 云端要齐 key 和 model 才发得出去。把 model 拿掉是同一道闸的另一半,改完能原样放回去。
        let defaults = UserDefaults.standard
        let savedModel = defaults.string(forKey: EngineSettings.modelKey)
        defaults.set("", forKey: EngineSettings.modelKey)
        defer { defaults.set(savedModel, forKey: EngineSettings.modelKey) }

        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: Date().addingTimeInterval(-60))
        let thread = Self.freshThread()

        #expect(await BackgroundDigest.runIfDue(memoryStore: memory, thread: thread) == false)
        #expect(await thread.loadTail().messages.isEmpty)
    }

    @Test("check-ins off means the conclusion has nowhere to go, so it is not computed")
    func checkInsOffMeansNoRun() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        UserDefaults.standard.set(false, forKey: EngineSettings.checkInsEnabledKey)
        defer { UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey) }

        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: Date().addingTimeInterval(-60))
        let thread = Self.freshThread()

        #expect(await BackgroundDigest.runIfDue(memoryStore: memory, thread: thread) == false)
        #expect(await thread.loadTail().messages.isEmpty)
    }

    @Test("memory off means there are no follow-ups at all")
    func memoryOffMeansNoPending() async throws {
        UserDefaults.standard.set(false, forKey: EngineSettings.memoryEnabledKey)
        defer { UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey) }

        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: Date().addingTimeInterval(-60))
        #expect(await FollowUpRunner.pending(now: Date(), memoryStore: memory, thread: Self.freshThread()) == nil)
    }

    @Test("a follow-up already run today is not picked again")
    func alreadyRunTodayIsSkipped() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        let now = Date()
        let memory = Self.freshMemory()
        let followUp = try #require(try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: now.addingTimeInterval(-60)).first)
        let thread = Self.freshThread()
        await thread.updateMeta { $0.derived[FollowUpRunner.key(followUp.id)] = .init(at: now.addingTimeInterval(-3_600), conclusion: "x") }

        // 用户一天里切几次前后台是常事。每次都跑一轮,是拿他的钱重复回答同一个问题。
        #expect(await FollowUpRunner.pending(now: now, memoryStore: memory, thread: thread) == nil)
        #expect(await FollowUpRunner.pending(now: now.addingTimeInterval(86_400), memoryStore: memory, thread: thread)?.id == followUp.id)
    }

    // MARK: - 跑成了之后

    @Test("a run appends the conclusion to the thread and records it in meta")
    func runAppendsProactiveMessage() async throws {
        let now = Date()
        let followUp = MemoryItem(kind: .followUp, text: "两周后看深睡", dueAt: now)
        let thread = Self.freshThread()
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(text: "深睡回到 1 小时 20 分了，比两周前多 25 分钟。后面几天再看看稳不稳。")
        ])

        let ran = await FollowUpRunner.run(
            followUp,
            now: now,
            memoryStore: Self.freshMemory(),
            thread: thread,
            tenant: .owner(),
            engineFactory: { _ in LoopEngine(client: client, capabilities: .empty) }
        )
        #expect(ran)

        let messages = await thread.loadTail().messages
        #expect(messages.count == 1)
        #expect(messages.first?.origin == .followUp)
        #expect(messages.first?.role == .assistant)
        // 通知那一行放不下一整段,取第一句。
        #expect(await FollowUpRunner.conclusion(for: followUp, in: thread) == "深睡回到 1 小时 20 分了，比两周前多 25 分钟。")
        // 发出去的是他当初那句话,还原成了人话。
        #expect(client.lastPromptText.contains("两周后看深睡"))
    }

    @Test("a failed run leaves nothing behind")
    func failedRunLeavesNothing() async {
        let followUp = MemoryItem(kind: .followUp, text: "两周后看深睡", dueAt: Date())
        let thread = Self.freshThread()
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(finishReason: .init(unified: .error), failureMessage: "invalid api key")
        ])
        let ran = await FollowUpRunner.run(
            followUp,
            memoryStore: Self.freshMemory(),
            thread: thread,
            tenant: .owner(),
            engineFactory: { _ in LoopEngine(client: client, capabilities: .empty) }
        )
        #expect(!ran)
        #expect(await thread.loadTail().messages.isEmpty)
        #expect(await FollowUpRunner.conclusion(for: followUp, in: thread) == nil)
    }

    @Test("the background route mounts no writes and no ask_user")
    func backgroundRouteIsReadOnly() async throws {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = await BackgroundTurn.environment(now: Date(), memoryStore: stores.memory, thread: stores.thread, tenant: .owner())
        let names = TestAssembly.toolNames(TestAssembly.engine(environment, route: .background))
        for forbidden in [MemoryTools.rememberToolName, MemoryTools.forgetToolName, AskUserTools.askToolName, MedicationTools.logToolName] {
            #expect(!names.contains(forbidden), "后台那一轮不该挂 \(forbidden)")
        }
    }

    @Test("the promise is not restated with two full stops")
    func questionDoesNotDoubleThePunctuation() {
        let withStop = MemoryItem(kind: .followUp, text: "3天后提醒他查看静息心率。")
        let without = MemoryItem(kind: .followUp, text: "3天后提醒他查看静息心率")
        #expect(!FollowUpRunner.question(for: withStop).contains("。。"))
        #expect(FollowUpRunner.question(for: withStop) == FollowUpRunner.question(for: without))
    }

    // MARK: - 结论怎么进通知

    @Test("with a conclusion the morning notification says the answer and adds no second opener")
    func notificationCarriesTheConclusion() {
        let followUp = MemoryItem(kind: .followUp, text: "他说两周后再看看深睡回来没有", dueAt: Date())
        let answered = CheckInScheduler.content(
            for: .morning,
            situation: HealthSituation(period: .morning, triggers: []),
            dueFollowUps: [followUp],
            followUpConclusions: [followUp.id: "深睡回到 1 小时 20 分了。"]
        )
        #expect(answered.body == "深睡回到 1 小时 20 分了。")
        // 结论已经由后台那一轮写进对话末尾了,点开不再说一遍。
        #expect(answered.opener == nil)
        #expect(answered.followUpId == followUp.id)
    }

    @Test("without a conclusion the morning notification still keeps its promise")
    func notificationFallsBackToThePromise() {
        let followUp = MemoryItem(kind: .followUp, text: "他说两周后再看看深睡回来没有", dueAt: Date())
        let plain = CheckInScheduler.content(
            for: .morning,
            situation: HealthSituation(period: .morning, triggers: []),
            dueFollowUps: [followUp]
        )
        #expect(plain.body == followUp.text)
        #expect(plain.opener?.contains("深睡回来没有") == true)
        #expect(plain.followUpId == followUp.id)
    }
}
