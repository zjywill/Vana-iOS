import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 装配契约:**什么条件下挂哪些工具、发哪几段话、按什么顺序**。
///
/// 这一份不依赖任何录下来的文本,断言全是手写的规则,所以它同时是两件事:今天的行为的说明书,
/// 和往插件系统重构时的防线。重构前后每一条都得成立——包括工具的**顺序**:工具定义排在消息前面,
/// 顺序一变,prompt 缓存的前缀就整个打掉。
///
/// 和 `AssemblyGoldenTests` 的分工:那份逐字比对,只在「纯搬家」的那几步有意义;这一份只管
/// 结构(有没有、在不在、先后),所以改措辞的那几步(拆提示词)它照样成立。
///
/// 场景和装配入口都在 `AssemblyFixtures`。**`.serialized` 只挡得住本套件内部**:装配要临时改
/// `UserDefaults` 里的开关,和别的套件并行时有一个极小的窗口(`FollowUpRunnerTests` 那几条
/// 已经在这么做),夹具里设完就还原。
@Suite("Assembly contract", .serialized)
struct AssemblyContractTests {

    // MARK: - 工具

    /// 256 种开关组合。挂哪些、按什么顺序,写在 `CapabilityRegistry.healthChat` 里的
    /// 那一串 `if ... registries.append(...)`——这里是把它逐条翻成规则。
    @Test("every flag combination mounts exactly the tools the rules say, in order")
    func toolMountingMatrix() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var mismatches: [String] = []
        for flags in Self.allFlagCombinations() {
            let actual = AssemblyFixtures.registry(flags, stores: stores).definitions.map(\.name)
            let expected = Self.expectedToolNames(flags)
            if actual != expected {
                mismatches.append("\(flags)\n  应该: \(expected)\n  实际: \(actual)")
            }
        }

