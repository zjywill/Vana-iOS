import Foundation

/// 一条永远的对话里,「最近的消息」这个窗口怎么滑。
///
/// 窗口之外的历史不丢:记忆管长期成立的事实,档案(逐字保留的全部历史)按需检索。窗口只决定
/// **每一轮请求里带多少原文**。三条规矩,都是踩过别人的坑:
///
/// - **批量淘汰,不逐条丢。** 涨到 `budgetTokens` 才动,而且一次砍到 `budgetTokens × lowRatio`。
///   逐条丢会让请求前缀每一轮都变,prompt 缓存整个失效——用户用自己的 key,这是真钱。批量之后
///   两次淘汰之间「system + 工具定义 + 窗口」是纯追加,缓存前缀稳定。
/// - **只在轮边界切。** 一轮是一条用户消息加其后的助手/工具消息;绝不切在一次工具调用和它的结果
///   之间。所以这里吃的是「每一轮多少 token」,不是逐条消息。
/// - **最近的几轮不动。** 至少留 `minTailTurns` 轮(含正在进行的这一轮),再大的单轮也不例外——
///   宁可这一轮超预算,让上下文降级去兜,也不能把用户刚说的话淘汰掉。
///
/// 纯逻辑,没有 UI、没有模型:秒级测试。和 Android 那份 `WindowPolicy` 同一套数字。
public struct WindowPolicy: Sendable, Equatable {
    public static let defaultLowRatio = 0.4
    public static let defaultMinTailTurns = 6

    public let budgetTokens: Int
    public let lowRatio: Double
    public let minTailTurns: Int

    public init(
        budgetTokens: Int,
        lowRatio: Double = WindowPolicy.defaultLowRatio,
        minTailTurns: Int = WindowPolicy.defaultMinTailTurns
    ) {
        precondition(budgetTokens > 0, "budget must be positive")
        precondition(lowRatio > 0 && lowRatio < 1, "lowRatio must be in (0, 1)")
        precondition(minTailTurns >= 1, "at least the newest turn is always kept")
        self.budgetTokens = budgetTokens
        self.lowRatio = lowRatio
        self.minTailTurns = minTailTurns
    }

    public var lowWatermark: Int { Int(Double(budgetTokens) * lowRatio) }

    /// `turns` 是从窗口起点起、按时间顺序每一轮的 token 估计;最后一轮是进行中的这一轮。
    /// 返回要从最前面**整轮**淘汰掉几轮;0 表示还没涨到高水位,不动。
    public func turnsToEvict(_ turns: [Int]) -> Int {
        guard !turns.isEmpty else { return 0 }
        let total = turns.reduce(0, +)
        guard total > budgetTokens else { return 0 }
        let evictable = max(turns.count - minTailTurns, 0)
        var remaining = total
        var evicted = 0
        while evicted < evictable && remaining > lowWatermark {
            remaining -= turns[evicted]
            evicted += 1
        }
        return evicted
    }

    private static let unknownContextBudget = 16_000
    private static let minBudget = 12_000
    private static let maxBudget = 32_000

    /// 窗口预算:模型上下文的三成半,夹在 12k–32k 之间;不知道上下文多大就按 16k。
    /// 封顶 32k 是花钱的考虑:窗口每一轮都要全额发出去,用户自己付这笔钱。
    public static func budget(forContextWindow contextWindow: Int?) -> Int {
        guard let contextWindow, contextWindow > 0 else { return unknownContextBudget }
        return min(max(Int(Double(contextWindow) * 0.35), minBudget), maxBudget)
    }

    public static func forContext(_ contextWindow: Int?) -> WindowPolicy {
        WindowPolicy(budgetTokens: budget(forContextWindow: contextWindow))
    }
}
