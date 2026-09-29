import Foundation
import AgentRuntime

extension Notification.Name {
    /// 某位成员的 `notes.json` 刚写过。`object` 是那个文件的 URL。
    static let vanaNotesDidChange = Notification.Name("vanaNotesDidChange")
}

/// 每个成员一份 `notes.json`。读写的稳妥度和 `TaskStore`、`MemoryStore` 一致:逐条解码、
/// 读不懂的原样留着、整份读不出来先备份、原子写。
actor NoteStore {
    static let fileName = "notes.json"

    static var shared: NoteStore { TenantScope.currentStores.notes }

    let fileURL: URL
    private let backupURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cached: [Note]?
    private var foreign: [RuntimeJSONValue] = []

    init(directory: URL) {
        fileURL = directory.appending(path: Self.fileName, directoryHint: .notDirectory)
        backupURL = directory.appending(path: "\(Self.fileName).bak", directoryHint: .notDirectory)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    /// 最近动过的在前。
    func all() -> [Note] { loaded().sorted { $0.updatedAt > $1.updatedAt } }

    func get(_ id: UUID) -> Note? { loaded().first { $0.id == id } }

    /// 按完整 id 或短编号(前缀)找。前缀不唯一时返回 nil——宁可找不到,也别动错一条。
    func find(_ idOrHandle: String) -> Note? {
        let key = idOrHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        let notes = loaded()
        if let exact = notes.first(where: { $0.id.uuidString.lowercased() == key }) { return exact }
        let matches = notes.filter { $0.id.uuidString.lowercased().hasPrefix(key) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// 到上限时返回 nil,由调用方告诉用户先清理。
    func add(_ note: Note) -> Note? {
        var notes = loaded()
        guard notes.count < Note.maxNotes else { return nil }
        notes.append(note)
        write(notes)
        return note
    }

    @discardableResult
    func update(_ id: UUID, now: Date = Date(), _ transform: @Sendable (inout Note) -> Void) -> Note? {
        var notes = loaded()
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        transform(&notes[index])
        notes[index].id = id
        notes[index].updatedAt = now
        write(notes)
        return notes[index]
    }

    /// 只有界面调。模型那边没有删除工具。
    @discardableResult
    func delete(_ id: UUID) -> Bool {
        var notes = loaded()
        guard notes.contains(where: { $0.id == id }) else { return false }
        notes.removeAll { $0.id == id }
        write(notes)
        return true
    }

    func removeAll() {
        foreign = []
        write([])
    }

    private func loaded() -> [Note] {
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
        var notes: [Note] = []
        foreign = []
        for element in elements {
            if let encoded = try? JSONEncoder().encode(element), let note = try? decoder.decode(Note.self, from: encoded) {
                notes.append(note)
            } else {
                foreign.append(element)
            }
        }
        cached = notes
        return notes
    }

    private func write(_ notes: [Note]) {
        cached = notes
        var elements: [RuntimeJSONValue] = []
        for note in notes {
            if let data = try? encoder.encode(note), let value = try? JSONDecoder().decode(RuntimeJSONValue.self, from: data) {
                elements.append(value)
            }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(elements + foreign) {
            try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        NotificationCenter.default.post(name: .vanaNotesDidChange, object: fileURL)
    }
}
