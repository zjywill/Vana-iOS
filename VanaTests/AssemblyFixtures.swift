import Foundation
import AgentRuntime

@testable import Vana

/// 「这一轮到底给了模型什么」的测试夹具:同一批场景,喂给装配契约测试和黄金测试。
///
/// **往插件系统重构时,这个文件是唯一要改的地方。** `Flags` 到 `healthChat(...)` 参数的映射在
/// `makeRegistry(_:stores:)` 里,系统提示的拼装在 `systemText(_:stores:)` 里;两套测试只认
/// `Flags` 和 `Scenario`,不认装配函数的签名。装配换了形状,这里改一处映射,断言一条不用动——
/// 这就是它存在的意义。
enum AssemblyFixtures {

    // MARK: - 输入

    /// 影响「挂哪些工具、发哪几段话」的全部输入。前六项是 `healthChat(...)` 的参数,后两项是
    /// `EngineSettings` 里的全局开关(存在 UserDefaults,装配时现读)。
    struct Flags: Equatable, Sendable, CustomStringConvertible {
        var includesHealthTools = true
        var allowsMemoryWrites = true
        var allowsRecall = false
        var allowsMedicationWrites = true
        var asksUser = true
        var webSearch = false
        var memoryEnabled = true
        var medicationsEnabled = true

        /// 什么都挂上。
        static let allOn = Flags(allowsRecall: true, webSearch: true)

        var description: String {
            [
                "health=\(includesHealthTools.bit)",
                "memoryWrites=\(allowsMemoryWrites.bit)",
                "recall=\(allowsRecall.bit)",
                "medWrites=\(allowsMedicationWrites.bit)",
                "asks=\(asksUser.bit)",
                "web=\(webSearch.bit)",
                "memoryOn=\(memoryEnabled.bit)",
                "medsOn=\(medicationsEnabled.bit)"
            ].joined(separator: " ")
        }
    }

    /// 一次完整的装配输入:谁在聊、快照里有什么、聊什么。
    struct Scenario {
        var name: String
        var tenant: Tenant = .owner()
        var flags = Flags()
        var memory: MemorySnapshot = .empty
        var medications: MedicationSnapshot = .empty
        var focusMedication: MedicationItem?
        var location: LocationSnapshot = .unknown
        var topic: ChatTopic?
        var goal: String?
        var acceptsInterjections = true
        var persona: AssistantPersona?
    }

    // MARK: - 临时 store

    /// 测试用的一套临时 store。**不许用 `.shared`**:app host 里那就是模拟器上真的 memory.json。
    struct Stores {
        let directory: URL
        let memory: MemoryStore
        let sessions: SessionStore
        let medications: MedicationStore

