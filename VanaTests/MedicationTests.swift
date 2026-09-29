import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 用药与补剂:存、进 system 段、三个工具、回访闭环。
///
/// 盯的是这几件事——「不能吃」永远在模型视野里、「试过没用」拦得住重复推荐、隐私会话写不进去、
/// 关掉开关三个工具一个都不挂、回访到点进 check-in。
///
/// 每条测试都开自己的临时 store。app 侧的测试跑在 app host 里,`MedicationStore.shared`
/// 就是模拟器上那份真的 `medications.json`——测试写它等于把用户录的药删了。
@Suite("Medications")
struct MedicationTests {

    private static func freshStore() -> MedicationStore {
        let directory = URL.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MedicationStore(directory: directory)
    }

    private static func invoke(
        _ registry: CapabilityRegistry,
        _ name: String,
        _ input: String = "{}"
    ) async -> CapabilityExecutionResult {
        await registry.execute(CapabilityInvocation(toolCallId: "t", name: name, input: input))
    }

    // MARK: - 存

    @Test("一条手写的药能原样读回来")
    func persistsAcrossInstances() async throws {
        let directory = URL.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let store = MedicationStore(directory: directory)
        try await store.add(MedicationItem(
            name: "褪黑素",
            status: .tried,
            outcome: "试了两周没感觉",
            origin: .manual
        ))

        // 换一个实例读同一个文件:测的是盘上那份,不是 actor 里的缓存。
        let reopened = MedicationStore(directory: directory)
        let items = await reopened.items()
        #expect(items.count == 1)
        #expect(items.first?.name == "褪黑素")
        #expect(items.first?.outcome == "试了两周没感觉")
        #expect(items.first?.origin == .manual)
    }

    @Test("同名的当成同一样东西改掉，不是再加一条")
    func sameNameMerges() async throws {
        let store = Self.freshStore()
        try await store.add(MedicationItem(name: "布洛芬", status: .asNeeded, when: "头疼时"))
        try await store.add(MedicationItem(name: " 布洛芬 ", status: .tried, outcome: "挺管用"))

        let items = await store.items()
        #expect(items.count == 1)
        #expect(items.first?.status == .tried)
        #expect(items.first?.outcome == "挺管用")
        // 原来写的那句没被空值冲掉。模型更新结果时手上没有 `when`。
        #expect(items.first?.when == "头疼时")
    }

    @Test("用户改过的一般说明不会被重新生成覆盖")
    func userWrittenBriefIsNotOverwritten() async throws {
        let store = Self.freshStore()
        let item = MedicationItem(
            name: "镁",
            status: .ongoing,
            brief: "我自己写的说明",
            briefIsUserWritten: true
        )
        try await store.add(item)
        try await store.setGeneratedBrief(id: item.id, text: "模型写的说明")

        #expect(await store.item(named: "镁")?.brief == "我自己写的说明")
    }

    // MARK: - system 段

    @Test("「不能吃」排在最前面，而且三句结尾一句不少")
    func snapshotLeadsWithCannotTakeAndKeepsFooter() throws {
        // 故意乱序传进去:分组是 `instructionBlock` 自己的事,不能指望调用方排好。
        let snapshot = MedicationSnapshot(items: [
            MedicationItem(name: "褪黑素", status: .tried, outcome: "试了两周没感觉"),
            MedicationItem(name: "阿托伐他汀", status: .ongoing, reason: "医生开的，降血脂"),
            MedicationItem(name: "青霉素", status: .cannotTake, reason: "过敏，起疹子")
        ])
        let block = try #require(snapshot.instructionBlock)
        let lines = block.split(separator: "\n").map(String.init)

        // 安全相关的那一条必须在模型开口之前就已经在视野里,而不是排在第三行。
        #expect(lines[1].contains("青霉素"))
        #expect(lines[1].contains("不能吃"))

        // 这三句是这个功能真正的产出,不是免责声明:前两句决定了这张表有没有用,
        // 第三句是安全线。少一句这个功能就退化成一个记事本。
        #expect(block.contains("绝对不要提"))
        #expect(block.contains("不要再推荐一次"))
        #expect(block.contains("剂量一律不给建议"))
    }

    @Test("空表不进 system 段")
    func emptySnapshotHasNoBlock() {
        #expect(MedicationSnapshot.empty.instructionBlock == nil)
    }

