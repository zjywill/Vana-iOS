import Foundation
import AgentRuntime

/// 这一轮工具挑中的动作。跟着 `AgentToolOutput.metadata` 走,卡片照着它渲染。
///
/// **卡片由工具返回的 id 决定,不认正文里的标记。** 让模型在回复里写
/// `[[动作:xxx]]` 的话,它迟早会编一个库里没有的名字出来——而正文写着「参考下面的图示」、
/// 底下却没有那一张,是这套东西最糟的一种失灵。闭集 + 工具锚定让它不可能发生。
struct ExerciseSelection: Codable, Equatable, Sendable {
    let moveIDs: [String]

    static func encodeForToolMetadata(_ selection: ExerciseSelection) -> RuntimeJSONValue? {
        guard let data = try? JSONEncoder().encode(selection) else { return nil }
        return try? JSONDecoder().decode(RuntimeJSONValue.self, from: data)
    }

    /// 健康查询的 metadata 装的是 `HealthReport`,两边互相解不出来(必填键不一样),
    /// 所以同一个字段上并存是安全的。
    static func decode(fromToolMetadata metadata: RuntimeJSONValue?) -> ExerciseSelection? {
        guard let metadata else { return nil }
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return try? JSONDecoder().decode(ExerciseSelection.self, from: data)
    }
}

/// 拉伸与简单锻炼:从打进包里的闭集里挑几个动作,卡片带图显示在这条回复下面。
///
/// **它补的不是知识,是表达。** 模型本来就知道该拉哪儿,只是「弓步下沉,后腿膝盖着地」
/// 这几个字对没练过的人是一串听不懂的词。所以工具返回的是名字和步骤,**图不进上下文**
/// ——图对模型是零信息,对预算是纯损失(同「逐小时序列只画在面板里」)。
enum ExerciseTools {
    static let suggestToolName = "suggest_exercises"

    /// 可以被排除的关节。用户说过哪儿不好,带那个关节的整组根本不返回。
    static let joints = ["颈", "肩", "肘", "腕", "腰", "髋", "膝", "踝"]

    /// 按部位挑时的闭集。**和场景是两把尺子**:「在工位上能做点什么」问的是场合,
    /// 「练胸」问的是部位,合成一个枚举的话模型每次都要在两类东西里挑一个,而它们
    /// 根本不互斥。
    static let regions = [
        "胸", "背", "肩", "手臂", "核心", "腰背", "臀", "腿", "小腿", "髋", "拉伸"
    ]

    /// 用户手边可能有什么。**这是硬过滤**:没说的时候只给
    /// `ExerciseLibrary.householdEquipment` 那几样。
    static let equipmentKinds = [
        "徒手", "墙", "门框", "毛巾", "椅子", "长凳", "箱子",
        "哑铃", "杠铃", "杠铃片", "壶铃", "弹力带", "绳索", "器械", "单杠", "瑜伽球"
    ]

    static func registry(library: ExerciseLibrary = .shared) -> CapabilityRegistry {
        CapabilityRegistry(definitions: [suggestDefinition(library: library)]) { invocation in
            guard invocation.name == suggestToolName else {
                return CapabilityExecutionResult(
                    output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                    isError: true
                )
            }
            return suggest(invocation, library: library)
        }
    }

    // MARK: - 定义

