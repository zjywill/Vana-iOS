import Foundation
import AgentRuntime

/// 后台助手(子 agent)的预算。**每一条都为了「用户不在场时也不会失控」**:轮数和时长挡住一个
/// 绕圈子的模型,排队和每日次数挡住一个被反复触发的入口,估算的 token 上限挡住一次搜出几十页
/// 内容的任务。任何一条撞上都是「失败即放弃」,不自动重试。和 Android 那份同一套数字。
enum SubagentLimits {
    static let maxToolRounds = 12
    static let maxWallClock: Duration = .seconds(5 * 60)
    /// 估算的 token 总量(字符数 ÷ 2,偏保守)。真实用量取决于 provider,这里只求「量级上别失控」。
    static let maxEstimatedTokens = 80_000
    /// 排队 + 正在跑的最多这么多件。
    static let maxQueued = 3
    static let maxRunsPerDay = 10
    static let maxBriefCharacters = 1_500
    /// 被系统打断后自动接着跑的次数上限(含第一次)。
    static let maxAttempts = 2

    static func estimateTokens(characters: Int) -> Int { (characters + 1) / 2 }

    /// 现在还能不能再开一件。不能就返回要说给用户/模型听的原因。
    static func problem(_ tasks: [TaskItem], now: Date, calendar: Calendar = .current) -> String? {
        let jobs = tasks.filter { $0.kind == .job }
        let waiting = jobs.count { $0.status == .queued || $0.status == .running }
        if waiting >= maxQueued {
            return "后台已经有 \(waiting) 件在排队或进行中了，等它们做完再开新的。"
        }
        let ranToday = jobs.count { $0.startedAt.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        if ranToday >= maxRunsPerDay {
            return "今天已经派出去 \(ranToday) 件后台任务了，明天再继续。"
        }
        return nil
    }
}

/// 把后台助手最后写的那段话拆成结果:第一段是结论(它会原样进对话,模型下一轮看得到),
/// 空一行之后是详细内容,最后一段「来源：」每行一条。
///
/// 不用一个专门的「交卷」工具:模型直接写话最自然,少一个它可能忘记调的工具,而格式偏了
/// 也不丢东西——最坏是整段成了结论。
enum SubagentResult {
    private static let summaryLimit = 160

