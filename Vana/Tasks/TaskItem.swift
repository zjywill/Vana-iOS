import Foundation

/// 一件「要做的事」。三种 kind 共用一个形状(同 Android 的 `Task`):
///
/// - `.reminder`:到点发一条本地通知,**到点不调模型**。
/// - `.goal`:用户自己长期在做的一件事(备半马、学吉他)。取代原来的「目标线」会话。
/// - `.job`:交给后台助手(子 agent)在隔离上下文里做的一件独立的事。
///
/// 叫 `TaskItem` 不叫 `Task`:后者是 Swift 并发里的那个类型,撞名只会让每一处 `Task { }` 都要
/// 写成 `_Concurrency.Task`。
struct TaskItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case job
        case goal
        case reminder
    }

    /// 三种任务共用一组状态,各取其中几个:
    /// - reminder:`.queued`(等着到点)→ `.done`(响过了)/ `.cancelled`;
    /// - goal:`.running`(进行中)→ `.done` / `.cancelled`;
    /// - job:`.proposed`(等用户点确认)→ `.queued` → `.running` → `.done` / `.failed` / `.cancelled`。
    enum Status: String, Codable, Sendable {
        case proposed
        case queued
        case running
        case needsYou
        case done
        case failed
        case cancelled

        var isActive: Bool { [.proposed, .queued, .running, .needsYou].contains(self) }
    }

    enum Repeat: String, Codable, Sendable, CaseIterable {
        case none
        case daily
        case weekly
    }

    struct PlanItem: Identifiable, Codable, Equatable, Sendable {
        var id = UUID()
        var text: String
        var done = false
    }

    /// 目标上的一条进展记录。
    struct Note: Codable, Equatable, Sendable {
        var at: Date
        var text: String
    }

    /// 后台任务的审计轨迹:每一步做了什么(工具名、参数摘要)。
    struct Step: Codable, Equatable, Sendable {
        var at: Date
        var label: String
        var detail: String?
    }

    /// 后台助手只读、不能写盘,想做的写操作只能「提议」,由用户点了才执行。
    struct Proposal: Identifiable, Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            case pending
            case accepted
            case dismissed
        }

        var id = UUID()
        /// `reminder` / `goal` / `memory`。
        var kind: String
        var text: String
        /// `reminder` 提议要用的时间。
        var at: Date?
        var why: String?
        var status: Status = .pending
    }

    struct Result: Codable, Equatable, Sendable {
        /// 一两句结论。它同时作为一条主动消息进对话窗口,模型看得到。
        var summary: String
        var body = ""
        var proposals: [Proposal] = []
        var sources: [String] = []
    }

    var id = UUID()
    var kind: Kind
    var title: String
    var status: Status
    var createdAt = Date()
    var updatedAt = Date()

    // MARK: job
    /// 交给后台助手的说明。必须自足:它不带主窗口。
    var brief = ""
    var result: Result?
    var steps: [Step] = []
    var tokensUsed = 0
    var error: String?
    /// 最近一次开跑的时间。「今天跑了几次」按它数。
    var startedAt: Date?
    /// 开跑过几次(含被系统打断后自动接着跑的那一次)。
    var attempts = 0

    // MARK: reminder
    var dueAt: Date?
    var repeatRule: Repeat = .none

    // MARK: goal
    var why = ""
    var plan: [PlanItem] = []
    var notes: [Note] = []
    /// 目标的「每周回顾」。用户在目标上**主动打开**才有——那一下就是同意。
    var digestEnabled = false
    var lastDigestAt: Date?

    var isActive: Bool { status.isActive }

    /// 短编号:给模型和用户指到某一条用。
    var handle: String { String(id.uuidString.prefix(Self.handleLength)).lowercased() }
    static let handleLength = 8

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, status, createdAt, updatedAt, brief, result, steps, tokensUsed, error, startedAt, attempts
        case dueAt, repeatRule = "repeat", why, plan, notes, digestEnabled, lastDigestAt
    }

    init(kind: Kind, title: String, status: Status, createdAt: Date = Date()) {
        self.kind = kind
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// 宽容解码:后加的字段缺了用默认值,认不得的 kind/status 整条交给 `TaskStore` 原样留着。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(Kind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(Status.self, forKey: .status)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        brief = try c.decodeIfPresent(String.self, forKey: .brief) ?? ""
        result = try c.decodeIfPresent(Result.self, forKey: .result)
        steps = try c.decodeIfPresent([Step].self, forKey: .steps) ?? []
        tokensUsed = try c.decodeIfPresent(Int.self, forKey: .tokensUsed) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        repeatRule = try c.decodeIfPresent(Repeat.self, forKey: .repeatRule) ?? .none
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        plan = try c.decodeIfPresent([PlanItem].self, forKey: .plan) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
        digestEnabled = try c.decodeIfPresent(Bool.self, forKey: .digestEnabled) ?? false
        lastDigestAt = try c.decodeIfPresent(Date.self, forKey: .lastDigestAt)
    }

    var planProgress: String {
        plan.isEmpty ? "还没有步骤" : "步骤 \(plan.count(where: \.done))/\(plan.count)"
    }
}

extension TaskItem.Status {
    /// 给模型看的标签,固定中文。
    var promptLabel: String {
        switch self {
        case .proposed: "等你确认"
        case .queued: "排队中"
        case .running: "进行中"
        case .needsYou: "需要你"
        case .done: "已完成"
        case .failed: "失败了"
        case .cancelled: "已取消"
        }
    }

    /// 界面上的标签,跟界面语言走。
    var label: String {
        switch self {
        case .proposed: String(localized: "等你确认")
        case .queued: String(localized: "排队中")
        case .running: String(localized: "进行中")
        case .needsYou: String(localized: "需要你")
        case .done: String(localized: "已完成")
        case .failed: String(localized: "失败了")
        case .cancelled: String(localized: "已取消")
        }
    }
}
