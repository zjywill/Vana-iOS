import Foundation
import AgentRuntime

/// 单线程里消息跨天:模型必须知道「昨天说的」是哪一次。
///
/// 相邻两条隔得够久,就在后一条用户消息前面补一行确定性的时间标记。它由每条消息存下来的
/// `createdAt` 算出,同一段历史每次算出来都一样——所以只会在窗口后面追加,不会让请求前缀
/// 变来变去。
enum HistoryMarkers {
    /// 隔多久算「隔了一阵」。
    static let gap: TimeInterval = 6 * 3_600

    static func marker(previous: Date, current: Date, timeZone: TimeZone = .current) -> String? {
        let interval = current.timeIntervalSince(previous)
        guard interval >= gap else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.month, .day, .hour, .minute], from: current)
        let stamp = String(
            format: "%d月%d日 %02d:%02d",
            parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0
        )
        let hours = Int(interval / 3_600)
        let since = hours < 48 ? "\(hours) 小时" : "\(Int(interval / 86_400)) 天"
        return "——（\(stamp)，距上一条约 \(since)）——"
    }

    /// 把线程里的消息变成发给模型的历史。两件事:
    ///
    /// - 隔得久的用户消息前面补时间标记;
    /// - **主动消息**(Vana 自己先开口:check-in、回头看的结论、提醒、任务结果)不作为独立的
    ///   助手消息发出去,而是折进**下一条用户消息**的开头(「Vana 之前主动说过：……」)。请求里
    ///   助手和用户消息严格交替——有的 provider 不接受连着两条助手消息,也不接受以助手消息开头。
    static func apply(_ messages: [ChatMessage], timeZone: TimeZone = .current) -> [AgentChatMessageDTO] {
        var previous: ChatMessage?
        var proactive: [String] = []
        var out: [AgentChatMessageDTO] = []
        for message in messages {
            let before = previous
            previous = message
            if message.role == .assistant, message.isProactive {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { proactive.append(text) }
                continue
            }
            var dto = message.agentDTO
            guard message.role == .user else {
                out.append(dto)
                continue
            }
            var prefix = ""
            if let earlier = before?.createdAt, let now = message.createdAt,
               let marker = marker(previous: earlier, current: now, timeZone: timeZone) {
                prefix += marker + "\n"
            }
            if !proactive.isEmpty {
                prefix += "（Vana 之前主动说过：\(proactive.joined(separator: "；"))）\n"
                proactive.removeAll()
            }
            if !prefix.isEmpty { dto.text = prefix + dto.text }
            out.append(dto)
        }
        return out
    }
}
