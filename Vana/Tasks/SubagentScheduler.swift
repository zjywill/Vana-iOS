import Foundation
import AgentRuntime
import UIKit
import UserNotifications

/// 后台任务的排队和运行。
///
/// - **一次只跑一件**:和「后台的模型调用同时只准跑一件」是同一把锁(`BackgroundModelWork`),
///   补的是同一个失灵(并行烧钱)。排在后面的等着,不丢(`runExclusive`)。
/// - **app 活着才跑**。切到后台时向系统多要一小段时间(`beginBackgroundTask`),被系统收回时正在跑的
///   那件会停;下次打开时 `resume` 把它接着排回去(最多再跑一次),再撞上就记为失败、由用户决定
///   要不要重试。先不上 `BGTaskScheduler`——要不要上,看真有没有人总在任务跑到一半时切走 app。
/// - **每一步先过闸**:没配模型、没点过同意,都不开跑(记成失败并说原因),不会静悄悄地发出去。
actor SubagentScheduler {
    static let shared = SubagentScheduler()

    enum Check: Equatable, Sendable {
        case ready
        case notConfigured
        case needsConsent(String)
    }

    static let notificationPrefix = "task."

    /// 正在跑的那几件怎么叫停。
    private var running: [UUID: @Sendable () -> Void] = [:]
    private var draining: Set<UUID> = []

    nonisolated static func check() -> Check {
        let key = (try? KeychainStore.get(account: KeychainStore.apiKeyAccount)) ?? ""
        let selection = EngineSettings.selection
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !selection.model.isEmpty else {
            return .notConfigured
        }
        return ProviderConsent.granted(selection.provider) ? .ready : .needsConsent(selection.provider)
    }

    func isRunning(_ taskId: UUID) -> Bool { running[taskId] != nil }

    /// 队里有等着的就开始排干。多次调用没关系:同一位成员同一时刻只有一个在排。
    func kick(_ tenant: Tenant) {
        guard !draining.contains(tenant.id) else { return }
        draining.insert(tenant.id)
        Task { await drain(tenant) }
    }

    private func drain(_ tenant: Tenant) async {
        let store = TenantScope.stores(for: tenant).tasks
        while let next = await store.all().filter({ $0.kind == .job && $0.status == .queued }).min(by: { $0.updatedAt < $1.updatedAt }) {
            await BackgroundModelWork.shared.runExclusive {
                await self.runOne(tenant, next.id)
            }
        }
        draining.remove(tenant.id)
    }

    func stop(_ tenant: Tenant, _ taskId: UUID) async {
        await TenantScope.stores(for: tenant).tasks.update(taskId) {
            if $0.isActive {
                $0.status = .cancelled
                $0.error = nil
            }
        }
        running[taskId]?()
    }

    /// 打开 app 时:把被打断的任务接着排回去(最多 `SubagentLimits.maxAttempts` 次),
    /// 再看有没有到点该回顾的目标。
    func resume() async {
        let tenants = (try? TenantStore.shared.tenants()) ?? [TenantScope.owner]
        for tenant in tenants {
            let store = TenantScope.stores(for: tenant).tasks
            for job in await store.all() where job.kind == .job && job.status == .running && running[job.id] == nil {
                await store.update(job.id) {
                    if $0.attempts < SubagentLimits.maxAttempts {
                        $0.status = .queued
                    } else {
                        $0.status = .failed
                        $0.error = String(localized: "中途被系统打断了，可以再试一次。")
                    }
                }
            }
            if Self.check() == .ready {
                await GoalDigest.enqueueDue(store: store, now: Date())
            }
            if await store.all().contains(where: { $0.kind == .job && $0.status == .queued }) {
                kick(tenant)
            }
        }
    }

    private func runOne(_ tenant: Tenant, _ taskId: UUID) async {
        let stores = TenantScope.stores(for: tenant)
        switch Self.check() {
        case .ready:
            break
        case .notConfigured:
            await stores.tasks.update(taskId) {
                $0.status = .failed
                $0.error = String(localized: "还没配置云端模型，先到设置里填好。")
            }
            return
        case .needsConsent:
            await stores.tasks.update(taskId) {
                $0.status = .failed
                $0.error = String(localized: "还没同意把数据发给当前的模型服务。")
            }
            return
        }

        let selection = EngineSettings.selection
        let environment = await BackgroundTurn.environment(
            now: Date(),
            memoryStore: stores.memory,
            thread: stores.thread,
            tenant: tenant,
            webSearch: .storedKey()
        )
        let runner = SubagentRunner(store: stores.tasks, engineFor: { collector in
            AIKitEngine(
                providerId: selection.provider,
                model: selection.model,
                plugins: PluginRegistry.agentPlugins(environment, route: .background) + [SubagentPlugin(collector: collector)],
                pluginContext: PluginRegistry.context(for: environment, route: .background, isPrivate: false),
                thinking: false,
                maxToolRounds: SubagentLimits.maxToolRounds
            )
        })

        let backgroundTask = await MainActor.run {
            UIApplication.shared.beginBackgroundTask(withName: "vana.subagent")
        }
        let work = Task { await runner.run(taskId) }
        running[taskId] = { work.cancel() }
        let outcome = await work.value
        running[taskId] = nil
        await MainActor.run { UIApplication.shared.endBackgroundTask(backgroundTask) }

        switch outcome {
        case .done(let task): await Self.announce(task, ok: true, stores: stores)
        case .failed(let task): await Self.announce(task, ok: false, stores: stores)
        case .skipped: break
        }
    }

    /// 做完(或没做成)了:一条主动消息落进对话末尾(结论那一句进窗口,模型下一轮看得到),
    /// 再发一条本地通知。
    static func announce(_ task: TaskItem, ok: Bool, stores: TenantStores) async {
        let text = ok
            ? "「\(task.title)」做完了：\(task.result?.summary ?? "")"
            : "「\(task.title)」没做成：\(task.error ?? "")"
        await stores.thread.appendAtEnd(ChatMessage(role: .assistant, text: text, origin: .task, refTaskId: task.id))

        let content = UNMutableNotificationContent()
        content.title = String(localized: "后台任务")
        content.body = text
        content.sound = .default
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: notificationPrefix + task.id.uuidString,
            content: content,
            trigger: nil
        ))
    }
}

