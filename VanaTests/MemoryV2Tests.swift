import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 记忆 v2:近况、忘和改、逐条宽容解码、按行截的记忆块。和 Android `MemoryStoreTest` /
/// `MemoryToolsTest` 同一套口径。
@Suite("Memory v2")
struct MemoryV2Tests {

    private static func freshDirectory() -> URL {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - 盘

    /// 更新版本写下的新种类不该拖垮整份文件,也不该在下一次保存时被悄悄丢掉。
    @Test("an unknown kind survives a round trip instead of wiping the file")
    func unknownKindSurvives() async throws {
        let directory = Self.freshDirectory()
        let url = directory.appending(path: "memory.json")
        let json = """
        [
          {"id":"\(UUID().uuidString)","kind":"profile","text":"他上夜班","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","origin":"manual"},
          {"id":"\(UUID().uuidString)","kind":"fromTheFuture","text":"新版本的东西","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","origin":"manual"}
        ]
        """
        try Data(json.utf8).write(to: url)

        let store = MemoryStore(directory: directory)
        #expect(await store.items().map(\.text) == ["他上夜班"])
        try await store.add(kind: .preference, text: "他要数字")

        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains("fromTheFuture"))
        #expect(written.contains("他要数字"))
    }

    /// 以前读不出来就当空的,下一次保存把整份文件覆盖成空的。
    @Test("an unreadable file is backed up before anything overwrites it")
    func unreadableFileIsBackedUp() async throws {
        let directory = Self.freshDirectory()
        try Data("{ 这不是 JSON".utf8).write(to: directory.appending(path: "memory.json"))

        let store = MemoryStore(directory: directory)
        #expect(await store.items().isEmpty)
        let backup = try String(contentsOf: directory.appending(path: "memory.json.bak"), encoding: .utf8)
        #expect(backup.contains("这不是 JSON"))
    }

