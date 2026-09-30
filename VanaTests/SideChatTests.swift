import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 侧聊:名单怎么存、删的顺序、孤儿目录、名字怎么来,以及一条侧聊接在 `ChatViewModel` 上时
/// 哪些东西和主对话一样、哪些只属于主对话。
@Suite("Side chats", .serialized)
@MainActor
struct SideChatTests {
    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 200_000,
        maxOutputTokens: 8_000
    )

    private struct Fixture {
        let root: URL
        let stores: TenantStores

        init() {
            root = URL.temporaryDirectory.appending(path: "vana-side-\(UUID().uuidString)", directoryHint: .isDirectory)
            stores = TenantStores(root: root)
        }

        @MainActor
        func model(_ client: ScriptedModelClient? = nil, sideChat: SideChat? = nil) -> ChatViewModel {
            let factory: ChatViewModel.EngineFactory? = client.map { client in
                { @MainActor @Sendable in LoopEngine(client: client, capabilities: stubRegistry([:])) }
            }
            return ChatViewModel(
                engineFactory: factory,
                loadsPersistedThread: true,
                sideChat: sideChat,
                memoryStore: stores.memory,
                medicationStore: stores.medications,
                thread: stores.thread,
                tasks: stores.tasks,
                notes: stores.notes
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private static func sidesDirectory() -> URL {
        URL.temporaryDirectory.appending(path: "vana-sides-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - 名字

    @Test("a side chat is named from the first line of the first thing said")
    func titleFromFirstLine() {
        #expect(SideChatTitle.make(from: "  十月去京都\n先看看住哪") == "十月去京都")
        #expect(SideChatTitle.make(from: "   \n  ") == nil)
        let long = String(repeating: "长", count: 40)
        let title = SideChatTitle.make(from: long)
        #expect(title?.count == SideChatTitle.maxLength)
        #expect(title?.hasSuffix("…") == true)
    }

    @Test("a name he types is flattened to one line and capped")
    func cleanTitle() {
        #expect(SideChatTitle.clean("  装修\n 比价  ") == "装修 比价")
        #expect(SideChatTitle.clean(String(repeating: "字", count: 50)).count == SideChatTitle.maxTypedLength)
        #expect(SideChatTitle.clean("Kyoto in October trip") == "Kyoto in October trip")
        #expect(SideChat(title: "  ").displayTitle == "新侧聊")
        #expect(SideChat(title: "  ").autoTitled)
        #expect(!SideChat(title: "京都").autoTitled)
    }

    // MARK: - 名单

    @Test("the list survives a fresh instance and is ordered by last activity")
    func listPersistsAndOrders() async {
        let directory = Self.sidesDirectory()
        let store = SideChatStore(directory: directory)
        let start = Date().addingTimeInterval(-600)
        let older = await store.create(title: "京都", now: start)
        let newer = await store.create(title: "装修", now: start.addingTimeInterval(60))
        #expect(await store.all().map(\.id) == [newer.id, older.id])

        await store.noteActivity(older.id, text: "再看一眼", now: start.addingTimeInterval(120))
        let reloaded = await SideChatStore(directory: directory).all()
        #expect(reloaded.map(\.id) == [older.id, newer.id])
        #expect(reloaded.map(\.title) == ["京都", "装修"])
    }

    /// 没起名的拿第一句带字的话起名;他自己起过或改过的名字,再也不替他改。
    @Test("only an unnamed side chat is named by what is said in it")
    func autoTitleOnlyWhenUnnamed() async {
        let store = SideChatStore(directory: Self.sidesDirectory())
        let unnamed = await store.create(title: "")
        await store.noteActivity(unnamed.id, text: "")
        #expect(await store.get(unnamed.id)?.autoTitled == true)
        await store.noteActivity(unnamed.id, text: "周末带孩子去哪")
        #expect(await store.get(unnamed.id)?.title == "周末带孩子去哪")
        await store.noteActivity(unnamed.id, text: "换个话题")
        #expect(await store.get(unnamed.id)?.title == "周末带孩子去哪")

        let named = await store.create(title: "京都")
        await store.noteActivity(named.id, text: "先看看住哪")
        #expect(await store.get(named.id)?.title == "京都")

        let renamedToEmpty = await store.create(title: "")
        await store.rename(renamedToEmpty.id, to: "")
        await store.noteActivity(renamedToEmpty.id, text: "这句不该拿来起名")
        #expect(await store.get(renamedToEmpty.id)?.title == "")
    }

    /// 同一条侧聊永远是同一个线程实例:两个实例就是两个写者。
    @Test("the same side chat always gets the same thread store")
    func oneThreadPerSideChat() async {
        let store = SideChatStore(directory: Self.sidesDirectory())
        let chat = await store.create(title: "京都")
        #expect(store.thread(for: chat.id) === store.thread(for: chat.id))
        #expect(store.thread(for: chat.id).directory.lastPathComponent == chat.id.uuidString)
    }

    @Test("deleting a side chat takes it off the list and removes its thread")
    func deleteRemovesEverything() async {
        let directory = Self.sidesDirectory()
        let store = SideChatStore(directory: directory)
        let chat = await store.create(title: "京都")
        let thread = store.thread(for: chat.id)
        _ = await thread.sync([ChatMessage(role: .user, text: "住哪")], dirty: [], known: [])
        #expect(Self.exists(thread.directory))

        await store.delete(chat.id)
        #expect(await store.all().isEmpty)
        #expect(await SideChatStore(directory: directory).all().isEmpty)
        #expect(!Self.exists(thread.directory))
    }

    /// 删到一半崩了留下的目录(名单上已经没有它),下一次读名单时清掉。
    @Test("a thread directory missing from the list is swept on the next read")
    func orphansAreSwept() async {
        let directory = Self.sidesDirectory()
        let store = SideChatStore(directory: directory)
        let kept = await store.create(title: "留着")
        _ = await store.thread(for: kept.id).sync([ChatMessage(role: .user, text: "在")], dirty: [], known: [])

        let orphan = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        _ = await ThreadStore(directory: orphan).sync([ChatMessage(role: .user, text: "孤儿")], dirty: [], known: [])
        #expect(Self.exists(orphan))

        let fresh = SideChatStore(directory: directory)
        #expect(await fresh.all().map(\.id) == [kept.id])
        #expect(!Self.exists(orphan))
        #expect(Self.exists(fresh.thread(for: kept.id).directory))
    }

    /// 名单读不懂的时候,每个目录看起来都是孤儿——那时候一个都不许动。
    @Test("an unreadable list sweeps nothing and is backed up")
    func unreadableListSweepsNothing() async throws {
        let directory = Self.sidesDirectory()
        let store = SideChatStore(directory: directory)
        let chat = await store.create(title: "京都")
        _ = await store.thread(for: chat.id).sync([ChatMessage(role: .user, text: "在")], dirty: [], known: [])
        let index = directory.appending(path: SideChatStore.indexName)
        try Data("{不是 json".utf8).write(to: index)

        let fresh = SideChatStore(directory: directory)
        #expect(await fresh.all().isEmpty)
        #expect(Self.exists(directory.appending(path: chat.id.uuidString)))
        #expect(Self.exists(directory.appending(path: "\(SideChatStore.indexName).bak")))
    }

    /// 读不懂的那一条原样留着,它的目录也放过:那是还没被理解的数据,不是垃圾。
    @Test("an entry it cannot read is kept, and so is its directory")
    func foreignEntriesAreKept() async throws {
        let directory = Self.sidesDirectory()
        let foreignId = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let raw = """
            [{"id":"\(foreignId.uuidString)","title":"未来的格式","createdAt":42}]
            """
        try Data(raw.utf8).write(to: directory.appending(path: SideChatStore.indexName))
        let foreignThread = directory.appending(path: foreignId.uuidString, directoryHint: .isDirectory)
        _ = await ThreadStore(directory: foreignThread).sync([ChatMessage(role: .user, text: "在")], dirty: [], known: [])

        let store = SideChatStore(directory: directory)
        #expect(await store.all().isEmpty)
        await store.create(title: "京都")
        #expect(Self.exists(foreignThread))
        let written = try String(contentsOf: directory.appending(path: SideChatStore.indexName), encoding: .utf8)
        #expect(written.contains(foreignId.uuidString))
    }

    /// 「清掉 30 天前的」:侧聊里旧的消息一起清;整条都在那之前的侧聊连名单一起删。
    @Test("clearing old history reaches into side chats")
    func deleteOlderThanCoversSideChats() async {
        let store = SideChatStore(directory: Self.sidesDirectory())
        let old = Date().addingTimeInterval(-40 * 86_400)
        let stale = await store.create(title: "旧的", now: old)
        _ = await store.thread(for: stale.id).sync([ChatMessage(role: .user, text: "很久以前", createdAt: old)], dirty: [], known: [])
        let live = await store.create(title: "新的", now: old)
        _ = await store.thread(for: live.id).sync([
            ChatMessage(role: .user, text: "很久以前", createdAt: old),
            ChatMessage(role: .user, text: "昨天", createdAt: Date().addingTimeInterval(-86_400))
        ], dirty: [], known: [])
        await store.noteActivity(live.id, text: "昨天", now: Date().addingTimeInterval(-86_400))

        let removed = await store.deleteOlderThan(Date().addingTimeInterval(-30 * 86_400))
        #expect(removed == 2)
        #expect(await store.all().map(\.id) == [live.id])
        #expect(await store.thread(for: live.id).loadTail().messages.map(\.text) == ["昨天"])
    }

    // MARK: - 隔离

    /// 那份清单就是「隔离」的定义:漏了 `sides`,侧聊就不进备份排除,删成员也删不干净。
    @Test("side chats live inside the member's directory and on the isolation list")
    func sideChatsAreIsolatedPerMember() {
        let fixture = Fixture()
        defer { fixture.remove() }
        #expect(TenantPaths.perTenantItems.map(\.name).contains(SideChatStore.directoryName))
        #expect(fixture.stores.sides.directory.deletingLastPathComponent().standardizedFileURL
            == fixture.root.standardizedFileURL)
        // 聊天界面没被告知用哪份名单时,推出来的必须是同一位成员的那一份、同一个实例。
        #expect(SideChatStore.beside(fixture.stores.thread) === fixture.stores.sides)
    }

    // MARK: - 接在聊天上

    @Test("a side chat talks into its own thread and names itself before the first request")
    func sideChatUsesItsOwnThread() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let chat = await fixture.stores.sides.create(title: "")
        let client = ScriptedModelClient(profile: Self.profile, turns: [.init(text: "住四条附近方便。")])
        let model = fixture.model(client, sideChat: chat)
        try await waitUntil("载入线程") { !model.isLoadingConversation }

        #expect(model.isSideChat)
        #expect(!model.isMainThread)
        #expect(model.navigationSubtitle.contains("侧聊"))

        model.send("十月去京都住哪")
        #expect(model.sideChat?.title == "十月去京都住哪")
        try await waitUntil("回复结束") { !model.isReplying }
        await model.flushPersistence()

        let sideThread = fixture.stores.sides.thread(for: chat.id)
        #expect(await sideThread.loadTail().messages.map(\.text) == ["十月去京都住哪", "住四条附近方便。"])
        #expect(await fixture.stores.thread.loadTail().messages.isEmpty)
        // 名单那一份是另起一个 task 写的,等它落地。
        let deadline = ContinuousClock.now + .seconds(5)
        while await fixture.stores.sides.get(chat.id)?.title != "十月去京都住哪", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fixture.stores.sides.get(chat.id)?.title == "十月去京都住哪")
    }

    /// 「今天」、首屏那段话和建议是主对话的首屏,侧聊里一样都不出。
    @Test("the main thread's opening screen stays out of a side chat")
    func sideChatHasNoMainScreen() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        var reminder = TaskItem(kind: .reminder, title: "交房租", status: .queued)
        reminder.dueAt = Date().addingTimeInterval(-60)
        _ = await fixture.stores.tasks.add(reminder)
        let chat = await fixture.stores.sides.create(title: "京都")
        let model = fixture.model(sideChat: chat)
        try await waitUntil("载入线程") { !model.isLoadingConversation }

        await model.refreshToday()
        model.refreshSuggestionsIfNeeded()
        model.pinTodayToLatest()
        #expect(model.todayCards.isEmpty)
        #expect(model.quickSummary == nil)
        #expect(model.todayAfterMessageId == nil)
    }

    /// 离开侧聊时正在写的回复停下(等于按了停止),已经写出来的留在侧聊的线程里。
    @Test("leaving a side chat stops the reply and keeps what was written")
    func leavingStopsTheReply() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let chat = await fixture.stores.sides.create(title: "京都")
        let hold = HoldUntilCancelled()
        let client = ScriptedModelClient(profile: Self.profile, turns: [
            .init(text: "这句写不完", beforeResponding: { try await hold.wait() })
        ])
        let model = fixture.model(client, sideChat: chat)
        try await waitUntil("载入线程") { !model.isLoadingConversation }
        model.send("住哪")
        try await waitUntil("开始回复") { model.isReplying }

        let leaving = model.leaveSideChat()
        await leaving?.value
        #expect(!model.isReplying)
        #expect(model.leaveSideChat() == nil)
        let stored = await fixture.stores.sides.thread(for: chat.id).loadTail().messages
        #expect(stored.first?.text == "住哪")
    }

    /// 「清空全部对话」里的「全部」包括侧聊;占用空间和清理的范围对得上。
    @Test("clearing everything from the main thread clears side chats too")
    func clearingMainClearsSides() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let chat = await fixture.stores.sides.create(title: "京都")
        _ = await fixture.stores.sides.thread(for: chat.id).sync([ChatMessage(role: .user, text: "住哪")], dirty: [], known: [])
        let model = fixture.model()
        try await waitUntil("载入线程") { !model.isLoadingConversation }
        #expect(await model.historySizeBytes() > 0)

        await model.clearHistory()
        #expect(await fixture.stores.sides.all().isEmpty)
        #expect(await model.historySizeBytes() == 0)
    }

    /// 记忆只有一份,主对话和侧聊都往里收;水位线各记各的。
    @Test("harvesting walks the main thread and every side chat")
    func harvestCoversSideChats() async {
        let fixture = Fixture()
        defer { fixture.remove() }
        let conversation = [
            ChatMessage(role: .user, text: "我在准备搬家"),
            ChatMessage(role: .assistant, text: "好。"),
            ChatMessage(role: .user, text: "月底之前要搬完"),
            ChatMessage(role: .assistant, text: "明白。")
        ]
        _ = await fixture.stores.thread.sync(conversation, dirty: [], known: [])
        let chat = await fixture.stores.sides.create(title: "搬家")
        let side = fixture.stores.sides.thread(for: chat.id)
        _ = await side.sync(conversation.map { ChatMessage(role: $0.role, text: $0.text) }, dirty: [], known: [])

        let outcomes = await MemoryHarvester.runIfDue(
            threads: [fixture.stores.thread] + (await fixture.stores.sides.allThreads()),
            memory: fixture.stores.memory,
            environment: PluginEnvironment(isEnabled: { _ in true }),
            extract: { _, _, _ in [] }
        )
        #expect(outcomes == [.done, .done])
        #expect(await fixture.stores.thread.meta().harvestedUpToPos != nil)
        #expect(await side.meta().harvestedUpToPos != nil)
    }
}

/// 把某一轮挂住,直到它被取消(等的就是停止)。
private actor HoldUntilCancelled {
    func wait() async throws {
        while true {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
