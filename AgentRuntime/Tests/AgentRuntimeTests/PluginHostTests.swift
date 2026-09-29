import Foundation
import Testing

@testable import AgentRuntime

@Suite("Plugin host")
struct PluginHostTests {

    private static func tool(_ name: String, _ effects: ToolEffect..., mount: MountPolicy = .always) -> PluginTool {
        PluginTool(
            definition: CapabilityDefinition(name: name, inputSchema: .object([:])),
            effects: Set(effects),
            mount: mount
        ) { invocation in
            CapabilityExecutionResult(output: .init(kind: .text, text: "ran \(invocation.name)"))
        }
    }

    private struct FakePlugin: AgentPlugin {
        var id: String
        var toolList: [PluginTool]
        var blocks: @Sendable (Set<String>) -> [PromptBlock] = { _ in [] }
        var dataScope: PluginDataScope = .tenant
        var memoryExclusions: [String] = []
        var memoryGuidance: [String] = []

        func tools(context: PluginContext) -> [PluginTool] { toolList }
        func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] { blocks(mountedTools) }
    }

    private let notes = FakePlugin(id: "notes", toolList: [tool("list_notes", .read), tool("write_note", .writeLocal)])
    private let ask = FakePlugin(id: "ask", toolList: [tool("ask_user", .needsUser)])
    private let search = FakePlugin(id: "search", toolList: [tool("web_search", .external)])

    private func names(_ plugins: [any AgentPlugin], _ context: PluginContext) -> [String] {
        PluginHost.assemble(plugins, context: context).registry.definitions.map(\.name)
    }

    @Test func keepsRegistrationOrderAcrossPlugins() {
        #expect(names([ask, notes, search], PluginContext()) == ["ask_user", "list_notes", "write_note", "web_search"])
    }

    @Test func privateSessionDropsEveryLocalWrite() {
        #expect(names([ask, notes, search], PluginContext(isPrivate: true)) == ["ask_user", "list_notes", "web_search"])
    }

    @Test func backgroundTurnDropsWritesAndUserPrompts() {
        #expect(names([ask, notes, search], PluginContext(isBackground: true)) == ["list_notes", "web_search"])
    }

    @Test func unlockedToolsOnlyMountAfterTheirTrigger() {
        let recall = FakePlugin(id: "recall", toolList: [Self.tool("search_sessions", .read, mount: .whenUnlocked("recall"))])
        #expect(names([recall], PluginContext()).isEmpty)
        #expect(names([recall], PluginContext(unlockedTriggers: ["recall"])) == ["search_sessions"])
    }

    @Test func deviceOwnerPluginsDisappearForOtherMembers() {
        let owned = FakePlugin(id: "owned", toolList: [Self.tool("owner_data", .read)], dataScope: .deviceOwner)
        #expect(names([owned], PluginContext()) == ["owner_data"])
        #expect(names([owned], PluginContext(isDeviceOwner: false)).isEmpty)
    }

    @Test func blocksSortByOrderAndSeeOnlyMountedTools() {
        let guided = FakePlugin(id: "guided", toolList: [Self.tool("write_note", .writeLocal)]) { mounted in
            var blocks = [PromptBlock(order: 30, text: "snapshot")]
            if mounted.contains("write_note") { blocks.append(PromptBlock(order: 100, text: "use write_note")) }
            if mounted.contains("ask_user") { blocks.append(PromptBlock(order: 90, text: "use ask_user")) }
            return blocks
        }
        let core = [PromptBlock(order: 0, text: "base"), PromptBlock(order: 200, text: "persona")]

        let normal = PluginHost.assemble([ask, guided], context: PluginContext(), coreBlocks: core)
        #expect(normal.instruction() == "base\n\nsnapshot\n\nuse ask_user\n\nuse write_note\n\npersona")

        let privateOne = PluginHost.assemble([ask, guided], context: PluginContext(isPrivate: true), coreBlocks: core)
        #expect(privateOne.instruction() == "base\n\nsnapshot\n\nuse ask_user\n\npersona")
    }

    @Test func sameOrderKeepsRegistrationOrder() {
        let a = FakePlugin(id: "a", toolList: []) { _ in [PromptBlock(order: 5, text: "a")] }
        let b = FakePlugin(id: "b", toolList: []) { _ in [PromptBlock(order: 5, text: "b")] }
        #expect(PluginHost.assemble([a, b], context: PluginContext()).instruction() == "a\n\nb")
        #expect(PluginHost.assemble([b, a], context: PluginContext()).instruction() == "b\n\na")
    }

    @Test func executesThroughTheOwningTool() async {
        let registry = PluginHost.assemble([ask, notes], context: PluginContext()).registry
        let ran = await registry.execute(CapabilityInvocation(toolCallId: "1", name: "list_notes", input: "{}"))
        #expect(ran.output.text == "ran list_notes")

        let filtered = PluginHost.assemble([notes], context: PluginContext(isPrivate: true)).registry
        let denied = await filtered.execute(CapabilityInvocation(toolCallId: "2", name: "write_note", input: "{}"))
        #expect(denied.isError)
    }

    // MARK: - 记忆排除项

    private final class ReadsExclusions: AgentPlugin, @unchecked Sendable {
        let id = "reader"
        var seenByTools: [String]?
        var seenByBlocks: [String]?

        func tools(context: PluginContext) -> [PluginTool] {
            seenByTools = context.memoryExclusions
            return []
        }

        func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
            seenByBlocks = context.memoryExclusions
            return []
        }
    }

    @Test func hostHandsEveryPluginTheExclusionsDeclaredByTheOthers() {
        let reader = ReadsExclusions()
        let meds = FakePlugin(id: "meds", toolList: [], memoryExclusions: ["用药与补剂"])
        let vitals = FakePlugin(id: "vitals", toolList: [], memoryExclusions: ["测量数字", "用药与补剂"])
        _ = PluginHost.assemble([reader, meds, vitals], context: PluginContext())
        #expect(reader.seenByTools == ["用药与补剂", "测量数字"])
        #expect(reader.seenByBlocks == ["用药与补剂", "测量数字"])
    }

    @Test func memoryPolicyCollectsExclusionsAndGuidanceFromActivePlugins() {
        let a = FakePlugin(id: "a", toolList: [], memoryExclusions: ["X"], memoryGuidance: ["g1"])
        let b = FakePlugin(id: "b", toolList: [], memoryExclusions: ["X", "Y"], memoryGuidance: ["g2"])
        let policy = PluginHost.memoryPolicy([a, b])
        #expect(policy.exclusions == ["X", "Y"])
        #expect(policy.guidance == ["g1", "g2"])
    }

    @Test func memoryPolicySkipsDeviceOwnerPluginsForOtherMembers() {
        let owner = FakePlugin(id: "owner", toolList: [], dataScope: .deviceOwner, memoryExclusions: ["机主的数据"])
        let tenant = FakePlugin(id: "tenant", toolList: [], memoryExclusions: ["成员的数据"])
        let policy = PluginHost.memoryPolicy([owner, tenant], context: PluginContext(isDeviceOwner: false))
        #expect(policy.exclusions == ["成员的数据"])
    }
}

