import Foundation
import Testing
import AgentRuntime
import AIKit

@testable import Vana

/// 会话文件的格式契约。
///
/// transcript 现在是 app 自己的类型了,但手机上已经存着一批「直接落 AIKit Message」的旧
/// 会话——那些历史必须还能读回来,否则用户一升级就失忆。
@Suite("Chat message persistence")
struct ChatMessagePersistenceTests {

    @Test("a legacy session that stored AIKit messages still replays its tool transcript")
    func decodesLegacyTranscript() throws {
        // 旧格式的 fixture 直接用 AIKit 自己编出来——手写 JSON 只会验到我猜的那个格式。
        let legacyReplay: [AIKit.Message] = [
            AIKit.Message(role: .assistant, content: [
                .text("最近一周平均 8,400 步。"),
                .toolCall(.init(
                    toolCallId: "call_1",
                    toolName: "daily_steps",
                    input: #"{"days":7}"#
                ))
            ]),
            .toolResult(
                toolCallId: "call_1",
                toolName: "daily_steps",
                result: .string("08-01 8,432 步")
            )
        ]

        var legacy = try #require(
            try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(["replayMessages": legacyReplay])
            ) as? [String: Any]
        )
        legacy["id"] = "2E5F1B0C-6C9E-4C41-9A1B-2F1C4E9A7D01"
        legacy["role"] = "assistant"
        legacy["text"] = "最近一周平均 8,400 步。"
        legacy["turnState"] = "completed"
        legacy["toolCalls"] = [[
            "id": "call_1",
            "name": "daily_steps",
            "input": #"{"days":7}"#,
            "output": "08-01 8,432 步",
            "isError": false
        ]]

        let message = try JSONDecoder().decode(
            ChatMessage.self,
            from: try JSONSerialization.data(withJSONObject: legacy)
        )

        #expect(message.turnState == .completed)
        #expect(message.toolCalls.count == 1)
        // 旧的 AIKit 消息被翻成了 app 自己的 transcript,而不是当成缺失丢掉。
        #expect(message.storedTurn.exactTranscript.messages.count == 2)
        #expect(message.storedTurn.exactTranscript.messages.first?.text == "最近一周平均 8,400 步。")
        #expect(message.storedTurn.exactTranscript.messages.last?.role == .tool)
    }

    @Test("saving a finished turn writes an explicit compaction artifact")
    func encodesCompactionArtifact() throws {
        var message = ChatMessage(role: .assistant, text: "")
        message.startToolCall(.init(id: "call_1", name: "sleep_summary", input: #"{"days":7}"#))
        message.finishToolCall(
            id: "call_1",
            output: .init(kind: .table, text: "08-01 7 小时 12 分"),
            isError: false
        )
        message.appendText("最近睡得还行。")
        message.completeTurn(
            transcript: .init(messages: [.assistant("最近睡得还行。")]),
            finishReason: .init(unified: .stop),
            usage: nil,
            context: nil
        )

        let round = try JSONDecoder().decode(
            ChatMessage.self,
            from: try JSONEncoder().encode(message)
        )
        let artifact = try #require(round.storedTurn.compaction)

        #expect(artifact.kind == .toolDigest)
        #expect(artifact.foldedToolCalls == 1)
        // 用户可见的那份是干净的回答。
        #expect(artifact.visibleSummary == "最近睡得还行。")
        // 回放给模型的那份多带一段工具轨迹——这正是两者要分开存的原因。
        #expect(artifact.replaySummary.text.contains("sleep_summary"))
        #expect(artifact.replaySummary.text.contains("折叠了 1 次工具调用"))
        #expect(round.toolCalls.first?.output == "08-01 7 小时 12 分")
    }

    @Test("an app placeholder is not replayed as if the model had said it")
    func placeholderIsNotReplayed() throws {
        var message = ChatMessage(role: .assistant, text: "")
        message.markFailed("云端服务返回错误：500")

        let round = try JSONDecoder().decode(
            ChatMessage.self,
            from: try JSONEncoder().encode(message)
        )

        #expect(round.textIsPlaceholder)
        #expect(round.text.hasPrefix("无法回复："))
        #expect(!round.agentDTO.hasReplayableContent)
        #expect(round.storedTurn.compaction == nil)
    }
}
