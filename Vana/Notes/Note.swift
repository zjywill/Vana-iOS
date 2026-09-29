import Foundation

/// 用户自己的内容。和记忆的分工:**记忆是关于他这个人的事实、常驻在上下文里;笔记是他要留着的
/// 东西、按需读写、不常驻**——购物单不该占着每一次对话的 system 段,也不该被当成「关于他的事」
/// 抽进记忆。
struct Note: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// 一段文字:想法、草稿、要抄的一段话。
        case note
        /// 一张清单:购物单、行李单,逐条能勾。
        case list
    }

    struct Item: Codable, Identifiable, Sendable, Equatable {
        var id = UUID()
        var text: String
        var done = false
    }

    static let handleLength = 8
    static let maxNotes = 100
    static let maxTitle = 60
    static let maxBody = 8000
    static let maxItems = 100
    static let maxItemCharacters = 120

    var id = UUID()
    var kind: Kind
    var title: String
    var body = ""
    var items: [Item] = []
    var createdAt = Date()
    var updatedAt = Date()

    /// 短编号:给模型和用户指到某一条用。
    var handle: String { String(id.uuidString.lowercased().prefix(Self.handleLength)) }

    /// 列表里第二行的字:一段话的开头,或清单的进度。
    var preview: String {
        switch kind {
        case .note:
            let line = body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map { String($0.trimmingCharacters(in: .whitespaces).prefix(60)) } ?? ""
        case .list:
            return items.isEmpty ? "" : "\(items.filter(\.done).count)/\(items.count)"
        }
    }

    /// 给模型的类别词。固定中文,和别的工具输出一样。
    var kindWord: String { kind == .list ? "清单" : "笔记" }

    init(kind: Kind, title: String, body: String = "", items: [Item] = [], now: Date = Date()) {
        self.kind = kind
        self.title = title
        self.body = body
        self.items = items
        createdAt = now
        updatedAt = now
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
    }
}
