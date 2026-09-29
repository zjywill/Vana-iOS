import Foundation
import AgentRuntime

extension Notification.Name {
    /// 某位成员的 `tasks.json` 刚写过。任务页、「今天」、顶栏角标据此重读。`object` 是那个文件的 URL。
    static let vanaTasksDidChange = Notification.Name("vanaTasksDidChange")
}

/// 每个成员一份 `tasks.json`:提醒、目标、后台任务。
///
/// 和 `MemoryStore` 同一套稳妥的读法:**逐条**解码,本版本读不懂的条目(更新版本写下的新种类、
/// 坏掉的一条)原样留在文件里、不会在下一次保存时被悄悄丢掉;整份读不出来时先备份再往下走。
/// 写入是原子的。
actor TaskStore {
    static let fileName = "tasks.json"

    static var shared: TaskStore { TenantScope.currentStores.tasks }

    let fileURL: URL
    private let backupURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cached: [TaskItem]?
    private var foreign: [RuntimeJSONValue] = []

    init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        backupURL = directory.appending(path: "\(Self.fileName).bak", directoryHint: .notDirectory)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - 读

    func all() -> [TaskItem] { loaded().sorted { $0.createdAt < $1.createdAt } }

    func active() -> [TaskItem] { all().filter(\.isActive) }

    func get(_ id: UUID) -> TaskItem? { loaded().first { $0.id == id } }

    /// 按完整 id 或短编号(前缀)找。前缀不唯一时返回 nil——宁可找不到,也别动错一条。
    func find(_ idOrHandle: String) -> TaskItem? {
        let key = idOrHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let tasks = loaded()
        if let exact = tasks.first(where: { $0.id.uuidString.lowercased() == key }) { return exact }
        let matches = tasks.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        return matches.count == 1 ? matches[0] : nil
    }

    // MARK: - 写

    @discardableResult
    func add(_ task: TaskItem) -> TaskItem {
        var tasks = loaded()
        tasks.append(task)
        write(tasks)
        return task
    }

    @discardableResult
    func update(_ id: UUID, now: Date = Date(), _ transform: @Sendable (inout TaskItem) -> Void) -> TaskItem? {
        var tasks = loaded()
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return nil }
        transform(&tasks[index])
        tasks[index].id = id
        tasks[index].updatedAt = now
        write(tasks)
        return tasks[index]
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        var tasks = loaded()
        guard tasks.contains(where: { $0.id == id }) else { return false }
        tasks.removeAll { $0.id == id }
        write(tasks)
        return true
    }

    func removeAll() {
        foreign = []
        write([])
    }

    // MARK: - 盘

    private func loaded() -> [TaskItem] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL) else {
            cached = []
            return []
        }
        guard let elements = try? decoder.decode([RuntimeJSONValue].self, from: data) else {
            if !FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)) {
                try? FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            cached = []
            return []
        }
        var tasks: [TaskItem] = []
        foreign = []
        for element in elements {
            if let encoded = try? JSONEncoder().encode(element), let task = try? decoder.decode(TaskItem.self, from: encoded) {
                tasks.append(task)
            } else {
                foreign.append(element)
            }
        }
        cached = tasks
        return tasks
    }

    private func write(_ tasks: [TaskItem]) {
        cached = tasks
        var elements: [RuntimeJSONValue] = []
        for task in tasks {
            if let data = try? encoder.encode(task), let value = try? JSONDecoder().decode(RuntimeJSONValue.self, from: data) {
                elements.append(value)
            }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(elements + foreign) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        NotificationCenter.default.post(name: .vanaTasksDidChange, object: fileURL)
    }
}