    private static func suggestDefinition(library: ExerciseLibrary) -> CapabilityDefinition {
        let scene: RuntimeJSONValue = .object([
            "type": "string",
            "description": .string(
                "什么场合，比如他在工位上、睡前、跑步之前。"
                    + "和 part 至少给一个；「跑完拉一下腿」这种两个都给"
            ),
            "enum": .array(library.scenes.map(RuntimeJSONValue.string))
        ])
        let part: RuntimeJSONValue = .object([
            "type": "string",
            "description": "练哪儿。他说「练胸」「练腿」时用这个，和 scene 至少给一个",
            "enum": .array(regions.map(RuntimeJSONValue.string))
        ])
        let equipment: RuntimeJSONValue = .object([
            "type": "array",
            "description": .string(
                "他手边有什么。**不确定就别传**——不传时只给徒手和家里现成的东西"
                    + "（墙、门框、毛巾、椅子）。他说了在健身房、或者说了有哑铃有弹力带，"
                    + "才把对应的几样列进来。列了他没有的，换回来的是一张他做不了的卡"
            ),
            "items": .object([
                "type": "string",
                "enum": .array(equipmentKinds.map(RuntimeJSONValue.string))
            ])
        ])
        let advanced: RuntimeJSONValue = .object([
            "type": "boolean",
            "description": .string(
                "他明确说了想练难一点的、或者说了自己一直在健身，才传 true。"
                    + "默认不给单腿深蹲、倒立俯卧撑这一类需要基础的动作"
            )
        ])
        let excludeJoint: RuntimeJSONValue = .object([
            "type": "array",
            "description": .string(
                "用户说过不好、受过伤、做不了的关节。带这些关节的动作一个都不会返回。"
                    + "记忆或用药表里提到过的也要带上"
            ),
            "items": .object([
                "type": "string",
                "enum": .array(joints.map(RuntimeJSONValue.string))
            ])
        ])
        let noFloor: RuntimeJSONValue = .object([
            "type": "boolean",
            "description": "他不方便躺下或跪地时传 true，比如在办公室、在外面，或者他说了起身困难"
        ])
        let count: RuntimeJSONValue = .object([
            "type": "integer",
            "description": "要几个，1–4，默认 3",
            "minimum": 1,
            "maximum": 4
        ])
        let schema: RuntimeJSONValue = .object([
            "type": "object",
            "properties": .object([
                "scene": scene,
                "part": part,
                "equipment": equipment,
                "advanced": advanced,
                "excludeJoint": excludeJoint,
                "noFloor": noFloor,
                "count": count
            ]),
            // scene 和 part 都不是必填,但**至少要有一个**——这一条 JSON Schema 表达不了
            // (anyOf 在几家 provider 的 strict 模式下都不保证支持),所以写在两处的
            // description 里,执行那一侧再兜一道:两个都空时照实说这次没说清要什么。
            "required": .array([]),
            "additionalProperties": .bool(false)
        ])

        return CapabilityDefinition(
            name: suggestToolName,
            description: """
            在用户问「做点什么」「怎么拉伸」「有什么动作」，\
            或者你打算建议他活动一下的时候调用。\
            返回的动作会带图示显示在你这条回复下面，用户能照着做。\
            **只能推荐这个工具返回的动作**：库以外的动作没有图，说了他也不知道怎么做。\
            疼痛、受伤、术后、孕期不要调这个，先让他去看医生。
            """,
            inputSchema: schema,
            strictPreferred: false
        )
    }

    // MARK: - 执行

