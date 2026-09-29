import Foundation
import AgentRuntime

/// 健康的规则本身,加上它对核心工具(搜索、反问、召回、记忆)的补充。没有工具,所以前台和后台都挂:
/// 那一轮没有用药表也没有动作库,但说到健康时该守的底线一条不少。
/// 记忆抽取器读这里的 `memoryGuidance`:什么算健康方面值得记的、什么不该记。
struct HealthRulesPlugin: AgentPlugin {
    let id = "\(PluginIds.health).rules"

    var memoryGuidance: [String] { HealthInstructions.memoryGuidance }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        var blocks = [PromptBlock(order: PromptOrder.healthRules, text: HealthInstructions.rules())]
        if let notes = HealthInstructions.toolNotes(mounted: mountedTools) {
            blocks.append(PromptBlock(order: PromptOrder.healthToolNotes, text: notes))
        }
        return blocks
    }
}

/// Apple 健康那几个工具。**数据归机主**(`dataScope = .deviceOwner`):切到家人时整组不挂——
/// 挂了的话模型会去查,而查回来的是机主的数字,它会一本正经地拿爸爸的静息心率解释妈妈的化验单,
/// 而且**不报错**。所以不是「挂了但返回空」,是根本不挂出去。
struct HealthDataPlugin: AgentPlugin {
    let id = "\(PluginIds.health).data"
    var dataScope: PluginDataScope { .deviceOwner }

    /// HealthKit 查得到的数字每次都会重新查,记进记忆第二天就是错的。
    var memoryExclusions: [String] { ["Apple 健康里查得到的数字"] }

    func tools(context: PluginContext) -> [PluginTool] {
        PluginTool.from(HealthTools.registry) { _ in [.read] }
    }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        guard let first = HealthTools.all.first, mountedTools.contains(first.name) else { return [] }
        return [PromptBlock(order: PromptOrder.guideHealthData, text: HealthInstructions.healthDataGuide)]
    }
}

/// 家人身份。**排在易变区最前面**(紧跟日期):它决定了后面每一句里的「他」指的是谁。
/// 放到记忆和用药表后面,模型已经按"用户本人"读完那两块了。
struct FamilyPlugin: AgentPlugin {
    let id = "\(PluginIds.health).family"
    let tenant: Tenant

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        guard let block = HealthInstructions.familyBlock(tenant) else { return [] }
        return [PromptBlock(order: PromptOrder.tenant, text: block)]
    }
}

/// 动作库。**没有自己的开关**:它不读 HealthKit、不落盘、不联网,一份打进包里的闭集而已——
/// 家人成员和隐私会话照挂。
struct ExercisePlugin: AgentPlugin {
    let id = "\(PluginIds.health).exercises"
    let library: ExerciseLibrary

    func tools(context: PluginContext) -> [PluginTool] {
        PluginTool.from(ExerciseTools.registry(library: library)) { _ in [.read] }
    }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        guard mountedTools.contains(ExerciseTools.suggestToolName) else { return [] }
        return [PromptBlock(order: PromptOrder.guideExercise, text: HealthInstructions.exerciseGuide)]
    }
}

/// 用药表。名单是**常驻段**,不做按需挂载:漏的代价不对称——要模型自己想起来去查,它想不起来的
/// 那次恰好就是最该说的那次(模型在不知道他吃着 β 阻滞剂的情况下解释他的静息心率)。
///
/// `store` 为 nil 就不挂工具(后台一轮);快照由调用方按开关给。隐私会话里读的那个照挂,
/// 写的两个由 `PluginContext.isPrivate` 丢掉——「他不能吃什么」在隐私会话里尤其不能关掉。
struct MedicationPlugin: AgentPlugin {
    let id = PluginIds.healthMedications
    let store: MedicationStore?
    let snapshot: MedicationSnapshot
    var focus: MedicationItem?

    /// 只在用药表真的开着的时候让路:关了它,「我不能吃布洛芬」就该老老实实进记忆。
    var memoryExclusions: [String] { store == nil ? [] : ["用药与补剂"] }