    static func parse(_ text: String, proposals: [TaskItem.Proposal] = []) -> TaskItem.Result? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lines = trimmed.components(separatedBy: "\n")
        var main = lines
        var sources: [String] = []
        if let start = lines.lastIndex(where: { sourceHeader($0) != nil }) {
            main = Array(lines[..<start])
            sources = ([sourceHeader(lines[start]) ?? ""] + lines[(start + 1)...])
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "-•* ").union(.whitespaces)) }
                .filter { !$0.isEmpty }
                .prefix(10)
                .map { $0 }
        }

        let mainText = main.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let first: String
        let rest: String
        if let range = mainText.range(of: "\n\n") {
            first = String(mainText[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            rest = String(mainText[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            first = mainText
            rest = ""
        }
        let summary = first.count <= summaryLimit ? first : clip(first)
        // 第一段被截短了,被截掉的那部分不能丢:并回详细内容。
        let body = first.count <= summaryLimit ? rest : first + (rest.isEmpty ? "" : "\n\n\(rest)")
        guard !summary.isEmpty else { return nil }
        return TaskItem.Result(summary: summary, body: body, proposals: proposals, sources: sources)
    }

    /// 「来源：xxx」那一行,返回冒号后面的内容;不是就 nil。
    private static func sourceHeader(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["来源", "参考", "资料来源", "Sources", "Source"] {
            for colon in ["：", ":"] where trimmed.lowercased().hasPrefix((prefix + colon).lowercased()) {
                return String(trimmed.dropFirst(prefix.count + colon.count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    private static func clip(_ text: String) -> String {
        let head = String(text.prefix(summaryLimit))
        if let end = head.lastIndex(where: { "。！？!?；;".contains($0) }), head.distance(from: head.startIndex, to: end) >= 40 {
            return String(head[...end])
        }
        return String(text.prefix(summaryLimit - 1)) + "…"
    }
}

/// 后台助手的角色说明。**不带领域词**:健康那一侧该守的规则由健康插件在这条路上自己贡献。
enum SubagentInstructions {
    static func text() -> String {
        """
        你现在是 Vana 派出去的后台助手，替用户独立完成一件事。他此刻不在场，你没有和他对话的通道：
        - 不能反问，也不要写「请告诉我」。信息不全就按最合理的假设做，并在结果里说明你的假设。
        - 你是只读的：可以查资料、看记忆和过往对话，不能改任何东西。想让用户做的事（设提醒、记成目标、记住某件事）用 \(SubagentTools.proposeToolName) 提议，他点了才会执行。
        - 工具最多用 \(SubagentLimits.maxToolRounds) 轮，够用就停，不要为了显得认真而多查。
        - 搜索词里不要写进用户的姓名、账号、住址这类个人信息。
        - 结果这样写：第一段一两句话的结论（它会直接出现在对话里）；空一行，写详细内容；如果引用了资料，最后另起一段「来源：」，一行一条。
        - 拿不准的地方直说拿不准，不要编。没有把握的事实不要写成确定的。
        """
    }
}

/// 后台助手一路上攒下来的「想让用户做的事」。它自己不能写任何东西,只能提议。
final class ProposalCollector: @unchecked Sendable {
    static let maxProposals = 5
    private let lock = NSLock()
    private var items: [TaskItem.Proposal] = []

    func add(_ proposal: TaskItem.Proposal) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard items.count < Self.maxProposals else { return false }
        items.append(proposal)
        return true
    }

    var all: [TaskItem.Proposal] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}

/// 后台任务的「手」:开始、重试、停止、对提议做决定。界面和 `start_task` 工具都经它。
protocol JobControls: Sendable {
    /// 设置里「只读任务自动开始」开着吗。默认关:每个任务先弹确认卡,用户点了才跑。
    var autoStart: Bool { get }
    /// 开始(或重试)。缺配置、缺同意、超限时**不**开始,原因写进任务的 `error` 让卡片显示。
    func start(_ taskId: UUID) async
}

/// 两个工具,分属两头:
/// - `start_task`:**前台**的 Vana 用它派活。只放一张确认卡,用户点了「开始」才会跑——所以它
///   声明成写盘 + 要用户参与,不留痕浮层和后台里都不挂(后台助手不能再派后台助手)。
/// - `propose_action`:**后台助手**用它提议「设个提醒 / 记成目标 / 记住这件事」。什么都不写,
///   只是攒在一个列表里,跑完之后放在结果里由用户逐条决定,所以是只读的。
enum SubagentTools {
    static let startToolName = "start_task"
    static let proposeToolName = "propose_action"
    static let taskIdKey = "startedTaskId"

    static func startTaskRegistry(_ env: TasksEnvironment) -> CapabilityRegistry {
        let definition = CapabilityDefinition(
            name: startToolName,
            description: "把一件**独立、要花几分钟**的事（查很多资料、比较几个方案、整理一个主题）派给后台助手去做。"
                + "它看不到这段对话，所以 brief 必须自己讲得清清楚楚。会先给用户一张确认卡，他点了「开始」才会跑；"
                + "结果出来后会出现在对话里。一句话能答的问题不要派。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "title": .object(["type": "string", "description": "任务名，短一点，比如「比较三款空气净化器」"]),
                    "brief": .object([
                        "type": "string",
                        "description": .string(
                            "交给后台助手的完整说明：要做什么、要什么样的结果、用户的相关偏好和限制。"
                                + "不超过 \(SubagentLimits.maxBriefCharacters) 字，不要写进用户不必要的个人信息。"
                        )
                    ])
                ]),
                "required": .array(["title", "brief"]),
                "additionalProperties": .bool(false)
            ])
        )
        return CapabilityRegistry(definitions: [definition]) { invocation in
            await startTask(env, try? RuntimeJSONValue.decode(from: invocation.input))
        }
    }

    private static func startTask(_ env: TasksEnvironment, _ input: RuntimeJSONValue?) async -> CapabilityExecutionResult {
        guard let jobs = env.jobs else { return .failure("这台设备上现在不能派后台任务。") }
        let title = (input?["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let brief = (input?["brief"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !brief.isEmpty else { return .failure("start_task 需要 title 和 brief。") }
        guard title.count <= TasksTools.maxTitleCharacters else { return .failure("任务名太长了，短一点。") }
        guard brief.count <= SubagentLimits.maxBriefCharacters else {
            return .failure("brief 太长了（最多 \(SubagentLimits.maxBriefCharacters) 字），压缩成后台助手真正需要的部分。")
        }
        if let problem = SubagentLimits.problem(await env.store.all(), now: env.now(), calendar: env.calendar) {
            return .failure(problem)
        }

        var task = TaskItem(kind: .job, title: title, status: .proposed, createdAt: env.now())
        task.brief = brief
        await env.store.add(task)
        let auto = jobs.autoStart
        if auto { await jobs.start(task.id) }

        let text = auto
            ? "已经交给后台助手（编号 \(task.handle)）。它需要几分钟，做完结果会出现在对话里。你现在不用等，也不要说已经做完了。"
            : "已经在对话里放了一张确认卡（编号 \(task.handle)）：用户点「开始」才会跑。"
                + "告诉他这件事会放到后台做、大概几分钟，然后接着聊别的；不要说已经开始了。"
        return CapabilityExecutionResult(output: .init(
            kind: .text,
            text: text,
            // 只给界面:卡片凭它找到那条任务。
            metadata: .object([taskIdKey: .string(task.id.uuidString)])
        ))
    }

    static func proposeRegistry(
        _ collector: ProposalCollector,
        calendar: Calendar = .current,
        now: @escaping @Sendable () -> Date = { Date() }
    ) -> CapabilityRegistry {
        let definition = CapabilityDefinition(
            name: proposeToolName,
            description: "提议一件你想让用户做的事，放进结果里由他逐条决定，你自己什么都不会被写下。"
                + "kind 是 reminder（设提醒，要给 at）、goal（记成长期目标）或 memory（记住一件长期成立的事）。"
                + "最多 \(ProposalCollector.maxProposals) 条，只提真正有用的。",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "kind": .object(["type": "string", "description": "提议的类型", "enum": .array(["reminder", "goal", "memory"])]),
                    "text": .object(["type": "string", "description": "提议的内容，一句话"]),
                    "at": .object(["type": "string", "description": "kind=reminder 时必填：用户当地时间，形如 2026-10-01T20:00"]),
                    "why": .object(["type": "string", "description": "为什么这样提议，一句话，可选"])
                ]),
                "required": .array(["kind", "text"]),
                "additionalProperties": .bool(false)
            ])
        )
        return CapabilityRegistry(definitions: [definition]) { invocation in
            let input = try? RuntimeJSONValue.decode(from: invocation.input)
            let kind = input?["kind"]?.stringValue ?? ""
            let text = (input?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard ["reminder", "goal", "memory"].contains(kind), !text.isEmpty else {
                return .failure("需要 kind（reminder / goal / memory）和 text。")
            }
            var at: Date?
            if kind == "reminder" {
                guard let parsed = ReminderRules.parseLocal(input?["at"]?.stringValue ?? "", calendar: calendar) else {
                    return .failure("提议提醒时要给 at，用用户当地时间，形如 2026-10-01T20:00。")
                }
                guard parsed > now() else { return .failure("这个时间已经过了，换一个之后的时间。") }
                at = parsed
            }
            let why = input?["why"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard collector.add(.init(kind: kind, text: String(text.prefix(200)), at: at, why: why.map { String($0.prefix(200)) })) else {
                return .failure("提议已经够多了（最多 \(ProposalCollector.maxProposals) 条），不要再加。")
            }
            return .success("已记下这条提议，用户会在结果里决定要不要照做。")
        }
    }
}

/// 后台助手这一路独有的:角色说明加「提议」工具。提议不写任何东西,所以声明为只读,后台路能挂。
struct SubagentPlugin: AgentPlugin {
    let id = "subagent"
    let collector: ProposalCollector

    func tools(context: PluginContext) -> [PluginTool] {
        PluginTool.from(SubagentTools.proposeRegistry(collector)) { _ in [.read] }
    }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        [PromptBlock(order: PromptOrder.subagent, text: SubagentInstructions.text())]
    }
}

/// 跑一件后台任务。**不碰通知、不碰对话线程**——那些在外面(`SubagentScheduler`):这里只负责
/// 「一个隔离的上下文、只读的工具、一份预算、把过程和结果记进任务」,所以能秒级测。
///
/// 隔离:上下文是它自己造的(角色说明 + brief 一条消息),不带主窗口的任何内容——所以 brief 必须
/// 自足,也所以后台一轮不会把用户的对话历史整个发给模型。失败即放弃:任何一条预算撞上、模型报错,
/// 都是记下原因、状态记为失败,由用户决定要不要再试;不自动重试。
struct SubagentRunner: Sendable {
    enum Outcome: Sendable {
        case done(TaskItem)
        case failed(TaskItem)
        case skipped
    }

    let store: TaskStore
    /// 造一个只读引擎。工具集合由调用方按「后台路 + 提议工具」装配,提议都攒进 collector。
    let engineFor: @Sendable (ProposalCollector) -> any AgentEngine
    var now: @Sendable () -> Date = { Date() }
    var wallClock: Duration = SubagentLimits.maxWallClock

    private static let maxSteps = 40

    func run(_ taskId: UUID) async -> Outcome {
        guard let queued = await store.get(taskId), queued.kind == .job, queued.status == .queued else { return .skipped }
        let started = now()
        await store.update(queued.id, now: started) {
            $0.status = .running
            $0.startedAt = started
            $0.attempts += 1
            $0.error = nil
            $0.steps = []
            $0.result = nil
        }

        let collector = ProposalCollector()
        let engine = engineFor(collector)
        let prompt = "任务：\(queued.title)\n\n\(queued.brief)"
        let consumption = Consumption(characters: prompt.count)

        let outcome: RunOutcome = await withTaskGroup(of: RunOutcome.self) { group in
            group.addTask {
                var messages = [ChatMessage(role: .user, text: prompt), ChatMessage(role: .assistant, text: "")]
                do {
                    for try await event in engine.reply(to: messages) {
                        switch event {
                        case .historyCompacted:
                            continue
                        case .textDelta(let delta), .reasoningDelta(let delta):
                            consumption.add(delta.count)
                        case .toolCallStarted(let record):
                            await recordStep(queued.id, record)
                        case .toolCallFinished(_, let output, _):
                            consumption.add(output.text.count)
                        default:
                            break
                        }
                        messages[messages.count - 1].apply(event)
                        if SubagentLimits.estimateTokens(characters: consumption.characters) > SubagentLimits.maxEstimatedTokens {
                            return .budget
                        }
                    }
                } catch is CancellationError {
                    return .cancelled
                } catch {
                    return .error(ChatViewModel.userFacingFailure(error))
                }
                if Task.isCancelled { return .cancelled }
                return .finished(messages.last)
            }
            group.addTask {
                try? await Task.sleep(for: wallClock)
                return .timeout
            }
            let first = await group.next() ?? .cancelled
            group.cancelAll()
            return first
        }

        let tokens = SubagentLimits.estimateTokens(characters: consumption.characters)
        switch outcome {
        case .budget:
            return await fail(queued.id, tokens, "这件事用到的内容超出了预算，先停下了。可以把范围缩小一点再试。")
        case .timeout:
            return await fail(queued.id, tokens, "超过 5 分钟还没做完，先停下了。")
        case .cancelled:
            // 用户点了「停止」:状态由停止的那一头写,这里不覆盖。
            return .skipped
        case .error(let reason):
            return await fail(queued.id, tokens, reason)
        case .finished(let reply):
            guard let reply, !reply.textIsPlaceholder,
                  let result = SubagentResult.parse(reply.text, proposals: collector.all)
            else {
                return await fail(queued.id, tokens, reply?.errorDescription ?? "后台助手没有给出结果。")
            }
            guard let done = await store.update(queued.id, now: now(), {
                // 停止的那一头已经把它标成取消了,就别再改回来。
                guard $0.status == .running else { return }
                $0.status = .done
                $0.result = result
                $0.tokensUsed = tokens
                $0.error = nil
            }), done.status == .done else { return .skipped }
            return .done(done)
        }
    }

    private enum RunOutcome: Sendable {
        case finished(ChatMessage?)
        case budget
        case timeout
        case cancelled
        case error(String)
    }

    private final class Consumption: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int
        init(characters: Int) { value = characters }
        var characters: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        func add(_ count: Int) {
            lock.lock()
            value += count
            lock.unlock()
        }
    }

    private func recordStep(_ id: UUID, _ record: ToolCallRecordDTO) async {
        let step = TaskItem.Step(at: now(), label: ToolLabels.stepLabel(name: record.name, input: record.input), detail: String(record.input.prefix(120)))
        await store.update(id) { task in
            task.steps = Array((task.steps + [step]).suffix(Self.maxSteps))
        }
    }

    private func fail(_ id: UUID, _ tokens: Int, _ reason: String) async -> Outcome {
        guard let failed = await store.update(id, now: now(), {
            guard $0.status == .running else { return }
            $0.status = .failed
            $0.error = reason
            $0.tokensUsed = tokens
        }), failed.status == .failed else { return .skipped }
        return .failed(failed)
    }
}

/// 后台任务详情里那一行「做了什么」。和聊天里的胶囊同一套说法,但这里不需要界面上下文。
enum ToolLabels {
    static func stepLabel(name: String, input: String) -> String {
        switch name {
        case WebSearchTools.searchToolName:
            return "搜索：\(WebSearchTools.query(fromInput: input) ?? "")"
        case HistoryRecallTools.searchToolName, HistoryRecallTools.readToolName:
            return "翻了翻过往对话"
        case SubagentTools.proposeToolName:
            return "提了一条建议"
        default:
            if HealthTools.all.contains(where: { $0.name == name }) { return "查了\(HealthTools.label(for: name))" }
            return "用了 \(name)"
        }
    }
}
