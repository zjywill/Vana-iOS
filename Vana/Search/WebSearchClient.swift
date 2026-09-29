import Foundation

/// 一次网页搜索的结果。
///
/// 只保留**有效载荷**:知识面板、自然结果的标题/来源/日期/摘要。Serper 还会返回
/// `peopleAlsoAsk`、`relatedSearches`、`sitelinks`——那几样是 Google 给人浏览用的导航和
/// 联想,不是信息。喂给模型的话,它们会把模型往一个用户没问的问题上带,同时白占上下文。
struct WebSearchResults: Equatable, Sendable {
    struct Item: Equatable, Sendable {
        let title: String
        let link: String
        let snippet: String
        /// Google 标出来的发布日期,不是每条都有。
        ///
        /// **这个字段不能省。** 健康问题上,一篇 2019 年的和一篇今年的分量完全不同,而摘要
        /// 里通常看不出来。日期原样给模型,让它自己判——app 不替它按日期筛,那会把一篇仍然
        /// 成立的旧综述也扔掉。
        let date: String?
    }

    /// 知识面板。药名、疾病名这类查询常有,是最浓缩的那一段。
    struct Knowledge: Equatable, Sendable {
        let title: String
        let description: String?
        /// 按键排序后取前几条。JSON 对象本来就没有顺序,不排的话同一次查询两次跑出来
        /// 的文本可能不一样,测试就没法盯。
        let attributes: [(key: String, value: String)]

        static func == (lhs: Knowledge, rhs: Knowledge) -> Bool {
            lhs.title == rhs.title
                && lhs.description == rhs.description
                && lhs.attributes.map(\.key) == rhs.attributes.map(\.key)
                && lhs.attributes.map(\.value) == rhs.attributes.map(\.value)
        }
    }

    let query: String
    var knowledge: Knowledge?
    var items: [Item] = []

    var isEmpty: Bool { knowledge == nil && items.isEmpty }
}

/// 「一个能搜网页的东西」。
///
/// 做成闭包而不是协议,理由同 `AgentModelClient` 那一层:测试要的只是「给一个查询、
/// 回一份结果」,不需要一个假的 URLSession。
struct WebSearchClient: Sendable {
    var search: @Sendable (_ query: String) async throws -> WebSearchResults
}

// MARK: - Serper

extension WebSearchClient {
    /// Keychain 里存着 key 就给一个客户端,没存就给 `nil`——调用方据此决定挂不挂这个工具。
    ///
    /// 读盘失败也当没有。搜索是锦上添花的一档,为它让整轮回复发不出去不值当。
    static func storedKey() -> WebSearchClient? {
        guard let stored = try? KeychainStore.get(account: KeychainStore.searchAPIKeyAccount) else {
            return nil
        }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : .serper(apiKey: key)
    }

    /// serper.dev,Google 搜索的一层薄封装。一次查询一个 credit。
    ///
    /// - Parameter apiKey: 只从 Keychain 来。没有 key 时**这个工具根本不挂出去**
    ///   (见 `WebSearchPlugin`),所以这里不处理空 key 的情况。
    static func serper(
        apiKey: String,
        session: URLSession = .shared,
        locale: Locale = .current
    ) -> WebSearchClient {
        WebSearchClient { query in
            var request = URLRequest(url: URL(string: "https://google.serper.dev/search")!)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            // 用户在等回复,搜索只是这一轮里的一步。宁可失败也不要挂住——失败了模型还能
            // 用自己知道的接着答,卡住十几秒是这一轮彻底废掉。
            request.timeoutInterval = 12

            var body: [String: Any] = ["q": query, "num": Self.resultLimit]
            // 地区和语言由 app 按系统语言定,不做成工具参数。多一个参数就多一处模型要猜的
            // 东西,而它猜不出用户在哪——这正是它不知道的那类事。
            if let region = locale.region?.identifier.lowercased() {
                body["gl"] = region
            }
            body["hl"] = Self.searchLanguage(for: locale)
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw WebSearchError(statusCode: http.statusCode)
            }
            return try Self.parse(data, query: query)
        }
    }

    /// 一次给几条。
    ///
    /// 6 条是权衡后的数:再多就开始进第 7 条以后那些明显不相关的,而工具输出的硬上限
    /// (`ContextPolicy.maxToolOutputCharacters`)本来就是给健康数据留的。
    static let resultLimit = 6

    /// 单条摘要的字数上限。Google 的摘要本来就短,超长的多半是把整段正文塞进来了。
    static let snippetLimit = 220

    static func searchLanguage(for locale: Locale) -> String {
        guard let code = locale.language.languageCode?.identifier else { return "en" }
        guard code == "zh" else { return code }
        // 简繁要分开:hl=zh 会被当成简体,给繁体用户的结果就不对了。
        return locale.language.script?.identifier == "Hant" ? "zh-tw" : "zh-cn"
    }

    static func parse(_ data: Data, query: String) throws -> WebSearchResults {
        let payload = try JSONDecoder().decode(SerperPayload.self, from: data)
        var results = WebSearchResults(query: query)

        if let graph = payload.knowledgeGraph, let title = graph.title {
            let attributes = (graph.attributes ?? [:])
                .sorted { $0.key < $1.key }
                .prefix(Self.attributeLimit)
                .map { (key: $0.key, value: $0.value) }
            results.knowledge = .init(
                title: title,
                description: graph.description,
                attributes: Array(attributes)
            )
        }

        results.items = (payload.organic ?? []).prefix(Self.resultLimit).compactMap { entry in
            guard let title = entry.title?.trimmed, !title.isEmpty,
                  let link = entry.link?.trimmed, !link.isEmpty else { return nil }
            return WebSearchResults.Item(
                title: title,
                link: link,
                snippet: (entry.snippet?.trimmed ?? "").truncated(to: Self.snippetLimit),
                date: entry.date?.trimmed.nilIfEmpty
            )
        }
        return results
    }

    static let attributeLimit = 6
}

/// Serper 的返回。只声明用得上的键——`JSONDecoder` 不会去实例化没声明的字段,
/// `peopleAlsoAsk` / `relatedSearches` / `sitelinks` 连解都不解。
private struct SerperPayload: Decodable {
    struct Knowledge: Decodable {
        let title: String?
        let description: String?
        let attributes: [String: String]?
    }

    struct Organic: Decodable {
        let title: String?
        let link: String?
        let snippet: String?
        let date: String?
    }

    let knowledgeGraph: Knowledge?
    let organic: [Organic]?
}

/// 分类要细,因为三种失败对用户是三件不同的事:key 填错了要去改设置,额度用完了这个月
/// 就别指望它,网络抖动下一句就好了。混成一句「搜索失败」的话,前两种会被当成第三种,
/// 用户一直重试到放弃。
struct WebSearchError: LocalizedError, Equatable {
    let statusCode: Int

    var errorDescription: String? {
        switch statusCode {
        case 401, 403:
            return "搜索服务的 key 无效或已过期，请到设置里检查。"
        case 429:
            return "搜索服务的额度用完了，这个月先靠已有的知识回答。"
        default:
            return "搜索服务返回了错误（\(statusCode)）。"
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    func truncated(to limit: Int) -> String {
        count <= limit ? self : String(prefix(limit)) + "…"
    }
}