    @Test("removeAll forgets what this version cannot read too")
    func removeAllClearsForeign() async throws {
        let directory = Self.freshDirectory()
        let url = directory.appending(path: "memory.json")
        try Data("""
        [{"id":"\(UUID().uuidString)","kind":"fromTheFuture","text":"x","createdAt":"2026-09-01T00:00:00Z","updatedAt":"2026-09-01T00:00:00Z","origin":"manual"}]
        """.utf8).write(to: url)
        let store = MemoryStore(directory: directory)
        _ = await store.items()
        try await store.removeAll()
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("fromTheFuture"))
    }

    // MARK: - 近况

    @Test("an episode fades exactly when it is due, with no grace")
    func episodeFadesOnTime() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        let now = Date()
        _ = try await store.remember(kind: .episode, text: "下周三面试", days: 7, now: now)
        #expect(await store.items(now: now.addingTimeInterval(6 * 86_400)).count == 1)
        #expect(await store.items(now: now.addingTimeInterval(7 * 86_400 + 1)).isEmpty)
    }

    @Test("a follow-up keeps its grace period after it is due")
    func followUpKeepsGrace() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        let now = Date()
        _ = try await store.remember(kind: .followUp, text: "两周后看深睡", days: 14, now: now)
        #expect(await store.items(now: now.addingTimeInterval(15 * 86_400)).count == 1)
        #expect(await store.items(now: now.addingTimeInterval(18 * 86_400)).isEmpty)
    }

    @Test("episode days are clamped to their own ceiling")
    func episodeDaysAreClamped() {
        let now = Date()
        let due = try? #require(MemoryItem.dueDate(kind: .episode, days: 400, now: now))
        #expect(due == now.addingTimeInterval(Double(MemoryItem.maxEpisodeDays) * 86_400))
        #expect(MemoryItem.dueDate(kind: .profile, days: 7, now: now) == nil)
    }

    /// 近况是「最近的事」:攒多了先淡掉最旧的,用户自己写的不动。
    @Test("too many extracted episodes fade oldest first, pinned ones stay")
    func episodeCap() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        let start = Date()
        _ = try await store.remember(kind: .episode, text: "他让我记的近况", days: 30, now: start)
        for index in 0..<12 {
            _ = try await store.apply(
                [.add(kind: .episode, text: "近况 \(index)", expiresInDays: 30)],
                sessionId: nil,
                now: start.addingTimeInterval(Double(index + 1))
            )
        }
        let episodes = await store.items(now: start).filter { $0.kind == .episode }
        #expect(episodes.count == MemoryItem.maxEpisodes)
        #expect(episodes.contains { $0.text == "他让我记的近况" })
        #expect(!episodes.contains { $0.text == "近况 0" })
    }

    @Test("extraction ignores whitespace and punctuation when deduplicating")
    func normalizedDedupe() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        _ = try await store.apply([.add(kind: .preference, text: "不吃香菜。", expiresInDays: nil)], sessionId: nil)
        _ = try await store.apply([.add(kind: .preference, text: "不吃 香菜", expiresInDays: nil)], sessionId: nil)
        #expect(await store.items().count == 1)
    }

    // MARK: - 记忆块

    @Test("the block numbers every line and ends with the tool-results-win rule")
    func blockIsNumbered() throws {
        let snapshot = MemorySnapshot(items: [
            MemoryItem(kind: .profile, text: "他上夜班"),
            MemoryItem(kind: .episode, text: "下周三面试")
        ])
        let block = try #require(snapshot.instructionBlock)
        #expect(block.contains("- M1 [长期情况] 他上夜班"))
        #expect(block.contains("- M2 [近况] 下周三面试"))
        #expect(block.contains("以本次工具返回的为准"))
        #expect(!block.hasPrefix(" "))
    }

    /// 截在半行的那一条会被模型读成另一句话。
    @Test("an oversized block is trimmed on line boundaries, keeping due follow-ups")
    func blockTrimsOnLines() throws {
        var items = (0..<40).map { MemoryItem(kind: .profile, text: String(repeating: "长", count: 100) + "\($0)") }
        items.append(MemoryItem(kind: .followUp, text: "说好的事", dueAt: Date(timeIntervalSince1970: 0)))
        let block = try #require(MemorySnapshot(items: items).instructionBlock)
        let lines = block.split(separator: "\n")
        for line in lines.dropFirst().dropLast() {
            #expect(line.hasPrefix("- M"), "截在了半行：\(line)")
        }
        #expect(block.count <= MemorySnapshot.blockBudget + 200)
    }

    /// 给模型看的标签不跟着界面语言变:同一份记忆在不同语言下渲染成不同前缀,缓存就多一个变量。
    @Test("prompt labels are fixed Chinese")
    func promptLabelsAreFixed() {
        #expect(MemoryKind.allCases.map(\.promptLabel) == ["长期情况", "表达偏好", "近况", "已有解释", "待跟进"])
    }

    // MARK: - 工具

    private static func invoke(_ registry: CapabilityRegistry, _ name: String, _ input: String) async -> CapabilityExecutionResult {
        await registry.execute(CapabilityInvocation(toolCallId: UUID().uuidString, name: name, input: input))
    }

    @Test("forget_memory removes the line the model was pointing at, by handle")
    func forgetByHandle() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        try await store.add(kind: .profile, text: "他上夜班")
        try await store.add(kind: .preference, text: "他要数字")
        let registry = MemoryTools.registry(store: store, snapshot: await store.snapshot())

        let result = await Self.invoke(registry, MemoryTools.forgetToolName, #"{"handle":"M2"}"#)
        #expect(!result.isError)
        #expect(result.output.text.contains("他要数字"))
        #expect(await store.items().map(\.text) == ["他上夜班"])

        let missing = await Self.invoke(registry, MemoryTools.forgetToolName, #"{"handle":"M9"}"#)
        #expect(missing.isError)
    }

    /// 后台抽出来的条目被用户当面纠正过,就成了他说的话:从此受保护。
    @Test("revise_memory rewrites the line and protects an extracted item from the extractor")
    func reviseProtects() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        _ = try await store.apply([.add(kind: .profile, text: "他周三加班", expiresInDays: nil)], sessionId: nil)
        let registry = MemoryTools.registry(store: store, snapshot: await store.snapshot())

        let result = await Self.invoke(registry, MemoryTools.reviseToolName, #"{"handle":"M1","text":"他周四加班"}"#)
        #expect(!result.isError)
        let item = try #require(await store.items().first)
        #expect(item.text == "他周四加班")
        #expect(item.pinned)

        _ = try await store.apply([.update(id: item.id, text: "抽取器又改回去")], sessionId: nil)
        #expect(await store.items().first?.text == "他周四加班")
    }

    @Test("remember refuses a paragraph")
    func rememberRefusesLongText() async {
        let store = MemoryStore(directory: Self.freshDirectory())
        let registry = MemoryTools.registry(store: store)
        let long = String(repeating: "很长", count: 80)
        let result = await Self.invoke(registry, MemoryTools.rememberToolName, "{\"text\":\"\(long)\",\"kind\":\"profile\"}")
        #expect(result.isError)
        #expect(await store.items().isEmpty)
    }

    @Test("remember stores an episode with its fade date")
    func rememberEpisode() async throws {
        let store = MemoryStore(directory: Self.freshDirectory())
        let registry = MemoryTools.registry(store: store)
        let result = await Self.invoke(registry, MemoryTools.rememberToolName, #"{"text":"最近在装修","kind":"episode","days":20}"#)
        #expect(result.output.text.contains("20 天后淡出"))
        let item = try #require(await store.items().first)
        #expect(item.kind == .episode)
        #expect(item.dueAt != nil)
        #expect(item.origin == .asked)
    }

    // MARK: - 抽取

    @Test("chunking takes the oldest messages first and always at least one")
    func harvestChunk() {
        let long = String(repeating: "字", count: 390)
        let messages = (0..<30).map { ChatMessage(role: $0.isMultiple(of: 2) ? .user : .assistant, text: "\($0)\(long)") }
        let chunk = MemoryHarvest.chunk(messages)
        #expect(chunk.first?.id == messages.first?.id)
        #expect(chunk.count < messages.count)
        #expect(MemoryExtractor.transcript(of: chunk).count <= MemoryExtractor.maxTranscriptCharacters)

        let huge = [ChatMessage(role: .user, text: String(repeating: "长", count: 10_000))]
        #expect(MemoryHarvest.chunk(huge).count == 1)
    }

    @Test("the extractor prompt names episode and has no domain words of its own")
    func extractorPromptIsGeneric() {
        let text = MemoryExtractor.instructions()
        #expect(text.contains("episode 近况"))
        for word in ["用药", "诊断", "化验", "健康"] {
            #expect(!text.contains(word), "核心抽取规则里不该有「\(word)」")
        }
        let withHealth = MemoryExtractor.instructions(policy: MemoryPolicy(guidance: HealthInstructions.memoryGuidance))
        #expect(withHealth.contains("不要记诊断结论"))
    }
}
