import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 回复还在跑的时候接着说话。
///
/// 从 `ChatViewModel.send()` 一路验到发给模型的 prompt。这套东西真正的风险不在「能不能
/// 发出去」,而在几处**不报错的错**:模型吐的字落进用户刚打的那句话里、同一句被发两遍、
/// 按了停止把用户没发出去的字替他扔掉。
@MainActor
@Suite("Queued messages")
struct QueuedMessageTests {

    private static func profile(_ modelId: String = "claude-sonnet-5") -> AgentModelProfile {
        .init(providerId: "anthropic", modelId: modelId, contextWindow: 200_000, maxOutputTokens: 4_000)
    }

    /// 假模型要在自己跑到一半的时候回头叫 view model 发一句话,而 view model 得先有 client
    /// 才建得起来。用个盒子把这个环打开。
    @MainActor
    private final class ModelBox {
        var model: ChatViewModel?

        func send(_ text: String) {
            model?.send(text)
        }
    }

    // MARK: - 排队

    @Test("发出去的话在排队时不另起一轮，按了停止也不会替他扔掉")
    func queuedInputSurvivesStop() async throws {
        let client = ScriptedModelClient(
            profile: Self.profile(),
            // 这一轮永远走不完:用户就是在模型迟迟不开口的时候接着说话的。
            turns: [.init(text: "……", beforeResponding: { try await Task.sleep(for: .seconds(30)) })]
        )
        let viewModel = ChatViewModel(
            engineFactory: { LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedThread: false
        )

        viewModel.send("看看最近睡眠")
        try await waitUntil("第一轮发出去了") { client.requests.count == 1 }

        viewModel.send("顺便也看看心率")
        // 补的那句立刻是一条真消息(打出去的字必须马上看得见),但模型还没看见它。
        #expect(viewModel.messages.last?.text == "顺便也看看心率")
        #expect(viewModel.messages.last?.isQueued == true)
        #expect(viewModel.hasQueuedInput)
        #expect(client.requests.count == 1)

        viewModel.stopReply()
        try await waitUntil("停下来了") { !viewModel.isReplying }

        // 停止之后不续跑——他按停止的意思就是别再发了。
        #expect(client.requests.count == 1)
        // 但打的字原样留着,发送按钮会一直亮着等他决定。
        #expect(viewModel.messages.last?.isQueued == true)
        #expect(viewModel.hasQueuedInput)
    }

    @Test("排队状态跟着会话存盘，重开还在排队")
    func queuedStateRoundTrips() throws {
        let queued = ChatMessage(role: .user, text: "顺便也看看心率", isQueued: true)
        let decoded = try JSONDecoder().decode(
            ChatMessage.self,
            from: try JSONEncoder().encode(queued)
        )
        #expect(decoded.isQueued)

        // 正常发出去的那些不该平白多一个键。
        let sent = ChatMessage(role: .user, text: "看看最近睡眠")
        let sentJSON = try #require(String(data: try JSONEncoder().encode(sent), encoding: .utf8))
        #expect(!sentJSON.contains("isQueued"))
    }

    // MARK: - 在工具轮边界接进上下文

    @Test("模型还在查数据时补的那句，下一轮就带上了")
    func interjectionJoinsTheNextRound() async throws {
        let box = ModelBox()
        let client = ScriptedModelClient(
            profile: Self.profile(),
            turns: [
                // 请求已经发出去了,模型正在查睡眠——用户这时候想起来还要看心率。
                .init(
                    toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: "{}")],
                    finishReason: .init(unified: .toolCalls),
                    beforeResponding: {
                        await MainActor.run { box.send("顺便也看看心率") }
                    }
                ),
                .init(text: "睡眠和心率都看了。")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: {
                LoopEngine(client: client, capabilities: stubRegistry(["sleep_summary": "7 小时 12 分"]))
            },
            loadsPersistedThread: false
        )
        box.model = viewModel

        viewModel.send("看看最近睡眠")
        try await waitUntil("这轮结束") { !viewModel.isReplying }

        // 一共两次请求:插话是在边界接进去的,没有为它单独再跑一轮。
        #expect(client.requests.count == 2)

        // 这一轮被劈成两段,插话夹在中间:答它的那段排在它**下面**。
        // 不劈开的话,答案会排在提问上面——屏幕上读起来就是「我问了,它没理我」。
        #expect(viewModel.messages.map(\.text) == [
            "看看最近睡眠", "", "顺便也看看心率", "睡眠和心率都看了。"
        ])
        // 前半段留着是因为它有东西给用户看(那次查询的 chip)。
        let firstHalf = viewModel.messages[1]
        #expect(firstHalf.role == .assistant)
        #expect(firstHalf.toolCalls.count == 1)

        // 最要紧的一条:模型吐的字要落在回复上,不能落进用户刚打的那句话里。
        // 收件人一旦退回「最后一条」,插话那条就会变成 "顺便也看看心率睡眠和心率都看了。"
        let interjection = viewModel.messages[2]
        #expect(interjection.text == "顺便也看看心率")
        #expect(!interjection.isQueued)

        // 整轮的 transcript 落在后半段上,里面同时含着插话和前半段说过的话——回放要跳过
        // 列表上那两条。
        let secondHalf = try #require(viewModel.messages.last)
        #expect(secondHalf.storedTurn.inlinedMessageIDs == [firstHalf.id, interjection.id])

        // 位置就是全部:排在工具结果前面的话,模型读到的是「他先追问、我才去查」。
        let prompt = try #require(client.requests.last?.prompt)
        let toolIndex = try #require(prompt.messages.lastIndex { $0.role == .tool })
        let interjected = try #require(
            prompt.messages.lastIndex { $0.role == .user && $0.text == "顺便也看看心率" }
        )
        #expect(interjected > toolIndex)
    }

    @Test("回放时插话只出现一次，不会在 prompt 里出现两遍")
    func interjectionIsNotReplayedTwice() async throws {
        let box = ModelBox()
        let client = ScriptedModelClient(
            profile: Self.profile(),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: "{}")],
                    finishReason: .init(unified: .toolCalls),
                    beforeResponding: {
                        await MainActor.run { box.send("顺便也看看心率") }
                    }
                ),
                .init(text: "睡眠和心率都看了。"),
                .init(text: "还行。")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: {
                LoopEngine(client: client, capabilities: stubRegistry(["sleep_summary": "7 小时 12 分"]))
            },
            loadsPersistedThread: false
        )
        box.model = viewModel

        viewModel.send("看看最近睡眠")
        try await waitUntil("第一轮结束") { !viewModel.isReplying }

        viewModel.send("那今天呢")
        try await waitUntil("第二轮结束") { !viewModel.isReplying }

        // 插话和被它劈开的前半段,在两个地方各有一份:消息列表里各一条气泡(界面要显示),
        // 那一轮的 transcript 里也各有一段(模型当时就是这么读的)。回放时都只能出一份。
        let prompt = try #require(client.requests.last?.prompt)
        #expect(prompt.messages.count { $0.role == .user && $0.text == "顺便也看看心率" } == 1)

        let toolCalls = prompt.messages.reduce(into: 0) { total, message in
            total += message.parts.count { part in
                if case .toolCall = part { return true }
                return false
            }
        }
        #expect(toolCalls == 1)
    }

    // MARK: - 最后一次请求之后才到的

    /// 这一句赶在最后一次请求之后才到,loop 已经没有边界可以接它了。
    ///
    /// 不自动接着跑一轮的话,它就一直排在那儿——屏幕上是一条发出去了的消息,而模型永远
    /// 不会回应它。
    @Test("赶在最后一次请求之后到的那句，自动接着跑一轮")
    func lateInterjectionStartsAnotherTurn() async throws {
        let box = ModelBox()
        let client = ScriptedModelClient(
            profile: Self.profile(),
            turns: [
                .init(
                    text: "睡眠还行。",
                    beforeResponding: {
                        await MainActor.run { box.send("顺便也看看心率") }
                    }
                ),
                .init(text: "心率也正常。")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { LoopEngine(client: client, capabilities: stubRegistry([:])) },
            loadsPersistedThread: false
        )
        box.model = viewModel

        viewModel.send("看看最近睡眠")
        try await waitUntil("两轮都结束") { !viewModel.isReplying }

        #expect(client.requests.count == 2)
        #expect(viewModel.messages.map(\.text) == [
            "看看最近睡眠", "睡眠还行。", "顺便也看看心率", "心率也正常。"
        ])
        #expect(!viewModel.hasQueuedInput)

        // 这一句是当作普通历史发出去的,不是插话——第二轮的 transcript 不该认领它。
        let second = try #require(viewModel.messages.last)
        #expect(second.storedTurn.inlinedMessageIDs.isEmpty)
    }
}
