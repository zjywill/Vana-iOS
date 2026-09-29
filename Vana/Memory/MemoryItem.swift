import Foundation

/// Vana 记住的一条事实。
///
/// 记忆里**不存 HealthKit 查得到的数字**。存「昨晚睡了 6.2 小时」明天就是错的,存「他觉得
/// 睡够 7 小时才算好」永远对。查得到的每次回工具拿,记忆只留查不到的:用户自己说的、模型
/// 推出来的解释、他希望被怎么对待。
///
/// 这条约束顺带解决了失效问题——不存易腐的东西,就不用给每条记忆做过期时间。唯一的例外是
/// `followUp`,那一类天生带时限,过期自己消失。
struct MemoryItem: Identifiable, Equatable, Codable, Sendable {
    /// 这条是怎么来的。
    ///
    /// 界面上要能回答「这句哪来的」:分不清是自己写的还是模型记的,用户就没法判断该不该
    /// 信它。也决定了后台的抽取能不能动它——前两种都不行。
    enum Origin: String, Codable, Sendable {
        /// 在设置页里手写或改过的。
        case manual
        /// 对话里明确让 Vana 记的(`remember` 工具)。
        case asked
        /// 会话结束后自动抽出来的。
        case extracted
    }

    let id: UUID
    var kind: MemoryKind
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var origin: Origin
    /// 从哪条会话来的。
    var sourceSessionId: UUID?
    /// `followUp`:说好什么时候回头看;`episode`:什么时候淡出。别的种类没有。
    ///
    /// 待跟进到期不等于删除——到期正是它要派上用场的时刻。过了这个点它会进 check-in,
    /// 再过 `MemoryStore.followUpGrace` 才真的消失。近况到点就没了(`MemoryKind.grace`)。
    var dueAt: Date?

    /// 用户主动写下或要求记的,淘汰和自动改写都跳过。
    var pinned: Bool { origin != .extracted }

    init(
        id: UUID = UUID(),
        kind: MemoryKind,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        origin: Origin = .extracted,
        sourceSessionId: UUID? = nil,
        dueAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.origin = origin
        self.sourceSessionId = sourceSessionId
        self.dueAt = dueAt
    }

    /// 说好回头看的那天到了。
    func isDue(at now: Date) -> Bool {
        guard let dueAt else { return false }
        return dueAt <= now
    }

    /// 到期之后又搁了一段时间(按种类,见 `MemoryKind.grace`),可以清掉了。
    func hasExpired(at now: Date) -> Bool {
        guard let dueAt, kind.expires else { return false }
        return dueAt.addingTimeInterval(kind.grace) <= now
    }
}

