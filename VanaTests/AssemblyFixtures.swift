import Foundation
import AgentRuntime

@testable import Vana

/// 「这一轮到底给了模型什么」的测试夹具:同一批场景,喂给装配契约测试和黄金测试。
///
/// **装配换了形状,这个文件是唯一要改的地方。** `Flags` 到装配环境的映射在 `engine(_:stores:)`
/// 里;两套测试只认 `Flags` 和 `Scenario`,不认装配函数的签名。
enum AssemblyFixtures {

    // MARK: - 输入

    /// 影响「挂哪些工具、发哪几段话」的全部开关。插件开关直接交给装配环境的 `isEnabled`,
    /// 不去改 UserDefaults——那是别的测试也在读的全局状态。
    struct Flags: Equatable, Sendable, CustomStringConvertible {
        var health = true
        var memoryOn = true
        var medicationsOn = true
        var webSearch = false
        /// 有看不见的历史可翻(召回挂出去的前提)。
        var recall = false
        var isPrivate = false
        var background = false
        var owner = true

        /// 什么都挂上。
        static let allOn = Flags(webSearch: true, recall: true)

        var description: String {
            [
                "health=\(health.bit)",
                "memory=\(memoryOn.bit)",
                "meds=\(medicationsOn.bit)",
                "web=\(webSearch.bit)",
                "recall=\(recall.bit)",
                "private=\(isPrivate.bit)",
                "background=\(background.bit)",
                "owner=\(owner.bit)"
            ].joined(separator: " ")
        }

        var isEnabled: @Sendable (String) -> Bool {
            let flags = self
            return { id in
                switch id {
                case PluginIds.core: true
                case PluginIds.health: flags.health
                case PluginIds.memory: flags.memoryOn
                case PluginIds.healthMedications: flags.medicationsOn
                default: true
                }
            }
        }
    }

    /// 一次完整的装配输入:谁在聊、快照里有什么。
    struct Scenario {
        var name: String
        var tenant: Tenant?
        var flags = Flags()
        var memory: MemorySnapshot = .empty
        var medications: MedicationSnapshot = .empty
        var focusMedication: MedicationItem?
        var location: LocationSnapshot = .unknown
        var goals: [TaskItem] = []
        var acceptsInterjections = true
        var persona: AssistantPersona?
        /// 在哪条侧聊里(它的名字)。nil 是主对话。
        var sideChatTitle: String?
    }

    // MARK: - 临时 store

    /// 测试用的一套临时 store。**不许用 `.shared`**:app host 里那就是模拟器上真的 memory.json。
    struct Stores {
        let directory: URL
        let bundle: TenantStores

        init() {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "vana-assembly-\(UUID().uuidString)", directoryHint: .isDirectory)
            bundle = TenantStores(root: directory)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - 装配

    /// 网页搜索的替身。只要「挂没挂」,不要真的发请求。
    private static let searchStub = WebSearchClient { _ in WebSearchResults(query: "") }
    private static let fetchStub = WebFetchClient { url in WebPage(url: url, title: nil, text: "", truncated: false) }

    static let managedMember = Tenant(name: "妈妈", kind: .managed, ageBand: .senior)

    /// **这是重构时要改的映射。**
    static func engine(_ scenario: Scenario, stores: Stores) -> AIKitEngine {
        let flags = scenario.flags
        let tenant = scenario.tenant ?? (flags.owner ? .owner() : managedMember)
        let environment = TestAssembly.environment(
            tenant: tenant,
            stores: stores.bundle,
            memory: scenario.memory,
            medications: scenario.medications,
            focusMedication: scenario.focusMedication,
            location: scenario.location,
            webSearch: flags.webSearch ? searchStub : nil,
            // 读网页不要 key:前台总是挂;后台只有后台任务那种一轮给(和搜索一起给)。
            webFetch: !flags.background || flags.webSearch ? fetchStub : nil,
            recall: flags.recall,
            // 前台才有提醒和目标(不留痕那一层不带);后台那几轮本来就不挂。
            tasks: flags.isPrivate ? nil : TasksEnvironment(
                store: stores.bundle.tasks,
                scheduling: NoReminderScheduling(),
                tenantId: tenant.id,
                activeGoals: scenario.goals,
                jobs: Jobs()
            ),
            notes: stores.bundle.notes,
            isEnabled: flags.isEnabled
        )
        return TestAssembly.engine(
            environment,
            route: flags.background ? .background : .foreground,
            isPrivate: flags.isPrivate,
            sideChatTitle: scenario.sideChatTitle
        )
    }

    /// 这一组开关下挂出去的工具。
    static func registry(_ flags: Flags, stores: Stores) -> CapabilityRegistry {
        engine(Scenario(name: "", flags: flags), stores: stores).capabilityRegistry
    }

    /// 这一个场景下给模型的 system 段,日期已经抹成占位符。人格从 UserDefaults 现读,
    /// 设完照原样还回去。
    static func systemText(_ scenario: Scenario, stores: Stores) -> String {
        withPersona(scenario.persona) {
            normalize(engine(scenario, stores: stores).systemInstruction(acceptsInterjections: scenario.acceptsInterjections))
        }
    }