    private static func suggest(
        _ invocation: CapabilityInvocation,
        library: ExerciseLibrary
    ) -> CapabilityExecutionResult {
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let scene = input?["scene"]?.stringValue ?? ""
        let region = input?["part"]?.stringValue ?? ""
        let excluded = input?["excludeJoint"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let noFloor = input?["noFloor"]?.boolValue ?? false
        let advanced = input?["advanced"]?.boolValue ?? false
        // **没传和传了空数组是两回事。** 没传是「不知道他有什么」,走家里现成的那几样;
        // 传了空数组是模型明确说了「什么都没有」,那就只剩徒手。分不开的话,一次
        // `"equipment": []` 会被当成没问过,照样给他一张椅子上的动作。
        let equipment = input?["equipment"]?.arrayValue.map { $0.compactMap(\.stringValue) }
        let count = input?["count"]?.intValue ?? 3

        let picked = library.suggest(
            scene: scene,
            region: region,
            excludeJoints: excluded,
            avoidsFloor: noFloor,
            equipment: equipment,
            includesAdvanced: advanced,
            limit: count
        )

        // 挑不到**不是错误**(同 `search_sessions` / `web_search` 搜不到那条)。报成错误的话
        // 模型会以为工具坏了,换个说法再调一次,白花一轮。
        guard !picked.isEmpty else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: emptyText(
                    scene: scene,
                    region: region,
                    excluded: excluded,
                    equipment: equipment
                ))
            )
        }

        return CapabilityExecutionResult(
            output: .init(
                kind: .text,
                text: modelText(picked),
                metadata: ExerciseSelection.encodeForToolMetadata(
                    ExerciseSelection(moveIDs: picked.map(\.id))
                )
            )
        )
    }

    /// 挑不到时说给模型听的那一段。
    ///
    /// **要说清是被哪一条挡住的。** 「没有可推荐的动作」是一句死路:模型只能原样转告,
    /// 而用户其实只要补一句「我有哑铃」就能拿到一整组。所以把当时的条件念回去——
    /// 器械那一档尤其要念,因为它有一个**用户从没说过的默认值**(不传就只给徒手和家里
    /// 现成的),不念的话那次落空在他看来毫无道理。
    static func emptyText(
        scene: String,
        region: String = "",
        excluded: [String] = [],
        equipment: [String]? = nil
    ) -> String {
        let asked = [scene.isEmpty ? nil : "「\(scene)」", region.isEmpty ? nil : "「\(region)」"]
            .compactMap { $0 }
            .joined(separator: "、")
        guard !asked.isEmpty else {
            return "这次调用没说要什么：scene（什么场合）和 part（练哪儿）至少要给一个。"
                + "重新调一次，别自己编一个动作出来。"
        }

        var text = "动作库里 \(asked) 这一类"
        if !excluded.isEmpty {
            text += "，避开\(excluded.joined(separator: "、"))之后"
        }
        text += "没有可推荐的动作。"
        if let equipment {
            text += "这次限定了只用\(equipment.isEmpty ? "徒手" : equipment.joined(separator: "、"))。"
        } else {
            text += "这次没有指定器械，所以只找了徒手和家里现成的东西"
                + "（墙、门框、毛巾、椅子）能做的。他要是在健身房、或者手边有哑铃弹力带，"
                + "问一句再调一次就有了。"
        }
        return text + "照实告诉用户这次没有能配图的动作，需要的话让他去问康复师或医生。不要自己编一个动作出来。"
    }

    /// 给模型的那一份。**只有名字、步骤、要领和禁忌,没有图**。
    static func modelText(_ moves: [ExerciseMove]) -> String {
        var lines = ["为用户挑了这 \(moves.count) 个动作，卡片（含图示）已经显示在你这条回复下面："]
        for (index, move) in moves.enumerated() {
            lines.append("")
            lines.append("\(index + 1). \(move.zh)（\(move.part)；\(move.gear)）")
            lines.append(contentsOf: move.steps.map { "   - \($0)" })
            lines.append("   要领：\(move.cue)")
            lines.append("   什么情况别做：\(move.avoid)")
        }
        lines.append("")
        lines.append(footer)
        return lines.joined(separator: "\n")
    }

    /// 这三句是这个工具真正的产出,不是免责声明。有测试盯着。
    ///
    /// 少第一句,正文会把卡片上已经有的步骤再抄一遍,把用户自己问的那句话推到屏幕外面去。
    /// 少第二句,一个膝盖不好的人会拿到一组深蹲。少第三句,它会开始开处方。
    static let footer = """
        接下来：正文里不要把上面的步骤逐条复述一遍——卡片上已经有图和步骤了，\
        说清为什么挑这几个、他做的时候要注意什么就够了。\
        用户说过做不了的动作绝对不要提。\
        不要给次数、组数或者保持多少秒，让他按自己的感觉来，有不适就停。
        """
}