/// 记忆的几类。
///
/// 分类不是为了好看:渲染进 prompt 时分组能让模型对短列表更服从,淘汰时也要按类别定优先级。
/// **声明顺序就是排序和编号的顺序**(`MemoryStore.sorted`),新加的种类别随手插在中间。
enum MemoryKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 长期情况:上夜班、腰伤不能跑、在备半马。
    case profile
    /// 表达偏好:别老提醒去看医生、只看深睡时长。
    case preference
    /// 近况:最近发生、还没了结的事(「下周三面试」「最近在装修」)。带过期时间,到点自己淡出,
    /// 不是长期成立的事实——一句话提过就能用上,又不会三个月后还在 system 段里挂着。
    case episode
    /// 已有解释:静息心率基线约 52、三月那周 HRV 掉是因为出差。**归健康插件**
    /// (`HealthVanaPlugin.memoryKinds`):健康关掉之后这类不再进对话。
    case interpretation
    /// 待跟进:说好过一阵子再看的事。
    case followUp

    var id: String { rawValue }

    /// **给模型看的**标签,固定中文,不随界面语言变。模型可见的提示词其余部分本来就是中文;
    /// 标签跟着界面语言变(英文界面下成了 `[Communication preferences]`)会让同一份记忆在不同
    /// 语言下渲染成不同长度、不同前缀——既让预算不稳,也让缓存前缀凭空多出一个变量。
    var promptLabel: String {
        switch self {
        case .profile: "长期情况"
        case .preference: "表达偏好"
        case .episode: "近况"
        case .interpretation: "已有解释"
        case .followUp: "待跟进"
        }
    }

    /// 界面上的名字,跟界面语言走。
    var title: String {
        switch self {
        case .profile: String(localized: "长期情况")
        case .preference: String(localized: "表达偏好")
        case .episode: String(localized: "近况")
        case .interpretation: String(localized: "已有解释")
        case .followUp: String(localized: "待跟进")
        }
    }

    var hint: String {
        switch self {
        case .profile: String(localized: "作息、工作或学习、身体上的限制、家人，还有正在进行的目标")
        case .preference: String(localized: "希望 Vana 怎么说话、怎么做事，自己看重什么")
        case .episode: String(localized: "最近发生、还没完的事，过一阵子会自己淡出")
        case .interpretation: String(localized: "已经讨论清楚的结论，比如某个指标对你而言的正常范围")
        case .followUp: String(localized: "说好过一阵子再看的事，到点会在 check-in 里提醒你")
        }
    }

    var icon: String {
        switch self {
        case .profile: "person.text.rectangle"
        case .preference: "text.bubble"
        case .episode: "calendar.badge.clock"
        case .interpretation: "chart.line.uptrend.xyaxis"
        case .followUp: "clock.arrow.circlepath"
        }
    }

    /// 带过期时间的种类。
    var expires: Bool { self == .followUp || self == .episode }

    /// 到期之后还留多久。待跟进到期那一刻正是它要派上用场的时候(进 check-in、进 system 段),
    /// 当场删掉等于永远用不上;近况到点就该消失,它本来就是「最近」的事。
    var grace: TimeInterval { self == .followUp ? MemoryStore.followUpGrace : 0 }

    /// 这一类的天数上限。
    var maxDays: Int? {
        switch self {
        case .followUp: MemoryItem.maxFollowUpDays
        case .episode: MemoryItem.maxEpisodeDays
        default: nil
        }
    }
}

extension MemoryItem {
    static let defaultExpiryDays = 14
    static let maxFollowUpDays = 180
    static let maxEpisodeDays = 60
    /// 一条记忆一句话:抽取器、`remember`、`revise_memory` 共用这一个上限。
    static let maxTextCharacters = 120
    /// 近况是「最近的事」,不是第二份长期记忆:攒多了先淡掉最旧的。
    static let maxEpisodes = 10

    /// `kind` 的到期时间;不带过期的种类返回 nil。`days` 缺省 14 天,按种类夹在各自的上限里。
    static func dueDate(kind: MemoryKind, days: Int?, now: Date) -> Date? {
        guard let upper = kind.maxDays else { return nil }
        let clamped = min(max(days ?? defaultExpiryDays, 1), upper)
        return now.addingTimeInterval(Double(clamped) * 86_400)
    }

    /// 比较用:去掉空白和标点、不分大小写。「不吃香菜。」和「不吃 香菜」是同一句。
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter {
            CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
        }.map(Character.init))
    }

    /// 界面上「这句哪来的」。
    var originLabel: String {
        switch origin {
        case .manual: String(localized: "你写的")
        case .asked: String(localized: "你让我记的")
        case .extracted: String(localized: "从对话中记下")
        }
    }
}

/// 一轮请求开始时拿到的记忆。
///
/// 引擎不许自己去读盘:由 `ChatViewModel` 读好传进去。记忆内容不变时渲染出来的块逐字相同,
/// prompt 缓存不受影响;变了只打掉易变区那一截尾巴(`PromptOrder.memory`)。
struct MemorySnapshot: Equatable, Sendable {
    static let empty = MemorySnapshot(items: [])

