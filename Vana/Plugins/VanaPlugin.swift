import Foundation
import AgentRuntime

/// 设置里能开关的东西的 id。子开关的 id 挂在所属插件下面(`health.medications`)。
/// 和 Android 那份 `PluginIds` 同一套字符串。
enum PluginIds {
    static let core = "core"
    static let memory = "memory"
    static let notes = "notes"
    static let health = "health"
    static let healthMedications = "health.medications"
}

/// 插件页上的一个入口:这个插件有哪些自己的页面。
/// 插件只说「是什么」(`id`),app 外壳决定「去哪儿」——路由表不该被插件反过来认识。
struct PluginSurface: Identifiable, Sendable, Equatable {
    static let medications = "medications"
    static let family = "family"
    static let notes = "notes"
    static let exercises = "exercises"

    let id: String
    let title: String
    let subtitle: String
    let icon: String
    /// 挂在哪个子开关下面(设置里能单独关);nil 表示这个入口没有独立开关。
    var toggleId: String?
}

/// 给插件页用的名片。`togglable` 为 false 的(核心)不出现在插件页,用户关不掉。
struct PluginManifest: Sendable, Equatable {
    let id: String
    let name: String
    let summary: String
    let icon: String
    let defaultEnabled: Bool
    var togglable = true
}

/// 首屏建议 chip 需要知道的那点上下文。完全本地拼,一次模型调用都不发。
struct SuggestionContext {
    var isEnabled: (String) -> Bool
    var tenant: Tenant
    var focusMedication: MedicationItem?
    var medications: MedicationSnapshot
}

/// 一个插件贡献的建议。`exclusive` 为 true 时说明它此刻有一个具体的上下文(正在聊某样药、
/// 正在替家人问),建议只该来自它——通用建议在这个时候是噪音。
struct SuggestionSet {
    var items: [SuggestedQuestion]
    var exclusive = false
}

/// 哪条路在装配:前台聊天,还是用户不在场的后台一轮。
enum PluginRoute: Sendable {
    case foreground
    case background
}

/// 装配一条路要用的全部输入。
///
/// 开关在这里就兑现成「有没有 store」:某一项关着,对应插件整个不构造,不是构造了返回空——
/// 给模型一个只会报错的工具,它得先调一次才知道不行。后台路用不到的保持默认的 nil。
struct PluginEnvironment: @unchecked Sendable {
    var isEnabled: @Sendable (String) -> Bool = EngineSettings.isPluginEnabled
    var tenant: Tenant = .owner()
    /// 召回的那两个工具。nil 就不挂(还没有看不见的历史,或者这条路不该翻)。
    var recall: CapabilityRegistry?
    var memoryStore: MemoryStore?
    var memory: MemorySnapshot = .empty
    var location: LocationSnapshot = .unknown
    var webSearch: WebSearchClient?
    var exerciseLibrary: ExerciseLibrary?
    /// Apple 健康那几个工具。**只有机主有**,而且只在前台和明确要它的后台一轮里挂。
    var includesHealthData = false
    var medicationStore: MedicationStore?
    var medications: MedicationSnapshot = .empty
    var focusMedication: MedicationItem?
    /// 旧会话模型的「话题」。一条对话落地之后删。
    var topic: ChatTopic?
    /// 用户正在做的那几件长期的事,常驻 system 段易变区。
    var goals: [String] = []
}

/// app 层的插件:名片加它在某条路上贡献的那几个 `AgentPlugin`。
/// `AgentRuntime` 只认识 `AgentPlugin`(工具加提示词),清单、开关、界面贡献都在这一层。
protocol VanaPlugin: Sendable {
    var manifest: PluginManifest { get }

    func agentPlugins(_ env: PluginEnvironment, route: PluginRoute) -> [any AgentPlugin]

    /// 这个插件自己的页面,列在插件页里。
    var surfaces: [PluginSurface] { get }

    /// 这个插件**拥有**的记忆种类(健康拥有「已有解释」)。插件关掉之后,这些种类的条目不再带进
    /// 对话(数据还在盘上,重新打开就回来),记忆页里标「暂不使用」。核心的种类不在任何插件名下。
    var memoryKinds: Set<MemoryKind> { get }

    /// 这个插件自己的免责声明,列在插件页里它的名字下面。
    var disclaimer: String? { get }

    /// 欢迎语里「我能帮你……」的那一小段。nil 就不提。
    var welcomeBlurb: String? { get }

    func suggestions(_ context: SuggestionContext) -> SuggestionSet
}

extension VanaPlugin {
    var surfaces: [PluginSurface] { [] }
    var memoryKinds: Set<MemoryKind> { [] }
    var disclaimer: String? { nil }
    var welcomeBlurb: String? { nil }
    func suggestions(_ context: SuggestionContext) -> SuggestionSet { SuggestionSet(items: []) }
}
