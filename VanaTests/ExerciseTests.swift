import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 动作库:挑得对、说得住、图不进上下文。
///
/// 这套东西盯的大半是「不该发生什么」——排除掉的关节不许再出现、没有图的动作不许进库、
/// 图不许进模型上下文、挑不到不许报成错误、末尾那三句不许被删掉。最要紧的是排除那一条:
/// 记忆里写着「膝盖不好」而卡片上出现深蹲,是这个功能能出的最严重的一种故障。
@Suite("Exercise")
struct ExerciseTests {

    private let library = ExerciseLibrary.shared

    // MARK: - 库本身

    @Test("库能从 app 包里载进来")
    func libraryLoads() {
        #expect(library.moves.count >= 40)
        #expect(!library.scenes.isEmpty)
    }

    /// **没有图的动作不进库。** 一条只有文字的卡片,正是模型不用这个库也能写出来的东西——
    /// 它进来只会占 prompt、占卡片的位置,还让「卡片上有图」这句话变成有时候成立。
    @Test("每个动作都有图")
    func everyMoveHasImages() {
        for move in library.moves {
            #expect(!move.files.isEmpty, "\(move.id) 没有图")
            #expect(move.imageNames.allSatisfy { !$0.hasSuffix(".svg") })
        }
    }

    /// **一张静图说不出方向。** 库里曾经有 31 个动作只有一张彩色图标,用户的原话是
    /// 「不是动作,我都看不懂」——那正是这个功能最贵的一次失灵:图在、卡片在、步骤也在,
    /// 屏幕上没有任何一处报错,只是那张图没有回答「我该往哪个方向动」。
    /// 所以门槛不是「有图」,是**至少两帧**。
    @Test("每个动作至少两帧,不许有单张的")
    func everyMoveShowsMotion() {
        for move in library.moves {
            #expect(move.files.count >= 2, "\(move.id) 只有一张图,说不出动作方向")
        }
    }

    /// 每条都要有「什么情况别做」。这是卡片上唯一一句可能拦住伤害的话。
    @Test("每个动作都有步骤、要领和禁忌")
    func everyMoveIsComplete() {
        for move in library.moves {
            #expect(!move.steps.isEmpty, "\(move.id) 没有步骤")
            #expect(!move.cue.isEmpty, "\(move.id) 没有要领")
            #expect(!move.avoid.isEmpty, "\(move.id) 没有禁忌")
            #expect(!move.scenes.isEmpty, "\(move.id) 没有场景")
        }
    }

    /// **不给次数、组数、保持秒数**,同「剂量一律不给建议」那条线。
    /// 这条最容易在补动作时被破坏——原始英文数据里到处都是「hold for 20-30 seconds」,
    /// 照着译就带进来了。
    ///
    /// 判据是**数字紧跟着单位**,不是出现过「秒」这个字:plank 那句「多撑的每一秒都是在练错的
    /// 东西」说的正好是反面。按字面查会把它一起毙掉,而那是这套东西里最该留下的一句话。
    @Test("步骤里不出现次数、组数或保持秒数")
    func noDosage() throws {
        let pattern = try Regex(#"[0-9０-９]+\s*(秒|分钟|组|次|下|遍)"#)
        for move in library.moves {
            for line in move.steps + [move.cue, move.avoid] {
                #expect(
                    try pattern.firstMatch(in: line) == nil,
                    "\(move.id) 里给了具体的量：\(line)"
                )
            }
        }
    }

    @Test("场景标签都在声明过的那一组里")
    func scenesAreDeclared() {
        let known = Set(library.scenes)
        for move in library.moves {
            #expect(Set(move.scenes).isSubset(of: known), "\(move.id) 的场景不在名单里")
        }
    }

    @Test("关节标签都在 excludeJoint 那一组里")
    func riskJointsAreDeclared() {
        let known = Set(ExerciseTools.joints)
        for move in library.moves {
            #expect(Set(move.risk).isSubset(of: known), "\(move.id) 的关节标签不在名单里")
        }
    }

