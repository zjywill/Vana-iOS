import Foundation
import AIKit

/// 云端 provider / 模型选项,全部来自 AIKit 内置 catalog,设置页只做选择不让手输。
enum CloudCatalog {
    /// 只列 AIKit 已实现协议、且填个 API key 就能连上的云端 provider,按显示名排序。
    static let providers: [ProviderInfo] = ProviderCatalog.all
        .filter { $0.wireProtocol != nil && isHostedCloud($0) }
        .sorted {
            displayName(of: $0).localizedCaseInsensitiveCompare(displayName(of: $1)) == .orderedAscending
        }

    /// 排除本地部署(Ollama、LM Studio)和目录里没有固定地址的 provider
    /// (custom-provider、DimCode OAuth 等):
    /// 手机连不到 localhost,而没有 base URL 的 provider 一发请求就是 missingBaseURL。
    private static func isHostedCloud(_ provider: ProviderInfo) -> Bool {
        guard let api = provider.api,
              let host = URL(string: api)?.host()?.lowercased() else {
            return false
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "0.0.0.0"]
        return !loopback.contains(host) && !host.hasSuffix(".local")
    }

    /// catalog 资源没打进 app 时为 false,设置页要退回手输并显示 diagnostics。
    static var isLoaded: Bool { !providers.isEmpty }

    static var diagnostics: String { ProviderCatalog.diagnostics }

    static func provider(_ id: String) -> ProviderInfo? {
        providers.first { $0.id == id }
    }

    static func displayName(of provider: ProviderInfo) -> String {
        provider.name ?? provider.id
    }

    static func providerName(for id: String) -> String {
        provider(id).map(displayName(of:)) ?? id
    }

    /// 该 provider 内置的模型;健康工具是刚需,不支持工具调用的模型不列。
    /// 保持 catalog 原始顺序(新模型在前)。
    static func models(for providerId: String) -> [ModelInfo] {
        (provider(providerId)?.models ?? []).filter(\.supportsTools)
    }

    static func model(_ modelId: String, in providerId: String) -> ModelInfo? {
        provider(providerId)?.model(modelId)
    }

    static func displayName(of model: ModelInfo) -> String {
        model.name ?? model.id
    }

    static func modelName(for modelId: String, in providerId: String) -> String {
        model(modelId, in: providerId).map(displayName(of:)) ?? modelId
    }

    /// 换 provider 后的默认模型:内置列表第一个;没有内置列表则返回 nil,由用户自己拉取或填。
    static func defaultModel(for providerId: String) -> String? {
        models(for: providerId).first?.id
    }

    /// "上下文 200K · 输出 64K",catalog 没写就返回 nil。
    static func limitSummary(of model: ModelInfo) -> String? {
        var parts: [String] = []
        if let context = model.contextWindow {
            parts.append("上下文 \(tokenCount(context))")
        }
        if let output = model.maxOutputTokens {
            parts.append("输出 \(tokenCount(output))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func tokenCount(_ tokens: Int) -> String {
        if tokens >= 1_000_000 {
            let value = Double(tokens) / 1_000_000
            return value == value.rounded() ? "\(Int(value))M" : String(format: "%.1fM", value)
        }
        if tokens >= 1_000 {
            return "\(tokens / 1_000)K"
        }
        return "\(tokens)"
    }

    /// 向服务端要模型列表。catalog 里没有内置模型的 provider(Ollama、OpenRouter、各种网关)靠这个。
    static func fetchModels(providerId: String, apiKey: String) async throws -> [ModelInfo] {
        let client = try AIClient(
            providerId: providerId,
            configuration: .init(apiKey: apiKey.isEmpty ? nil : apiKey)
        )
        return try await client.models()
    }
}
