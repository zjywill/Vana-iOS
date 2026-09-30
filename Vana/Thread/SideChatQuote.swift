import Foundation

/// 在主对话和侧聊之间搬一段话。纯函数。
///
/// 两个方向:
/// - **在侧聊里接着聊**:主对话里某一问一答,作为一条新侧聊的开头(`.fromMain`)。
/// - **带回主对话**:侧聊里他挑的一段回复,原样追加到主对话(`.fromSideChat`)。
///
/// **搬的是文字,不是 transcript。** 原样拷过去的话,`tool_call` 和结果的配对、DeepSeek 的
/// `reasoning_content`、随行原图,随便断一样就是一个 400,而且那条线从此发不出去。所以只带
/// 可见的正文,工具只留名字(同召回读回来的原文);照片不带——照片文件归原来那条线,两条线
/// 引用同一张图的话,删其中一条就会把另一条的图删掉。
///
/// **带回来不花一次调用去总结**:总结会漂,还多付一次钱;要带什么由他自己挑那一条。
enum SideChatQuote {
    /// 搬过去的正文最长多少字。它要进另一条线的窗口,一段几千字的长回复原样搬过去,
    /// 等于一次性占掉那边窗口的一大块。
    static let maxCharacters = 3_000

    /// 这一条能不能搬:模型真的写的、写完了的、不是主动消息的回复。
    static func canQuote(_ message: ChatMessage) -> Bool {
        message.isModelWritten && !message.isProactive && !message.isQueued
    }

    /// 侧聊的开头。`question` 是这段回答上面那句提问(找不到就是 nil)。
    static func seed(question: ChatMessage?, answer: ChatMessage, now: Date = Date()) -> ChatMessage {
        let asked = question.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return ChatMessage(
            role: .assistant,
            text: capped(answer.text),
            createdAt: now,
            origin: .fromMain,
            provenance: .init(
                question: asked?.isEmpty == false ? asked : nil,
                toolNames: toolNames(of: answer),
                date: answer.createdAt
            )
        )
    }

    /// 带回主对话的那一条。
    static func broughtBack(_ answer: ChatMessage, from sideChatTitle: String, now: Date = Date()) -> ChatMessage {
        ChatMessage(
            role: .assistant,
            text: capped(answer.text),
            createdAt: now,
            origin: .fromSideChat,
            provenance: .init(
                sideChatTitle: sideChatTitle,
                toolNames: toolNames(of: answer),
                date: answer.createdAt
            )
        )
    }

    /// 气泡顶上那一行小字。带回来的那条要写出是哪条侧聊:主对话里可能摆着好几条侧聊带回来的话。
    static func label(for message: ChatMessage) -> String {
        if message.origin == .fromSideChat, let title = message.provenance?.sideChatTitle, !title.isEmpty {
            return String(localized: "从侧聊「\(title)」带回来的")
        }
        return message.origin.label
    }

    /// 给模型看的那一段(`HistoryMarkers` 把它折进下一条用户消息开头)。不是这两种就返回 nil。
    ///
    /// 要说清两件事:这段话从哪儿来,以及它**不是对上一句的回答**——否则模型读到的是自己
    /// 突然说了一段和上下文不相干的话。
    static func modelNote(for message: ChatMessage) -> String? {
        let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let tools = message.provenance?.toolNames ?? []
        let checked = tools.isEmpty ? "" : "（当时查过：\(tools.joined(separator: "、"))）"
        switch message.origin {
        case .fromMain:
            let asked = message.provenance?.question.map { "用户当时问：「\($0)」\n" } ?? ""
            return "（这条侧聊接着主对话里的这一段开始。\(asked)你当时答\(checked)：\n\(text)\n）"
        case .fromSideChat:
            let title = message.provenance?.sideChatTitle.map { "「\($0)」" } ?? ""
            return "（用户从侧聊\(title)里带回来一段你在那里说过的话\(checked)：\n\(text)\n）"
        default:
            return nil
        }
    }

    private static func capped(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > maxCharacters else { return trimmed }
        return String(trimmed.prefix(maxCharacters)) + "…"
    }

    private static func toolNames(of message: ChatMessage) -> [String] {
        var seen: Set<String> = []
        return message.toolCalls.map(\.name).filter { seen.insert($0).inserted }
    }
}
