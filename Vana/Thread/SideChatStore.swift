import Foundation
import Synchronization
import AgentRuntime

extension Notification.Name {
    /// 某位成员的侧聊名单变了(新建、改名、删、有人在里面说了话)。`object` 是那位成员的
    /// `sides/` 目录。
    static let vanaSideChatsDidChange = Notification.Name("vanaSideChatsDidChange")
}

/// 一条侧聊:用户从主对话旁边单独拿出来聊的一件事。
///
/// 名单上只记这几样;对话本身是一条和主对话**同一格式**的线程(`ThreadStore`),换了个目录而已。
struct SideChat: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    /// 他起的名字。留空时是 ""——拿第一句话自动起一个(`autoTitled`),之后他能改。
    var title: String
    /// 名字还没被他定过:第一句带字的话会拿来起名。他改过一次就是 false,再也不替他改。
    var autoTitled: Bool
    var createdAt: Date
    var lastActiveAt: Date

    init(id: UUID = UUID(), title: String, now: Date = Date()) {
        self.id = id
        let trimmed = SideChatTitle.clean(title)
        self.title = trimmed
        autoTitled = trimmed.isEmpty
        createdAt = now
        lastActiveAt = now
    }

    /// 界面上显示的名字。还没起名的叫「新侧聊」。
    var displayTitle: String {
        title.isEmpty ? String(localized: "新侧聊") : title
    }
}

/// 侧聊的名字怎么来。纯函数。
enum SideChatTitle {
    /// 拿第一句话起名时最多取多少个字。再长就是一句话了,列表上一行放不下,标题栏也放不下。
    static let maxLength = 20
    /// 他自己起的名字最长多少个字符。比自动起名宽一倍:这是他特意打的,而同样一个名字英文要比
    /// 中文长两三倍(「十月去京都」是五个字,「Kyoto in October」是十六个字符)——按中文的
    /// 上限截,英文名字会被切掉半个词(踩过)。
    static let maxTypedLength = 40

    /// 他自己起的名字:去掉首尾空白、换行压成空格、截到上限。
    static func clean(_ raw: String) -> String {
        let flattened = raw
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(flattened.prefix(maxTypedLength))
    }

    /// 拿第一句话起名:只取第一行,太长就截断加省略号。一个字都没有(只发了照片)返回 nil,
    /// 等下一句带字的。
    static func make(from text: String) -> String? {
        let firstLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        guard let firstLine else { return nil }
        guard firstLine.count > maxLength else { return firstLine }
        return String(firstLine.prefix(maxLength - 1)) + "…"
    }
}

