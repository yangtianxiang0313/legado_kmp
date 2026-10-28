import CFNetwork
import Foundation

struct ForegroundHTTPRequest {
    let method: String
    let path: String
    let host: String
    let origin: String?
    let token: String?
    let parameters: [String: String]
    let body: Data
}

@MainActor
final class ForegroundHTTPParser {
    private let message = CFHTTPMessageCreateEmpty(nil, true).takeRetainedValue()
    private var received = 0
    private var headerBytes = Data()
    private var headerLength: Int?
    private var contentLength: Int?

    func append(_ data: Data) throws -> ForegroundHTTPRequest? {
        guard !data.isEmpty else { return nil }
        received += data.count
        guard received <= 8 * 1024 * 1024 + 16 * 1024 else { throw failure("请求过大") }
        if headerLength == nil {
            headerBytes.append(data)
            if let range = headerBytes.range(of: Data([13, 10, 13, 10])) {
                headerLength = range.upperBound
                guard range.upperBound <= 16 * 1024 else { throw failure("请求头过大") }
                headerBytes.removeAll()
            } else if headerBytes.count > 16 * 1024 {
                throw failure("请求头过大")
            }
        }
        guard
            data.withUnsafeBytes({ buffer in
                CFHTTPMessageAppendBytes(message, buffer.bindMemory(to: UInt8.self).baseAddress!, data.count)
            })
        else { throw failure("HTTP 请求无效") }
        guard CFHTTPMessageIsHeaderComplete(message), let headerLength else { return nil }
        func header(_ name: String) -> String? {
            CFHTTPMessageCopyHeaderFieldValue(message, name as CFString)?.takeRetainedValue() as String?
        }
        if contentLength == nil {
            guard header("Transfer-Encoding") == nil, header("Expect") == nil else { throw failure("不支持此传输方式") }
            let raw = header("Content-Length") ?? "0"
            guard !raw.isEmpty, raw.allSatisfy({ $0.isASCII && $0.isNumber }),
                let count = Int(raw), count <= 8 * 1024 * 1024
            else { throw failure("正文长度无效") }
            contentLength = count
        }
        guard let expected = contentLength, received <= headerLength + expected else { throw failure("不接受复用或多余请求数据") }
        guard received == headerLength + expected else { return nil }
        guard let method = CFHTTPMessageCopyRequestMethod(message)?.takeRetainedValue() as String?,
            let url = CFHTTPMessageCopyRequestURL(message)?.takeRetainedValue() as URL?,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let host = header("Host"), !host.contains(",")
        else { throw failure("请求地址无效") }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard query[item.name] == nil else { throw failure("查询参数重复") }
            query[item.name] = item.value ?? ""
        }
        let body = CFHTTPMessageCopyBody(message)?.takeRetainedValue() as Data? ?? Data()
        guard body.count == expected else { throw failure("正文长度不一致") }
        return ForegroundHTTPRequest(
            method: method, path: components.path, host: host, origin: header("Origin"),
            token: header("Authorization"), parameters: query, body: body)
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.http", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
