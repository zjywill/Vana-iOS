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
        tasks: TasksEnvironment? = nil,
        isEnabled: @escaping @Sendable (String) -> Bool = EngineSettings.isPluginEnabled
    ) -> PluginEnvironment {
        PluginEnvironment(
            isEnabled: isEnabled,
            tenant: tenant,
            // 有看不见的历史才挂召回。这里只管「挂没挂」,位置取一个在所有消息之后的数。
            recall: recall && stores != nil
                ? HistoryRecallTools.registry(store: stores!.thread, hiddenBefore: .greatestFiniteMagnitude)
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
            tasks: tasks
        )
    }

    static func engine(
        _ environment: PluginEnvironment = environment(),
        route: PluginRoute = .foreground,
        isPrivate: Bool = false
    ) -> AIKitEngine {
        AIKitEngine(environment: environment, route: route, isPrivate: isPrivate)
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
