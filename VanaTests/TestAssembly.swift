import Foundation
import AgentRuntime

@testable import Vana

/// 测试里造一份装配环境。**不给 `.shared` 的 store**:app host 里那就是模拟器上真的
/// memory.json / medications.json。要挂写工具的测试自己传一套临时 store。
enum TestAssembly {
    static func environment(
        tenant: Tenant = .owner(),
        stores: TenantStores? = nil,
        memory: MemorySnapshot = .empty,
        medications: MedicationSnapshot = .empty,
        focusMedication: MedicationItem? = nil,
        location: LocationSnapshot = .unknown,
        webSearch: WebSearchClient? = nil,
        recall: Bool = false,
        includesHealthData: Bool = true,
        goals: [String] = [],
        topic: ChatTopic? = nil,
        isEnabled: @escaping @Sendable (String) -> Bool = EngineSettings.isPluginEnabled
    ) -> PluginEnvironment {
        PluginEnvironment(
            isEnabled: isEnabled,
            tenant: tenant,
            recall: recall && stores != nil
                ? SessionRecallTools.registry(store: stores!.sessions, currentSessionId: nil)
                : nil,
            memoryStore: stores?.memory,
            memory: memory,
            location: location,
            webSearch: webSearch,
            exerciseLibrary: .shared,
            includesHealthData: includesHealthData,
            medicationStore: stores?.medications,
            medications: medications,
            focusMedication: focusMedication,
            topic: topic,
            goals: goals
        )
    }

    static func engine(
        _ environment: PluginEnvironment = environment(),
        route: PluginRoute = .foreground,
        isPrivate: Bool = false,
        unlocked: Set<String> = [RecallPlugin.unlockTrigger]
    ) -> AIKitEngine {
        AIKitEngine(environment: environment, route: route, isPrivate: isPrivate, unlocked: unlocked)
    }

    static func toolNames(_ engine: AIKitEngine) -> [String] {
        engine.capabilityRegistry.definitions.map(\.name)
    }

    /// 一套临时 store。调用方负责删目录。
    static func freshStores() -> (TenantStores, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "vana-assembly-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (TenantStores(root: root), root)
    }
}
