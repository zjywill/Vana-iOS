import Foundation
import Testing
import AgentRuntime
import AIKit

@testable import Vana

/// 规划期间的物理内存峰值。
///
/// `phys_footprint` 就是 iOS 用来决定「要不要干掉这个 app」的那个数,所以盯它而不是别的。
/// 两套性能测试共用一份采样器。
final class FootprintSampler: @unchecked Sendable {
    private var baseline = 0
    private var peak = 0
    private var isRunning = false
    private let lock = NSLock()

    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    func start() {
        baseline = Self.footprint()
        peak = baseline
        lock.lock()
        isRunning = true
        lock.unlock()

        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let running = isRunning
                if running { peak = max(peak, Self.footprint()) }
                lock.unlock()
                guard running else { return }
                usleep(200)
            }
        }
    }

    /// 相对基线的峰值增量。
    func stop() -> Int {
        lock.lock()
        isRunning = false
        let measured = peak
        lock.unlock()
        return max(0, measured - baseline)
    }
}

/// 上下文规划的开销。
///
/// 手机上这段是每轮、每个工具轮都要跑一遍的,而且跑在用户已经在等的那段时间里。估算器本身
/// 不便宜:每次都要把整份 transcript 深拷贝成 AIKit 类型、把每条工具结果和每份工具 schema
/// 重新 JSON 编码一遍、再逐个 unicode scalar 扫过去。
@Suite("Context budget performance")
struct ContextBudgetPerformanceTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 200_000,
        maxOutputTokens: 64_000
    )

    /// 线上那条估算路径,顺便数一下被调了几次。
    private final class CountingEstimator: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0
        private let definitions: [CapabilityDefinition]
        private let reporter = ContextReporter()

        init(definitions: [CapabilityDefinition]) {
            self.definitions = definitions
        }

        func estimate(_ transcript: AgentTranscript) -> Int {
            estimate(transcript, tools: definitions)
        }

        /// 逐条计价走的那条:同一个估算器,只是不带工具面。
        func estimateMessages(_ transcript: AgentTranscript) -> Int {
            estimate(transcript, tools: [])
        }

        private func estimate(_ transcript: AgentTranscript, tools: [CapabilityDefinition]) -> Int {
            lock.lock()
            calls += 1
            lock.unlock()
            return reporter.report(
                CallOptions(
                    model: "claude-sonnet-5",
                    prompt: transcript.aiKitPrompt,
                    tools: tools.map(\.aiKitToolDefinition)
                ),
                contextWindow: 200_000
            ).used
        }
    }

    /// 一段快把窗口填满的真实会话:每轮一问一答加两次健康查询,工具输出按线上的闸门封顶。
    private func longConversation(turns: Int) -> [AgentChatMessageDTO] {
        var history: [AgentChatMessageDTO] = []
        for turn in 1...turns {
            history.append(.init(role: .user, text: "第 \(turn) 问：最近的睡眠和步数怎么样"))
            let calls = (1...2).map { index -> ToolCallRecordDTO in
                .init(
                    id: "call_\(turn)_\(index)",
                    name: index == 1 ? "daily_steps" : "sleep_summary",
                    input: #"{"days":30}"#,
                    output: .init(
                        kind: .table,
                        // 线上单次工具输出的上限就是这个量级。
                        text: String(repeating: "08-0\(index) | 9,132 步 | 7 小时 12 分\n", count: 100)
                    )
                )
            }
            history.append(.init(
                role: .assistant,
                text: "第 \(turn) 答：这一个月日均 9,100 步，平均睡眠 7 小时 05 分，周末明显比工作日多睡。",
                toolCalls: calls,
                storedTurn: .init(
                    exactTranscript: .init(messages: [
                        .init(role: .assistant, parts: [.text("第 \(turn) 答")] + calls.map {
                            .toolCall(.init(toolCallId: $0.id, toolName: $0.name, input: $0.input))
                        })
                    ] + calls.map {
                        .toolResult(
                            toolCallId: $0.id,
                            toolName: $0.name,
                            result: .string($0.output?.text ?? ""),
                            isError: false
                        )
                    }),
                    state: .completed
                )
            ))
        }
        history.append(.init(role: .user, text: "那这周呢"))
        return history
    }

    @Test(
        "planning stays cheap whether or not the conversation needs compacting",
        arguments: [
            // 绝大多数会话长这样:离水位线还远,规划本身不该有任何额外开销。
            (turns: 40, expectsCompaction: false),
            // 快把 20 万窗口填满的极端情况。
            (turns: 110, expectsCompaction: true)
        ]
    )
    func planningCostIsBounded(turns: Int, expectsCompaction: Bool) {
        let definitions = HealthTools.registry.definitions
        let estimator = CountingEstimator(definitions: definitions)
        let history = longConversation(turns: turns)

        let planner = ConversationHistoryPlanner(
            systemInstruction: CoreInstructions.text(),
            profile: Self.profile,
            reservedOutputTokens: AgentLoop.reservedOutputTokens(for: Self.profile),
            compactor: .vana,
            policy: .vana,
            estimateMessageTokens: estimator.estimateMessages,
            estimateTokens: estimator.estimate
        )

        // 峰值内存和耗时一样要紧:手机上 app 是会因为内存被直接干掉的,而这段跑在用户
        // 已经在等的时候。采样线程盯着规划期间的物理占用。
        let sampler = FootprintSampler()
        sampler.start()
        let started = ContinuousClock.now
        let prepared = planner.prepare(history: history)
        let elapsed = ContinuousClock.now - started
        let peakGrowth = sampler.stop()

        print("""
            PLAN 消息=\(history.count) 压缩=\(prepared.compactedAssistantMessages) \
            估算次数=\(estimator.calls) 估算 token=\(prepared.estimatedPromptTokens) \
            耗时=\(elapsed) 峰值内存增量=\(peakGrowth / 1024) KB
            """)

        #expect((prepared.compactedAssistantMessages > 0) == expectsCompaction)
        // 一份 20 万 token 的会话文本本身就有几百 KB。规划期间的峰值增量得和它同一个量级,
        // 而不是它的几十倍——那说明每轮都在把整份对话重新深拷一遍。
        #expect(peakGrowth < 12 * 1024 * 1024)

        if expectsCompaction {
            // 每个工具轮都要重来一遍,一轮最多 6 个。留 200ms 是给最慢的机器的余量;
            // 真正的意义是把「悄悄退化回按条全量重估」挡在门外。
            #expect(elapsed < .milliseconds(200))
        } else {
            // 压都不用压的时候,规划就该只是「估一次」。成本模型是压缩才付的钱,
            // 不能让不压缩的会话替它买单。
            #expect(estimator.calls == 1)
            #expect(elapsed < .milliseconds(60))
        }
    }
}