        init() {
            directory = FileManager.default.temporaryDirectory
                .appending(path: "vana-assembly-\(UUID().uuidString)", directoryHint: .isDirectory)
            memory = MemoryStore(directory: directory)
            sessions = SessionStore(parent: directory)
            medications = MedicationStore(directory: directory)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - 装配

    /// 网页搜索的替身。只要「挂没挂」,不要真的发请求。
    private static let searchStub = WebSearchClient { _ in WebSearchResults(query: "") }

    /// 只造 registry。全局开关由调用方用 `withSettings` 包住。
    ///
    /// **这是重构时要改的映射之一。**
    private static func makeRegistry(_ flags: Flags, stores: Stores) -> CapabilityRegistry {
        CapabilityRegistry.healthChat(
            includesHealthTools: flags.includesHealthTools,
            allowsMemoryWrites: flags.allowsMemoryWrites,
            allowsRecall: flags.allowsRecall,
            allowsMedicationWrites: flags.allowsMedicationWrites,
            asksUser: flags.asksUser,
            memoryStore: stores.memory,
            sessionStore: stores.sessions,
            medicationStore: stores.medications,
            webSearch: flags.webSearch ? searchStub : nil
        )
    }

    /// 这一组开关下挂出去的工具。
    static func registry(_ flags: Flags, stores: Stores) -> CapabilityRegistry {
        withSettings(for: flags, persona: nil) {
            makeRegistry(flags, stores: stores)
        }
    }

    /// 这一个场景下给模型的 system 段,日期已经抹成占位符。
    ///
    /// **这是重构时要改的映射之二。**
    static func systemText(_ scenario: Scenario, stores: Stores) -> String {
        withSettings(for: scenario.flags, persona: scenario.persona) {
            let engine = AIKitEngine(
                topic: scenario.topic,
                tenant: scenario.tenant,
                goal: scenario.goal,
                memory: scenario.memory,
                medications: scenario.medications,
                focusMedication: scenario.focusMedication,
                location: scenario.location,
                capabilityRegistry: makeRegistry(scenario.flags, stores: stores)
            )
            return normalize(engine.systemInstruction(acceptsInterjections: scenario.acceptsInterjections))
        }
    }

    /// 装配时现读的全局设置。设完照原样还回去(原来没设过的就删掉):别的测试读到的应该还是
    /// 它们自己的值。
    ///
    /// 人格不指定就是默认那一档,不是「保持原样」——别的测试可能改过它。
    static func withSettings<T>(
        for flags: Flags,
        persona: AssistantPersona?,
        _ body: () throws -> T
    ) rethrows -> T {
        let overrides: [String: Any] = [
            EngineSettings.memoryEnabledKey: flags.memoryEnabled,
            EngineSettings.medicationsEnabledKey: flags.medicationsEnabled,
            EngineSettings.personaKey: (persona ?? .balanced).rawValue
        ]
        let defaults = UserDefaults.standard
        var previous: [String: Any] = [:]
        for key in overrides.keys {
            if let value = defaults.object(forKey: key) { previous[key] = value }
        }
        for (key, value) in overrides {
            defaults.set(value, forKey: key)
        }
        defer {
            for key in overrides.keys {
                if let value = previous[key] {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
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

    /// 黄金文本是按简体中文界面录的。别的语言下 `replyLanguage` 和一批 `String(localized:)` 都会变,
    /// 那时候对不上不是回归。测试 scheme 已经钉在 zh-Hans(`project.yml`),这里只是把原因说清楚。
    static var isRecordedLanguage: Bool {
        HealthAssistantInstructions.replyLanguage == "简体中文"
    }

    // MARK: - 样本数据

    /// 四种记忆都有,其中那条待跟进的到期时间在 1970 年:到点了的那句提示是确定的。
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

    static var sampleLocation: LocationSnapshot {
        LocationSnapshot(place: "杭州")
    }

    // MARK: - 场景

    /// 什么都有:所有快照、话题、目标、用药话题、人格,所有工具都挂上。
    static var everything: Scenario {
        Scenario(
            name: "owner-everything",
            flags: .allOn,
            memory: sampleMemory,
            medications: sampleMedications,
            focusMedication: sampleFocusMedication,
            location: sampleLocation,
            topic: ChatTopics.topic(id: "sleep"),
            goal: "减脂",
            acceptsInterjections: true,
            persona: .coach
        )
    }

    /// 家人成员:不是本人,没有健康工具。
    static var managedSenior: Scenario {
        Scenario(
            name: "managed-senior",
            tenant: Tenant(name: "妈妈", kind: .managed, ageBand: .senior),
            flags: Flags(includesHealthTools: false, webSearch: true),
            medications: sampleMedications
        )
    }

    /// 录成黄金文本的那几种。挑的是线上真会出现的几条路:普通、隐私、后台派生、家人、
    /// 目标线、两个设置项关掉、挂着搜索又知道城市。
    static var goldenScenarios: [Scenario] {
        [
            Scenario(name: "owner-minimal"),
            everything,
            Scenario(
                name: "owner-private",
                flags: Flags(allowsMemoryWrites: false, allowsMedicationWrites: false),
                memory: sampleMemory,
                medications: sampleMedications,
                location: sampleLocation
            ),
            Scenario(
                name: "owner-background",
                flags: Flags(allowsMemoryWrites: false, asksUser: false),
                memory: sampleMemory,
                acceptsInterjections: false
            ),
            managedSenior,
            Scenario(
                name: "owner-goal-recall",
                flags: Flags(allowsRecall: true),
                goal: "减脂"
            ),
            Scenario(
                name: "owner-settings-off",
                flags: Flags(memoryEnabled: false, medicationsEnabled: false)
            ),
            Scenario(
                name: "owner-web-location",
                flags: Flags(webSearch: true),
                location: sampleLocation
            )
        ]
    }
}

private extension Bool {
    var bit: Int { self ? 1 : 0 }
}
