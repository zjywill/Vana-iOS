import Foundation

/// 一件「要做的事」。两种 kind 共用一个形状(同 Android 的 `Task`):
///
/// - `.reminder`:到点发一条本地通知,**到点不调模型**。
/// - `.goal`:用户自己长期在做的一件事(备半马、学吉他)。取代原来的「目标线」会话。
///
/// 以前还有第三种 `.job`(交给后台助手的事),2026-09-30 连同子 agent 一起撤掉了——独立的活由
/// 用户自己开的侧聊来做。盘上留下来的那几条认不出 kind,由 `TaskStore` 原样留着、不再显示。
///
/// 叫 `TaskItem` 不叫 `Task`:后者是 Swift 并发里的那个类型,撞名只会让每一处 `Task { }` 都要
/// 写成 `_Concurrency.Task`。
struct TaskItem: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case goal
        case reminder
    }

    /// 两种共用一组状态,各取其中几个:
    /// - reminder:`.queued`(等着到点)→ `.done`(响过了)/ `.cancelled`;
    /// - goal:`.running`(进行中)→ `.done` / `.cancelled`。
    enum Status: String, Codable, Sendable {
        case queued
        case running
        case done
        case cancelled

        var isActive: Bool { [.queued, .running].contains(self) }
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

    var id = UUID()
    var kind: Kind
    var title: String
    var status: Status
    var createdAt = Date()
    var updatedAt = Date()

    // MARK: reminder
    var dueAt: Date?
    var repeatRule: Repeat = .none

    // MARK: goal
    var why = ""
    var plan: [PlanItem] = []
    var notes: [Note] = []

    var isActive: Bool { status.isActive }

    /// 短编号:给模型和用户指到某一条用。
    var handle: String { String(id.uuidString.prefix(Self.handleLength)).lowercased() }
    static let handleLength = 8

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, status, createdAt, updatedAt
        case dueAt, repeatRule = "repeat", why, plan, notes
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
        dueAt = try c.decodeIfPresent(Date.self, forKey: .dueAt)
        repeatRule = try c.decodeIfPresent(Repeat.self, forKey: .repeatRule) ?? .none
        why = try c.decodeIfPresent(String.self, forKey: .why) ?? ""
        plan = try c.decodeIfPresent([PlanItem].self, forKey: .plan) ?? []
        notes = try c.decodeIfPresent([Note].self, forKey: .notes) ?? []
    }

    var planProgress: String {
        plan.isEmpty ? "还没有步骤" : "步骤 \(plan.count(where: \.done))/\(plan.count)"
    }
}

extension TaskItem.Status {
    /// 给模型看的标签,固定中文。
    var promptLabel: String {
        switch self {
        case .queued: "还没到点"
        case .running: "进行中"
        case .done: "已完成"
        case .cancelled: "已取消"
        }
    }

    /// 界面上的标签,跟界面语言走。
    var label: String {
        switch self {
        case .queued: String(localized: "还没到点")
        case .running: String(localized: "进行中")
        case .done: String(localized: "已完成")
        case .cancelled: String(localized: "已取消")
        }
    }
}