/// 目标的每周回顾:开了「每周回顾」的目标,每隔七天派一件后台任务去看看进展。
///
/// 它和用户手动派的任务是同一种东西。确认在**他打开这个开关的那一刻**:开关的说明里写明了会在
/// 后台请模型看一眼目标的进展、内容会发给模型服务——所以到点直接排队,不再弹卡。目标的内容写进
/// brief 里:后台助手不带主窗口,它只知道 brief 里有什么。放下一个月不动的目标不问:那是纠缠不是关心。
enum GoalDigest {
    static let interval: TimeInterval = 7 * 86_400
    static let staleAfter: TimeInterval = 30 * 86_400

    static func due(_ goals: [TaskItem], now: Date) -> [TaskItem] {
        goals.filter { goal in
            guard goal.kind == .goal, goal.status == .running, goal.digestEnabled else { return false }
            guard now.timeIntervalSince(goal.updatedAt) < staleAfter || goal.lastDigestAt == nil else { return false }
            let since = goal.lastDigestAt ?? goal.createdAt
            return now.timeIntervalSince(since) >= interval
        }
    }

    static func brief(_ goal: TaskItem, now: Date) -> String {
        var lines = [
            "回顾一个用户正在推进的目标，写三四句话：这段时间做了什么、卡在哪、下周建议他做的一个小步。不要空洞的鼓励，不要重复他已经知道的。",
            "",
            "目标：\(goal.title)"
        ]
        if !goal.why.isEmpty { lines.append("原因：\(goal.why)") }
        if !goal.plan.isEmpty {
            lines.append("步骤：")
            lines += goal.plan.map { "- [\($0.done ? "x" : " ")] \($0.text)" }
        }
        let recent = goal.notes.suffix(6)
        if !recent.isEmpty {
            lines.append("最近的进展记录：")
            lines += recent.map { "- \($0.text)" }
        }
        let day = { (date: Date) in date.formatted(.iso8601.year().month().day()) }
        lines.append("开始于：\(day(goal.createdAt))，现在是 \(day(now))。")
        lines.append("可以用记忆和过往对话补充背景。如果建议他设一个提醒或加一个步骤，用 \(SubagentTools.proposeToolName) 提议。")
        return String(lines.joined(separator: "\n").prefix(SubagentLimits.maxBriefCharacters))
    }

