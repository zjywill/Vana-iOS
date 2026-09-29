import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 家庭成员(租户):隔离、迁移、以及**Apple 健康数据归机主**那条线。
///
/// 盯的是这几件事——一位成员写的东西另一位读不到、老数据搬进机主目录只搬一次而且搬不动就整个
/// 退回、家人身上一个健康工具都不挂、system 段里那三句说清了"这不是你本人、你读不到他的数据、
/// 要数值就让他拍一张"。
///
/// 每条测试都开自己的临时目录。app 侧的测试跑在 app host 里,`TenantStore.shared` 指的是模拟器
/// 上那份真的成员名单,测试写它等于把用户的家人删了(`MemoryStore` 那条血泪的第五次)。
@Suite("Tenant")
struct TenantTests {

    private static func freshParent() -> URL {
        let directory = URL.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// 造一份"多成员上线之前"的盘面:四样东西直接躺在 `Documents/` 下。
    private static func writeLegacyLayout(at parent: URL) throws {
        let sessions = parent.appending(path: "sessions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sessions.appending(path: "one.json", directoryHint: .notDirectory))
        try Data("[]".utf8).write(to: parent.appending(path: "memory.json", directoryHint: .notDirectory))
        try Data("[]".utf8).write(to: parent.appending(path: "medications.json", directoryHint: .notDirectory))
    }

    private static func waitUntil(
        _ condition: @MainActor () -> Bool,
        timeout: Duration = .seconds(2)
    ) async {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await MainActor.run(body: condition) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - 迁移

    @Test("老数据搬进机主目录，原位置不再留一份")
    func migratesLegacyLayoutIntoOwnerDirectory() throws {
        let parent = Self.freshParent()
        try Self.writeLegacyLayout(at: parent)

        let store = TenantStore(parent: parent)
        let owner = try store.owner()
        #expect(owner.isOwner)

        let root = TenantPaths.root(for: owner.id, parent: parent)
        #expect(Self.exists(root.appending(path: "sessions/one.json", directoryHint: .notDirectory)))
        #expect(Self.exists(root.appending(path: "memory.json", directoryHint: .notDirectory)))
        #expect(Self.exists(root.appending(path: "medications.json", directoryHint: .notDirectory)))

        // 搬走了就不能在原位置再留一份:留着的话下次启动会把它当成又一次待迁移的老数据,
        // 而那时候机主目录里已经有内容了。
        #expect(!Self.exists(parent.appending(path: "memory.json", directoryHint: .notDirectory)))
        #expect(!Self.exists(parent.appending(path: "sessions", directoryHint: .isDirectory)))
    }

    @Test("迁移是幂等的：跑第二遍还是同一个机主，不会再搬一次")
    func migrationIsIdempotent() throws {
        let parent = Self.freshParent()
        try Self.writeLegacyLayout(at: parent)

        let first = try TenantStore(parent: parent).owner()
        // 换一个实例,等于下一次冷启动。
        let second = try TenantStore(parent: parent).owner()
        #expect(first.id == second.id)
        #expect(try TenantStore(parent: parent).tenants().count == 1)
    }

    @Test("没有老数据时也能起来，机主目录是空的")
    func bootstrapsOnFreshInstall() throws {
        let parent = Self.freshParent()
        let owner = try TenantStore(parent: parent).owner()
        #expect(owner.name == Tenant.ownerDefaultName)
        #expect(Self.exists(parent.appending(path: "tenants.json", directoryHint: .notDirectory)))
    }

    // MARK: - 隔离

    @Test("一位成员写的记忆和用药，另一位读不到")
    func storesAreIsolatedPerTenant() async throws {
        let parent = Self.freshParent()
        let store = TenantStore(parent: parent)
        let owner = try store.owner()
        let mom = try store.add(name: "妈妈", ageBand: .senior)

        let mine = TenantStores(root: TenantPaths.root(for: owner.id, parent: parent))
        let hers = TenantStores(root: TenantPaths.root(for: mom.id, parent: parent))

        try await mine.memory.add(kind: .profile, text: "我习惯十一点睡")
        try await hers.memory.add(kind: .profile, text: "妈妈对青霉素过敏")

        let myItems = await mine.memory.items()
        let herItems = await hers.memory.items()
        #expect(myItems.count == 1)
        #expect(herItems.count == 1)
        #expect(myItems.first?.text.contains("十一点") == true)
        #expect(herItems.first?.text.contains("青霉素") == true)
    }

    @Test("一位成员的对话不会出现在另一位的线程和召回里")
    func threadsAreIsolatedPerTenant() async throws {
        let parent = Self.freshParent()
        let store = TenantStore(parent: parent)
        let owner = try store.owner()
        let mom = try store.add(name: "妈妈", ageBand: .senior)

        let mine = TenantStores(root: TenantPaths.root(for: owner.id, parent: parent))
        let hers = TenantStores(root: TenantPaths.root(for: mom.id, parent: parent))

        await mine.thread.sync([ChatMessage(role: .user, text: "我最近睡不好")], dirty: [], known: [])

        #expect(await mine.thread.loadTail().messages.count == 1)
        #expect(await hers.thread.loadTail().messages.isEmpty)
        // 召回的档案是从同一条线程建的,所以它也天然隔离。串数据要是从这儿漏出去,模型会在
        // 妈妈那条对话里引用机主上个月说过的话。
        #expect(await hers.thread.allArchiveRows().isEmpty)
    }

    @Test("删掉一位成员，他那一整个目录都不在了")
    func removingTenantDeletesItsDirectory() async throws {
        let parent = Self.freshParent()
        let store = TenantStore(parent: parent)
        let mom = try store.add(name: "妈妈", ageBand: .senior)
        let root = TenantPaths.root(for: mom.id, parent: parent)

        let hers = TenantStores(root: root)
        try await hers.memory.add(kind: .profile, text: "妈妈对青霉素过敏")
        #expect(Self.exists(root.appending(path: "memory.json", directoryHint: .notDirectory)))

        try store.remove(id: mom.id)
        #expect(!Self.exists(root))
        #expect(try store.tenants().count == 1)
    }

    @Test("机主删不掉")
    func ownerCannotBeRemoved() throws {
        let parent = Self.freshParent()
        let store = TenantStore(parent: parent)
        let owner = try store.owner()
        #expect(throws: (any Error).self) { try store.remove(id: owner.id) }
        #expect(try store.tenants().count == 1)
    }

    // MARK: - 数据归属:工具

    @Test("家人身上一个健康工具都不挂")
    func managedTenantGetsNoHealthTools() async throws {
        let parent = Self.freshParent()
        let stores = TenantStores(root: parent)
        let mom = Tenant(name: "妈妈", kind: .managed)
        let registry = TestAssembly.engine(TestAssembly.environment(tenant: mom, stores: stores)).capabilityRegistry
        let names = Set(registry.definitions.map(\.name))
        for tool in HealthTools.all {
            #expect(!names.contains(tool.name), "家人身上不该挂 \(tool.name)")
        }
        // 用药表照挂:那是家人这边最主要的信息来源。
        #expect(names.contains(MedicationTools.logToolName))
    }

    @Test("机主身上健康工具照挂")
    func ownerKeepsHealthTools() async throws {
        let parent = Self.freshParent()
        let stores = TenantStores(root: parent)
        let registry = TestAssembly.engine(TestAssembly.environment(stores: stores)).capabilityRegistry
        let names = Set(registry.definitions.map(\.name))
        for tool in HealthTools.all {
            #expect(names.contains(tool.name))
        }
    }

    // MARK: - 数据归属:system 段

    @Test("机主不带身份块——不为一件已经成立的事花 token")
    func ownerHasNoIdentityBlock() {
        #expect(HealthInstructions.familyBlock(Tenant.owner()) == nil)
    }

    @Test("家人的身份块说清三件事：不是本人、读不到他的数据、要数值就让他拍一张")
    func managedTenantIdentityBlockCarriesTheThreeRules() throws {
        let mom = Tenant(name: "妈妈", kind: .managed, ageBand: .senior)
        let block = try #require(HealthInstructions.familyBlock(mom))
        #expect(block.contains("妈妈"))
        #expect(block.contains("不是用户本人"))
        #expect(block.contains("读不到"))
        #expect(block.contains("拍一张"))
        #expect(block.contains("老年人"))
    }

    @Test("家人那一轮的 system 段里没有「先调用健康工具」那几条")
    func managedTenantSystemInstructionDropsHealthToolRules() async throws {
        let parent = Self.freshParent()
        let stores = TenantStores(root: parent)
        let mom = Tenant(name: "妈妈", kind: .managed)
        let engine = TestAssembly.engine(TestAssembly.environment(tenant: mom, stores: stores))
        let instruction = engine.systemInstruction()
        #expect(instruction.contains("不是用户本人"))
        // 对着一个没挂出去的工具发指令,模型只会调一次、失败一次,再自己想办法圆场。
        #expect(!instruction.contains("先调用合适的健康工具"))
        #expect(!instruction.contains("引导其询问步数"))
    }

    @Test("机主那一轮照旧带着健康工具的规则")
    func ownerSystemInstructionKeepsHealthToolRules() async throws {
        let parent = Self.freshParent()
        let stores = TenantStores(root: parent)
        let engine = TestAssembly.engine(TestAssembly.environment(stores: stores))
        let instruction = engine.systemInstruction()
        #expect(instruction.contains("先调用合适的健康工具"))
        #expect(!instruction.contains("不是用户本人"))
    }

    // MARK: - 数据归属:首屏

    @Test("家人的首屏不跑 HealthSituation，那句话说的是这儿有什么")
    @MainActor
    func managedTenantFirstScreenSkipsHealthSituation() async throws {
        let parent = Self.freshParent()
        let stores = TenantStores(root: parent)
        let model = ChatViewModel(
            loadsPersistedThread: false,
            tenant: Tenant(name: "妈妈", kind: .managed),
            memoryStore: stores.memory,
            medicationStore: stores.medications,
            thread: stores.thread
        )
        #expect(!model.hasHealthData)

        model.refreshSuggestionsIfNeeded()
        await Self.waitUntil { model.quickSummary != nil }

        let summary = try #require(model.quickSummary)
        #expect(summary.contains("妈妈"))
        // 这条是这个测试真正盯着的:HealthKit 那句「昨晚只睡了 …」绝不该印在妈妈的首屏上。
        #expect(!summary.contains("昨晚"))
        #expect(!model.suggestions.isEmpty)
    }

    @Test("导航栏一直挂着家人的名字，机主那边一个字都没变")
    @MainActor
    func subtitleNamesTheManagedTenantOnly() {
        let parent = Self.freshParent()
        let stores = TenantStores(root: parent)
        func model(_ tenant: Tenant) -> ChatViewModel {
            ChatViewModel(
                loadsPersistedThread: false,
                tenant: tenant,
                memoryStore: stores.memory,
                medicationStore: stores.medications,
                thread: stores.thread
            )
        }
        #expect(model(Tenant(name: "妈妈", kind: .managed)).navigationSubtitle.contains("妈妈"))
        // 关键是**没有名字**:单人用户那一屏不该因为这个功能多出一行字。
        #expect(!model(.owner()).navigationSubtitle.contains(Tenant.ownerDefaultName))
    }
}
