import Foundation
import AgentRuntime

/// 对话里当场动记忆的三个工具:记(`remember`)、忘(`forget_memory`)、改(`revise_memory`)。
///
/// 和后台的自动抽取是**互补**的,不是替代:抽取跑在后台,用户不用等,但它会漏——
/// 模型那一轮的注意力在回答问题上。用户明说「记住我不能跑步」的时候必须当场落下,并且
/// 让他在气泡上看见落下了;等他关掉 app 再由后台补记,他无从知道到底记没记住。
///
/// 忘和改是**用户明说**才调的:「忘掉我说过的那个」「不对,其实是周四」。它们按记忆块里的
/// 短编号(M1、M2…)指到某一条,编号和模型此刻读到的那一块是同一套——所以工具拿的是
/// **这一轮绑定的快照**,不是去盘上重新数(盘上的顺序可能已经因为别处的写入变了)。
/// 指到之后按 id 动,id 不会指错。与抽取器不同,这里对用户自己写的条目也能忘、能改:
/// 那是他在对话里明确要求的。
enum MemoryTools {
    static let rememberToolName = "remember"
    static let forgetToolName = "forget_memory"
    static let reviseToolName = "revise_memory"

    /// 别的插件自己存着的话题。它们有专门的存放处,记进这里就是同一件事两份。
    private static func elsewhere(_ exclusions: [String]) -> String {
        guard !exclusions.isEmpty else { return "" }
        return "\(exclusions.joined(separator: "、"))已经有专门的存放处，不要用 remember 再记一份。"
    }

    /// system 段里那句「什么时候调这三个」。三个工具同挂同撤,所以写在一起。
    static func guide(exclusions: [String] = []) -> String {
        "用户明确要求记住某件事，或者说出一个长期成立的个人情况"
            + "（作息、工作安排、身体上的限制、目标、他希望你怎么说话）时，调用 remember 记下来，"
            + "并在回复里说一句已经记住了；最近发生、还没完的事记成 episode（近况）。"
            + "他说「忘掉…」「别再提…」时用 forget_memory；纠正一条已经记下的事（「不对，其实是…」）时用"
            + " revise_memory——这两个都按「关于这位用户」里那条的编号（M1、M2…）。"
            + "一次性的要求（「这次简短点」）不是偏好，不要记；具体数值也不要记，那些每次都会重新查。"
            + elsewhere(exclusions)
    }

    /// - Parameters:
    ///   - store: 测试传自己的临时 store。默认这个参数不是可有可无的:app 侧的测试跑在
    ///     app host 里,`MemoryStore.shared` 就是模拟器上那份真的 `memory.json`——
    ///     测试写它等于把用户记住的东西删了。
    ///   - snapshot: 这一轮 system 段里那一块。忘和改按它的编号找人。
    ///   - exclusions: 别的插件声明的「有专门存放处」的话题(`PluginContext.memoryExclusions`)。
    static func registry(
        store: MemoryStore = .shared,
        snapshot: MemorySnapshot = .empty,
        exclusions: [String] = []
    ) -> CapabilityRegistry {
        CapabilityRegistry(definitions: [
            rememberDefinition(exclusions: exclusions),
            forgetDefinition,
            reviseDefinition
        ]) { invocation in
            switch invocation.name {
            case rememberToolName: await remember(invocation, store: store)
            case forgetToolName: await forget(invocation, store: store, snapshot: snapshot)
            case reviseToolName: await revise(invocation, store: store, snapshot: snapshot)
            default: failure("不支持名为 \(invocation.name) 的工具。")
            }
        }
    }

    // MARK: - 定义

    private static func rememberDefinition(exclusions: [String]) -> CapabilityDefinition {
        let kinds = ["profile", "preference", "episode", "followUp"]
        let text: RuntimeJSONValue = .object([
            "type": "string",
            "description": "用中文第三人称写，一句话，不超过 40 个字"
        ])
        let kind: RuntimeJSONValue = .object([
            "type": "string",
            "description": .string(
                "profile 长期情况、preference 表达偏好、"
                    + "episode 近况（最近发生、还没完的事，配合 days，到点自己淡出）、"
                    + "followUp 说好过一阵子再看的事（配合 days）"
            ),
            "enum": .array(kinds.map { .string($0) })
        ])
        let days: RuntimeJSONValue = .object([
            "type": "integer",
            "description": "只有 followUp 和 episode 用：几天后回头看或淡出。followUp 1–180，episode 1–60，默认都是 14",
            "minimum": 1,
            "maximum": .int(MemoryItem.maxFollowUpDays)
        ])
        return CapabilityDefinition(
            name: rememberToolName,
            description: """
            记住一条关于这位用户的事，之后每次对话都会带上。\
            只在两种情况下调用：用户明确要求记住某件事，或者他说出了一个长期成立的个人情况\
            （作息、工作安排、身体上的限制、正在进行的目标、他希望你怎么说话）。
            不要记具体的数值和某一天的数据——那些每次都该重新查，记下来第二天就是错的。\
            不要记只在这次对话里成立的话题。\
            同一件事已经在系统提示的「关于这位用户」里出现过了，就不要再记一遍。
            """ + elsewhere(exclusions),
            inputSchema: .object([
                "type": "object",
                "properties": .object(["text": text, "kind": kind, "days": days]),
                "required": .array([.string("text"), .string("kind")]),
                "additionalProperties": .bool(false)
            ])
        )
    }

