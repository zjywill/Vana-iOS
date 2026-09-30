import Foundation
import AgentRuntime

/// 检索这条对话里**已经滑出窗口**的历史,以及别的线(主对话、侧聊)里说过的。
///
/// 侧聊和主对话窗口各管各的,互通靠的就是这一层和记忆:别的线整条都算「看不见」,搜出来的每一处
/// 标上它在哪条线上(`Source.label`)。
///
/// 工具名(`search_sessions` / `read_session`)沿用旧的——历史 transcript 里已经写过对它们的
/// 调用,改名只会让旧调用对不上号;对模型来说它们的意思是「翻对话历史」。
///
/// 胜负手是**召回精度不是召回广度**:模型说「我们上次说过…」而用户根本不记得说过,那一瞬间
/// 信任掉得比从没记住过还快。所以:
///
/// - **只搜窗口之外的**:窗口里的原文模型本来就看得见,再搜出来只是重复。
/// - **只打分用户说过的话**:助手那几段什么都提一句,放进来的话每一处都能匹配上任何查询。
/// - **门槛是相对的**:只留到最高分三分之二的,最多 6 处。`score > 0` 意味着任何查询都能捞回
///   一把弱匹配,而模型分不出哪条才是用户说的那次,只好挨条读过去。
/// - **读回来用原文,不重新总结**(那要多花一次模型调用,而用户正等着),每段标日期,末尾原样
///   带上「数值一律以本次工具返回的为准」。
/// - **找不到不报错**。「以前没聊过这个」是有效答案;报成错误模型会以为工具坏了,换个说法再试。
enum HistoryRecallTools {
    static let searchToolName = "search_sessions"
    static let readToolName = "read_session"

    static let maxCharacters = 2_500
    static let maxUserCharacters = 200
    static let maxAssistantCharacters = 320
    static let maxMatches = 6

    /// 末尾这句是整套召回最要紧的防线,和记忆块末尾那句同源:旧对话里全是当时的具体数字,
    /// 而它们**全部**已经过期。
    static let footer = "（以上是当时说过的话，日期见开头。里面的具体数值都可能已经过时，"
        + "要用就现在重新查一遍工具，一律以本次返回的为准。）"

    private static let headerPrefix = "这是 "
    private static let headerSuffix = " 的一段对话"

    /// 能翻的一条线。
    struct Source: Sendable {
        /// nil 是这条对话本身;别的线写它是哪条(「主对话」「侧聊「京都」」),搜出来的每一处都标上。
        var label: String?
        var store: ThreadStore
        /// 它**之前**的才算看不见。这条对话本身是窗口起点;别的线整条都看不见。
        var hiddenBefore: Double = .greatestFiniteMagnitude
    }

    /// - Parameter hiddenBefore: 窗口起点的位置。它**之前**的才是「滑出去了」的历史。
    static func registry(store: ThreadStore, hiddenBefore: Double) -> CapabilityRegistry {
        registry(sources: [Source(label: nil, store: store, hiddenBefore: hiddenBefore)])
    }

    /// 几条线一起翻。只有这条对话本身的时候,工具说明和线上一直以来的那份逐字一样。
    static func registry(sources: [Source]) -> CapabilityRegistry {
        let spansOtherThreads = sources.contains { $0.label != nil }
        return CapabilityRegistry(definitions: [searchDefinition(spansOtherThreads: spansOtherThreads), readDefinition]) { invocation in
            let input = try? RuntimeJSONValue.decode(from: invocation.input)
            switch invocation.name {
            case searchToolName:
                return await search(
                    query: input?["query"]?.stringValue ?? "",
                    sinceDays: input?["since_days"]?.intValue,
                    sources: sources
                )
            case readToolName:
                return await read(handle: input?["id"]?.stringValue ?? "", sources: sources)
            default:
                return .failure("不支持名为 \(invocation.name) 的工具。")
            }
        }
    }

    /// 搜出来的一处:哪一行、在哪条线上。
    private struct Hit {
        var row: ThreadStore.ArchiveRow
        var source: Int
        var label: String?
    }

