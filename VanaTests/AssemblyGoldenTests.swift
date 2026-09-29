import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 黄金文本:同一批场景下,给模型的 system 段和全部工具定义**逐字**不变。
///
/// 只有一种用途:往插件系统重构的头几步是**纯搬家**,搬完之后模型看到的每一个字都该和搬之前
/// 一样。这一份负责证明它。改措辞的那几步(拆提示词)会有意打破它——那时候看
/// `AssemblyContractTests`(只认结构),再一次性重录并逐段 diff 复核。
///
/// ## 怎么录
///
/// 录在**重构之前**的提交上:
///
/// ```bash
/// TEST_RUNNER_VANA_RECORD_GOLDEN=1 xcodebuild -project Vana.xcodeproj -scheme Vana \
///   -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:VanaTests/AssemblyGoldenTests
/// ```
///
/// 录制那一遍会**故意报失败**(和 swift-snapshot-testing 同一个做法):防止把录制开关留在 CI 里。
/// 文件写在 `VanaTests/Golden/`,`git diff` 就是这次变了什么。去掉环境变量再跑一遍,应该全绿。
///
/// 日期那一行抹成 `<DATE>`。文本按简体中文界面录(测试 scheme 已经钉在 zh-Hans)。
@Suite("Assembly golden", .serialized)
struct AssemblyGoldenTests {

    @Test("the system prompt of each scenario matches the recorded text")
    func systemPrompts() {
        guard AssemblyFixtures.isRecordedLanguage else {
            Issue.record("黄金文本只在简体中文界面下有意义;检查测试 scheme 的 language 有没有还是 zh-Hans。")
            return
        }
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        for scenario in AssemblyFixtures.goldenScenarios {
            let text = AssemblyFixtures.systemText(scenario, stores: stores)
            Golden.check(text, named: "system-\(scenario.name).txt")
        }
    }

    /// 全开时的 18 个工具,名字、描述、参数 schema 全部原样。描述是写给模型看的,
    /// 少一个字都是行为变化。
    @Test("the full tool definitions match the recorded JSON")
    func toolDefinitions() throws {
        guard AssemblyFixtures.isRecordedLanguage else {
            Issue.record("黄金文本只在简体中文界面下有意义;检查测试 scheme 的 language 有没有还是 zh-Hans。")
            return
        }
        let stores = AssemblyFixtures.Stores()
        defer { stores.remove() }

        let registry = AssemblyFixtures.registry(.allOn, stores: stores)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(registry.definitions)
        let text = String(decoding: data, as: UTF8.self) + "\n"

        Golden.check(text, named: "tool-definitions-all-on.json")
    }
}

/// 读写 `VanaTests/Golden/` 下的文件。路径从这个源文件的位置推出来:模拟器进程读得到宿主机的
/// 文件系统,所以录制时直接写回源码树,不用绕一圈 bundle。
private enum Golden {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Golden", directoryHint: .isDirectory)

    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["VANA_RECORD_GOLDEN"] == "1"
    }

    static func check(_ actual: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = directory.appending(path: name, directoryHint: .notDirectory)

        if isRecording {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try actual.write(to: url, atomically: true, encoding: .utf8)
                Issue.record(
                    "已录制 \(name)。去掉 VANA_RECORD_GOLDEN 再跑一遍,确认对得上。",
                    sourceLocation: sourceLocation
                )
            } catch {
                Issue.record("录制 \(name) 失败:\(error)", sourceLocation: sourceLocation)
            }
            return
        }

        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record(
                "没有找到 \(name)。先在重构之前的提交上用 VANA_RECORD_GOLDEN=1 录一遍。",
                sourceLocation: sourceLocation
            )
            return
        }
        if expected != actual {
            Issue.record(
                "\(name) 和录下来的不一致。\(firstDifference(expected, actual))",
                sourceLocation: sourceLocation
            )
        }
    }

    /// 整段文本对不上时,只告诉人第一处不同:够定位,又不会把几十行输出刷满。
    static func firstDifference(_ expected: String, _ actual: String) -> String {
        let old = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let new = actual.split(separator: "\n", omittingEmptySubsequences: false)
        for index in 0..<min(old.count, new.count) where old[index] != new[index] {
            return "第 \(index + 1) 行起不同:\n  录下的: \(old[index])\n  现在的: \(new[index])"
        }
        return "前 \(min(old.count, new.count)) 行相同,长度不同(录下的 \(old.count) 行,现在 \(new.count) 行)。"
    }
}