/// 每个成员一个 `sides/` 目录:
///
/// ```
/// <tenantRoot>/sides/
///   index.json      名单:[{id, title, autoTitled, createdAt, lastActiveAt}]
///   <uuid>/         和 thread/ 同一格式:seg-*.jsonl + meta.json(窗口游标、收割水位线)
/// ```
///
/// **线程格式一个字不改**:`ThreadStore` 换个目录就是侧聊,窗口、收割、召回全部原样。照片照旧
/// 放在成员的 `attachments/` 里。
///
/// 名单的读法和 `NoteStore`、`TaskStore` 一样稳妥:逐条解码、读不懂的原样留着、整份读不出来先
/// 备份、原子写。
actor SideChatStore {
    static let directoryName = "sides"
    static let indexName = "index.json"

    nonisolated let directory: URL
    private let indexURL: URL
    private let backupURL: URL
    private let attachments: AttachmentStore?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var cached: [SideChat]?
    private var foreign: [RuntimeJSONValue] = []
    /// 名单这一回是读懂了的。整份读不出来时(已经备份成 `.bak`)**不许**清孤儿目录:
    /// 那时候每一个目录看起来都是孤儿。
    private var indexIsTrustworthy = false
    private var didSweep = false

    /// 每条侧聊**一个** `ThreadStore` 实例。它是那条线程的单写者:同一个目录上有两个实例,
    /// 就是两个写者,位置和已删的记账会各记各的。放在锁里而不是 actor 里,是因为界面要**同步**
    /// 拿到它(`ChatViewModel` 一造出来就要知道自己读哪个目录)。
    private nonisolated let threads = Mutex<[UUID: ThreadStore]>([:])

    /// 每个 `sides/` 目录一个实例,理由同 `thread(for:)`:同一个目录上两个实例,就是两份各记各的
    /// 名单缓存、两个各自的线程写者。
    private static let instances = Mutex<[String: SideChatStore]>([:])

    /// 这个目录的那一个实例。成员那一套 store(`TenantStores`)从这里拿。
    static func instance(directory: URL, attachments: AttachmentStore?) -> SideChatStore {
        let key = directory.standardizedFileURL.path(percentEncoded: false)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return instances.withLock { cache in
            if let existing = cache[key] { return existing }
            let store = SideChatStore(directory: directory, attachments: attachments)
            cache[key] = store
            return store
        }
    }

    /// 某条主对话线程旁边的那份名单(`<成员>/thread` 旁边的 `<成员>/sides`)。
    ///
    /// `ChatViewModel` 没被告知用哪份名单时从它手里的线程推出来:测试传进来的是临时目录里的线程,
    /// 推出来的也就是临时目录里的名单——碰不到模拟器上那份真的(「清空全部对话」连侧聊一起清,
    /// 默认值要是指着 `TenantScope.currentStores`,一条测试就能把真的侧聊全删了)。
    static func beside(_ thread: ThreadStore) -> SideChatStore {
        instance(
            directory: thread.directory.deletingLastPathComponent()
                .appending(path: directoryName, directoryHint: .isDirectory),
            attachments: nil
        )
    }

    init(directory: URL, attachments: AttachmentStore? = nil) {
        self.directory = directory
        self.attachments = attachments
        indexURL = directory.appending(path: Self.indexName, directoryHint: .notDirectory)
        backupURL = directory.appending(path: "\(Self.indexName).bak", directoryHint: .notDirectory)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - 线程

    /// 这条侧聊的线程。同一条永远拿到同一个实例。
    nonisolated func thread(for id: UUID) -> ThreadStore {
        threads.withLock { cache in
            if let existing = cache[id] { return existing }
            let store = ThreadStore(
                directory: directory.appending(path: id.uuidString, directoryHint: .isDirectory),
                attachments: attachments
            )
            cache[id] = store
            return store
        }
    }

    /// 名单上每一条的线程,最近说过话的在前。收割和「对话历史」用。
    func allThreads() async -> [ThreadStore] {
        await all().map { thread(for: $0.id) }
    }

    // MARK: - 名单

    /// 最近说过话的在前。
    func all() async -> [SideChat] {
        let chats = loaded()
        await sweepOrphansIfNeeded()
        return chats.sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    func get(_ id: UUID) -> SideChat? {
        loaded().first { $0.id == id }
    }

    @discardableResult
    func create(title: String, now: Date = Date()) -> SideChat {
        let chat = SideChat(title: title, now: now)
        write(loaded() + [chat])
        return chat
    }

    /// 他改了名字。从此不再替他起名;改成空的就退回「新侧聊」,也不再自动起名——他清空它是
    /// 一个明确的动作。
    @discardableResult
    func rename(_ id: UUID, to title: String) -> SideChat? {
        update(id) {
            $0.title = SideChatTitle.clean(title)
            $0.autoTitled = false
        }
    }

    /// 在里面说了一句话。名单按这个排;还没起名的顺手拿这句话起名。
    @discardableResult
    func noteActivity(_ id: UUID, text: String, now: Date = Date()) -> SideChat? {
        update(id) { chat in
            chat.lastActiveAt = now
            if chat.autoTitled, let title = SideChatTitle.make(from: text) {
                chat.title = title
                chat.autoTitled = false
            }
        }
    }

    // MARK: - 删

    /// 删掉一条侧聊,连同它的照片。
    ///
    /// **顺序是先落名单,再清线程,最后删目录。** 反过来的话,删到一半崩了,名单上留着一条点进去
    /// 是空的侧聊;按这个顺序最坏只剩一个不在名单上的目录,下次启动时清掉(`sweepOrphansIfNeeded`)。
    func delete(_ id: UUID) async {
        var chats = loaded()
        guard chats.contains(where: { $0.id == id }) else { return }
        chats.removeAll { $0.id == id }
        write(chats)
        await removeThread(id)
    }

    /// 清空全部侧聊。设置 › 对话历史用。
    func deleteAll() async {
        let ids = loaded().map(\.id)
        write([])
        for id in ids { await removeThread(id) }
    }

    /// 清掉 `cutoff` 之前的消息,返回清了多少条。**整条都在那之前的侧聊连名单一起删**:
    /// 留下一个名字、点进去什么都没有,只会让他以为是出了错。
    @discardableResult
    func deleteOlderThan(_ cutoff: Date) async -> Int {
        var removed = 0
        for chat in loaded() {
            let store = thread(for: chat.id)
            removed += await store.deleteOlderThan(cutoff)
            if chat.lastActiveAt < cutoff { await delete(chat.id) }
        }
        return removed
    }

    /// 所有侧聊在盘上一共占多少字节。
    func sizeBytes() async -> Int {
        var total = 0
        for chat in loaded() { total += await thread(for: chat.id).sizeBytes() }
        return total
    }

    private func removeThread(_ id: UUID) async {
        let store = thread(for: id)
        await store.deleteAll()
        try? FileManager.default.removeItem(at: store.directory)
        _ = threads.withLock { $0.removeValue(forKey: id) }
    }

    /// 名单上没有的目录:删到一半崩了留下的。**只在名单读懂了的时候清**,读不懂的那几条
    /// (`foreign`)的目录也放过——那是还没被理解的数据,不是垃圾。
    private func sweepOrphansIfNeeded() async {
        guard !didSweep else { return }
        didSweep = true
        guard indexIsTrustworthy else { return }
        var known = Set(loaded().map(\.id.uuidString))
        for element in foreign {
            if case .object(let fields) = element, case .string(let id)? = fields["id"] {
                known.insert(id)
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        for name in names {
            guard let id = UUID(uuidString: name), !known.contains(id.uuidString) else { continue }
            await removeThread(id)
        }
    }

    // MARK: - 读写

    private func update(_ id: UUID, _ transform: (inout SideChat) -> Void) -> SideChat? {
        var chats = loaded()
        guard let index = chats.firstIndex(where: { $0.id == id }) else { return nil }
        transform(&chats[index])
        chats[index].id = id
        write(chats)
        return chats[index]
    }

    private func loaded() -> [SideChat] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: indexURL) else {
            // 没有名单文件:还一条侧聊都没建过。目录里要是有东西,那不是这份代码写的,别碰。
            cached = []
            indexIsTrustworthy = false
            return []
        }
        guard let elements = try? decoder.decode([RuntimeJSONValue].self, from: data) else {
            if !FileManager.default.fileExists(atPath: backupURL.path(percentEncoded: false)) {
                try? FileManager.default.copyItem(at: indexURL, to: backupURL)
            }
            cached = []
            indexIsTrustworthy = false
            return []
        }
        var chats: [SideChat] = []
        foreign = []
        for element in elements {
            if let encoded = try? JSONEncoder().encode(element), let chat = try? decoder.decode(SideChat.self, from: encoded) {
                chats.append(chat)
            } else {
                foreign.append(element)
            }
        }
        cached = chats
        indexIsTrustworthy = true
        return chats
    }

    private func write(_ chats: [SideChat]) {
        cached = chats
        var elements: [RuntimeJSONValue] = []
        for chat in chats {
            if let data = try? encoder.encode(chat), let value = try? JSONDecoder().decode(RuntimeJSONValue.self, from: data) {
                elements.append(value)
            }
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(elements + foreign) {
            try? data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            indexIsTrustworthy = true
        }
        NotificationCenter.default.post(name: .vanaSideChatsDidChange, object: directory)
    }
}
