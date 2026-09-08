import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 答完一轮之后生成的那几条追问 chip。
///
/// 它挂在 `AgentHook` 上,所以这里连着验两件事:hook 那套通知够不够写出一条追问(材料分在
/// 两条通知里),以及几种"不该生成"的情况有没有真的不生成——多花一次调用用户看不见,而
/// 三条接不上屏幕的追问他一眼就会看见。
@Suite("Follow-up chips")
struct FollowUpChipTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 20_000,
        maxOutputTokens: 8_000
    )

    private static let sleepOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分\n08-02 | 6 小时 04 分"

    /// 记下每次生成拿到的材料和交付出去的东西。可以挂在闸上,用来制造「还在生成时下一轮开跑」。
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _contexts: [FollowUpContext] = []
        private var _delivered: [[String]] = []
        private let gate: Gate?
        private let answer: [String]

        init(returning answer: [String] = ["那第三天呢", "为什么会这样", "白天累不累"], gate: Gate? = nil) {
            self.answer = answer
            self.gate = gate
        }

        var contexts: [FollowUpContext] { lock.withLock { _contexts } }
        var delivered: [[String]] { lock.withLock { _delivered } }

        func hook() -> FollowUpSuggestionHook {
            FollowUpSuggestionHook(
                generate: { [self] context in
                    lock.withLock { _contexts.append(context) }
                    await gate?.wait()
                    return answer
                },
                deliver: { [self] suggestions in
                    lock.withLock { _delivered.append(suggestions) }
                }
            )
        }
    }

    /// 只记这一轮是怎么收尾的,别的什么都不做。
    ///
    /// 「不生成」那几条用例断言的是**什么都没发生**,而那种断言天然会在「通知压根没到」的
    /// 时候一起过——那时候它测的其实是自己的测试架子有没有跑起来。挂一个旁观的 hook 把
    /// `state` 记下来,断言就从「没生成」变成「收尾是 .stopped,而且没生成」。
    private final class StateRecorder: AgentHook, @unchecked Sendable {
        private let lock = NSLock()
        private var _states: [AgentHookTurnOutcome.State] = []

        var states: [AgentHookTurnOutcome.State] { lock.withLock { _states } }

        func observe(_ notice: AgentHookNotice) async {
            guard case .turnFinished(let outcome) = notice.kind else { return }
            lock.withLock { _states.append(outcome.state) }
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    private static func engine(
        _ hooks: AgentHookDispatcher,
        turns: [ScriptedModelClient.Turn]
    ) -> LoopEngine {
        var engine = LoopEngine(
            client: ScriptedModelClient(profile: profile, turns: turns),
            capabilities: stubRegistry(["sleep_summary": sleepOutput])
        )
        engine.hooks = hooks
        return engine
    }

    /// 照 app 的方式跑一轮:事件流抽干就算这一轮结束。
    private static func run(
        _ engine: LoopEngine,
        history: [ChatMessage],
        stoppingAfterTool: Bool = false
    ) async {
        let task = Task {
            try? await { () async throws in
                for try await event in engine.reply(to: history) {
                    if stoppingAfterTool, case .toolCallFinished = event {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }()
        }
        await task.value
    }

    // MARK: - 材料

    @Test("答完一轮：问句、回答和工具名字凑齐，工具的原始数字一个都不带")
    func materialsComeFromBothNotices() async throws {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: #"{"days":7}"#)],
                finishReason: .init(unified: .toolCalls)
            ),
            .init(text: "这两晚都不到 7 小时，周末补了一点", finishReason: .init(unified: .stop))
        ])

        await Self.run(engine, history: [ChatMessage(role: .user, text: "最近睡得怎么样")])
        await dispatcher.settle()
        // 生成和交付挂在 hook 自己的 Task 上,`settle()` 等的是通知派发——它们不在 loop 那条
        // 路上,本来就等不到。
        try await waitFor("交付") { spy.delivered.count == 1 }

        let context = try #require(spy.contexts.first)
        // 问句在 `turnStarted` 的历史里,回答在 `turnFinished` 的 transcript 里——材料本来
        // 就分在两条通知上,认错一条就会拿上一句去配这一段回答。
        #expect(context.question == "最近睡得怎么样")
        #expect(context.answer == "这两晚都不到 7 小时，周末补了一点")
        #expect(context.toolNames == ["sleep_summary"])
        // 查过什么有用,查出来的数字没用:它明天就过期了,而这一次生成要为它多付一整段钱。
        #expect(!context.answer.contains("7 小时 12 分"))
        let request = FollowUpSuggester.request(for: context)
        #expect(!request.contains("7 小时 12 分"))
        #expect(request.contains("sleep_summary"))

        #expect(spy.delivered == [["那第三天呢", "为什么会这样", "白天累不累"]])
    }

    @Test("中途插的那句也算他问的")
    func interjectionCountsAsPartOfTheQuestion() async throws {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: "{}")],
                finishReason: .init(unified: .toolCalls)
            ),
            .init(text: "睡眠和心率都看了", finishReason: .init(unified: .stop))
        ])

        // 第一个边界(第一次请求之前)空着,第二个边界才有——「他在模型查数据的时候补了一句」。
        let queue = QueuedBatches([[], [AgentPendingInput(text: "顺便也看看心率")]])
        let task = Task {
            try? await { () async throws in
                for try await _ in engine.reply(
                    to: [ChatMessage(role: .user, text: "最近睡得怎么样")],
                    pendingInput: { queue.take() }
                ) {}
            }()
        }
        await task.value
        await dispatcher.settle()
        try await waitFor("生成跑起来") { spy.contexts.count == 1 }

        let context = try #require(spy.contexts.first)
        #expect(context.question.contains("最近睡得怎么样"))
        // 不带上它,生成的三条会绕开他刚补的那句问下去——那正是他不想再听的。
        #expect(context.question.contains("顺便也看看心率"))
    }

    // MARK: - 不生成

    @Test("按了停止的那一轮不生成：他要按的是重试，不是追问")
    func stoppedTurnGeneratesNothing() async throws {
        let spy = Spy()
        let recorder = StateRecorder()
        let dispatcher = AgentHookDispatcher([spy.hook(), recorder])
        let engine = Self.engine(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: "{}")],
                finishReason: .init(unified: .toolCalls)
            ),
            // **这一轮必须挂住,不能让它抢在停止送达之前答完。** 脚本化的模型是瞬时返回的,
            // 而按停止走的是协作式取消:取消标记还在往下传的时候,这一轮已经吐完
            // "看完了" 正常收尾了,于是 hook 拿到的是 `.completed`,照常生成——测试挂在
            // 一件线上不会发生的事情上(真模型那儿隔着一整个网络往返)。
            // 挂住之后,取消一定发生在它开口之前,`.stopped` 是确定的。
            .init(
                text: "看完了",
                finishReason: .init(unified: .stop),
                beforeResponding: { try await Task.sleep(for: .seconds(30)) }
            )
        ])

        await Self.run(
            engine,
            history: [ChatMessage(role: .user, text: "最近睡得怎么样")],
            stoppingAfterTool: true
        )
        // **等的是那条收尾通知本身,不是一个拍脑袋的毫秒数。**
        // 按停止之后,`run` 一等到消费端那个 task 就返回了,而 loop 还在另一条 task 上往
        // 回退——`turnFinished` 那时候还没发出去,`settle()` 排的是一条空队,断言「什么都
        // 没生成」于是恒真。原来那个 200 毫秒只是把这个窗口盖住了,盖不住的那次才是它挂的
        // 时候(而挂的方向恰好相反,所以一直没人发现它平时是假过的)。
        try await waitFor("这一轮收尾") { recorder.states.count == 1 }
        // 收尾通知到了之后再排一次:每个 hook 各有一条尾巴,recorder 收到不等于被测的那个
        // 也收到了(「不同 hook 之间不保证顺序」)。
        await dispatcher.settle()

        // 先确认这一轮真的是「被停掉」收的尾。少了这一句,下面两条在通知根本没送到的时候
        // 也一样过——而那正是这个用例挂过一次的那种情况的反面。
        #expect(recorder.states == [.stopped])
        #expect(spy.contexts.isEmpty)
        #expect(spy.delivered.isEmpty)
    }

    @Test("报错的那一轮不生成")
    func failedTurnGeneratesNothing() async throws {
        let spy = Spy()
        let recorder = StateRecorder()
        let dispatcher = AgentHookDispatcher([spy.hook(), recorder])
        let engine = Self.engine(dispatcher, turns: [.init(failureMessage: "invalid api key")])

        await Self.run(engine, history: [ChatMessage(role: .user, text: "最近睡得怎么样")])
        // 报错和按停止走的是同一个出口(`AgentLoop` 里那个 catch),所以窗口也是同一个:
        // 等收尾通知真的到了再断言,别用毫秒数去盖。
        try await waitFor("这一轮收尾") { recorder.states.count == 1 }
        await dispatcher.settle()

        #expect(recorder.states == [.failed("invalid api key")])
        #expect(spy.contexts.isEmpty)
    }

    @Test("助手一个字没说就不生成")
    func silentTurnGeneratesNothing() async throws {
        let spy = Spy()
        let recorder = StateRecorder()
        let dispatcher = AgentHookDispatcher([spy.hook(), recorder])
        let engine = Self.engine(dispatcher, turns: [.init(finishReason: .init(unified: .stop))])

        await Self.run(engine, history: [ChatMessage(role: .user, text: "最近睡得怎么样")])
        try await waitFor("这一轮收尾") { recorder.states.count == 1 }
        await dispatcher.settle()

        // 这一轮是正常收尾的,不生成的理由是「助手一个字都没说」——和上面两条不是一回事,
        // 断言要能把这三种分开,否则哪天 `.completed` 那条路整个断了它也照样绿。
        #expect(recorder.states == [.completed])
        #expect(spy.contexts.isEmpty)
    }

    @Test("下一轮开跑就作废：还在写的那几条不会摆到新回答下面")
    func nextTurnSupersedesTheSuggestionsInFlight() async throws {
        let gate = Gate()
        let spy = Spy(gate: gate)
        let hook = spy.hook()
        let dispatcher = AgentHookDispatcher([hook])

        // 第一轮答完,生成挂在闸上;紧接着第二轮开跑——这正是插话续跑时的形状。
        await Self.run(
            Self.engine(dispatcher, turns: [.init(text: "第一段", finishReason: .init(unified: .stop))]),
            history: [ChatMessage(role: .user, text: "最近睡得怎么样")]
        )
        await dispatcher.settle()
        try await waitFor("第一轮那次生成挂在闸上") { spy.contexts.count == 1 }
        #expect(spy.delivered.isEmpty)

        await Self.run(
            Self.engine(dispatcher, turns: [.init(text: "第二段", finishReason: .init(unified: .stop))]),
            history: [ChatMessage(role: .user, text: "那心率呢")]
        )
        await gate.open()
        await dispatcher.settle()
        // `settle()` 只等通知派发完,等不到生成那一步——它本来就不在 loop 的那条路上。
        try await waitFor("第二轮那几条交付") { spy.delivered.count == 1 }
        // 放开之后再给第一轮那次一点时间:它要是也交付了,这里会变成 2。
        try? await Task.sleep(for: .milliseconds(100))

        // 两轮各生成了一次,但只交付一次:第一轮那几条接的是"最近睡得怎么样",而屏幕上已经
        // 多了一段关于心率的回答。
        #expect(spy.contexts.count == 2)
        #expect(spy.contexts.last?.question == "那心率呢")
        #expect(spy.delivered.count == 1)
    }

    // MARK: - 收尾

    @Test("剥掉壳、筛掉放不下的，够两条就用")
    func parsingKeepsWhatFits() {
        #expect(FollowUpSuggester.parse("1. 那第三天呢\n- 为什么会这样\n「白天累不累」") == [
            "那第三天呢", "为什么会这样", "白天累不累"
        ])
        // 超长的那行放不进 chip,等于没写;剩下两条照用。
        //
        // 门槛不设在"恰好三条":中文追问写到十一二个字很常见,一条超长就把另外两条也带走,
        // 而那条路径是静默的——界面上只表现为"没生成"。
        #expect(FollowUpSuggester.parse("""
            那第三天呢
            为什么会这样
            这一条特别特别长，长到一个按钮根本放不下它
            """) == ["那第三天呢", "为什么会这样"])
        // 只剩一条就整体作废:一颗生成的加一颗固定的,长短语气都不一样,比少一颗更像坏了。
        #expect(FollowUpSuggester.parse("那第三天呢").isEmpty)
        #expect(FollowUpSuggester.parse("").isEmpty)
    }

    @Test("答案太长时保头保尾")
    func aLongAnswerKeepsBothEnds() {
        let answer = String(repeating: "头", count: 700)
            + String(repeating: "中", count: 3_000)
            + String(repeating: "尾", count: 700)
        let request = FollowUpSuggester.request(for: .init(question: "问", answer: answer))

        #expect(request.contains(String(repeating: "头", count: 600)))
        #expect(request.contains(String(repeating: "尾", count: 600)))
        // 丢掉的中段是把数据一天天念过去的那部分,对"接着问什么"没有贡献。
        #expect(request.count < answer.count)
    }
}

/// 轮询等一个条件。生成那一步不在 `settle()` 等得到的范围里(它挂在 hook 自己的 Task 上),
/// 所以只能等条件成立。
private func waitFor(
    _ what: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimeout(description: "等 \(what) 超时")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// 按次数发号的排队消息。
private final class QueuedBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [[AgentPendingInput]]

    init(_ batches: [[AgentPendingInput]]) { remaining = batches }

    func take() -> [AgentPendingInput] {
        lock.withLock { remaining.isEmpty ? [] : remaining.removeFirst() }
    }
}
