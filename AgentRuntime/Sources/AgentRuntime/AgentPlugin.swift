import Foundation

/// 一个工具会碰到什么。装配时按它统一过滤,而不是每个调用点各传一串 `allowsXWrites`。
///
/// 「隐私会话」按写入路径定义,不按名字:它丢掉的就是全部 `.writeLocal`。以前是三个参数
/// 各堵一条路(`allowsMemoryWrites` / `allowsMedicationWrites` / …),加一个会写盘的工具就要
/// 记得在每个调用点再加一个参数——漏一次,「不保存」就成了假话。
public enum ToolEffect: String, Sendable, Hashable, CaseIterable {
    /// 只读本机数据或打包资源。
    case read
    /// 往本机盘上写(记忆,以及各插件自己的数据)。隐私会话和后台派生都不挂。
    case writeLocal
    /// 发到模型以外的第三方(网页搜索、读网页)。
    case external
    /// 产出要等用户点一下才有意义(ask_user 那张卡、开始任务的确认卡)。后台派生没人在场,不挂。
    case needsUser
}

/// 插件读的是谁的数据。HealthKit 属于机主,不属于当前选中的成员(见 CLAUDE.md「家庭成员」)。
public enum PluginDataScope: Sendable, Hashable {
    case tenant
    case deviceOwner
}

/// 工具什么时候挂出去。`.whenUnlocked` 由 app 判,解锁之后粘住不撤——一轮挂一轮撤会把
/// prompt 缓存的前缀反复打掉。
public enum MountPolicy: Sendable, Hashable {
    case always
    case whenUnlocked(String)
}

public struct PluginTool: Sendable {
    public var definition: CapabilityDefinition
    public var effects: Set<ToolEffect>
    public var mount: MountPolicy
    private let executeClosure: @Sendable (CapabilityInvocation) async -> CapabilityExecutionResult

    public var name: String { definition.name }

    public init(
        definition: CapabilityDefinition,
        effects: Set<ToolEffect>,
        mount: MountPolicy = .always,
        execute: @escaping @Sendable (CapabilityInvocation) async -> CapabilityExecutionResult
    ) {
        self.definition = definition
        self.effects = effects
        self.mount = mount
        self.executeClosure = execute
    }

    public func execute(_ invocation: CapabilityInvocation) async -> CapabilityExecutionResult {
        await executeClosure(invocation)
    }

    /// 把一个现成的 registry 拆成逐个工具。`effects` 按工具名给出副作用;执行仍然走原 registry。
    public static func from(
        _ registry: CapabilityRegistry,
        mount: MountPolicy = .always,
        effects: (String) -> Set<ToolEffect>
    ) -> [PluginTool] {
        registry.definitions.map { definition in
            PluginTool(definition: definition, effects: effects(definition.name), mount: mount) { invocation in
                await registry.execute(invocation)
            }
        }
    }
}

/// 一段进 system 段的文字。`order` 决定它排在哪:同一个插件的几段可以分散在不同位置
/// (用药名单排在易变区,「怎么用 log_medication」排在工具说明那一片)。
/// 排序是稳定的,同 order 按插件注册顺序。
public struct PromptBlock: Sendable, Equatable {
    public var order: Int
    public var text: String

    public init(order: Int, text: String) {
        self.order = order
        self.text = text
    }
}

public struct PluginContext: Sendable, Equatable {
    /// 隐私会话:不往盘上写。
    public var isPrivate: Bool
    /// 后台派生:用户不在场。
    public var isBackground: Bool
    /// 当前成员是不是机主。
    public var isDeviceOwner: Bool
    /// app 已经判定解锁的触发器(见 `MountPolicy.whenUnlocked`)。
    public var unlockedTriggers: Set<String>
    /// 这一路上**所有生效插件**声明的「有专门存放处、别记进记忆」的话题。由 `PluginHost.assemble`
    /// 填进来,调用方不用管;`remember` 的工具描述照它拼。
    public var memoryExclusions: [String]

    public init(
        isPrivate: Bool = false,
        isBackground: Bool = false,
        isDeviceOwner: Bool = true,
        unlockedTriggers: Set<String> = [],
        memoryExclusions: [String] = []
    ) {
        self.isPrivate = isPrivate
        self.isBackground = isBackground
        self.isDeviceOwner = isDeviceOwner
        self.unlockedTriggers = unlockedTriggers
        self.memoryExclusions = memoryExclusions
    }
}