        #expect(
            mismatches.isEmpty,
            "\(mismatches.count) 种组合不对,前三种:\n\(mismatches.prefix(3).joined(separator: "\n"))"
        )
    }

    @Test("no tool name is mounted twice")
    func toolNamesAreUnique() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let names = AssemblyFixtures.registry(.allOn, stores: stores).definitions.map(\.name)
        #expect(Set(names).count == names.count, "重名的工具:\(names)")
    }

    /// 顺序写死在这儿,不是从代码里抄的:模型看到的工具表的前缀要稳定,健康在前、
    /// 记忆在最后是现在的样子。
    private static func expectedToolNames(_ flags: AssemblyFixtures.Flags) -> [String] {
        var names: [String] = []
        if flags.includesHealthTools {
            names += HealthTools.all.map(\.name)
        }
        // 动作库没有开关。
        names.append(ExerciseTools.suggestToolName)
        if flags.asksUser {
            names.append(AskUserTools.askToolName)
        }
        if flags.webSearch {
            names.append(WebSearchTools.searchToolName)
        }
        // 用药表有自己的开关,不归在记忆下面;隐私会话只挂读的那个。
        if flags.medicationsEnabled {
            names.append(MedicationTools.listToolName)
            if flags.allowsMedicationWrites {
                names += [MedicationTools.logToolName, MedicationTools.updateToolName]
            }
        }
        // 召回和记忆写入都归在 memoryEnabled 下面。
        if flags.memoryEnabled && flags.allowsRecall {
            names += [SessionRecallTools.searchToolName, SessionRecallTools.readToolName]
        }
        if flags.memoryEnabled && flags.allowsMemoryWrites {
            names.append(MemoryTools.rememberToolName)
        }
        return names
    }

    private static func allFlagCombinations() -> [AssemblyFixtures.Flags] {
        (0..<256).map { bits in
            AssemblyFixtures.Flags(
                includesHealthTools: bits & 1 != 0,
                allowsMemoryWrites: bits & 2 != 0,
                allowsRecall: bits & 4 != 0,
                allowsMedicationWrites: bits & 8 != 0,
                asksUser: bits & 16 != 0,
                webSearch: bits & 32 != 0,
                memoryEnabled: bits & 64 != 0,
                medicationsEnabled: bits & 128 != 0
            )
        }
    }

    // MARK: - system 段的顺序

    /// 全开的机主会话里,每一块出现的先后。
    ///
    /// 「身份」「日期」「急症」都在基础规则里,基础规则整段在最前面;后面各块的顺序是
    /// `AIKitEngine.systemInstruction()` 里一段段 `instructions +=` 的顺序。位置紧跟日期那一块
    /// 之后、记忆在人格前面、用药名单紧跟记忆——这些顺序各有各的理由(见那个函数里的注释),
    /// 这里只钉住结果。
    private static let ownerBlockOrder: [(name: String, marker: String)] = [
        ("身份", "你是 Vana 的健康助手"),
        ("日期", "今天是"),
        ("急症规则", "急症优先于一切"),
        ("基础规则结尾", "用户提出与健康数据无关的问题时"),
        ("位置", "他此刻大概在："),
        ("话题", "本次对话的话题："),
        ("目标", "这条对话属于他一件长期在做的事："),
        ("记忆", "关于这位用户（来自过往对话，不是健康数据）："),
        ("用药名单", "关于他和药/补剂（他自己记的，不是健康数据）："),
        ("用药话题", "这条对话围绕他记下的「"),
        ("召回", "默认不要去翻过往对话"),
        ("记用药的指令", "用户说出他和某样药或补剂的关系时"),
        ("remember 的指令", "用户明确要求记住某件事"),
        ("上网搜", "遇到你的知识里没有"),
        ("反问", "他的描述里缺一个"),
        ("插话", "用户可能在你还在查数据"),
        ("人格", "语气偏向教练")
    ]

    @Test("the system prompt blocks come in the order the engine builds them")
    func blockOrder() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let text = AssemblyFixtures.systemText(AssemblyFixtures.everything, stores: stores)
        Self.expectOrdered(Self.ownerBlockOrder, in: text)
    }

    /// 家人成员:成员身份块接在基础规则(含急症)后面,先于位置、记忆和用药——钉的是现状。
    /// 健康工具那几条规则整个不发,那些工具根本没挂。
    @Test("a managed member's prompt says who they are and drops the health-tool rules")
    func managedMemberPrompt() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let text = AssemblyFixtures.systemText(AssemblyFixtures.managedSenior, stores: stores)

        #expect(text.contains("关于这次对话的对象："))
        #expect(!text.contains("先调用合适的健康工具"))
        #expect(!text.contains("引导其询问步数"))
        Self.expectOrdered(
            [
                ("急症规则", "急症优先于一切"),
                ("成员身份", "关于这次对话的对象："),
                ("用药名单", "关于他和药/补剂（他自己记的，不是健康数据）：")
            ],
            in: text
        )
    }

    // MARK: - 每一段的条件

    /// 每一段「怎么用某个工具」的话,只在那个工具真的挂出去时才发。对着一个没挂出去的工具发指令,
    /// 模型只会调一次、失败一次,再自己想办法圆场。
    @Test("each tool paragraph is only sent when its tool is mounted")
    func paragraphsFollowTheRegistry() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        typealias Disable = (inout AssemblyFixtures.Flags) -> Void
        let toggles: [(name: String, marker: String, disable: Disable)] = [
            ("asksUser", "他的描述里缺一个", { $0.asksUser = false }),
            ("webSearch", "遇到你的知识里没有", { $0.webSearch = false }),
            ("allowsRecall", "默认不要去翻过往对话", { $0.allowsRecall = false }),
            ("allowsMemoryWrites", "用户明确要求记住某件事", { $0.allowsMemoryWrites = false }),
            ("memoryEnabled", "用户明确要求记住某件事", { $0.memoryEnabled = false }),
            ("allowsMedicationWrites", "用户说出他和某样药或补剂的关系时", { $0.allowsMedicationWrites = false }),
            ("medicationsEnabled", "用户说出他和某样药或补剂的关系时", { $0.medicationsEnabled = false })
        ]

        let baseline = AssemblyFixtures.systemText(AssemblyFixtures.everything, stores: stores)
        for toggle in toggles {
            #expect(baseline.contains(toggle.marker), "全开时应该有「\(toggle.marker)」")

            var scenario = AssemblyFixtures.everything
            toggle.disable(&scenario.flags)
            let text = AssemblyFixtures.systemText(scenario, stores: stores)
            #expect(
                !text.contains(toggle.marker),
                "关掉 \(toggle.name) 之后不该还有「\(toggle.marker)」"
            )
        }
    }

    @Test("interjection paragraph is only sent to sessions that accept interjections")
    func interjectionsAreForegroundOnly() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.everything
        #expect(AssemblyFixtures.systemText(scenario, stores: stores).contains("用户可能在你还在查数据"))

        // 后台派生的那几轮没有用户在场,那段话对它们只是白占 token。
        scenario.acceptsInterjections = false
        #expect(!AssemblyFixtures.systemText(scenario, stores: stores).contains("用户可能在你还在查数据"))
    }

    /// 目标线那一段里「需要就用 search_sessions 往前翻」只在召回挂着时才说。
    @Test("the goal paragraph only points at search_sessions when recall is mounted")
    func goalParagraphFollowsRecall() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.Scenario(name: "goal", goal: "减脂")

        scenario.flags.allowsRecall = true
        #expect(AssemblyFixtures.systemText(scenario, stores: stores).contains("search_sessions"))

        scenario.flags.allowsRecall = false
        #expect(!AssemblyFixtures.systemText(scenario, stores: stores).contains("search_sessions"))
    }

    /// `remember` 那段里让路给用药表的那一句,只在用药写入工具挂着时才说。
    @Test("the remember paragraph only yields to the medication tools when they are mounted")
    func rememberYieldsToMedications() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.Scenario(name: "remember")

        let withMeds = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(withMeds.contains("用户明确要求记住某件事"))
        #expect(withMeds.contains("药和补剂不要用 remember 记"))

        scenario.flags.medicationsEnabled = false
        let withoutMeds = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(withoutMeds.contains("用户明确要求记住某件事"))
        #expect(!withoutMeds.contains("药和补剂不要用 remember 记"))
    }

    // MARK: - 工具

    /// 按先后顺序核对一串标记:每一个都得在,而且在前一个后面。
    private static func expectOrdered(
        _ markers: [(name: String, marker: String)],
        in text: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        var previous: String.Index?
        var previousName = ""
        for entry in markers {
            guard let range = text.range(of: entry.marker) else {
                Issue.record("缺了「\(entry.name)」:找不到「\(entry.marker)」", sourceLocation: sourceLocation)
                continue
            }
            if let previous, range.lowerBound <= previous {
                Issue.record("「\(entry.name)」应该排在「\(previousName)」后面", sourceLocation: sourceLocation)
            }
            previous = range.lowerBound
            previousName = entry.name
        }
    }
}
