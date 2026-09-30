import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 装配契约:**什么条件下挂哪些工具、发哪几段话、按什么顺序**。
///
/// 这一份不依赖任何录下来的文本,断言全是手写的规则。重构前后每一条都得成立——包括工具的
/// **顺序**:工具定义排在消息前面,顺序一变,prompt 缓存的前缀就整个打掉。
///
/// 和 `AssemblyGoldenTests` 的分工:那份逐字比对,只在「纯搬家」的那几步有意义;这一份只管
/// 结构(有没有、在不在、先后),所以改措辞的那几步它照样成立。
///
/// 场景和装配入口都在 `AssemblyFixtures`。人格要临时改 UserDefaults,`.serialized` 只挡得住
/// 本套件内部,夹具里设完就还原。
@Suite("Assembly contract", .serialized)
struct AssemblyContractTests {

    // MARK: - 工具

    /// 256 种开关组合。挂哪些、按什么顺序,是各插件的 `tools` 加 `PluginHost` 的过滤——
    /// 这里是把它逐条翻成规则。
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

    /// 顺序写死在这儿,不是从代码里抄的:核心在前、健康在后,是插件的注册顺序。
    private static func expectedToolNames(_ flags: AssemblyFixtures.Flags) -> [String] {
        let writes = !flags.isPrivate && !flags.background
        var names: [String] = []
        // 核心
        if !flags.background { names.append(AskUserTools.askToolName) }
        if flags.webSearch { names.append(WebSearchTools.searchToolName) }
        // 读网页不要 key,前台总挂;后台只跟着搜索一起给(后台任务那一种)。
        if !flags.background || flags.webSearch { names.append(WebFetchTools.fetchToolName) }
        // 召回和记忆写入都归在记忆开关下面。
        if flags.memoryOn && flags.recall {
            names += [HistoryRecallTools.searchToolName, HistoryRecallTools.readToolName]
        }
        if flags.memoryOn && writes {
            names += [MemoryTools.rememberToolName, MemoryTools.forgetToolName, MemoryTools.reviseToolName]
        }
        // 提醒、目标、派后台任务:前台才有,不留痕那一层整组不带。
        if writes {
            names += [
                TasksTools.getTimeToolName, TasksTools.createReminderToolName, TasksTools.listToolName,
                TasksTools.updateTaskToolName, TasksTools.createGoalToolName, TasksTools.updateGoalToolName,
                SubagentTools.startToolName
            ]
        }
        // 笔记:只前台挂;不留痕只挂读的那两个。
        if !flags.background {
            if writes { names.append(NotesTools.save) }
            names += [NotesTools.list, NotesTools.read]
            if writes { names.append(NotesTools.update) }
        }
        // 健康
        guard flags.health else { return names }
        // Apple 健康归机主,家人身上一个都不挂。
        if flags.owner { names += HealthTools.all.map(\.name) }
        guard !flags.background else { return names }
        // 动作库没有开关。
        names.append(ExerciseTools.suggestToolName)
        // 用药表有自己的开关,不归在记忆下面;隐私会话只挂读的那个。
        if flags.medicationsOn {
            names.append(MedicationTools.listToolName)
            if writes { names += [MedicationTools.logToolName, MedicationTools.updateToolName] }
        }
        return names
    }

    private static func allFlagCombinations() -> [AssemblyFixtures.Flags] {
        (0..<256).map { bits in
            AssemblyFixtures.Flags(
                health: bits & 1 != 0,
                memoryOn: bits & 2 != 0,
                medicationsOn: bits & 4 != 0,
                webSearch: bits & 8 != 0,
                recall: bits & 16 != 0,
                isPrivate: bits & 32 != 0,
                background: bits & 64 != 0,
                owner: bits & 128 != 0
            )
        }
    }

    // MARK: - system 段的顺序

