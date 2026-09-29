import Foundation
import AgentRuntime

/// 把 `WindowPolicy`(纯逻辑,只认「每一轮多少 token」)接到真正的消息列表上:
/// 切轮、估 token、算出窗口起点该前移到哪。和 Android 那份 `ThreadWindow` 同一套算法。
enum ThreadWindow {
    /// 一轮:从 `startIndex` 起,一条用户消息加其后的助手消息。
    struct Turn: Equatable {
        var startIndex: Int
        var tokens: Int
    }

    /// 一条消息发出去要占多少。除了正文和工具的输入输出,还有**回放给模型的思考**:历史里
    /// 助手消息的 `.reasoning` 在要求回传的协议下会原样发回去(DeepSeek 带 tools 时必须),思考
    /// 模型的思考常常比答案还长,不计入的话窗口以为自己没满、请求其实已经大了一截。算的是
    /// `storedTurn.exactTranscript` 里那份(界面上的 `reasoning` 是同一段文字的副本,不能再算一遍)。
    /// 哪家协议真的回传由 AIKit 按模型决定;这里一律算上——宁可高估。
    static func estimate(_ message: ChatMessage) -> Int {
        var tokens = TokenEstimate.text(message.modelText)
        for call in message.toolCalls {
            tokens += TokenEstimate.text(call.input) + TokenEstimate.text(call.output ?? "")
        }
        if message.role == .assistant {
            for replayed in message.storedTurn.exactTranscript.messages {
                for part in replayed.parts {
                    if case .reasoning(let text, _) = part { tokens += TokenEstimate.text(text) }
                }
            }
        }
        // 每条消息的角色、分隔这些固定开销。
        return tokens + 6
    }

    /// 从 `startIndex` 起按轮切。开头如果不是用户消息(主动消息打头),并进第一轮。
    static func turns(_ messages: [ChatMessage], from startIndex: Int) -> [Turn] {
        guard messages.indices.contains(startIndex) else { return [] }
        var turns: [Turn] = []
        var start = startIndex
        var tokens = 0
        for index in startIndex..<messages.count {
            if messages[index].role == .user, index > start {
                turns.append(Turn(startIndex: start, tokens: tokens))
                start = index
                tokens = 0
            }
            tokens += estimate(messages[index])
        }
        turns.append(Turn(startIndex: start, tokens: tokens))
        return turns
    }

    /// 窗口起点该在哪。返回 `startIndex` 表示不动;否则是新起点(某一轮的第一条)的下标。
    ///
    /// `overheadTokens` 是每一轮请求都要带、但不在消息列表里的那部分(system 段、工具定义):
    /// 从预算里先扣掉,不然窗口按「只有对话」算,加上固定开销就超了。
    static func evict(
        _ messages: [ChatMessage],
        from startIndex: Int,
        policy: WindowPolicy,
        overheadTokens: Int = 0
    ) -> Int {
        let turns = turns(messages, from: startIndex)
        guard !turns.isEmpty else { return startIndex }
        let effective = WindowPolicy(
            budgetTokens: max(policy.budgetTokens - overheadTokens, policy.budgetTokens / 2),
            lowRatio: policy.lowRatio,
            minTailTurns: policy.minTailTurns
        )
        let evicted = effective.turnsToEvict(turns.map(\.tokens))
        return evicted <= 0 ? startIndex : turns[evicted].startIndex
    }

    /// 溢出救援用:不管水位线,只留最近 `keepTurns` 轮。
    static func forceEvict(_ messages: [ChatMessage], from startIndex: Int, keepTurns: Int) -> Int {
        let turns = turns(messages, from: startIndex)
        guard turns.count > keepTurns else { return startIndex }
        return turns[turns.count - keepTurns].startIndex
    }
}