    /// 进 system 段的那一块的上限。每行除了正文还有「- M12 [长期情况] 」这段前缀,
    /// 预算把它算上,存满 40 条也能整块放下。
    static let blockBudget = MemoryStore.maxCharacters + MemoryStore.maxItems * 20

    let items: [MemoryItem]

    var isEmpty: Bool { items.isEmpty }

    /// 只留 `keep` 认可的条目。插件关掉之后,它拥有的那类记忆不再带进对话(数据还在盘上)。
    func filtered(_ keep: (MemoryItem) -> Bool) -> MemorySnapshot {
        MemorySnapshot(items: items.filter(keep))
    }

    /// 拼进 system 段的那一块。空记忆返回 nil,不要往提示里塞一句「（暂无）」——那只会
    /// 让模型去解释为什么没有。
    var instructionBlock: String? {
        instructionBlock(now: Date())
    }

    /// 每行带短编号(M1、M2…):对话里「忘掉…」「不对，其实是…」靠它指到某一条。编号就是条目
    /// 在 `items` 里的位置,和抽取器看到的 `handleListing` 是同一套,排序稳定才不会指错。
    ///
    /// 按渲染出来的整行算预算,并且**在行边界上截**——截在半行的那一条会被模型读成另一句话。
    /// 到期的待跟进优先留:那是用户自己定下的约定。
    func instructionBlock(now: Date) -> String? {
        guard !items.isEmpty else { return nil }
        let indexed = Array(items.prefix(MemoryStore.maxItems).enumerated())

        func line(_ index: Int, _ item: MemoryItem) -> String {
            // 到期的待跟进要说清已经到点了,否则模型只会把它当成一句将来时的计划,
            // 而这条记忆存在的全部意义就是「现在该回头看了」。
            let due = item.kind == .followUp && item.isDue(at: now) ? "（说好的时间已经到了）" : ""
            return "- \(Self.handle(index)) [\(item.kind.promptLabel)] \(item.text)\(due)"
        }

        var budget = Self.blockBudget
        var kept = Set<Int>()
        for (index, item) in indexed where item.kind == .followUp && item.isDue(at: now) {
            kept.insert(index)
            budget -= line(index, item).count + 1
        }
        for (index, item) in indexed where !kept.contains(index) {
            let length = line(index, item).count + 1
            if length <= budget {
                kept.insert(index)
                budget -= length
            }
        }
        let body = indexed.filter { kept.contains($0.offset) }.map { line($0.offset, $0.element) }
        // 最后一句是这套东西最要紧的防线。没有它,模型会拿三个月前记下的一句话当今天的数据讲。
        return (["关于这位用户（来自过往对话）："] + body + [
            "以上只用于理解他的处境和表达方式。任何具体数值一律以本次工具返回的为准，"
                + "记忆与工具结果冲突时以工具结果为准。"
        ]).joined(separator: "\n")
    }

    static func handle(_ index: Int) -> String { "M\(index + 1)" }

    /// 给抽取器看的那份:每条前面挂一个短编号,和进 system 段的那一块同一套。
    ///
    /// 不给模型看 UUID——36 个字符乘以几十条纯属浪费,而且模型抄长串本来就容易抄错,抄错
    /// 一位就是一条改不动的记忆。
    var handles: [(handle: String, item: MemoryItem)] {
        items.prefix(MemoryStore.maxItems).enumerated().map { (handle: Self.handle($0.offset), item: $0.element) }
    }

    func resolve(handle: String) -> UUID? {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        return handles.first { $0.handle.caseInsensitiveCompare(trimmed) == .orderedSame }?.item.id
    }

    var handleListing: String {
        guard !items.isEmpty else { return "（目前还没有记住任何事）" }
        return handles
            .map { "\($0.handle) [\($0.item.kind.promptLabel)] \($0.item.text)" }
            .joined(separator: "\n")
    }

    /// 说好该回头看的那几条。check-in 用它挑今天早上说什么。
    func due(at now: Date) -> [MemoryItem] {
        items.filter { $0.kind == .followUp && $0.isDue(at: now) }
    }
}