    /// 到点的目标各排一件回顾任务。受排队和每日次数的限制,超了这次就先不排(下次打开再看)。
    static func enqueueDue(store: TaskStore, now: Date) async {
        for goal in due(await store.all(), now: now) {
            guard SubagentLimits.problem(await store.all(), now: now) == nil else { return }
            var job = TaskItem(kind: .job, title: String("本周回顾：\(goal.title)".prefix(TasksTools.maxTitleCharacters)), status: .queued, createdAt: now)
            job.brief = brief(goal, now: now)
            await store.add(job)
            await store.update(goal.id, now: now) { $0.lastDigestAt = now }
        }
    }
}

/// `JobControls` 在 iOS 上的接线:碰调度器、设置和当前成员的存储。界面(确认卡、任务页)和
/// `start_task` 工具都经它。
@MainActor
@Observable
final class AppJobControls: JobControls {
    static let shared = AppJobControls()

    /// 用户点了「开始」,但还没同意把数据发给当前这家模型服务:先点名征同意,同意了再开始。
    struct PendingConsent: Equatable {
        let taskId: UUID
        let providerId: String
    }

    private(set) var pendingConsent: PendingConsent?

    nonisolated var autoStart: Bool { EngineSettings.autoStartTasks }

    func start(_ taskId: UUID) async {
        let tenant = TenantScope.current
        let store = TenantScope.currentStores.tasks
        guard let task = await store.get(taskId), task.kind == .job,
              ![.queued, .running, .done].contains(task.status) else { return }

        switch SubagentScheduler.check() {
        case .ready:
            break
        case .notConfigured:
            await store.update(taskId) { $0.error = String(localized: "还没配置云端模型，先到设置里填好。") }
            return
        case .needsConsent(let provider):
            pendingConsent = PendingConsent(taskId: taskId, providerId: provider)
            return
        }
        if let problem = SubagentLimits.problem(await store.all(), now: Date()) {
            await store.update(taskId) { $0.error = problem }
            return
        }
        await store.update(taskId) {
            $0.status = .queued
            $0.error = nil
        }
        await SubagentScheduler.shared.kick(tenant)
    }

    /// 他在点名确认的 alert 上同意了:记下来,把刚才那件开始。
    func confirmConsent() {
        guard let pending = pendingConsent else { return }
        ProviderConsent.record(pending.providerId)
        pendingConsent = nil
        Task { await start(pending.taskId) }
    }

    func declineConsent() {
        pendingConsent = nil
    }

    func stop(_ taskId: UUID) {
        Task { await SubagentScheduler.shared.stop(TenantScope.current, taskId) }
    }

    func dismiss(_ taskId: UUID) {
        Task {
            await TenantScope.currentStores.tasks.update(taskId) {
                if $0.status == .proposed { $0.status = .cancelled }
            }
        }
    }

    func decide(_ taskId: UUID, proposalId: UUID, accept: Bool) {
        Task {
            let stores = TenantScope.currentStores
            let env = TasksEnvironment(store: stores.tasks, tenantId: TenantScope.current.id)
            if let problem = await TaskActions.decide(
                env,
                memory: EngineSettings.memoryEnabled ? stores.memory : nil,
                taskId: taskId,
                proposalId: proposalId,
                accept: accept
            ) {
                await stores.tasks.update(taskId) { $0.error = String(localized: "有一条没能照做：\(problem)") }
            }
        }
    }
}