/// 插件:一组工具加几段提示词,安装、开关、隔离的单位。
///
/// 插件自己的开关(设置里关掉用药表)和数据由构造它的那一侧决定——关掉了就不构造,
/// 或者 `tools` 返回空。「不挂出去」,而不是「挂了返回空」:给一个只会报错的工具,
/// 模型得先调一次才知道不行。
public protocol AgentPlugin: Sendable {
    var id: String { get }
    var dataScope: PluginDataScope { get }

    /// 抽记忆时要让路的话题(短标签):这个插件自己存着的东西,别在记忆里再存一份。
    /// **只在它真的存着的时候才声明**——用药表关了,「我不能吃布洛芬」就该进记忆。
    var memoryExclusions: [String] { get }

    /// 给记忆抽取器的补充说明(整句):这个领域里什么值得记、什么不该记。
    var memoryGuidance: [String] { get }

    func tools(context: PluginContext) -> [PluginTool]

    /// `mountedTools` 是装配完之后真的挂出去的全部工具名(所有插件的)。
    /// 工具说明照着它拼:工具没挂出去,那段「该调 xxx」也不发。
    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock]
}

public extension AgentPlugin {
    var dataScope: PluginDataScope { .tenant }
    var memoryExclusions: [String] { [] }
    var memoryGuidance: [String] { [] }
    func tools(context: PluginContext) -> [PluginTool] { [] }
    func promptBlocks(context: PluginContext, mountedTools: Set<String>) -> [PromptBlock] { [] }
}

/// 记忆抽取器要看的、来自各插件的那部分规则。
public struct MemoryPolicy: Sendable, Equatable {
    public var exclusions: [String]
    public var guidance: [String]

    public init(exclusions: [String] = [], guidance: [String] = []) {
        self.exclusions = exclusions
        self.guidance = guidance
    }
}

public struct PluginAssembly: Sendable {
    public var registry: CapabilityRegistry
    public var blocks: [PromptBlock]

    /// 按 order 稳定排序后用空行接起来。
    public func instruction() -> String {
        blocks.enumerated()
            .sorted { ($0.element.order, $0.offset) < ($1.element.order, $1.offset) }
            .map(\.element.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

public enum PluginHost {
    private static func active(_ plugins: [any AgentPlugin], _ context: PluginContext) -> [any AgentPlugin] {
        plugins.filter { $0.dataScope == .tenant || context.isDeviceOwner }
    }

    /// 生效的插件(按数据归属过滤后)合起来要抽取器遵守的规则。
    public static func memoryPolicy(
        _ plugins: [any AgentPlugin],
        context: PluginContext = PluginContext()
    ) -> MemoryPolicy {
        let active = active(plugins, context)
        return MemoryPolicy(
            exclusions: active.flatMap(\.memoryExclusions).uniqued(),
            guidance: active.flatMap(\.memoryGuidance)
        )
    }

    /// 这个上下文里某个工具能不能挂出去。
    public static func allows(_ tool: PluginTool, context: PluginContext) -> Bool {
        if context.isPrivate && tool.effects.contains(.writeLocal) { return false }
        if context.isBackground && !tool.effects.isDisjoint(with: [.writeLocal, .needsUser]) { return false }
        switch tool.mount {
        case .always: return true
        case .whenUnlocked(let trigger): return context.unlockedTriggers.contains(trigger)
        }
    }

    public static func assemble(
        _ plugins: [any AgentPlugin],
        context: PluginContext,
        coreBlocks: [PromptBlock] = []
    ) -> PluginAssembly {
        let active = active(plugins, context)
        // 每个插件都能看到「别的插件声明了哪些话题有专门存放处」,而不必互相认识。
        var context = context
        context.memoryExclusions = active.flatMap(\.memoryExclusions).uniqued()
        let tools = active.flatMap { plugin in plugin.tools(context: context).filter { allows($0, context: context) } }
        var byName: [String: PluginTool] = [:]
        var definitions: [CapabilityDefinition] = []
        for tool in tools where byName[tool.name] == nil {
            byName[tool.name] = tool
            definitions.append(tool.definition)
        }
        let registry: CapabilityRegistry
        if definitions.isEmpty {
            registry = .empty
        } else {
            let lookup = byName
            registry = CapabilityRegistry(definitions: definitions) { invocation in
                guard let tool = lookup[invocation.name] else {
                    return CapabilityExecutionResult(
                        output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                        isError: true
                    )
                }
                return await tool.execute(invocation)
            }
        }
        let mounted = Set(byName.keys)
        let blocks = coreBlocks + active.flatMap { $0.promptBlocks(context: context, mountedTools: mounted) }
        return PluginAssembly(registry: registry, blocks: blocks)
    }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