    /// 人格不指定就是默认那一档,不是「保持原样」——别的测试可能改过它。
    static func withPersona<T>(_ persona: AssistantPersona?, _ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.standard
        let key = EngineSettings.personaKey
        let previous = defaults.object(forKey: key)
        defaults.set((persona ?? .balanced).rawValue, forKey: key)
        defer {
            if let previous { defaults.set(previous, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        return try body()
    }

    /// 「今天是 2026-09-29 周二。」每一轮都现取,黄金文本里只能留占位符。
    static func normalize(_ text: String) -> String {
        guard let pattern = try? NSRegularExpression(pattern: "今天是 \\d{4}-\\d{2}-\\d{2}[^\\n]*") else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "今天是 <DATE>。")
    }

    /// 黄金文本是按简体中文界面录的。测试 scheme 已经钉在 zh-Hans(`project.yml`)。
    static var isRecordedLanguage: Bool {
        CoreInstructions.replyLanguage == "简体中文"
    }

    // MARK: - 样本数据

    /// 几种记忆都有,其中那条待跟进的到期时间在 1970 年:到点了的那句提示是确定的。
    static var sampleMemory: MemorySnapshot {
        MemorySnapshot(items: [
            MemoryItem(kind: .profile, text: "他上夜班，作息不固定", origin: .manual),
            MemoryItem(kind: .preference, text: "他要数字，不要鼓励", origin: .asked),
            MemoryItem(kind: .interpretation, text: "他觉得睡够 7 小时才算好"),
            MemoryItem(kind: .followUp, text: "两周后看深睡有没有变化", dueAt: Date(timeIntervalSince1970: 0))
        ])
    }

    /// 四种状态各一条。没有任何剂量:这份数据要走进「剂量一律不给建议」那条线里。
    static var sampleMedications: MedicationSnapshot {
        MedicationSnapshot(items: [
            MedicationItem(name: "青霉素", status: .cannotTake, reason: "过敏，起过皮疹"),
            MedicationItem(name: "二甲双胍", status: .ongoing, when: "每天早上", reason: "控制血糖"),
            MedicationItem(name: "布洛芬", status: .asNeeded, when: "头疼时", outcome: "一般半小时见效"),
            MedicationItem(name: "褪黑素", status: .tried, reason: "入睡困难", outcome: "试了两周没感觉")
        ])
    }

    static var sampleFocusMedication: MedicationItem {
        MedicationItem(name: "褪黑素", status: .tried, reason: "入睡困难", outcome: "试了两周没感觉")
    }

    /// id 固定:短编号要进黄金文本。
    static var sampleGoal: TaskItem {
        var goal = TaskItem(kind: .goal, title: "减脂", status: .running, createdAt: Date(timeIntervalSince1970: 0))
        goal.id = UUID(uuidString: "0A1B2C3D-0000-0000-0000-000000000001")!
        goal.why = "想跑得更轻松"
        goal.plan = [.init(text: "每周跑三次", done: true), .init(text: "晚饭少吃主食")]
        return goal
    }

    static var sampleLocation: LocationSnapshot {
        LocationSnapshot(place: "杭州")
    }

    // MARK: - 场景

    /// 什么都有:所有快照、目标、用药焦点、人格,所有工具都挂上。
    static var everything: Scenario {
        Scenario(
            name: "owner-everything",
            flags: .allOn,
            memory: sampleMemory,
            medications: sampleMedications,
            focusMedication: sampleFocusMedication,
            location: sampleLocation,
            goals: [sampleGoal],
            acceptsInterjections: true,
            persona: .coach
        )
    }

    /// 家人成员:不是本人,没有 Apple 健康工具。
    static var managedSenior: Scenario {
        Scenario(
            name: "managed-senior",
            flags: Flags(webSearch: true, owner: false),
            medications: sampleMedications
        )
    }

    /// 录成黄金文本的那几种。挑的是线上真会出现的几条路:普通、隐私、后台、家人、
    /// 有历史可翻、两个设置项关掉、挂着搜索又知道城市、健康整个关掉。
    static var goldenScenarios: [Scenario] {
        [
            Scenario(name: "owner-minimal"),
            everything,
            Scenario(
                name: "owner-private",
                flags: Flags(isPrivate: true),
                memory: sampleMemory,
                medications: sampleMedications,
                location: sampleLocation
            ),
            Scenario(
                name: "owner-background",
                flags: Flags(background: true),
                memory: sampleMemory,
                acceptsInterjections: false
            ),
            managedSenior,
            Scenario(name: "owner-goal-recall", flags: Flags(recall: true), goals: [sampleGoal]),
            Scenario(name: "owner-settings-off", flags: Flags(memoryOn: false, medicationsOn: false)),
            Scenario(name: "owner-web-location", flags: Flags(webSearch: true), location: sampleLocation),
            Scenario(
                name: "owner-health-off",
                flags: Flags(health: false, webSearch: true, recall: true),
                memory: sampleMemory,
                medications: sampleMedications,
                location: sampleLocation
            )
        ]
    }
}

/// 派后台任务那一头的替身:只要 `start_task` 挂得出去。
private struct Jobs: JobControls {
    var autoStart: Bool { false }
    func start(_ taskId: UUID) async {}
}

private extension Bool {
    var bit: Int { self ? 1 : 0 }
}
