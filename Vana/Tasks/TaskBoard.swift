import Foundation

/// 界面手里那一份任务表。任务页、详情页、对话里那张确认卡读的都是它。
///
/// `TaskStore` 是 actor,界面要的是一个同步可读、会自己刷新的值:盘上一写(工具、后台助手、到点
/// 的提醒),这里跟着重读一遍。一个成员一份,跟着 `ChatViewModel` 走(切成员时整个换掉)。
@MainActor
@Observable
final class TaskBoard {
    let store: TaskStore
    let tenantId: UUID
    private(set) var tasks: [TaskItem] = []
    private var observer: (any NSObjectProtocol)?

    init(store: TaskStore, tenantId: UUID) {
        self.store = store
        self.tenantId = tenantId
        let file = store.fileURL
        observer = NotificationCenter.default.addObserver(
            forName: .vanaTasksDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard (note.object as? URL) == file else { return }
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    isolated deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func reload() {
        Task { tasks = await store.all() }
    }

    func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }

    var environment: TasksEnvironment {
        TasksEnvironment(store: store, tenantId: tenantId)
    }

    func active(_ kind: TaskItem.Kind) -> [TaskItem] {
        tasks.filter { $0.kind == kind && $0.isActive }
            .sorted { ($0.dueAt ?? $0.createdAt) < ($1.dueAt ?? $1.createdAt) }
    }

    /// 最近完成、取消、失败的那几件。
    var recentlyFinished: [TaskItem] {
        Array(tasks.filter { !$0.isActive }.sorted { $0.updatedAt > $1.updatedAt }.prefix(20))
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}
