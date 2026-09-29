import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 一条永远的对话:盘上的格式、窗口、时间标记、档案召回。和 Android `ThreadStoreTest` /
/// `ThreadWindowTest` / `HistoryMarkersTest` / `HistoryRecallToolsTest` 同一套口径。
@Suite("Thread store")
struct ThreadStoreTests {
    private static func directory() -> URL {
        URL.temporaryDirectory.appending(path: "vana-thread-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func user(_ text: String, at date: Date = Date()) -> ChatMessage {
        ChatMessage(role: .user, text: text, createdAt: date)
    }

    private static func assistant(_ text: String, at date: Date = Date()) -> ChatMessage {
        ChatMessage(role: .assistant, text: text, createdAt: date)
    }

    @Test func anEmptyThreadLoadsAsAnEmptyPage() async {
        let page = await ThreadStore(directory: Self.directory()).loadTail()
        #expect(page.messages.isEmpty)
        #expect(!page.hasOlder)
    }

    @Test func whatIsSyncedComesBackInOrderFromAFreshInstance() async {
        let directory = Self.directory()
        let messages = [Self.user("一"), Self.assistant("二"), Self.user("三")]
        _ = await ThreadStore(directory: directory).sync(messages, dirty: [], known: [])
        let reloaded = await ThreadStore(directory: directory).loadTail().messages
        #expect(reloaded.map(\.text) == ["一", "二", "三"])
    }

    @Test func theLatestPutOfAMessageWins() async {
        let directory = Self.directory()
        let store = ThreadStore(directory: directory)
        let question = Self.user("问")
        var reply = Self.assistant("写到一半")
        let known = await store.sync([question, reply], dirty: [], known: [])
        reply.text = "写完了"
        _ = await store.sync([question, reply], dirty: [reply.id], known: known)
        let reloaded = await ThreadStore(directory: directory).loadTail().messages
        #expect(reloaded.map(\.text) == ["问", "写完了"])
    }

    /// 只删「界面自己同步过的」:后台追加、界面还没读到的主动消息不在 `known` 里,不会被误删。
    @Test func aMessageMissingFromTheListIsDeletedButOnlyIfTheListKnewIt() async {
        let directory = Self.directory()
        let store = ThreadStore(directory: directory)
        let a = Self.user("留着"), b = Self.assistant("删掉")
        let known = await store.sync([a, b], dirty: [], known: [])
        await store.appendAtEnd(ChatMessage(role: .assistant, text: "后台来的", origin: .reminder))
        _ = await store.sync([a], dirty: [], known: known)
        let reloaded = await ThreadStore(directory: directory).loadTail().messages.map(\.text)
        #expect(reloaded == ["留着", "后台来的"])
    }

    /// 助手还在回答时用户补了一句:那条回复要排在补的话**前面**,可它是后写的。
    @Test func aMessageInsertedBetweenTwoPersistedOnesLandsBetweenThem() async {
        let directory = Self.directory()
        let store = ThreadStore(directory: directory)
        let question = Self.user("问"), interjection = Self.user("补一句")
        let known = await store.sync([question, interjection], dirty: [], known: [])
        let firstHalf = Self.assistant("前半段")
        _ = await store.sync([question, firstHalf, interjection], dirty: [], known: known)
        let reloaded = await ThreadStore(directory: directory).loadTail().messages.map(\.text)
        #expect(reloaded == ["问", "前半段", "补一句"])
    }

    @Test func manyInsertsInTheSameGapKeepTheirOrder() async {
        let directory = Self.directory()
        let store = ThreadStore(directory: directory)
        let first = Self.user("头"), last = Self.user("尾")
        var list = [first, last]
        var known = await store.sync(list, dirty: [], known: [])
        for index in 0..<20 {
            list.insert(Self.assistant("中\(index)"), at: list.count - 1)
            known = await store.sync(list, dirty: [], known: known)
        }
        let reloaded = await ThreadStore(directory: directory).loadTail(minMessages: 100).messages.map(\.text)
        #expect(reloaded == list.map(\.text))
    }

    @Test func theThreadRollsToANewSegmentAndPagesBackwardWithoutDuplicates() async {
        let directory = Self.directory()
        let store = ThreadStore(directory: directory)
        var list: [ChatMessage] = []
        var known: Set<UUID> = []
        for index in 0..<(ThreadStore.segmentMaxRecords + 50) {
            list.append(Self.user("第\(index)条"))
            known = await store.sync(list, dirty: [], known: known)
        }
        // 改一条旧的、删一条旧的:往前翻时它们不该以旧样子复活。
        list[3].text = "改过的第3条"
        let deleted = list.remove(at: 5)
        known = await store.sync(list, dirty: [list[3].id], known: known)
        #expect(!known.contains(deleted.id))

        let fresh = ThreadStore(directory: directory)
        let tail = await fresh.loadTail(minMessages: 10, maxSegments: 1)
        #expect(tail.hasOlder)
        #expect(tail.messages.last?.text == list.last?.text)
        var all = tail.messages
        var page = tail
        while page.hasOlder {
            page = await fresh.loadOlder(beforeSegment: page.oldestSegment)
            all = await fresh.sortedByPosition(page.messages + all)
        }
        #expect(all.map(\.text) == list.map(\.text))
        #expect(Set(all.map(\.id)).count == all.count)
    }

    /// 进程被杀在半路:坏的至多是最后一行,不会把整份历史带走。
    @Test func aHalfWrittenLastLineIsSkippedAndDoesNotCorruptTheNextRecord() async throws {
        let directory = Self.directory()
        _ = await ThreadStore(directory: directory).sync([Self.user("好的一条")], dirty: [], known: [])
        let segment = directory.appending(path: "seg-000001.jsonl")
        let handle = try FileHandle(forWritingTo: segment)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"p\":2,\"m\":{\"id\":\"半截".utf8))
        try handle.close()

