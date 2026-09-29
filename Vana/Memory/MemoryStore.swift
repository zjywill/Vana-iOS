import Foundation
import AgentRuntime

/// 记忆持久化:`Documents/memory.json`,一个文件装下全部。
///
/// 没做索引层,也不打算做。Claude Code 那种「索引 + 按需读」是为了几百条记忆装不进上下文
/// 而存在的,代价是漏召回——索引说有、模型没去读。这里的记忆对象只有一个人,全部加起来几十
/// 条、一两千 token,**全量进 system 段**最简单也最可靠,加个硬上限就够了。
actor MemoryStore {
    /// 当前那位成员的记忆(同 `SessionStore.shared`)。「关于这位用户」在多成员之后就是
    /// 「关于这位成员」——妈妈的忌口和机主的作息本来就不该在一个文件里。
    static var shared: MemoryStore { TenantScope.currentStores.memory }

    /// 上限存在的意义是「别让 system 段慢慢长成一篇作文」,不是省那点存储。
    /// 两个都卡:条数管住列表长度,字数管住有人写小作文。
    static let maxItems = 40
    static let maxCharacters = 2_000
    /// 待跟进到期之后再留几天。
    ///
    /// 到期那一刻正是它要派上用场的时候(进 check-in、进 system 段),当场删掉等于永远
    /// 用不上。留三天,够早上那条通知说到它,又不至于变成一条赖着不走的旧提醒。
    static let followUpGrace: TimeInterval = 3 * 86_400

    private let fileURL: URL
    private let backupURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    /// 读盘结果留在 actor 里。每轮都去解一次 JSON 没必要,而所有写入都从这里过,
    /// 缓存不会和文件漂移。
    private var cached: [MemoryItem]?
    /// 本版本认不得的条目(更新版本写下的新种类、损坏的一条)。原样留着,下次写盘时一并写回去——
    /// 读不懂不是删掉它的理由。
    private var foreign: [RuntimeJSONValue] = []

    init(directory: URL = URL.documentsDirectory) {
        fileURL = directory.appending(path: "memory.json", directoryHint: .notDirectory)
        backupURL = directory.appending(path: "memory.json.bak", directoryHint: .notDirectory)
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - 读

    func snapshot(now: Date = Date()) -> MemorySnapshot {
        MemorySnapshot(items: items(now: now))
    }

    /// 早就过了宽限期的在读的时候滤掉,但不为此单独写一次盘——下一次真正的写入会把它
    /// 带走。为了删一条旧记忆去动文件,是拿一次 I/O 换一件没人看得见的事。
    func items(now: Date = Date()) -> [MemoryItem] {
        loaded().filter { !$0.hasExpired(at: now) }
    }

    // MARK: - 用户手改 / 对话里明确要求

    /// 用户自己加的,或者对话里让 Vana 记的。两种都 `pinned`——他开口说了的东西,
    /// 不该被后台的抽取悄悄改掉或挤掉。
    @discardableResult
    func add(
        kind: MemoryKind,
        text: String,
        origin: MemoryItem.Origin = .manual,
        dueAt: Date? = nil,
        sourceSessionId: UUID? = nil
    ) throws -> [MemoryItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items() }
        var all = loaded()
        all.append(MemoryItem(
            kind: kind,
            text: trimmed,
            origin: origin,
            sourceSessionId: sourceSessionId,
            dueAt: kind.expires ? dueAt : nil
        ))
        return try persist(all)
    }

    /// 对话里当场记一条(`remember`)。返回真的落下的那一条;容量满了被挤掉就是 nil,
    /// 那种情况下不能回「已记住」。
    func remember(
        kind: MemoryKind,
        text: String,
        days: Int? = nil,
        now: Date = Date()
    ) throws -> MemoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = MemoryItem(
            kind: kind,
            text: trimmed,
            createdAt: now,
            updatedAt: now,
            origin: .asked,
            dueAt: MemoryItem.dueDate(kind: kind, days: days, now: now)
        )
        var all = loaded()
        all.append(item)
        return try persist(all, now: now).first { $0.id == item.id }
    }

    /// 用户在对话里纠正了一条(`revise_memory`)。后台抽出来的条目被他当面改过,就成了他说的话:
    /// 从此受保护,不再被抽取器改回去。
    @discardableResult
    func revise(id: UUID, text: String, now: Date = Date()) throws -> MemoryItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var all = loaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return nil }
        all[index].text = trimmed
        all[index].updatedAt = now
        if all[index].origin == .extracted { all[index].origin = .asked }
        let revised = all[index]
        _ = try persist(all, now: now)
        return revised
    }

    func item(id: UUID) -> MemoryItem? {
        loaded().first { $0.id == id }
    }

    /// 改过的一律算手写:用户校对过的说法,比抽取器下次的判断可信。
    @discardableResult
    func update(id: UUID, kind: MemoryKind, text: String, dueAt: Date? = nil) throws -> [MemoryItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items() }
        var all = loaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return items() }
        all[index].kind = kind
        all[index].text = trimmed
        all[index].updatedAt = Date()
        all[index].origin = .manual
        // 改成别的类别就没有「到期」这回事了,留着一个看不见的到期时间,记忆会莫名其妙地消失。
        all[index].dueAt = kind.expires ? (dueAt ?? all[index].dueAt) : nil
        return try persist(all)
    }

    @discardableResult
    func delete(id: UUID) throws -> [MemoryItem] {
        try persist(loaded().filter { $0.id != id })
    }

    /// 「忘掉全部」。连本版本读不懂的条目一起清:用户点的是忘掉,不是「忘掉我看得见的那部分」。
    @discardableResult
    func removeAll() throws -> [MemoryItem] {
        foreign = []
        return try persist([])
    }

    // MARK: - 抽取器写

    /// 应用一批抽取出来的操作。
    ///
    /// 抽取器输出的是**修改**不是重写,所以这里也只做修改。全量覆盖会把用户手改过的那几条
    /// 一起冲掉,而那几条恰恰是最该留的。
    @discardableResult
    func apply(
        _ operations: [MemoryOperation],
        sessionId: UUID?,
        now: Date = Date()
    ) throws -> [MemoryItem] {
        guard !operations.isEmpty else { return items(now: now) }
        var all = loaded()

        for operation in operations {
            switch operation {
            case .add(let kind, let text, let expiresInDays):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { break }
                // 同一句别再加。模型偶尔会把上一轮记过的话重说一遍,那不是新事实——去掉空白和
                // 标点再比:「不吃香菜。」和「不吃 香菜」以前会各记一条。
                let key = MemoryItem.normalized(trimmed)
                guard !all.contains(where: { $0.kind == kind && MemoryItem.normalized($0.text) == key }) else { break }
                all.append(MemoryItem(
                    kind: kind,
                    text: trimmed,
                    createdAt: now,
                    updatedAt: now,
                    origin: .extracted,
                    sourceSessionId: sessionId,
                    dueAt: MemoryItem.dueDate(kind: kind, days: expiresInDays, now: now)
                ))
            case .update(let id, let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { break }
                // 用户手改过的不让抽取器再动。他改成那样就是不认同模型的说法,下次跑一遍
                // 又被改回去,等于这个设置页是假的。
                guard !all[index].pinned else { break }
                all[index].text = trimmed
                all[index].updatedAt = now
                all[index].sourceSessionId = sessionId
            case .delete(let id):
                guard let index = all.firstIndex(where: { $0.id == id }) else { break }
                guard !all[index].pinned else { break }
                all.remove(at: index)
            }
        }

        return try persist(all, now: now)
    }

    // MARK: - 存

    /// 逐条解码:本版本认不得的条目不会拖垮整份文件,也不会在下一次保存时被悄悄丢掉。
    /// 整份文件读不出来时先备份成 `memory.json.bak` 再往下走——以前是 `try? decode` 失败就当空的,
    /// 下一次保存就把一份读不出来的文件覆盖成空的。
    private func loaded() -> [MemoryItem] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL) else {
            cached = []
            return []
        }
        guard let elements = try? decoder.decode([RuntimeJSONValue].self, from: data) else {
            backUpUnreadable()
            cached = []
            return []
        }
        var items: [MemoryItem] = []
        foreign = []
        for element in elements {
            if let encoded = try? JSONEncoder().encode(element),
               let item = try? decoder.decode(MemoryItem.self, from: encoded) {
                items.append(item)
            } else {
                foreign.append(element)
            }
        }
        let normalized = Self.sorted(items)
        cached = normalized
        return normalized
    }

    /// 只留第一份:之后再坏的文件不该盖掉当初还读得出来的那份。
    private func backUpUnreadable() {
        let manager = FileManager.default
        guard !manager.fileExists(atPath: backupURL.path(percentEncoded: false)) else { return }
        try? manager.copyItem(at: fileURL, to: backupURL)
    }

    @discardableResult
    private func persist(_ items: [MemoryItem], now: Date = Date()) throws -> [MemoryItem] {
        let kept = Self.sorted(Self.evicting(items, now: now))
        cached = kept
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var elements: [RuntimeJSONValue] = []
        for item in kept {
            let data = try encoder.encode(item)
            elements.append(try JSONDecoder().decode(RuntimeJSONValue.self, from: data))
        }
        try encoder.encode(elements + foreign).write(to: fileURL, options: .atomic)
        return kept
    }

    /// 固定顺序:先按类别,同类里旧的在前。
    ///
    /// 顺序稳定不只是好看——记忆块进的是 system 段,顺序一抖就是一次 prompt 缓存失效,
    /// 而且抽取器看到的编号(M1、M2…)也会跟着换,上一轮说的「改 M3」就指到别处去了。
    private static func sorted(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { lhs, rhs in
            let left = MemoryKind.allCases.firstIndex(of: lhs.kind) ?? 0
            let right = MemoryKind.allCases.firstIndex(of: rhs.kind) ?? 0
            if left != right { return left < right }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 淘汰顺序:先扔过期的,近况超过自己的上限先淡掉最旧的,再从最久没更新的自动记忆里扔。
    ///
    /// `pinned` 的永远不扔。全满了又全是用户手写的,就停止接收新的自动记忆——宁可学不到
    /// 新东西,也不能把用户自己写的挤掉。设置页里能看到条数,满了让他自己删。
    private static func evicting(_ items: [MemoryItem], now: Date) -> [MemoryItem] {
        var kept = items.filter { !$0.hasExpired(at: now) }

        /// 淘汰 `candidates` 里最旧的一条**不受保护的**;都受保护就不动,返回 false。
        func evictOldest(where candidates: (MemoryItem) -> Bool) -> Bool {
            guard let victim = kept
                .filter({ candidates($0) && !$0.pinned })
                .min(by: { $0.updatedAt < $1.updatedAt }),
                let index = kept.firstIndex(where: { $0.id == victim.id })
            else { return false }
            kept.remove(at: index)
            return true
        }

        // 近况先按自己的上限淡掉:它是「最近的事」,攒到十条以上就不是近况了。
        while kept.count(where: { $0.kind == .episode }) > MemoryItem.maxEpisodes {
            guard evictOldest(where: { $0.kind == .episode }) else { break }
        }

        func isOverCapacity() -> Bool {
            kept.count > maxItems || kept.reduce(0) { $0 + $1.text.count } > maxCharacters
        }

        while isOverCapacity() {
            guard evictOldest(where: { _ in true }) else { break }
        }

        return kept
    }
}