    func tools(context: PluginContext) -> [PluginTool] {
        guard let store else { return [] }
        return PluginTool.from(MedicationTools.registry(store: store, allowsWrites: true)) { name in
            name == MedicationTools.listToolName ? [.read] : [.writeLocal]
        }
    }

    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] {
        var blocks: [PromptBlock] = []
        if let block = snapshot.instructionBlock {
            blocks.append(PromptBlock(order: PromptOrder.medications, text: block))
        }
        // 以某一条为话题。放在名单后面:先看见整张表,再收窄到其中一条。
        if let focus {
            blocks.append(PromptBlock(order: PromptOrder.focusMedication, text: focus.focusInstruction))
        }
        if mountedTools.contains(MedicationTools.logToolName) {
            blocks.append(PromptBlock(order: PromptOrder.guideMedicationLog, text: HealthInstructions.medicationLogGuide))
        }
        return blocks
    }
}

/// 健康:规则、Apple 健康、用药表、动作库、家人身份。整个可关;用药表另有子开关。
/// 后台一轮只带规则和(调用方明确要的)Apple 健康——结论不取决于别的。
struct HealthVanaPlugin: VanaPlugin {
    var manifest: PluginManifest {
        PluginManifest(
            id: PluginIds.health,
            name: String(localized: "健康"),
            summary: String(localized: "读 Apple 健康、用药与补剂、锻炼动作库、化验单解读"),
            icon: "heart.text.square",
            defaultEnabled: true
        )
    }

    var surfaces: [PluginSurface] {
        [
            PluginSurface(
                id: PluginSurface.medications,
                title: String(localized: "用药与补剂"),
                subtitle: String(localized: "在吃的、不能吃的、试过没用的，分开记"),
                icon: "pills",
                toggleId: PluginIds.healthMedications
            ),
            PluginSurface(
                id: PluginSurface.family,
                title: String(localized: "家人档案"),
                subtitle: String(localized: "为家人分别记录用药和对话，数据互相隔离"),
                icon: "person.2"
            )
        ]
    }

    var disclaimer: String? { DataUseNotice.medicalDisclaimer }

    var memoryKinds: Set<MemoryKind> { [.interpretation] }

    var welcomeBlurb: String? { String(localized: "看懂 Apple 健康里的数据、解读化验单、记用药") }

    func suggestions(_ context: SuggestionContext) -> SuggestionSet {
        if let focus = context.focusMedication {
            return SuggestionSet(
                items: focus.openingQuestions.map { SuggestedQuestion(icon: focus.status.icon, text: $0) },
                exclusive: true
            )
        }
        guard context.tenant.isOwner else {
            return SuggestionSet(
                items: TenantOpening.questions(for: context.tenant, medications: context.medications),
                exclusive: true
            )
        }
        if !context.healthQuestions.isEmpty {
            return SuggestionSet(items: context.healthQuestions)
        }
        return SuggestionSet(items: [
            SuggestedQuestion(icon: "bed.double", text: String(localized: "昨晚睡得怎么样？")),
            SuggestedQuestion(icon: "doc.text.viewfinder", text: String(localized: "帮我看看这张化验单")),
            SuggestedQuestion(icon: "figure.walk", text: String(localized: "最近活动量够吗？"))
        ])
    }

    func todayCards(_ context: TodayContext) -> [TodayCard] { HealthToday.cards(context) }

    func agentPlugins(_ env: PluginEnvironment, route: PluginRoute) -> [any AgentPlugin] {
        guard env.isEnabled(PluginIds.health) else { return [] }
        var plugins: [any AgentPlugin] = [HealthRulesPlugin()]
        // 机主以外的成员由 `dataScope` 挡住,这里只管「这条路要不要它」。
        if env.includesHealthData { plugins.append(HealthDataPlugin()) }
        guard route == .foreground else { return plugins }
        if let library = env.exerciseLibrary { plugins.append(ExercisePlugin(library: library)) }
        if env.isEnabled(PluginIds.healthMedications) {
            plugins.append(MedicationPlugin(store: env.medicationStore, snapshot: env.medications, focus: env.focusMedication))
        }
        plugins.append(FamilyPlugin(tenant: env.tenant))
        return plugins
    }
}
