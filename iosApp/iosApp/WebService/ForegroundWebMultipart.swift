import Foundation
import MultipartKit

enum ForegroundWebMultipart {
    struct Upload: Sendable {
        let fileName: String
        let data: Data
    }

    static func decode(body: Data, contentType: String?) async throws -> Upload {
        try Task.checkCancellation()
        let boundary = try boundary(contentType)
        let task = Task.detached(priority: .userInitiated) {
            try parse(body, boundary: boundary)
        }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            try Task.checkCancellation()
            return value
        } onCancel: {
            task.cancel()
        }
    }

    private static func boundary(_ value: String?) throws -> String {
        guard let value, value.utf8.count <= 256 else { throw failure("缺少 multipart Content-Type") }
        let pattern =
            #"^multipart/form-data\s*;\s*boundary=(?:"([0-9A-Za-z'()+_,./:=? -]{1,70})"|([0-9A-Za-z'()+_,./:=?-]{1,70}))\s*$"#
        let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.range == range,
            let selected = Range(match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1), in: value)
        else { throw failure("multipart boundary 无效") }
        let result = String(value[selected])
        guard !result.hasSuffix(" ") else { throw failure("multipart boundary 无效") }
        return result
    }

    private static func parse(_ data: Data, boundary: String) throws -> Upload {
        guard !data.isEmpty, data.count <= 32 * 1024 * 1024 + 64 * 1024,
            data.starts(with: Data("--\(boundary)\r\n".utf8)),
            Data(data.suffix(boundary.utf8.count + 8)) == Data("\r\n--\(boundary)--\r\n".utf8)
                || Data(data.suffix(boundary.utf8.count + 6)) == Data("\r\n--\(boundary)--".utf8)
        else { throw failure("multipart 内容不完整或超过上限") }
        try validateHeaderBytes(data, boundary: boundary)
        let parser = MultipartParser(boundary: boundary)
        var headers = HTTPHeaders()
        var bytes = Data()
        var parts: [String: Data] = [:]
        var headerSize = 0
        var headerCount = 0
        var awaitingBody = true
        var headerInput = 0
        var problem: Error?
        parser.onHeader = { name, value in
            headerSize += name.utf8.count + value.utf8.count
            headerCount += 1
            guard problem == nil else { return }
            guard headerSize <= 16 * 1024, headerCount <= 8, headers[name].isEmpty,
                !value.contains("\n"), !value.contains("\r"), !value.contains("\0")
            else {
                problem = failure("multipart 请求头重复或过大")
                return
            }
            headers.add(name: name, value: value)
        }
        parser.onBody = { buffer in
            guard problem == nil else { return }
            awaitingBody = false
            guard let name = MultipartPart(headers: headers, body: "").name,
                ["fileName", "fileData"].contains(name), parts[name] == nil,
                headers["Content-Transfer-Encoding"].isEmpty,
                headers["Content-Disposition"].first?.lowercased().hasPrefix("form-data;") == true
            else {
                problem = failure("需要唯一的 fileName 和 fileData 字段")
                return
            }
            let limit = name == "fileName" ? 1024 : 32 * 1024 * 1024
            guard bytes.count + buffer.readableBytes <= limit else {
                problem = failure("上传文件超过 32 MiB 或文件名过长")
                return
            }
            bytes.append(contentsOf: buffer.readableBytesView)
        }
        parser.onPartComplete = {
            guard problem == nil else { return }
            let part = MultipartPart(headers: headers, body: "")
            guard let name = part.name, ["fileName", "fileData"].contains(name), parts[name] == nil,
                headers["Content-Transfer-Encoding"].isEmpty,
                headers["Content-Disposition"].first?.lowercased().hasPrefix("form-data;") == true
            else {
                problem = failure("需要唯一的 fileName 和 fileData 字段")
                return
            }
            parts[name] = bytes
            headers = HTTPHeaders()
            bytes = Data()
            headerSize = 0
            headerCount = 0
            awaitingBody = true
            headerInput = 0
        }
        // MultipartKit owns MIME framing; feed bounded chunks so cancellation and limits are observed.
        for offset in stride(from: 0, to: data.count, by: 4 * 1024) {
            try Task.checkCancellation()
            let count = min(4 * 1024, data.count - offset)
            if awaitingBody { headerInput += count }
            let start = data.index(data.startIndex, offsetBy: offset)
            try parser.execute(ByteBuffer(bytes: data[start..<data.index(start, offsetBy: count)]))
            if let problem { throw problem }
            // Also bound a header which never terminates and therefore never triggers onHeader.
            guard !awaitingBody || headerInput <= 20 * 1024 else { throw failure("multipart 请求头过大") }
        }
        try Task.checkCancellation()
        guard parts.count == 2, let nameBytes = parts["fileName"],
            let fileName = String(data: nameBytes, encoding: .utf8), let file = parts["fileData"], !file.isEmpty
        else { throw failure("fileName 或 fileData 缺失、为空或编码无效") }
        return Upload(fileName: fileName, data: file)
    }

    // MultipartKit 4.x indexes an ASCII table before reporting header names. Reject unsafe
    // names before feeding it; MIME body framing and field decoding remain owned by the parser.
    private static func validateHeaderBytes(_ data: Data, boundary: String) throws {
        let marker = Data("\r\n--\(boundary)".utf8)
        let separator = Data("\r\n\r\n".utf8)
        var start = data.index(data.startIndex, offsetBy: boundary.utf8.count + 4)
        while start < data.endIndex {
            try Task.checkCancellation()
            let limit = data.index(start, offsetBy: min(16 * 1024 + 4, data.distance(from: start, to: data.endIndex)))
            guard let end = data.range(of: separator, in: start..<limit) else {
                throw failure("multipart 请求头不完整或过大")
            }
            var readingName = true
            var previous: UInt8 = 0
            for byte in data[start..<end.lowerBound] {
                if readingName, byte >= 128 { throw failure("multipart 请求头名称必须为 ASCII") }
                if byte == 58 { readingName = false }
                if previous == 13, byte == 10 { readingName = true }
                previous = byte
            }
            guard let next = data.range(of: marker, in: end.upperBound..<data.endIndex) else {
                throw failure("multipart 内容不完整")
            }
            let suffix = next.upperBound
            guard data.distance(from: suffix, to: data.endIndex) >= 2 else { throw failure("multipart 内容不完整") }
            let after = data.index(suffix, offsetBy: 2)
            if data[suffix..<after].elementsEqual([45, 45]) { return }
            guard data[suffix..<after].elementsEqual([13, 10]) else { throw failure("multipart 分隔符无效") }
            start = after
        }
        throw failure("multipart 内容不完整")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web.multipart", code: 400, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