    /// 全开的机主会话里,每一块出现的先后。**静态的在前、易变的在后**(`PromptOrder`):
    /// prompt 缓存认前缀,记忆、位置、今天这些一变只该打掉尾巴。
    private static let ownerBlockOrder: [(name: String, marker: String)] = [
        ("身份", "你是 Vana，用户的日常助手"),
        ("安全底线", "人身安全优先于一切"),
        ("插话", "用户可能在你还在查资料"),
        ("人格", "语气偏向教练"),
        ("召回", "这条对话更早的部分已经滑出了"),
        ("记忆的指令", "用户明确要求记住某件事"),
        ("上网搜", "遇到你的知识里没有"),
        ("读网页", "用户发来一个链接想让你看"),
        ("反问", "他的描述里缺一个"),
        ("提醒与目标", "用户要你在某个时间提醒他做某件事时"),
        ("后台任务", "遇到**独立的、要花几分钟**的事"),
        ("笔记", "用户有自己的笔记和清单"),
        ("健康规则", "处理健康相关的话题"),
        ("急症规则", "急症优先于一切"),
        ("Apple 健康", "他的 Apple 健康数据"),
        ("动作库", "建议用户做拉伸或简单锻炼时"),
        ("记用药的指令", "用户说出他和某样药或补剂的关系时"),
        ("健康补充", "健康方面的补充"),
        ("日期", "今天是"),
        ("位置", "他此刻大概在："),
        ("记忆", "关于这位用户（来自过往对话）："),
        ("用药名单", "关于他和药/补剂"),
        ("用药焦点", "这条对话围绕他记下的「"),
        ("目标", "他正在推进的目标")
    ]

