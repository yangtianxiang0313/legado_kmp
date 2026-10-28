import Foundation
import shared

struct HLSResourceResponse: @unchecked Sendable {
    let url: URL
    let statusCode: Int
    let headers: [String: String]
    let body: Data
    /// Actual final-hop intent. Children must inherit this snapshot, never the original root headers.
    let finalRequest: PreparedMediaRequest
}

/// Fetches individual native HLS resources, without a media cache, source scripts, WK, proxy or DRM handling.
/// The 16 MiB bound applies to one response body, not aggregate player or process memory.
actor HLSResourceFetcher {
    private var active: [UUID: HLSResourceHTTPTransfer] = [:]
    private var cancelled = false

    init() {}

    func fetch(_ request: PreparedMediaRequest, range: String? = nil) async throws -> HLSResourceResponse {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        let input = try HLSResourceHTTPPolicy.Input(request, range: range)
        let transfer = HLSResourceHTTPTransfer(input: input)
        let id = UUID()
        active[id] = transfer
        defer { active.removeValue(forKey: id) }
        return try await transfer.load()
    }

    /// Terminal for this fetcher. All sessions and shared preparation work have ended on return.
    func cancel() async {
        cancelled = true
        let transfers = Array(active.values)
        for transfer in transfers { transfer.cancel() }
        for transfer in transfers { await transfer.waitUntilFinished() }
    }
}

enum HLSResourceHTTPError: LocalizedError, Sendable {
    case invalidRequest, invalidRange, unsupportedTransport, unsupportedRedirect
    case invalidResponse, tooLarge, timeout, network, empty
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidRequest: return "HLS 资源请求无效"
        case .invalidRange: return "HLS 仅支持 GET 的单段字节范围请求"
        case .unsupportedTransport: return "原生 HLS 不支持书源代理、WebView 或 DRM 处理"
        case .unsupportedRedirect: return "HLS 重定向不安全、超过 10 次或需要跨站重发 POST 正文"
        case .invalidResponse: return "HLS 响应编码、字节范围或长度无效"
        case .tooLarge: return "单个 HLS 资源响应超过 16 MiB 上限"
        case .timeout: return "HLS 资源加载超时"
        case .network: return "HLS 资源网络请求失败"
        case .empty: return "HLS 服务返回了空资源"
        case let .http(status): return "HLS 资源请求失败：HTTP \(status)"
        }
    }
}