    // MARK: - 挑选

    @Test("按场景挑,默认三个")
    func suggestsByScene() {
        let picked = library.suggest(scene: "颈肩")
        #expect(!picked.isEmpty)
        #expect(picked.count <= 3)
        #expect(picked.allSatisfy { $0.scenes.contains("颈肩") })
    }

    /// **排除是硬的。** 排在后面不算——模型看到列表里有它就可能提一句,而用户已经说了做不了。
    @Test("排除掉的关节一个都不出现")
    func excludesJoints() {
        let picked = library.suggest(scene: "髋腿", excludeJoints: ["膝"], limit: 4)
        #expect(!picked.isEmpty)
        #expect(picked.allSatisfy { !$0.risk.contains("膝") })
    }

    @Test("不方便到地上时不给躺跪趴的动作")
    func avoidsFloor() {
        let picked = library.suggest(scene: "腰背", avoidsFloor: true, limit: 4)
        #expect(!picked.isEmpty)
        #expect(picked.allSatisfy { !$0.floor })
    }

    /// 同一个人在同一个场景下问两次拿到两组不同的动作,会让人以为前一组是随口说的。
    @Test("同样的条件挑出来的是同一组")
    func suggestionIsStable() {
        let first = library.suggest(scene: "睡前", limit: 3)
        let second = library.suggest(scene: "睡前", limit: 3)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("最多四个")
    func limitIsCapped() {
        #expect(library.suggest(scene: "腰背", limit: 99).count <= 4)
    }

    // MARK: - 工具

    @Test("挑中的动作 id 跟着 metadata 走,卡片照着它渲染")
    func selectionRidesInMetadata() async {
        let result = await run(#"{"scene":"颈肩"}"#)
        let ids = ExerciseSelection.decode(fromToolMetadata: result.output.metadata)?.moveIDs
        #expect(ids?.isEmpty == false)
        #expect(result.isError == false)
    }

    /// **图对模型是零信息,对预算是纯损失**(同「逐小时序列只画在面板里」)。
    @Test("图不进模型上下文")
    func imagesStayOutOfContext() async {
        let result = await run(#"{"scene":"颈肩"}"#)
        let text = result.output.text
        #expect(!text.contains(".svg"))
        for move in library.moves {
            for name in move.imageNames {
                #expect(!text.contains(name), "工具输出里出现了图名 \(name)")
            }
        }
    }

    /// 这三句是这个工具真正的产出,不是免责声明。少第一句,正文会把卡片上已经有的步骤再抄
    /// 一遍;少第二句,膝盖不好的人会拿到一组深蹲;少第三句,它会开始开处方。
    @Test("末尾那三句都在")
    func footerHoldsTheLine() async {
        let text = await run(#"{"scene":"腰背"}"#).output.text
        #expect(text.contains("不要把上面的步骤逐条复述"))
        #expect(text.contains("做不了的动作绝对不要提"))
        #expect(text.contains("不要给次数、组数"))
    }

    @Test("工具输出里带着中文名和步骤")
    func modelTextCarriesTheMoves() async {
        let picked = library.suggest(scene: "颈肩")
        let text = await run(#"{"scene":"颈肩"}"#).output.text
        for move in picked {
            #expect(text.contains(move.zh))
            #expect(move.steps.allSatisfy { text.contains($0) })
            #expect(text.contains(move.avoid))
        }
    }

    /// 挑不到**不是错误**(同 `search_sessions` / `web_search` 搜不到那条)。报成错误的话,
    /// 模型会以为工具坏了,换个说法再调一次,白花一轮。
    @Test("挑不到不是错误,而且明说不要自己编")
    func emptyIsNotAnError() async {
        let input = #"{"scene":"平衡","excludeJoint":["颈","肩","肘","腕","腰","髋","膝","踝"]}"#
        let result = await run(input)
        #expect(result.isError == false)
        #expect(result.output.text.contains("不要自己编"))
        #expect(ExerciseSelection.decode(fromToolMetadata: result.output.metadata) == nil)
    }

    @Test("认不出的工具名报错")
    func unknownToolIsAnError() async {
        let registry = ExerciseTools.registry()
        let result = await registry.execute(
            CapabilityInvocation(toolCallId: "1", name: "no_such_tool", input: "{}")
        )
        #expect(result.isError)
    }

    // MARK: - 装配与提示词

    /// 家人成员没有 Apple 健康数据,健康工具整组不挂——但动作库照挂。它不读 HealthKit、
    /// 不落盘、不联网,而那正是这个 app 里少有的、在家人身上完整成立的健康建议。
    @Test("家人成员那条路上照样挂得出去")
    func availableWithoutHealthTools() {
        let registry = CapabilityRegistry.healthChat(includesHealthTools: false)
        #expect(registry.definitions.contains { $0.name == ExerciseTools.suggestToolName })
    }

    /// 隐私会话承诺的是不留本机痕迹,而这个工具一个字都不往盘上写。
    @Test("隐私会话照挂")
    func availableInPrivateSessions() {
        let registry = CapabilityRegistry.healthChat(
            allowsMemoryWrites: false,
            allowsMedicationWrites: false
        )
        #expect(registry.definitions.contains { $0.name == ExerciseTools.suggestToolName })
    }

    /// 只挂工具不说话,模型不会想到去调;说了话不挂工具,它会调一个不存在的东西。
    @Test("系统提示里那几句都在")
    func instructionsMentionTheTool() {
        let text = HealthAssistantInstructions.text()
        #expect(text.contains(ExerciseTools.suggestToolName))
        #expect(text.contains("只推荐它返回的动作"))
        #expect(text.contains("excludeJoint"))
        #expect(text.contains("不要再逐条复述"))
        #expect(text.contains("不要给次数、组数"))
    }

    /// 署名是授权要求,不是礼貌:CC BY-SA 明写要保留出处,而少了那一行是静默的
    /// ——没人会点进「关于」发现它不见了。
    ///
    /// **改编者和原始来源两个名字都要在。** workout-guide 本身是 Everkinetic 的改编作品,
    /// CC BY-SA 的传递性要求两级都署;只署一个是这条路上最容易犯的错。
    @Test("两个图源的署名都在")
    func attributionsAreListed() {
        let joined = ExerciseLibrary.attributions.joined()
        #expect(joined.contains("everkinetic"))
        #expect(joined.contains("workout-guide"))
        #expect(joined.contains("Bryl Lim"))
        #expect(joined.contains("CC BY-SA"))
    }

    // MARK: - 存盘

    /// 卡片靠 id 渲染,所以 id 必须活过一次存盘。同一个字段上还躺着 `HealthReport`,
    /// 两边必填键不一样,互相解不出来——这条要有测试盯着,否则哪天加个字段就串了。
    @Test("挑中的动作存得下来,也不会和 HealthReport 串味")
    func selectionSurvivesPersistence() throws {
        let call = ToolCallRecord(
            id: "call-1",
            name: ExerciseTools.suggestToolName,
            input: #"{"scene":"颈肩"}"#,
            output: "…",
            exerciseIDs: ["neck-side", "cat-cow"]
        )
        let data = try JSONEncoder().encode(call)
        let decoded = try JSONDecoder().decode(ToolCallRecord.self, from: data)
        #expect(decoded.exerciseIDs == ["neck-side", "cat-cow"])
        #expect(decoded.report == nil)

        let metadata = call.metadataValue
        #expect(HealthReport.decode(fromToolMetadata: metadata) == nil)
        #expect(ExerciseSelection.decode(fromToolMetadata: metadata)?.moveIDs.count == 2)
    }

    // MARK: -

    private func run(_ input: String) async -> CapabilityExecutionResult {
        await ExerciseTools.registry().execute(
            CapabilityInvocation(toolCallId: "1", name: ExerciseTools.suggestToolName, input: input)
        )
    }
}