    @Test("超上限时先裁「试过了」，「不能吃」一条都不裁")
    func trimmingNeverDropsCannotTake() {
        let allergies = (0..<30).map {
            MedicationItem(
                name: "过敏\($0)",
                status: .cannotTake,
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0)
            )
        }
        let tried = (0..<10).map {
            MedicationItem(
                name: "试过\($0)",
                status: .tried,
                updatedAt: Date(timeIntervalSince1970: 100)
            )
        }
        let kept = MedicationSnapshot.trimmed(allergies + tried)
        #expect(kept.count(where: { $0.status == .cannotTake }) == 30)
        #expect(kept.contains { $0.status == .tried } == false)
    }

    @Test("每一类各取自己那半句：在吃的取原因，试过的取结果")
    func snapshotDetailPicksPerStatus() {
        let ongoing = MedicationItem(name: "D3", status: .ongoing, reason: "冬天日照少")
        #expect(ongoing.snapshotDetail == "冬天日照少")

        // 试过没用那条要带着结果进 system 段——不带结果,「别再推荐一次」就没有依据。
        let tried = MedicationItem(name: "褪黑素", status: .tried, outcome: "没感觉")
        #expect(tried.snapshotDetail == "没感觉")
    }

    // MARK: - 工具

    @Test("空清单不报错")
    func listOnEmptyStoreIsNotAnError() async {
        let registry = MedicationTools.registry(store: Self.freshStore())
        let result = await Self.invoke(registry, MedicationTools.listToolName)
        // 「他还没记过什么」是有效答案。报成错误模型会以为工具坏了,换个说法再试一次。
        #expect(result.isError == false)
        #expect(result.output.text.contains("还没有"))
    }

    @Test("log 落一条，update 把它改成试过了")
    func logThenUpdate() async throws {
        let store = Self.freshStore()
        let registry = MedicationTools.registry(store: store)

        let logged = await Self.invoke(
            registry,
            MedicationTools.logToolName,
            #"{"name":"褪黑素","status":"asNeeded","when":"睡不着时","followUpDays":14}"#
        )
        #expect(logged.isError == false)
        let afterLog = try #require(await store.item(named: "褪黑素"))
        #expect(afterLog.status == .asNeeded)
        #expect(afterLog.origin == .asked)
        #expect(afterLog.followUpAt != nil)

        let updated = await Self.invoke(
            registry,
            MedicationTools.updateToolName,
            #"{"name":"褪黑素","status":"tried","outcome":"试了两周没感觉"}"#
        )
        #expect(updated.isError == false)
        let afterUpdate = try #require(await store.item(named: "褪黑素"))
        #expect(afterUpdate.status == .tried)
        #expect(afterUpdate.outcome == "试了两周没感觉")
        // 结果记下来了,那个约定就兑现了。不清掉的话接下来几天的早上会重复问同一句。
        #expect(afterUpdate.followUpAt == nil)
    }

    @Test("update 匹配不上时，把现有的名字列出来")
    func updateListsNamesWhenNotFound() async throws {
        let store = Self.freshStore()
        try await store.add(MedicationItem(name: "维生素D3", status: .ongoing))
        let registry = MedicationTools.registry(store: store)

        let result = await Self.invoke(
            registry,
            MedicationTools.updateToolName,
            #"{"name":"维D","outcome":"还行"}"#
        )
        #expect(result.isError == true)
        // 只回一句「没找到」的话,模型只能瞎猜下一个写法,白调两轮。
        #expect(result.output.text.contains("维生素D3"))
    }

    @Test("隐私会话只挂读的那一个")
    func privateSessionGetsReadOnlyTools() {
        let names = MedicationTools.registry(store: Self.freshStore(), allowsWrites: false)
            .definitions.map(\.name)
        #expect(names == [MedicationTools.listToolName])
    }

    @Test("工具输出末尾带着那句防线")
    func renderCarriesTheGuardrail() {
        let text = MedicationTools.render([
            MedicationItem(name: "青霉素", status: .cannotTake, reason: "过敏")
        ])
        #expect(text.contains("不是医嘱"))
        #expect(text.contains("绝对不要推荐"))
    }

    @Test("他自己的评价排在自动生成的说明前面")
    func renderPutsOutcomeBeforeBrief() throws {
        let text = MedicationTools.render([
            MedicationItem(name: "镁", status: .tried, outcome: "睡得沉了点", brief: "一般用于补充镁")
        ])
        let outcomeIndex = try #require(text.range(of: "睡得沉了点"))
        let briefIndex = try #require(text.range(of: "一般用于补充镁"))
        // 反过来排,这份输出读起来就像一份说明书摘抄,而这张表的价值恰恰在于它是他自己的。
        #expect(outcomeIndex.lowerBound < briefIndex.lowerBound)
    }

    // MARK: - 挂载

    @Test("关掉开关时三个工具一个都不挂")
    func disabledSwitchUnmountsEveryTool() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: EngineSettings.medicationsEnabledKey)
        defer { defaults.removeObject(forKey: EngineSettings.medicationsEnabledKey) }

        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TestAssembly.engine(TestAssembly.environment(stores: stores)).capabilityRegistry
        #expect(registry.definition(named: MedicationTools.listToolName) == nil)
        #expect(registry.definition(named: MedicationTools.logToolName) == nil)
        #expect(registry.definition(named: MedicationTools.updateToolName) == nil)
    }

    @Test("清单真的进了 system 段，写工具的指令也跟着挂上")
    func snapshotReachesTheSystemPrompt() {
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = TestAssembly.engine(TestAssembly.environment(
            stores: stores,
            medications: MedicationSnapshot(items: [
                MedicationItem(name: "青霉素", status: .cannotTake, reason: "过敏")
            ])
        ))
        let instruction = engine.systemInstruction()
        #expect(instruction.contains("青霉素"))
        #expect(instruction.contains("绝对不要提"))
        // 两条写入路径落到同一件事上就是两份会各自被改的记录。
        #expect(instruction.contains("药和补剂不要用 remember 记"))
    }

    @Test("以某一条为话题时，focus 进 system 段且不带剂量建议")
    func focusMedicationReachesTheSystemPrompt() {
        let engine = TestAssembly.engine(TestAssembly.environment(
            focusMedication: MedicationItem(
                name: "褪黑素",
                status: .tried,
                reason: "睡不着",
                outcome: "试了两周没感觉"
            )
        ))
        let instruction = engine.systemInstruction()
        #expect(instruction.contains("这条对话围绕他记下的「褪黑素」"))
        #expect(instruction.contains("试了两周没感觉"))
        #expect(instruction.contains("不要建议他调整剂量"))
    }

    // MARK: - 回访闭环

    @Test("到点的回访进了早上那条 check-in，并落在这条药自己的线上")
    func dueFollowUpReachesTheMorningCheckIn() throws {
        let item = MedicationItem(
            name: "褪黑素",
            status: .asNeeded,
            followUpAt: Date().addingTimeInterval(-86_400)
        )
        let checkIn = CheckInScheduler.content(
            for: .morning,
            situation: HealthSituation(period: .morning, triggers: []),
            dueMedications: [item]
        )
        #expect(checkIn.body.contains("褪黑素"))
        // 点开落回这条药自己的线,不是 check-in 线——通知说的是褪黑素,点开就该聊褪黑素。
        #expect(checkIn.threadId == SessionThread.medication(item.id).id)
    }

    @Test("晚上那条不重复问同一件事")
    func eveningDoesNotRepeatTheFollowUp() {
        let checkIn = CheckInScheduler.content(
            for: .evening,
            situation: HealthSituation(period: .evening, triggers: []),
            dueMedications: [
                MedicationItem(name: "褪黑素", followUpAt: Date().addingTimeInterval(-86_400))
            ]
        )
        #expect(checkIn.body.contains("褪黑素") == false)
    }

    @Test("说好的日子没到就不问")
    func futureFollowUpIsNotDue() {
        let store = MedicationSnapshot(items: [
            MedicationItem(name: "镁", followUpAt: Date().addingTimeInterval(86_400))
        ])
        #expect(store.due(at: Date()).isEmpty)
    }

    // MARK: - 延续线

    @Test("用药线断得和目标线一样宽")
    func medicationThreadUsesTheLongIdleWindow() {
        let thread = SessionThread.medication(UUID())
        #expect(SessionThread(id: thread.id) == thread)
        #expect(thread.isLongRunning)
        #expect(thread.isGoal == false)
    }

    // MARK: - 和记忆的隔离

    @Test("抽取器被告知用药不归它管")
    func extractorIsToldToStayOut() {
        // 两条写入路径落到同一件事上,就是两份会各自被改的记录,而对不上的那次可能是禁忌。
        // 这句话是用药插件在它**真的存着**的时候带来的,核心不认识它。
        let (stores, root) = TestAssembly.freshStores()
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = PluginRegistry.memoryPolicy(TestAssembly.environment(stores: stores))
        let instructions = MemoryExtractor.instructions(policy: policy)
        #expect(instructions.contains("用药与补剂"))
        #expect(instructions.contains("有专门的地方存"))

        // 用药表关了,「我不能吃布洛芬」就该老老实实进记忆。
        let off = PluginRegistry.memoryPolicy(TestAssembly.environment(
            stores: stores,
            isEnabled: { $0 != PluginIds.healthMedications }
        ))
        #expect(!MemoryExtractor.instructions(policy: off).contains("用药与补剂"))
    }

    // MARK: - 一般说明

    @Test("模型说不认识就不写")
    func brieferRefusesToGuess() {
        #expect(MedicationBriefer.parse("无") == nil)
        #expect(MedicationBriefer.parse("   ") == nil)
        // 写一句它自己也不确定的话,比空着糟得多——用户看不出那一行是猜的。
        #expect(MedicationBriefer.parse(String(repeating: "长", count: 200)) == nil)
        #expect(MedicationBriefer.parse("「一般用于补充维生素 D。」") == "一般用于补充维生素 D")
    }
}
