import Foundation

/// 本地 token 粗估,给滑动窗口用(`WindowPolicy` 只认「每一轮多少 token」)。
///
/// 中日韩字符大约一字一 token,其余大约四字符一 token。**宁可高估**:高估只会让窗口早一点滑,
/// 低估会让请求撞上模型的上下文上限。和 Android 那份 `TokenEstimate` 同一个口径——
/// 两端对同一段对话算出两种窗口,改的人只会更糊涂。
///
/// 上下文规划器(`ConversationHistoryPlanner`)用的是 `AgentModelClient.estimateTokens`,那是
/// 按整份请求、带校准比值的精确一些的尺子;这一把只负责「窗口该不该滑」这种粗判断。
public enum TokenEstimate {
    public static func text(_ text: String) -> Int {
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xAC00...0xD7AF, 0xFF00...0xFFEF: cjk += 1
            default: other += 1
            }
        }
        return cjk + (other + 3) / 4
    }

    /// 一个工具定义占的位子:名字、描述,加**发出去的那份** JSON Schema。
    public static func definition(_ definition: CapabilityDefinition) -> Int {
        text(definition.name)
            + text(definition.description ?? "")
            + text((try? definition.inputSchema.encodedString()) ?? "")
    }

    public static func part(_ part: AgentTranscript.Part) -> Int {
        switch part {
        case .text(let value): text(value)
        case .reasoning(let value, _): text(value)
        case .toolCall(let call): text(call.input) + text(call.toolName)
        case .toolResult(let result): text(result.result.stringValue ?? ((try? result.result.encodedString()) ?? ""))
        case .file: filePartTokens
        }
    }

    public static func transcript(_ transcript: AgentTranscript) -> Int {
        transcript.messages.reduce(0) { total, message in
            total + message.parts.reduce(0) { $0 + part($1) }
        }
    }

    /// 一张图或一份文件的固定估值。真实开销随模型和分辨率差很多,这里只求不为零。
    private static let filePartTokens = 25
}