        let reopened = ThreadStore(directory: directory)
        #expect(await reopened.loadTail().messages.map(\.text) == ["好的一条"])
        await reopened.appendAtEnd(Self.user("之后的一条"))
        #expect(await ThreadStore(directory: directory).loadTail().messages.map(\.text) == ["好的一条", "之后的一条"])
    }

    @Test func messagesAfterTheWatermarkAreTheOnesNotYetHarvested() async {
        let store = ThreadStore(directory: Self.directory())
        let list = [Self.user("一"), Self.user("二"), Self.user("三")]
        _ = await store.sync(list, dirty: [], known: [])
        let pos = await store.position(of: list[0].id)
        #expect(await store.messages(after: pos).map(\.message.text) == ["二", "三"])
        #expect(await store.messages(after: nil).count == 3)
    }

    @Test func deletingAMessageRemovesItsPhotoButKeepsOnesStillUsedElsewhere() async throws {
        let root = Self.directory()
        let attachments = AttachmentStore(parent: root)
        _ = try await attachments.store(Data([1]), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        _ = try await attachments.store(Data([2]), id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        let a = ChatAttachment.fileName(for: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!)
        let b = ChatAttachment.fileName(for: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!)
        let store = ThreadStore(directory: root.appending(path: "thread"), attachments: attachments)
        let doomed = ChatMessage(role: .user, text: "删", attachments: [
            ChatAttachment(text: "", imageFileName: a), ChatAttachment(text: "", imageFileName: b)
        ])
        let keeper = ChatMessage(role: .user, text: "留", attachments: [ChatAttachment(text: "", imageFileName: b)])
        _ = await store.sync([doomed, keeper], dirty: [], known: [])

        await store.delete([doomed.id])
        #expect(await attachments.data(named: a) == nil)
        #expect(await attachments.data(named: b) != nil)
    }

    @Test func deleteOlderThanRemovesOnlyOldMessages() async {
        let store = ThreadStore(directory: Self.directory())
        let old = Self.user("上个月", at: Date().addingTimeInterval(-40 * 86_400))
        let recent = Self.user("今天")
        _ = await store.sync([old, recent], dirty: [], known: [])
        #expect(await store.deleteOlderThan(Date().addingTimeInterval(-30 * 86_400)) == 1)
        #expect(await store.loadTail().messages.map(\.text) == ["今天"])
    }

    @Test func deleteAllClearsTheThreadButRemembersTheLegacyCleanup() async {
        let root = Self.directory()
        LegacySessions.clearIfNeeded(root: root)
        let store = ThreadStore(directory: root.appending(path: "thread"))
        _ = await store.sync([Self.user("一")], dirty: [], known: [])
        await store.updateMeta { $0.windowStartPos = 1 }
        await store.deleteAll()
        #expect(await store.loadTail().messages.isEmpty)
        #expect(await store.meta() == ThreadStore.Meta())
        // 清空线程不等于再清一遍旧会话目录。
        #expect(!LegacySessions.clearIfNeeded(root: root))
    }

    /// 旧的「一个会话一个文件」首次启动时清掉,不迁移;记忆和用药表不动。
    @Test func legacySessionsAreClearedOnceAndMemoryIsLeftAlone() throws {
        let root = Self.directory()
        let manager = FileManager.default
        try manager.createDirectory(at: root.appending(path: "sessions"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: root.appending(path: "sessions/a.json"))
        try Data("[]".utf8).write(to: root.appending(path: "memory.json"))
        try Data("[]".utf8).write(to: root.appending(path: "medications.json"))

        #expect(LegacySessions.clearIfNeeded(root: root))
        #expect(!manager.fileExists(atPath: root.appending(path: "sessions").path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: root.appending(path: "memory.json").path(percentEncoded: false)))
        #expect(manager.fileExists(atPath: root.appending(path: "medications.json").path(percentEncoded: false)))
        #expect(!LegacySessions.clearIfNeeded(root: root))
    }

    @Test func theArchiveTracksWritesAndDeletes() async {
        let store = ThreadStore(directory: Self.directory())
        let a = Self.user("装修预算超了"), b = Self.assistant("先看哪一项超得最多")
        let known = await store.sync([a, b], dirty: [], known: [])
        #expect(await store.allArchiveRows().map(\.text) == ["装修预算超了", "先看哪一项超得最多"])
        _ = await store.sync([b], dirty: [], known: known)
        #expect(await store.allArchiveRows().map(\.text) == ["先看哪一项超得最多"])
    }
}

@Suite("Thread window")
struct ThreadWindowTests {
    private static func conversation(turns: Int, charactersPerTurn: Int) -> [ChatMessage] {
        (0..<turns).flatMap { index in
            [
                ChatMessage(role: .user, text: "问\(index)"),
                ChatMessage(role: .assistant, text: String(repeating: "答", count: charactersPerTurn))
            ]
        }
    }

    @Test func aTurnIsAUserMessageAndWhatFollowsUntilTheNextUserMessage() {
        let messages = [
            ChatMessage(role: .assistant, text: "早上好", origin: .checkIn),
            ChatMessage(role: .user, text: "一"), ChatMessage(role: .assistant, text: "二"),
            ChatMessage(role: .user, text: "三")
        ]
        let turns = ThreadWindow.turns(messages, from: 0)
        // 打头的主动消息自成一轮:它不是对哪句提问的回答,切在它后面不会把一次工具调用劈开。
        #expect(turns.map(\.startIndex) == [0, 1, 3])
        #expect(ThreadWindow.turns([], from: 0).isEmpty)
    }

    @Test func theWindowDoesNotMoveUntilItReachesTheHighWatermark() {
        let messages = Self.conversation(turns: 8, charactersPerTurn: 100)
        #expect(ThreadWindow.evict(messages, from: 0, policy: WindowPolicy(budgetTokens: 12_000)) == 0)
    }

    @Test func onceOverBudgetItMovesToATurnBoundaryInOneStep() {
        let messages = Self.conversation(turns: 20, charactersPerTurn: 1_000)
        let policy = WindowPolicy(budgetTokens: 12_000)
        let start = ThreadWindow.evict(messages, from: 0, policy: policy)
        #expect(start > 0)
        #expect(messages[start].role == .user)
        let remaining = ThreadWindow.turns(messages, from: start)
        // 一次砍到低水位,或者砍到只剩受保护的最近那几轮为止——不是丢一轮就停在高水位边上。
        #expect(remaining.reduce(0) { $0 + $1.tokens } <= policy.lowWatermark
            || remaining.count == policy.minTailTurns)
    }

    @Test func theFixedRequestOverheadIsSubtractedFromTheBudget() {
        let messages = Self.conversation(turns: 10, charactersPerTurn: 1_000)
        let policy = WindowPolicy(budgetTokens: 12_000)
        #expect(ThreadWindow.evict(messages, from: 0, policy: policy) == 0)
        #expect(ThreadWindow.evict(messages, from: 0, policy: policy, overheadTokens: 5_000) > 0)
    }

    @Test func theNewestTurnsAreNeverEvicted() {
        let messages = Self.conversation(turns: 7, charactersPerTurn: 5_000)
        let start = ThreadWindow.evict(messages, from: 0, policy: WindowPolicy(budgetTokens: 12_000))
        #expect(ThreadWindow.turns(messages, from: start).count >= WindowPolicy.defaultMinTailTurns)
    }

    /// 思考模型的思考常常比答案还长。不计入的话窗口以为自己没满,请求其实已经大了一截。
    @Test func replayedReasoningCountsOnceFromTheExactTranscript() {
        var message = ChatMessage(role: .assistant, text: "答", reasoning: String(repeating: "想", count: 500))
        let plain = ThreadWindow.estimate(message)
        message.storedTurn.exactTranscript = AgentTranscript(messages: [
            .init(role: .assistant, parts: [.reasoning(String(repeating: "想", count: 500)), .text("答")])
        ])
        #expect(ThreadWindow.estimate(message) == plain + 500)
    }

    @Test func forceEvictKeepsOnlyTheLastFewTurns() {
        let messages = Self.conversation(turns: 5, charactersPerTurn: 10)
        let start = ThreadWindow.forceEvict(messages, from: 0, keepTurns: 2)
        #expect(ThreadWindow.turns(messages, from: start).count == 2)
        #expect(ThreadWindow.forceEvict(Self.conversation(turns: 2, charactersPerTurn: 10), from: 0, keepTurns: 2) == 0)
    }

    @Test func aWindowThatHasAlreadyMovedIsMeasuredFromItsOwnStart() {
        let messages = Self.conversation(turns: 20, charactersPerTurn: 1_000)
        let policy = WindowPolicy(budgetTokens: 12_000)
        let first = ThreadWindow.evict(messages, from: 0, policy: policy)
        #expect(ThreadWindow.evict(messages, from: first, policy: policy) == first)
    }
}

@Suite("History markers")
struct HistoryMarkersTests {
    private static let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test func aLongGapGetsADeterministicMarkerOnTheNextUserMessage() throws {
        let start = Date(timeIntervalSince1970: 1_780_000_000)
        let messages = [
            ChatMessage(role: .user, text: "早", createdAt: start),
            ChatMessage(role: .assistant, text: "早上好", createdAt: start.addingTimeInterval(10)),
            ChatMessage(role: .user, text: "我回来了", createdAt: start.addingTimeInterval(14 * 3_600))
        ]
        let dtos = HistoryMarkers.apply(messages, timeZone: Self.zone)
        #expect(dtos.count == 3)
        #expect(dtos[0].text == "早")
        let last = try #require(dtos.last?.text)
        #expect(last.hasPrefix("——（"))
        #expect(last.contains("距上一条约 13 小时"))
        #expect(last.hasSuffix("我回来了"))
        // 同一段历史每次算出来都一样:前缀不会变来变去。
        #expect(HistoryMarkers.apply(messages, timeZone: Self.zone).map(\.text) == dtos.map(\.text))
    }

    @Test func aShortGapHasNoMarker() {
        let now = Date()
        let dtos = HistoryMarkers.apply([
            ChatMessage(role: .user, text: "一", createdAt: now),
            ChatMessage(role: .user, text: "二", createdAt: now.addingTimeInterval(3_600))
        ])
        #expect(dtos.map(\.text) == ["一", "二"])
    }

    /// 请求里助手和用户消息严格交替:主动消息不单独发,折进下一条用户消息开头。
    @Test func proactiveMessagesFoldIntoTheNextUserMessage() {
        let now = Date()
        let dtos = HistoryMarkers.apply([
            ChatMessage(role: .user, text: "问", createdAt: now),
            ChatMessage(role: .assistant, text: "答", createdAt: now),
            ChatMessage(role: .assistant, text: "到点了：带伞", createdAt: now, origin: .reminder),
            ChatMessage(role: .assistant, text: "深睡回来了", createdAt: now, origin: .followUp),
            ChatMessage(role: .user, text: "好的", createdAt: now)
        ])
        #expect(dtos.map(\.role) == [.user, .assistant, .user])
        #expect(dtos.last?.text == "（Vana 之前主动说过：到点了：带伞；深睡回来了）\n好的")
    }

    @Test func aTrailingProactiveMessageWaitsForTheNextUserMessage() {
        let dtos = HistoryMarkers.apply([
            ChatMessage(role: .assistant, text: "早上好", origin: .checkIn)
        ])
        #expect(dtos.isEmpty)
    }
}

@Suite("History recall")
struct HistoryRecallTests {
    private static func invoke(_ registry: CapabilityRegistry, _ name: String, _ input: String) async -> CapabilityExecutionResult {
        await registry.execute(CapabilityInvocation(toolCallId: "1", name: name, input: input))
    }

    private static func seeded() async -> (ThreadStore, [ChatMessage]) {
        let store = ThreadStore(directory: URL.temporaryDirectory.appending(path: UUID().uuidString))
        let messages = [
            ChatMessage(role: .user, text: "装修预算超了两万"),
            ChatMessage(role: .assistant, text: "先看哪一项超得最多"),
            ChatMessage(role: .user, text: "周末想去爬山"),
            ChatMessage(role: .assistant, text: "天气不错"),
            ChatMessage(role: .user, text: "今天的事")
        ]
        _ = await store.sync(messages, dirty: [], known: [])
        return (store, messages)
    }

    @Test func searchFindsOnlyWhatSlidOutOfTheWindow() async {
        let (store, messages) = await Self.seeded()
        let hidden = await store.position(of: messages[4].id)!
        let registry = HistoryRecallTools.registry(store: store, hiddenBefore: hidden)

        let found = await Self.invoke(registry, HistoryRecallTools.searchToolName, #"{"query":"装修预算"}"#)
        #expect(found.output.text.contains("装修预算超了两万"))
        #expect(!found.output.text.contains("周末想去爬山"))

        let inWindow = await Self.invoke(registry, HistoryRecallTools.searchToolName, #"{"query":"今天的事"}"#)
        #expect(!inWindow.output.text.contains("今天的事") || inWindow.output.text.contains("没有找到"))
        #expect(!inWindow.isError)
    }

    @Test func readReturnsTheOriginalWithDateAndFooter() async throws {
        let (store, messages) = await Self.seeded()
        let hidden = await store.position(of: messages[4].id)!
        let registry = HistoryRecallTools.registry(store: store, hiddenBefore: hidden)
        let handle = HistoryRecallTools.handle(of: messages[0].id)
        let read = await Self.invoke(registry, HistoryRecallTools.readToolName, "{\"id\":\"\(handle)\"}")
        #expect(!read.isError)
        #expect(read.output.text.contains("他：装修预算超了两万"))
        #expect(read.output.text.contains("Vana：先看哪一项超得最多"))
        #expect(read.output.text.hasSuffix(HistoryRecallTools.footer))
        #expect(HistoryRecallTools.dateLabel(inOutput: read.output.text) != nil)
    }

    @Test func anUnknownHandleIsAnErrorButNothingFoundIsNot() async {
        let (store, messages) = await Self.seeded()
        let hidden = await store.position(of: messages[4].id)!
        let registry = HistoryRecallTools.registry(store: store, hiddenBefore: hidden)
        #expect(await Self.invoke(registry, HistoryRecallTools.readToolName, #"{"id":"HZZZ"}"#).isError)
        #expect(!(await Self.invoke(registry, HistoryRecallTools.searchToolName, #"{"query":"火星移民"}"#).isError))
    }

    /// 编号是 id 的稳定散列:删一条不会让别的编号错位,重启之后也还是那一个。
    @Test func handlesAreStable() {
        let id = UUID(uuidString: "3F2A0000-0000-0000-0000-000000000001")!
        #expect(HistoryRecallTools.handle(of: id) == HistoryRecallTools.handle(of: id))
        #expect(HistoryRecallTools.handle(of: id).hasPrefix("H"))
        #expect(HistoryRecallTools.handle(of: id) != HistoryRecallTools.handle(of: UUID()))
    }
}