    private static let handleProperty: RuntimeJSONValue = .object([
        "type": "string",
        "description": "记忆块里那一条的编号，形如 M3"
    ])

    private static let forgetDefinition = CapabilityDefinition(
        name: forgetToolName,
        description: "用户明确要求忘掉、别再提某件已经记下的事时调用。按「关于这位用户」里那一条的编号（形如 M3）忘掉它。"
            + "只在用户明说时才调用，不要自己判断哪条该忘。",
        inputSchema: .object([
            "type": "object",
            "properties": .object(["handle": handleProperty]),
            "required": .array([.string("handle")]),
            "additionalProperties": .bool(false)
        ])
    )

    private static let reviseDefinition = CapabilityDefinition(
        name: reviseToolName,
        description: "用户纠正一条已经记下的事时调用（「不对，其实是…」）。把编号指到的那一条改成新的一句话，种类不变。",
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "handle": handleProperty,
                "text": .object([
                    "type": "string",
                    "description": "改后的那一句，用中文第三人称，不超过 40 个字"
                ])
            ]),
            "required": .array([.string("handle"), .string("text")]),
            "additionalProperties": .bool(false)
        ])
    )

    // MARK: - 执行

    private static func failure(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text), isError: true)
    }

    private static func success(_ text: String) -> CapabilityExecutionResult {
        CapabilityExecutionResult(output: .init(kind: .text, text: text))
    }

    private static func remember(_ invocation: CapabilityInvocation, store: MemoryStore) async -> CapabilityExecutionResult {
        guard EngineSettings.memoryEnabled else {
            // 报成错误,模型才会在回复里跟用户说一声。悄悄丢掉的话,它会顺口说「记住了」。
            return failure("用户关掉了记忆功能，这次没有记下来。")
        }
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let text = (input?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let kind = input?["kind"]?.stringValue.flatMap(MemoryKind.init(rawValue:)),
              kind != .interpretation
        else {
            return failure("参数不全：需要 text 和合法的 kind。")
        }
        guard text.count <= MemoryItem.maxTextCharacters else {
            return failure("这一句太长了（\(text.count) 字）。压成一句话、不超过 40 个字再记。")
        }
        let requestedDays = input?["days"]?.intValue
        do {
            // `.asked` 而不是 `.extracted`:用户开口说了的东西,后台抽取不该再去改它。
            guard let item = try await store.remember(kind: kind, text: text, days: requestedDays) else {
                // 上限满了会静静地把它挤掉,那种情况下不能回「已记住」。
                return failure("记忆已满，这条没有记下来。让用户到设置里清理一下。")
            }
            var suffix = ""
            if let upper = kind.maxDays {
                let days = min(max(requestedDays ?? MemoryItem.defaultExpiryDays, 1), upper)
                suffix = kind == .episode ? "（\(days) 天后淡出）" : "（\(days) 天后回头看）"
            }
            return success("已记住：\(item.text)\(suffix)")
        } catch {
            return failure("没能记下来：\(error.localizedDescription)")
        }
    }

    private static func forget(
        _ invocation: CapabilityInvocation,
        store: MemoryStore,
        snapshot: MemorySnapshot
    ) async -> CapabilityExecutionResult {
        let handle = handle(fromInput: invocation.input)
        guard let id = snapshot.resolve(handle: handle) else {
            return failure("没有编号为 \(handle) 的记忆。编号见系统提示里「关于这位用户」那一块。")
        }
        guard let item = await store.item(id: id) else {
            return failure("编号 \(handle) 的那条记忆已经不在了。")
        }
        do {
            try await store.delete(id: id)
            return success("已忘掉：\(item.text)")
        } catch {
            return failure("没能忘掉：\(error.localizedDescription)")
        }
    }

    private static func revise(
        _ invocation: CapabilityInvocation,
        store: MemoryStore,
        snapshot: MemorySnapshot
    ) async -> CapabilityExecutionResult {
        let input = try? RuntimeJSONValue.decode(from: invocation.input)
        let handle = (input?["handle"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let text = (input?["text"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return failure("revise_memory 需要改后的 text。") }
        guard text.count <= MemoryItem.maxTextCharacters else {
            return failure("这一句太长了（\(text.count) 字）。压成一句话、不超过 40 个字再改。")
        }
        guard let id = snapshot.resolve(handle: handle) else {
            return failure("没有编号为 \(handle) 的记忆。编号见系统提示里「关于这位用户」那一块。")
        }
        do {
            guard try await store.revise(id: id, text: text) != nil else {
                return failure("编号 \(handle) 的那条记忆已经不在了。")
            }
            return success("已改成：\(text)")
        } catch {
            return failure("没能改：\(error.localizedDescription)")
        }
    }

    static func text(fromInput input: String) -> String? {
        (try? RuntimeJSONValue.decode(from: input))?["text"]?.stringValue
    }

    static func handle(fromInput input: String) -> String {
        ((try? RuntimeJSONValue.decode(from: input))?["handle"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension CapabilityRegistry {
    /// 把几组能力并成一份。
    static func combining(_ registries: [CapabilityRegistry]) -> CapabilityRegistry {
        CapabilityRegistry(definitions: registries.flatMap(\.definitions)) { invocation in
            for registry in registries where registry.definition(named: invocation.name) != nil {
                return await registry.execute(invocation)
            }
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "不支持名为 \(invocation.name) 的工具。"),
                isError: true
            )
        }
    }
}
