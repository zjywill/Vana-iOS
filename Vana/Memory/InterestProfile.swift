import Foundation

/// 这个人实际关心什么。
///
/// **数出来的,不是模型抽出来的。**「最近 30 条会话里 18 条查了睡眠、2 条查了体重」是统计,
/// 本地数一遍更准更便宜,而且随时可重算、不占记忆的额度。分工是清楚的:模型抽的是他**说过
/// 的话**,app 数的是他**点过的东西**。为数数花一次模型调用是纯亏。
///
/// 数的是工具调用而不是问句里的关键词。他点的按钮、问出去的问题最后都会落成一次工具调用,
/// 而关键词匹配会把「今天不想聊睡眠」也算成关心睡眠。
struct InterestProfile: Sendable, Equatable {
    static let empty = InterestProfile(weights: [:])

    /// 工具名 → 加权次数。
    let weights: [String: Double]

    /// 越近的会话算得越重。半年前问过一阵子睡眠,不代表现在还在关心。
    private static let decayPerSession = 0.93
    /// 低于这个权重当没有:一次两次算不上倾向。
    private static let meaningfulWeight = 1.5

    func weight(forTool tool: String?) -> Double {
        guard let tool else { return 0 }
        return weights[tool] ?? 0
    }

    /// 从高到低,只留够得上「倾向」的。
    var ranked: [String] {
        weights
            .filter { $0.value >= Self.meaningfulWeight }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    /// 给 `QuestionSuggester` 的一句话。没形成倾向就返回 nil——硬凑一句「他关心健康」
    /// 只会占掉提示词的位置。
    var summary: String? {
        let top = ranked.prefix(2).map { HealthTools.label(for: $0) }
        guard !top.isEmpty else { return nil }

        var sentence = "他最常问的是\(top.joined(separator: "、"))。"
        // 从来没碰过的那几类也值得说一句:据此别再推荐它们,比多推荐一次更有用。
        let untouched = HealthTools.all
            .map(\.name)
            .filter { weights[$0] == nil }
            .prefix(2)
            .map { HealthTools.label(for: $0) }
        if !untouched.isEmpty {
            sentence += "几乎不问\(untouched.joined(separator: "、"))。"
        }
        return sentence
    }

    /// 从线程档案里数一遍。**一天算一段**——一条永远的对话里没有「会话」了,而「这几天他在问
    /// 什么」正是这份统计要的粒度。越近的一天权重越高。
    ///
    /// 只数**用户开口之后**那几轮的工具:Vana 主动说的(check-in、回头看的结论、任务结果)是
    /// app 替他查的,后台替他查了三次睡眠不代表他关心睡眠——而这份统计反过来又会影响后台去查
    /// 什么,不挡住就是自己喂自己。
    static func build(from rows: [ThreadStore.ArchiveRow], calendar: Calendar = .current) -> InterestProfile {
        var byDay: [Date: Set<String>] = [:]
        for row in rows where !row.isUser && !row.isProactive && !row.toolNames.isEmpty {
            guard let createdAt = row.createdAt else { continue }
            // 一天里同一个工具查了五次也只算一次:那是一个问题被拆成了五步,
            // 不是他关心这件事的程度是别人的五倍。
            byDay[calendar.startOfDay(for: createdAt), default: []].formUnion(row.toolNames)
        }

        var weights: [String: Double] = [:]
        for (index, day) in byDay.keys.sorted(by: >).enumerated() {
            let weight = pow(decayPerSession, Double(index))
            for tool in byDay[day] ?? [] {
                weights[tool, default: 0] += weight
            }
        }
        return InterestProfile(weights: weights)
    }
}

extension ThreadStore {
    /// 这条线程里他实际在问什么。首屏、check-in、Siri 三处排序用同一份。
    func interests() -> InterestProfile {
        InterestProfile.build(from: allArchiveRows())
    }
}