@Suite("Window policy")
struct WindowPolicyTests {
    private let policy = WindowPolicy(budgetTokens: 1000, lowRatio: 0.4, minTailTurns: 3)

    @Test func nothingHappensUntilTheHighWatermarkIsReached() {
        #expect(policy.turnsToEvict([]) == 0)
        #expect(policy.turnsToEvict([200, 200, 200, 200, 200]) == 0)
    }

    @Test func onceOverItCutsDownToTheLowWatermarkInOneStep() {
        let turns = [200, 200, 200, 200, 100, 100, 100]
        let evicted = policy.turnsToEvict(turns)
        #expect(evicted == 4)
        #expect(turns.dropFirst(evicted).reduce(0, +) <= policy.lowWatermark)
    }

    @Test func evictionIsBatchedSoTheNextTurnsDoNotTriggerAnotherOneImmediately() {
        let turns = [200, 200, 200, 200, 100, 100, 100]
        var after = Array(turns.dropFirst(policy.turnsToEvict(turns)))
        var appended = 0
        while policy.turnsToEvict(after) == 0 {
            after.append(100)
            appended += 1
        }
        #expect(appended >= 4, "淘汰之后应当还有余量：只追加了 \(appended) 轮")
    }

    @Test func newestTurnsAreNeverEvictedEvenWhenTheyAloneExceedTheBudget() {
        #expect(policy.turnsToEvict([100, 800, 800, 800]) == 1)
        #expect(policy.turnsToEvict([800, 800, 800]) == 0)
    }

    @Test func singleHugeCurrentTurnIsProtectedToo() {
        let single = WindowPolicy(budgetTokens: 1000, minTailTurns: 1)
        #expect(single.turnsToEvict([5000]) == 0)
        #expect(single.turnsToEvict([300, 5000]) == 1)
    }

    @Test func budgetIsAboutAThirdOfTheContextClampedAndHasADefault() {
        #expect(WindowPolicy.budget(forContextWindow: nil) == 16_000)
        #expect(WindowPolicy.budget(forContextWindow: 0) == 16_000)
        #expect(WindowPolicy.budget(forContextWindow: 8_000) == 12_000)
        #expect(WindowPolicy.budget(forContextWindow: 128_000) == 32_000)
        #expect(WindowPolicy.budget(forContextWindow: 60_000) == 21_000)
    }
}

@Suite("Token estimate")
struct TokenEstimateTests {
    @Test func chineseCountsOneTokenPerCharacter() {
        #expect(TokenEstimate.text("你好世界") == 4)
    }

    @Test func asciiCountsRoughlyFourCharactersPerToken() {
        #expect(TokenEstimate.text("abcd") == 1)
        #expect(TokenEstimate.text("abcde") == 2)
        #expect(TokenEstimate.text("") == 0)
    }

    @Test func mixedTextAddsBoth() {
        #expect(TokenEstimate.text("睡了 7 小时") == 4 + 1)
    }

    @Test func definitionsCountTheSchemaThatIsSent() {
        let definition = CapabilityDefinition(
            name: "remember",
            description: "记住一条",
            inputSchema: .object(["type": "object"])
        )
        #expect(TokenEstimate.definition(definition) > TokenEstimate.text("remember") + TokenEstimate.text("记住一条"))
    }
}
