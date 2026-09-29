import Foundation

extension Notification.Name {
    /// 有后台来的主动消息落进了某条线程(check-in、提醒、任务结果、回头看的结论)。
    /// `object` 是那条线程的目录。界面在**一轮回复结束之后**才把新消息并进列表。
    static let vanaThreadDidAppend = Notification.Name("vanaThreadDidAppend")
}

/// 那条永远的对话在磁盘上的样子。
///
/// ```
/// <tenantRoot>/thread/
///   meta.json            水位线、窗口游标、后台跑过的账(小,整个原子重写)
///   seg-000001.jsonl     追加写,一行一条记录;满了滚到下一段
/// ```
///
/// **追加写**代替「每轮把整个会话文件重写一遍」:写入量只和这一轮改了什么有关,和历史多长
/// 无关;进程被杀在半路,坏的至多是最后一行(读的时候跳过),不会像整文件写一半那样把整份
/// 历史带走。
///
/// 一条记录要么是 put(一条消息的最新样子,带位置 `p`),要么是 del。同一条消息可以被 put
/// 很多次,**最后一次为准**——所以重试、补答案都还是追加。顺序由位置 `p`(浮点数)定,不由
/// 写入先后定:用户在助手还在回答时补了一句,那条回复要排在补的话**前面**,可它是后写的——
/// 给它一个夹在两者之间的位置就行。
///
/// 读是**从新往旧**:先加载最新几段给界面,滑到顶再往前翻。旧段里的 put 若被新段里的
/// put/del 盖过,读旧段时按 `resolved` 跳过——所以它得一直记着已经见过哪些 id。
///
/// 和 Android 那份 `ThreadStore` 同一个格式。actor 本身就是那个「单写者」:聊天界面、
/// 后台一轮、到点的提醒往同一条线程里写,全在这一条队上。
actor ThreadStore {
    struct Page: Sendable {
        var messages: [ChatMessage]
        var oldestSegment: Int
        var hasOlder: Bool
    }

    /// 后台那一轮(待跟进回访)跑过的记录:什么时候跑的、得出的一句结论。
    struct DerivedRecord: Codable, Sendable, Equatable {
        var at: Date
        var conclusion: String?
    }

    struct Meta: Codable, Sendable, Equatable {
        var schema = 1
        /// 后台一轮的记录,按键(比如待跟进条目的 id)存。
        var derived: [String: DerivedRecord] = [:]
        /// 记忆收割到哪个位置为止(含)。之后的消息还没被抽过。
        var harvestedUpToPos: Double?
        /// 滑动窗口的起点位置。窗口只在淘汰时才前移。
        var windowStartPos: Double?
        var lastRequestAt: Date?
    }

    /// 档案里的一行:给召回检索用的、截短了的文字。
    struct ArchiveRow: Sendable, Equatable {
        var id: UUID
        var pos: Double
        var createdAt: Date?
        var isUser: Bool
        var text: String
        var toolNames: [String]
        var isProactive: Bool
    }

    private struct Record: Codable {
        var p: Double?
        var m: ChatMessage?
        var d: UUID?
    }

    static let metaName = "meta.json"
    static let legacyMarker = ".legacy-sessions-cleared"
    /// 一段最多这么多条记录。再多就滚到下一段——读旧段和往前翻都是按段来的。
    static let segmentMaxRecords = 400
    static let defaultTailMessages = 60
    static let defaultTailSegments = 3
    /// 档案每条只存截断后的文字,够搜索和「读那一段」用,不把整轮 transcript 攒在内存里。
    static let archiveUserLimit = 800
    static let archiveAssistantLimit = 320

    let directory: URL
    private let attachments: AttachmentStore?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// id → 位置。只记这个进程里见过(加载过或写过)的。
    private var positions: [UUID: Double] = [:]
    /// 读的时候已经确定了最终状态的 id(活的或已删的)。往旧翻时据此跳过被盖过的 put。
    private var resolved: Set<UUID> = []
    private var maxPos: Double = 0
    private var currentIndex = 1
    private var currentRecords = 0
    private var didOpen = false

    /// 档案索引,按位置排。启动之后第一次问到它时扫一遍盘建起来,之后随每次写入增量更新,
    /// 不落盘:它随时能从线程重建,落盘只会多一份要保持同步的东西。
    private var archive: [ArchiveRow]?

    init(directory: URL, attachments: AttachmentStore? = nil) {
        self.directory = directory
        self.attachments = attachments
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - 打开

    private func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let newest = segments().last else { return }
        currentIndex = newest.index
        healUnterminatedTail(newest.url)
        let records = readRecords(newest.url)
        currentRecords = records.count
        maxPos = records.compactMap(\.p).max() ?? 0
    }

    // MARK: - 读

    /// 最新的几段:凑够 `minMessages` 条活的消息就停,最多 `maxSegments` 段。
    func loadTail(minMessages: Int = defaultTailMessages, maxSegments: Int = defaultTailSegments) -> Page {
        openIfNeeded()
        resolved.removeAll()
        positions.removeAll()
        return readBackwards(before: .max, minMessages: minMessages, maxSegments: maxSegments)
    }

    /// 再往前翻:`beforeSegment` 是上一页的 `oldestSegment`。
    func loadOlder(beforeSegment: Int, minMessages: Int = defaultTailMessages) -> Page {
        openIfNeeded()
        return readBackwards(before: beforeSegment, minMessages: minMessages, maxSegments: Self.defaultTailSegments)
    }

    private func readBackwards(before: Int, minMessages: Int, maxSegments: Int) -> Page {
        let files = segments().filter { $0.index < before }.reversed()
        var live: [UUID: (Double, ChatMessage)] = [:]
        var oldest = before
        var read = 0
        for file in files {
            for record in readRecords(file.url).reversed() {
                if let deleted = record.d { resolved.insert(deleted) }
                guard let message = record.m else { continue }
                guard resolved.insert(message.id).inserted else { continue }
                live[message.id] = (record.p ?? 0, message)
            }
            oldest = file.index
            read += 1
            if live.count >= minMessages || read >= maxSegments { break }
        }
        for (id, entry) in live {
            positions[id] = entry.0
            maxPos = max(maxPos, entry.0)
        }
        let ordered = live.values.sorted { $0.0 < $1.0 }.map(\.1)
        let hasOlder = segments().contains { $0.index < oldest }
        return Page(messages: ordered, oldestSegment: oldest, hasOlder: hasOlder)
    }

    /// 这条消息在线程里的位置。只认这个进程加载过或写过的。
    func position(of id: UUID) -> Double? { positions[id] }

    /// 按位置重排。**往前翻页之后必须过一遍**:一条旧消息最近被改过(补了答案、换了状态),它最后
    /// 一次 put 落在新段里,于是它跟着末尾那一页先被读出来了;把更早的一页直接接在前面的话,
    /// 它会排在比它新的消息前面。没有位置的(还没同步过的)保持原来的相对顺序,排在最后。
    func sortedByPosition(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.enumerated().sorted { lhs, rhs in
            switch (positions[lhs.element.id], positions[rhs.element.id]) {
            case let (l?, r?): l != r ? l < r : lhs.offset < rhs.offset
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    /// 位置在 `pos` 之后的活消息,按位置排。记忆收割用:只喂水位线之后没抽过的。
    /// 从最新一段往前读,读到整段都在 `pos` 之前就停。
    func messages(after pos: Double?) -> [(pos: Double, message: ChatMessage)] {
        openIfNeeded()
        let floor = pos ?? -.infinity
        var seen = Set<UUID>()
        var live: [(pos: Double, message: ChatMessage)] = []
        for file in segments().reversed() {
            var segmentMax = -Double.infinity
            for record in readRecords(file.url).reversed() {
                if let p = record.p { segmentMax = max(segmentMax, p) }
                if let deleted = record.d { seen.insert(deleted) }
                guard let message = record.m, seen.insert(message.id).inserted, let p = record.p else { continue }
                if p > floor { live.append((p, message)) }
            }
            if segmentMax <= floor { break }
        }
        return live.sorted { $0.pos < $1.pos }
    }

    /// 整条线程里所有活着的消息,不保证顺序,逐条交给 `body`。不把消息攒在内存里
    /// (每条都带整轮 transcript,攒起来是历史长度的几倍)。
    func scan(_ body: (Double, ChatMessage) -> Void) {
        openIfNeeded()
        var seen = Set<UUID>()
        for file in segments().reversed() {
            for record in readRecords(file.url).reversed() {
                if let deleted = record.d { seen.insert(deleted) }
                guard let message = record.m, seen.insert(message.id).inserted else { continue }
                body(record.p ?? 0, message)
            }
        }
    }

    // MARK: - 写

    /// 把界面持有的那一段消息同步到盘上,只写**变了的**:
    /// - 盘上还没有的:按它在列表里的位置排个号(夹在前后两条之间),写一条 put;
    /// - 在 `dirty` 里的:原位置再 put 一次;
    /// - 上次同步过(`known`)、这次不在列表里的:写 del。
    ///
    /// 返回这次同步之后界面持有的 id 集合,下次原样传回来。**只删「界面自己同步过的」**——
    /// 后台追加的主动消息界面还没加载到,不在 `known` 里,不会被误删。
    @discardableResult
    func sync(_ messages: [ChatMessage], dirty: Set<UUID>, known: Set<UUID>) -> Set<UUID> {
        openIfNeeded()
        var out: [Record] = []
        var nextKnown = [Double?](repeating: nil, count: messages.count)
        var following: Double?
        for index in messages.indices.reversed() {
            nextKnown[index] = following
            if let p = positions[messages[index].id] { following = p }
        }
        var previous: Double?
        for (index, message) in messages.enumerated() {
            if let existing = positions[message.id] {
                if dirty.contains(message.id) { out.append(Record(p: existing, m: message)) }
                previous = existing
                continue
            }
            let next = nextKnown[index]
            let p: Double = if let previous, let next, next > previous {
                (previous + next) / 2
            } else if let previous {
                previous + 1
            } else if let next {
                next - 1
            } else {
                maxPos + 1
            }
            positions[message.id] = p
            resolved.insert(message.id)
            maxPos = max(maxPos, p)
            out.append(Record(p: p, m: message))
            previous = p
        }
        let current = Set(messages.map(\.id))
        let removed = known.subtracting(current)
        for id in removed {
            out.append(Record(d: id))
            positions[id] = nil
            resolved.insert(id)
        }
        append(out)
        if !removed.isEmpty { pruneAttachments(of: removed, fromAppended: out) }
        return current
    }

    /// 加到线程最末尾。后台来的主动消息走这条:界面没在跑就直接落盘,在跑就等轮边界再并进去。
    @discardableResult
    func appendAtEnd(_ message: ChatMessage) -> Double {
        openIfNeeded()
        let p = maxPos + 1
        maxPos = p
        positions[message.id] = p
        resolved.insert(message.id)
        append([Record(p: p, m: message)])
        NotificationCenter.default.post(name: .vanaThreadDidAppend, object: directory)
        return p
    }

    /// 改一条已经落盘的消息。只改这个进程认得的、或读得到的。
    @discardableResult
    func put(_ message: ChatMessage) -> Bool {
        openIfNeeded()
        guard let p = positions[message.id] ?? findPosition(message.id) else { return false }
        append([Record(p: p, m: message)])
        return true
    }

    private func findPosition(_ id: UUID) -> Double? {
        var seen = Set<UUID>()
        for file in segments().reversed() {
            for record in readRecords(file.url).reversed() {
                if let deleted = record.d { seen.insert(deleted) }
                guard let message = record.m, message.id == id else { continue }
                return seen.contains(id) ? nil : record.p
            }
        }
        return nil
    }

    /// 删掉这些消息,顺手清掉只有它们引用的照片。
    func delete(_ ids: Set<UUID>) async {
        openIfNeeded()
        guard !ids.isEmpty else { return }
        var doomed: [String] = []
        scan { _, message in
            if ids.contains(message.id) { doomed += message.attachments.compactMap(\.imageFileName) }
        }
        append(ids.map { Record(d: $0) })
        for id in ids {
            positions[id] = nil
            resolved.insert(id)
        }
        await prune(doomed)
    }

    /// 删掉创建时间早于 `cutoff` 的全部消息,返回删了多少条。没有时间的(老数据)当成很久以前。
    @discardableResult
    func deleteOlderThan(_ cutoff: Date) async -> Int {
        var doomed = Set<UUID>()
        scan { _, message in
            if (message.createdAt ?? .distantPast) < cutoff { doomed.insert(message.id) }
        }
        await delete(doomed)
        return doomed.count
    }

    /// 清空整条线程(和它引用过的全部照片)。
    func deleteAll() async {
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        var images: [String] = []
        scan { _, message in images += message.attachments.compactMap(\.imageFileName) }
        for name in names where name != Self.legacyMarker {
            try? manager.removeItem(at: directory.appending(path: name))
        }
        positions.removeAll()
        resolved.removeAll()
        maxPos = 0
        currentIndex = 1
        currentRecords = 0
        archive = []
        if let attachments, !images.isEmpty { await attachments.remove(named: images) }
    }

    // MARK: - meta

    func meta() -> Meta {
        let url = directory.appending(path: Self.metaName)
        guard let data = try? Data(contentsOf: url),
              let meta = try? decoder.decode(Meta.self, from: data)
        else { return Meta() }
        return meta
    }

    func updateMeta(_ transform: @Sendable (inout Meta) -> Void) {
        openIfNeeded()
        var meta = meta()
        transform(&meta)
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: directory.appending(path: Self.metaName), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// 磁盘上这条线程一共占多少字节。设置里「对话历史」显示用。
    func sizeBytes() -> Int {
        segments().reduce(0) { total, file in
            total + ((try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    // MARK: - 档案

    private func ensureArchive() -> [ArchiveRow] {
        if let archive { return archive }
        var rows: [ArchiveRow] = []
        scan { pos, message in
            if let row = Self.archiveRow(pos: pos, message: message) { rows.append(row) }
        }
        rows.sort { $0.pos < $1.pos }
        archive = rows
        return rows
    }

    private static func archiveRow(pos: Double, message: ChatMessage) -> ArchiveRow? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.textIsPlaceholder, !text.isEmpty else { return nil }
        let isUser = message.role == .user
        var seen = Set<String>()
        return ArchiveRow(
            id: message.id,
            pos: pos,
            createdAt: message.createdAt,
            isUser: isUser,
            text: String(text.prefix(isUser ? archiveUserLimit : archiveAssistantLimit)),
            toolNames: message.toolCalls.map(\.name).filter { seen.insert($0).inserted },
            isProactive: message.isProactive
        )
    }

    private func updateArchive(with records: [Record]) {
        guard var rows = archive else { return }
        for record in records {
            if let deleted = record.d {
                rows.removeAll { $0.id == deleted }
            }
            if let message = record.m {
                rows.removeAll { $0.id == message.id }
                if let row = Self.archiveRow(pos: record.p ?? 0, message: message) {
                    let index = rows.firstIndex { $0.pos > row.pos } ?? rows.endIndex
                    rows.insert(row, at: index)
                }
            }
        }
        archive = rows
    }

    /// 位置在 `pos` 之前的全部行(按位置)。窗口里的原文模型本来就看得见,不该再搜出来。
    func archiveRows(before pos: Double) -> [ArchiveRow] {
        ensureArchive().filter { $0.pos < pos }
    }

    func hasArchiveRows(before pos: Double) -> Bool {
        ensureArchive().first.map { $0.pos < pos } ?? false
    }

    /// 以 `id` 那一行为中心,往前 `before` 行、往后 `after` 行。
    func archiveRows(around id: UUID, before: Int = 1, after: Int = 5) -> [ArchiveRow]? {
        let rows = ensureArchive()
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return nil }
        return Array(rows[max(index - before, 0)..<min(index + after + 1, rows.count)])
    }

    /// 整份档案。兴趣统计用(按天数工具调用)。
    func allArchiveRows() -> [ArchiveRow] { ensureArchive() }

    // MARK: - 内部

    private func append(_ records: [Record]) {
        guard !records.isEmpty else { return }
        if currentRecords >= Self.segmentMaxRecords {
            currentIndex += 1
            currentRecords = 0
        }
        var data = Data()
        for record in records {
            guard let line = try? encoder.encode(record) else { continue }
            data.append(line)
            data.append(0x0A)
        }
        let url = segmentURL(currentIndex)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path(percentEncoded: false)) {
            // 会话文件里逐轮记着从 HealthKit 查到的数值和化验单的识别文本,比 `memory.json` 严一档。
            manager.createFile(atPath: url.path(percentEncoded: false), contents: nil, attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.synchronize()
        }
        currentRecords += records.count
        updateArchive(with: records)
    }

    private func segmentURL(_ index: Int) -> URL {
        directory.appending(path: String(format: "seg-%06d.jsonl", index))
    }

    private func segments() -> [(index: Int, url: URL)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names.compactMap { name -> (Int, URL)? in
            guard name.hasPrefix("seg-"), name.hasSuffix(".jsonl"),
                  let index = Int(name.dropFirst(4).dropLast(6)) else { return nil }
            return (index, directory.appending(path: name))
        }
        .sorted { $0.0 < $1.0 }
    }

    private func readRecords(_ url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(Record.self, from: Data(line))
        }
    }

    /// 进程死在写到一半的那一行:补一个换行,免得下一条记录被接在半行后面一起读坏。
    private func healUnterminatedTail(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return }
        try? handle.seek(toOffset: end - 1)
        if let last = try? handle.read(upToCount: 1), last != Data([0x0A]) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data([0x0A]))
        }
    }

    /// 同步时删掉的那几条引用的照片。`sync` 是同步调用,照片清理放进一个 Task 里做。
    private func pruneAttachments(of removed: Set<UUID>, fromAppended records: [Record]) {
        guard attachments != nil else { return }
        var doomed: [String] = []
        // 被删的消息最后一次 put 的样子才知道带了哪些图;扫一遍盘。
        var seen = Set<UUID>()
        for file in segments().reversed() {
            for record in readRecords(file.url).reversed() {
                guard let message = record.m, removed.contains(message.id), seen.insert(message.id).inserted else { continue }
                doomed += message.attachments.compactMap(\.imageFileName)
            }
        }
        guard !doomed.isEmpty else { return }
        Task { await self.prune(doomed) }
    }

    /// 删掉 `candidates` 里不再被任何消息引用的照片文件。整条线程里只要还有一条在引用就留着。
    private func prune(_ candidates: [String]) async {
        guard let attachments, !candidates.isEmpty else { return }
        var stillReferenced = Set<String>()
        scan { _, message in
            for name in message.attachments.compactMap(\.imageFileName) { stillReferenced.insert(name) }
        }
        let doomed = Set(candidates).subtracting(stillReferenced)
        guard !doomed.isEmpty else { return }
        await attachments.remove(named: Array(doomed))
    }
}