    @Test("the system prompt blocks come static first, volatile last")
    func blockOrder() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let text = AssemblyFixtures.systemText(AssemblyFixtures.everything, stores: stores)
        Self.expectOrdered(Self.ownerBlockOrder, in: text)
    }

    /// 家人成员:身份块排在易变区最前面,先于记忆和用药——它决定了后面每一句里的「他」指的是谁。
    /// Apple 健康那几条规则整个不发,那些工具根本没挂。
    @Test("a managed member's prompt says who they are and drops the health-data rules")
    func managedMemberPrompt() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let text = AssemblyFixtures.systemText(AssemblyFixtures.managedSenior, stores: stores)

        #expect(text.contains("关于这次对话的对象："))
        #expect(!text.contains("先调用合适的健康工具"))
        Self.expectOrdered(
            [
                ("急症规则", "急症优先于一切"),
                ("成员身份", "关于这次对话的对象："),
                ("用药名单", "关于他和药/补剂")
            ],
            in: text
        )
    }

    // MARK: - 每一段的条件

    /// 每一段「怎么用某个工具」的话,只在那个工具真的挂出去时才发。
    @Test("each tool paragraph is only sent when its tool is mounted")
    func paragraphsFollowTheRegistry() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        typealias Disable = (inout AssemblyFixtures.Flags) -> Void
        let toggles: [(name: String, marker: String, disable: Disable)] = [
            ("background", "他的描述里缺一个", { $0.background = true }),
            ("webSearch", "遇到你的知识里没有", { $0.webSearch = false }),
            ("recall", "这条对话更早的部分已经滑出了", { $0.recall = false }),
            ("background", "用户有自己的笔记和清单", { $0.background = true; $0.webSearch = false }),
            ("background", "用户发来一个链接想让你看", { $0.background = true; $0.webSearch = false }),
            ("isPrivate", "用户明确要求记住某件事", { $0.isPrivate = true }),
            ("memoryOn", "用户明确要求记住某件事", { $0.memoryOn = false }),
            ("isPrivate", "用户说出他和某样药或补剂的关系时", { $0.isPrivate = true }),
            ("medicationsOn", "用户说出他和某样药或补剂的关系时", { $0.medicationsOn = false }),
            ("owner", "他的 Apple 健康数据", { $0.owner = false }),
            ("health", "处理健康相关的话题", { $0.health = false })
        ]

        let baseline = AssemblyFixtures.systemText(AssemblyFixtures.everything, stores: stores)
        for toggle in toggles {
            #expect(baseline.contains(toggle.marker), "全开时应该有「\(toggle.marker)」")

            var scenario = AssemblyFixtures.everything
            toggle.disable(&scenario.flags)
            let text = AssemblyFixtures.systemText(scenario, stores: stores)
            #expect(!text.contains(toggle.marker), "改了 \(toggle.name) 之后不该还有「\(toggle.marker)」")
        }
    }

    @Test("interjection paragraph is only sent to sessions that accept interjections")
    func interjectionsAreForegroundOnly() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.everything
        #expect(AssemblyFixtures.systemText(scenario, stores: stores).contains("用户可能在你还在查资料"))

        scenario.acceptsInterjections = false
        #expect(!AssemblyFixtures.systemText(scenario, stores: stores).contains("用户可能在你还在查资料"))
    }

    /// 侧聊说明只在侧聊里发,排在静态区(插话之后、人格之前);还没起名时不写话题。
    /// 侧聊不属于哪个插件:健康关掉之后,侧聊里模型读到的东西照样一个健康词都没有。
    @Test("the side chat paragraph is only sent inside a side chat, in the static zone")
    func sideChatParagraph() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let marker = "这是一条侧聊"
        var scenario = AssemblyFixtures.everything
        #expect(!AssemblyFixtures.systemText(scenario, stores: stores).contains(marker))

        scenario.sideChatTitle = "十月去京都"
        let text = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(text.contains("话题是「十月去京都」"))
        Self.expectOrdered(
            [
                ("插话", "用户可能在你还在查资料"),
                ("侧聊", marker),
                ("人格", "语气偏向教练")
            ],
            in: text
        )

        scenario.sideChatTitle = ""
        let untitled = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(untitled.contains(marker))
        #expect(!untitled.contains("话题是"))

        scenario.flags.health = false
        scenario.focusMedication = nil
        scenario.sideChatTitle = "十月去京都"
        let corpus = Self.everythingTheModelReads(scenario, stores: stores)
        let leaked = Self.healthWords.filter { corpus.contains($0) }
        #expect(leaked.isEmpty, "侧聊里还有健康词：\(leaked)")
    }

    /// 召回够得着侧聊时:召回那段说清还有哪儿能翻;主对话里多一块侧聊名单,排在易变区最后,
    /// 并且说一句「他没提起时别主动说」。健康关掉之后照样没有健康词。
    @Test("recall across side chats adds its sentence and the side chat list, last")
    func recallReachParagraphs() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.everything
        scenario.goals = [TaskItem(kind: .goal, title: "每周运动三次", status: .queued)]
        let plain = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(!plain.contains("他另外开着几条侧聊"))
        #expect(!plain.contains("他提到他开的侧聊"))

        scenario.recallReach = RecallReach(
            ownHistory: true,
            others: "他开的侧聊",
            sideChats: [.init(title: "十月去京都", lastActiveAt: Date())]
        )
        let text = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(text.contains("他开的侧聊里说过的你在这里也看不到"))
        #expect(text.contains("他提到他开的侧聊里的事时也一样。"))
        #expect(text.contains("- 「十月去京都」，最近一次是"))
        #expect(text.contains("他没提起时不要主动说起它们"))
        Self.expectOrdered(
            [
                ("召回", "他开的侧聊里说过的你在这里也看不到"),
                ("目标", "他正在推进的目标"),
                ("侧聊名单", "他另外开着几条侧聊")
            ],
            in: text
        )

        // 召回没挂(记忆关着)就连名单一起不发:名单指向的正是召回那两个工具。
        var memoryOff = scenario
        memoryOff.flags.memoryOn = false
        #expect(!AssemblyFixtures.systemText(memoryOff, stores: stores).contains("他另外开着几条侧聊"))

        scenario.flags.health = false
        scenario.focusMedication = nil
        let corpus = Self.everythingTheModelReads(scenario, stores: stores)
        let leaked = Self.healthWords.filter { corpus.contains($0) }
        #expect(leaked.isEmpty, "侧聊名单里还有健康词：\(leaked)")
    }

    /// `remember` 那段里让路给用药表的那一句,只在用药写入工具挂着时才说。
    @Test("the remember paragraph only yields to the medication tools when they are mounted")
    func rememberYieldsToMedications() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.Scenario(name: "remember")
        let withMeds = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(withMeds.contains("用户明确要求记住某件事"))
        #expect(withMeds.contains("用药与补剂已经有专门的存放处"))
        #expect(withMeds.contains("药和补剂不要用 remember 记"))

        scenario.flags.medicationsOn = false
        let withoutMeds = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(withoutMeds.contains("用户明确要求记住某件事"))
        #expect(!withoutMeds.contains("用药与补剂已经有专门的存放处"))
        #expect(!withoutMeds.contains("药和补剂不要用 remember 记"))
    }

    // MARK: - 健康关掉

    /// 健康关掉之后,整段 system 加全部工具定义里**一个健康词都没有**——模型看到的是一个不认识
    /// 药、化验单和症状清单的日常助手。检测器自己也要验:健康开着时它必须命中一大把,
    /// 否则这条测试是在空转。
    private static let healthWords = [
        "用药", "药品", "药盒", "补剂", "化验", "诊断", "剂量", "血压", "心率", "体重", "体检",
        "症状", "不舒服", "病史", "健康", "就医", "医疗", "医生", "疾病", "过敏", "HealthKit",
        "suggest_exercises", "log_medication", "list_medications", "daily_steps"
    ]

    private static func everythingTheModelReads(_ scenario: AssemblyFixtures.Scenario, stores: AssemblyFixtures.Stores) -> String {
        let text = AssemblyFixtures.systemText(scenario, stores: stores)
        let definitions = AssemblyFixtures.engine(scenario, stores: stores).capabilityRegistry.definitions
        let encoder = JSONEncoder()
        let tools = definitions.map { String(decoding: (try? encoder.encode($0)) ?? Data(), as: UTF8.self) }
        return ([text] + tools).joined(separator: "\n")
            // JSONEncoder 会把中文编成原样,但保险起见也看一眼描述本身。
            + definitions.compactMap(\.description).joined(separator: "\n")
    }

    @Test("with health off, nothing the model reads mentions health")
    func healthOffLeavesNoHealthWords() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        for background in [false, true] {
            for isPrivate in [false, true] {
                for persona in AssistantPersona.allCases {
                    var scenario = AssemblyFixtures.everything
                    scenario.flags.health = false
                    scenario.flags.background = background
                    scenario.flags.isPrivate = isPrivate
                    scenario.persona = persona
                    scenario.focusMedication = nil
                    let corpus = Self.everythingTheModelReads(scenario, stores: stores)
                        // 样本里的记忆和用药是**用户的数据**,不是提示词。用药名单在健康关掉之后
                        // 本来就不进,记忆里那条「他觉得睡够 7 小时」不是健康词表里的词。
                    let leaked = Self.healthWords.filter { corpus.contains($0) }
                    #expect(leaked.isEmpty, "background=\(background) private=\(isPrivate) persona=\(persona) 里还有健康词：\(leaked)")
                }
            }
        }
    }

    @Test("the health-word detector is not idle: with health on it hits plenty")
    func healthWordDetectorIsNotIdle() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let corpus = Self.everythingTheModelReads(AssemblyFixtures.everything, stores: stores)
        let seen = Self.healthWords.filter { corpus.contains($0) }
        #expect(seen.count >= 15, "健康开着时应当命中大量健康词，实际只有：\(seen)")
    }

    @Test("with health off the safety floor is still there")
    func healthOffKeepsTheSafetyFloor() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.Scenario(name: "off")
        scenario.flags.health = false
        let text = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(text.contains("你是 Vana，用户的日常助手"))
        #expect(text.contains("拨打当地急救电话"))
        #expect(text.contains("想伤害自己或不想活了"))
        #expect(!text.contains("急症优先于一切"))
    }

    /// 健康关掉之后,健康拥有的那类记忆(已有解释)不进对话。数据还在盘上。
    @Test("memory kinds owned by health stay out of the prompt when health is off")
    func healthOwnedMemoryIsHidden() {
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        var scenario = AssemblyFixtures.Scenario(name: "memory", memory: AssemblyFixtures.sampleMemory)
        #expect(AssemblyFixtures.systemText(scenario, stores: stores).contains("他觉得睡够 7 小时才算好"))
        scenario.flags.health = false
        let text = AssemblyFixtures.systemText(scenario, stores: stores)
        #expect(!text.contains("他觉得睡够 7 小时才算好"))
        #expect(text.contains("他上夜班，作息不固定"))
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