    /// 谁更近。同一条线上按位置(它才是真顺序:插话之前的回复位置更小);跨线只能按时间。
    private static func isMoreRecent(_ a: Hit, _ b: Hit) -> Bool {
        if a.source == b.source { return a.row.pos > b.row.pos }
        return (a.row.createdAt ?? .distantPast) > (b.row.createdAt ?? .distantPast)
    }

    /// 一条消息的短编号:id 的稳定散列。**不按「第几条」编**——删掉一条,编号就全错位了;
    /// 也不能用 `hashValue`,那个每次启动都换一个种子。
    static func handle(of id: UUID) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in id.uuidString.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return "H" + String(hash, radix: 36).uppercased()
    }

    // MARK: - 执行

    private static func search(
        query: String,
        sinceDays: Int?,
        sources: [Source],
        now: Date = Date()
    ) async -> CapabilityExecutionResult {
        let since = sinceDays.map { now.addingTimeInterval(-Double(min(max($0, 1), 365)) * 86_400) }
        var candidates: [Hit] = []
        for (index, source) in sources.enumerated() {
            candidates += await source.store.archiveRows(before: source.hiddenBefore)
                .filter { row in row.isUser && (since.map { (row.createdAt ?? .distantPast) >= $0 } ?? true) }
                .map { Hit(row: $0, source: index, label: source.label) }
        }
        guard !candidates.isEmpty else { return .success("还没有可以回顾的过往对话。") }

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: [Hit]
        if trimmed.isEmpty {
            matches = Array(candidates.sorted(by: isMoreRecent).prefix(maxMatches))
        } else {
            let wanted = terms(in: trimmed)
            let scored = candidates.compactMap { hit -> (Hit, Int)? in
                let score = wanted.intersection(terms(in: hit.row.text)).count
                return score > 0 ? (hit, score) : nil
            }
            guard let best = scored.map(\.1).max() else { return .success("没有找到相关的过往对话。") }
            let floor = max(1, best * 2 / 3)
            matches = scored
                .filter { $0.1 >= floor }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : isMoreRecent($0.0, $1.0) }
                .prefix(maxMatches)
                .map(\.0)
        }

        var lines = ["找到 \(matches.count) 处相关的过往对话："]
        for hit in matches {
            let row = hit.row
            let first = row.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? row.text
            let place = hit.label.map { " · \($0)" } ?? ""
            lines.append("- \(handle(of: row.id)) · \(dateLabel(row.createdAt, now: now))\(place) · \(first.prefix(80))")
        }
        // 末尾这句是条件句,不是祈使句。写成「用 read_session 读其中一条」的话,检索结果本身
        // 就成了下一次调用的指令——哪怕列出来的这几条明显不是用户说的那次,模型也会挨个读下去。
        lines.append("")
        lines.append("其中确实是用户说的那次，用 read_session 读它；都对不上就别读了，照常回答。")
        return .success(lines.joined(separator: "\n"))
    }

    private static func read(handle: String, sources: [Source]) async -> CapabilityExecutionResult {
        let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        for source in sources {
            guard let target = await source.store.archiveRows(before: source.hiddenBefore)
                .first(where: { Self.handle(of: $0.id).caseInsensitiveCompare(trimmed) == .orderedSame })
            else { continue }
            guard let rows = await source.store.archiveRows(around: target.id) else {
                return .failure("编号 \(trimmed) 的对话已经读不到了，可能刚被删除。")
            }
            return .success(transcript(rows, place: source.label))
        }
        return .failure("没有编号为 \(trimmed) 的对话。先调 search_sessions 拿编号。")
    }

    /// - Parameter place: 这段在哪条线上。写在日期**后面**的括号里:胶囊上的日期是从开头那几个字
    ///   里取的(`dateLabel(inOutput:)`),不能被它挤乱。
    static func transcript(_ rows: [ThreadStore.ArchiveRow], place: String? = nil, now: Date = Date()) -> String {
        let where_ = place.map { "（\($0)）" } ?? ""
        var lines = ["\(headerPrefix)\(dateLabel(rows.first?.createdAt, now: now))\(headerSuffix)\(where_)：", ""]
        var used = lines.reduce(0) { $0 + $1.count }
        for row in rows {
            var body = String(row.text.prefix(row.isUser ? maxUserCharacters : maxAssistantCharacters))
            // 工具轨迹只留名字不留数字:查过什么说明结论建立在哪些数据上,有用;带回数字等于
            // 拿三个月前的读数污染这一轮。
            if !row.isUser, !row.toolNames.isEmpty {
                body += "（当时查了：\(row.toolNames.joined(separator: "、"))）"
            }
            let line = (row.isUser ? "他：" : "Vana：") + body
            if used + line.count + footer.count + 4 > maxCharacters { break }
            lines.append(line)
            used += line.count
        }
        lines.append("")
        lines.append(footer)
        return lines.joined(separator: "\n")
    }

    /// 从读回来的那段里取出日期,给气泡上的胶囊用。和给模型的是同一个来源,不会出现胶囊说
    /// 8 月 8 日、点开是 8 月 6 日。
    static func dateLabel(inOutput output: String?) -> String? {
        guard let first = output?.split(separator: "\n", maxSplits: 1).first.map(String.init),
              first.hasPrefix(headerPrefix),
              let end = first.range(of: headerSuffix)
        else { return nil }
        let label = String(first[first.index(first.startIndex, offsetBy: headerPrefix.count)..<end.lowerBound])
        return label.isEmpty ? nil : label
    }

    /// 一律说得出具体是哪天:「上个月」听着自然,但模型拿它没法判断一条三个月前的结论还算不算数。
    static func dateLabel(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "更早" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: date)
    }

    /// 中文两字一组、英文整词。全英文的词整个留着:把 "hrv" 拆成 hr/rv 会匹配上一堆无关的东西。
    static func terms(in text: String) -> Set<String> {
        var result: Set<String> = []
        for chunk in text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let characters = Array(chunk)
            guard characters.count > 1 else { continue }
            if chunk.allSatisfy(\.isASCII) {
                result.insert(String(chunk))
                continue
            }
            for index in 0..<(characters.count - 1) {
                result.insert(String(characters[index...(index + 1)]))
            }
        }
        return result
    }

    // MARK: - 定义

    /// 只有这条对话本身时,说明和线上一直以来的那份逐字一样;能翻别的线时多说一句「还有哪儿」。
    private static func searchDefinition(spansOtherThreads: Bool) -> CapabilityDefinition {
        spansOtherThreads ? searchAcrossThreadsDefinition : searchDefinition
    }

    private static let searchAcrossThreadsDefinition: CapabilityDefinition = {
        var definition = searchDefinition
        definition.description = (definition.description ?? "").replacingOccurrences(
            of: "搜索这条对话里更早的、已经不在上面的部分，",
            with: "搜索这条对话里更早的、已经不在上面的部分，以及别的对话线（主对话、侧聊）里说过的，"
        ) + "他提到主对话或别的侧聊里的事时也一样。"
        return definition
    }()

    private static let searchDefinition = CapabilityDefinition(
        name: searchToolName,
        description: """
        搜索这条对话里更早的、已经不在上面的部分，返回相关的那几处。\
        只在用户自己提起过去时调用：他说了「上次」「之前说过」「我们聊过」「你还记得」，\
        或者直接问一件他以前交代过、这次没再说的事。\
        眼前的数据不走这里——今天怎么样、最近的趋势，一律直接调对应的工具现查。\
        用户没提过去就不要试探性地找一次。找到相关的那处之后用 read_session 读它。
        """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "query": .object([
                    "type": "string",
                    "description": "检索词，来自用户提到过去时说的话，用中文关键词，比如「装修 预算」「周末计划」"
                ]),
                "since_days": .object([
                    "type": "integer",
                    "description": "只看最近多少天，1–365，可选",
                    "minimum": 1,
                    "maximum": 365
                ])
            ]),
            "required": .array([.string("query")]),
            "additionalProperties": .bool(false)
        ])
    )

    private static let readDefinition = CapabilityDefinition(
        name: readToolName,
        description: """
        按 search_sessions 给出的短编号读取那一处前后的对话原文。\
        读到的都标着日期，里面的具体数值都是当时的，现在多半已经变了——要用数值就重新调工具查，以本次返回的为准。
        """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "id": .object([
                    "type": "string",
                    "description": "search_sessions 给出的短编号，形如 H3F2A"
                ])
            ]),
            "required": .array([.string("id")]),
            "additionalProperties": .bool(false)
        ])
    )
}
