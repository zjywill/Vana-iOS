import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// `ChatViewModel` 接在一条永远的对话上:冷启动接着上次、窗口批量滑、撞墙时强制留两轮再跑、
/// 后台来的主动消息在轮边界并进来、删一问一答、不留痕的一个字都不落盘。
@Suite("Chat thread", .serialized)
@MainActor
struct ChatThreadTests {
    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 200_000,
        maxOutputTokens: 8_000
    )

    private struct Fixture {
        let root: URL
        let stores: TenantStores

        init() {
            root = URL.temporaryDirectory.appending(path: "vana-chat-thread-\(UUID().uuidString)", directoryHint: .isDirectory)
            stores = TenantStores(root: root)
        }

        @MainActor
        func model(
            _ client: ScriptedModelClient? = nil,
            isEphemeral: Bool = false,
            capabilities: CapabilityRegistry = stubRegistry([:])
        ) -> ChatViewModel {
            let factory: ChatViewModel.EngineFactory? = client.map { client in
                { @MainActor @Sendable in LoopEngine(client: client, capabilities: capabilities) }
            }
            return ChatViewModel(
                engineFactory: factory,
                loadsPersistedThread: true,
                isEphemeral: isEphemeral,
                memoryStore: stores.memory,
                medicationStore: stores.medications,
                thread: stores.thread
            )
        }
    }

    private static func loaded(_ model: ChatViewModel) async throws {
        try await waitUntil("载入线程") { !model.isLoadingConversation }
    }

    @Test("a cold start lands at the end of the last conversation")
    func coldStartContinues() async throws {
        let fixture = Fixture()
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "日均 9,100 步。")])
        let first = fixture.model(client)
        try await Self.loaded(first)
        first.send("上周走了多少")
        try await waitUntil("回复结束") { !first.isReplying }
        await first.flushPersistence()

        let second = fixture.model()
        try await Self.loaded(second)
        #expect(second.messages.map(\.text) == ["上周走了多少", "日均 9,100 步。"])
        #expect(!second.isThreadEmpty)
    }

    @Test("an ephemeral conversation writes nothing to the thread")
    func ephemeralWritesNothing() async throws {
        let fixture = Fixture()
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "好的。")])
        let model = fixture.model(client, isEphemeral: true)
        try await Self.loaded(model)
        model.send("这件事别记")
        try await waitUntil("回复结束") { !model.isReplying }
        await model.flushPersistence()

        #expect(model.messages.count == 2)
        #expect(await fixture.stores.thread.loadTail().messages.isEmpty)
        #expect(model.navigationSubtitle.contains("不留痕"))
    }

    /// 窗口涨到高水位才动,一次砍到低水位;游标存进线程 meta,消息一条不删,请求里不再带远处的原文。
    @Test("a long thread slides the window before the request and keeps every message on disk")
    func windowSlides() async throws {
        let fixture = Fixture()
        var seeded: [ChatMessage] = []
        let start = Date().addingTimeInterval(-3_600)
        for index in 0..<24 {
            seeded.append(ChatMessage(role: .user, text: "第\(index)问", createdAt: start.addingTimeInterval(Double(index))))
            seeded.append(ChatMessage(
                role: .assistant,
                text: String(repeating: "答", count: 1_500),
                createdAt: start.addingTimeInterval(Double(index) + 0.5)
            ))
        }
        _ = await fixture.stores.thread.sync(seeded, dirty: [], known: [])

        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "好。")])
        let model = fixture.model(client)
        try await Self.loaded(model)
        model.send("接着说")
        try await waitUntil("回复结束") { !model.isReplying }
        await model.flushPersistence()

        #expect(await fixture.stores.thread.meta().windowStartPos != nil)
        #expect(!client.lastPromptText.contains("第0问"))
        #expect(client.lastPromptText.contains("接着说"))
        // 淘汰只前移游标,盘上一条不少。
        #expect(await fixture.stores.thread.loadTail(minMessages: 100).messages.count == seeded.count + 2)

        // 重启之后窗口还在原处。
        let reopened = fixture.model(ScriptedModelClient(profile: Self.profile, turns: [.init(text: "嗯。")]))
        try await Self.loaded(reopened)
        #expect(reopened.messages.count >= seeded.count)
    }

    /// 撞上模型的上下文上限:没有「新对话」可开了。强制把窗口砍到最近两轮,再原样跑一次。
    @Test("a context overflow shrinks the window to the last two turns and runs again")
    func overflowShrinksAndRetries() async throws {
        let fixture = Fixture()
        let overflow = ScriptedModelClient.Turn(
            finishReason: .init(unified: .error),
            failureMessage: "prompt is too long: 210000 tokens > 200000 maximum"
        )
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(text: "答一"), .init(text: "答二"), .init(text: "答三"),
            overflow, overflow,
            .init(text: "砍完了，接着说")
        ])
        let model = fixture.model(client)
        try await Self.loaded(model)
        for question in ["问一", "问二", "问三"] {
            model.send(question)
            try await waitUntil("回复结束") { !model.isReplying }
        }
        model.send("问四")
        try await waitUntil("回复结束") { !model.isReplying }

        #expect(model.messages.last?.text == "砍完了，接着说")
        #expect(model.messages.last?.errorDescription == nil)
        #expect(!client.lastPromptText.contains("问一"))
        #expect(client.lastPromptText.contains("问四"))
    }

    @Test("a proactive message that arrives while idle shows up at the end")
    func backgroundMessageMergesWhenIdle() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        try await Self.loaded(model)
        await fixture.stores.thread.appendAtEnd(ChatMessage(role: .assistant, text: "到点了：带伞", origin: .reminder))
        try await waitUntil("主动消息并进来") { model.messages.last?.text == "到点了：带伞" }
        #expect(model.messages.last?.isProactive == true)
    }

    @Test("a proactive message waits for the reply to finish before it is merged")
    func backgroundMessageWaitsForTheTurnBoundary() async throws {
        let fixture = Fixture()
        let gate = Gate()
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(text: "慢慢答", beforeResponding: { await gate.wait() })
        ])
        let model = fixture.model(client)
        try await Self.loaded(model)
        model.send("问")
        try await waitUntil("开始回复") { model.isReplying }

        await fixture.stores.thread.appendAtEnd(ChatMessage(role: .assistant, text: "后台结果", origin: .task))
        try await Task.sleep(for: .milliseconds(50))
        // 回答还在写的时候不动——插进来的话,它会出现在正在流的那条回复中间。
        #expect(!model.messages.contains { $0.text == "后台结果" })

        await gate.open()
        try await waitUntil("回复结束") { !model.isReplying }
        try await waitUntil("主动消息并进来") { model.messages.contains { $0.text == "后台结果" } }
        #expect(model.messages.last?.text == "后台结果")
    }

    @Test("deleting an answer takes its question with it, on disk too")
    func deleteExchange() async throws {
        let fixture = Fixture()
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "答一"), .init(text: "答二")])
        let model = fixture.model(client)
        try await Self.loaded(model)
        model.send("问一")
        try await waitUntil("回复结束") { !model.isReplying }
        model.send("问二")
        try await waitUntil("回复结束") { !model.isReplying }
        await model.flushPersistence()

        let firstAnswer = try #require(model.messages.first { $0.text == "答一" })
        model.deleteExchange(firstAnswer.id)
        await model.flushPersistence()

        #expect(model.messages.map(\.text) == ["问二", "答二"])
        #expect(await fixture.stores.thread.loadTail().messages.map(\.text) == ["问二", "答二"])
    }

    @Test("clearing the history empties the thread")
    func clearHistory() async throws {
        let fixture = Fixture()
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "答")])
        let model = fixture.model(client)
        try await Self.loaded(model)
        model.send("问")
        try await waitUntil("回复结束") { !model.isReplying }
        await model.clearHistory()
        #expect(model.messages.isEmpty)
        #expect(model.isThreadEmpty)
        #expect(await fixture.stores.thread.loadTail().messages.isEmpty)
    }

    /// 点开 check-in:Vana 在对话里开个场(一条主动消息,不调模型),开场问题填进输入框。
    @Test("opening a check-in adds an opener and prefills the question")
    func openCheckIn() async throws {
        let fixture = Fixture()
        let model = fixture.model()
        try await Self.loaded(model)
        model.open(CheckInLaunch(opener: "昨晚只睡了 5.4 小时。", question: "昨晚睡得怎么样？"))
        #expect(model.messages.last?.origin == .checkIn)
        #expect(model.messages.last?.text == "昨晚只睡了 5.4 小时。")
        #expect(model.input == "昨晚睡得怎么样？")
        await model.flushPersistence()
        #expect(await fixture.stores.thread.loadTail().messages.first?.origin == .checkIn)
    }

    /// 主动消息不单独发给模型:折进下一条用户消息开头。
    @Test("the model sees a proactive opener folded into the next user message")
    func proactiveFoldsIntoTheRequest() async throws {
        let fixture = Fixture()
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "那就早点睡。")])
        let model = fixture.model(client)
        try await Self.loaded(model)
        model.open(CheckInLaunch(opener: "昨晚只睡了 5.4 小时。", question: nil))
        model.send("有点困")
        try await waitUntil("回复结束") { !model.isReplying }
        let prompt = try #require(client.requests.last?.prompt)
        let users = prompt.messages.filter { $0.role == .user }.map(\.text)
        #expect(users.last?.contains("（Vana 之前主动说过：昨晚只睡了 5.4 小时。）") == true)
        #expect(users.last?.hasSuffix("有点困") == true)
    }
}

/// 一道门:测试里把某一轮挂住,打开之后再放行。
actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}
