import Foundation
import shared

/// The immutable DTO snapshot crosses to one serial worker; only the cancellation gate is shared.
final class WebBookFileInlineLoader: WebBookFileLoading, @unchecked Sendable {
    private static let maximumEncodedBytes = 96 * 1024 * 1024
    private static let maximumDecodedBytes: Int64 = 64 * 1024 * 1024
    private static let chunkBytes = 64 * 1024

    private let queue = DispatchQueue(label: "io.legado.web-book.file.inline", qos: .userInitiated)
    private let gate = WebBookFileCancellation()
    private let base64: String
    private let fileName: String
    private let expectedBytes: Int64
    private let progress: WebBookFileProgress

    // Confined to queue, including decoding, output ownership and continuation completion.
    private var started = false
    private var receivedBytes: Int64 = 0
    private var lastProgressTime: TimeInterval = 0

    @MainActor
    init(data: WebBookFileInlineData, progress: WebBookFileProgress) {
        base64 = data.dataBase64
        fileName = data.fileName
        expectedBytes = data.decodedBytes
        self.progress = progress
    }

    func load() async throws -> WebBookFileReceipt {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.started else {
                        continuation.resume(throwing: WebBookFilePolicy.failure("文件下载已经开始"))
                        return
                    }
                    self.started = true
                    let result = Result { try self.decodeAndWrite() }
                    // Cancellation never resumes early: decoding and staging cleanup have both ended.
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() { _ = gate.cancel() }

    private func decodeAndWrite() throws -> WebBookFileReceipt {
        try gate.check()
        guard expectedBytes > 0 else { throw WebBookFilePolicy.failure("内嵌文件为空或声明长度无效") }
        guard expectedBytes <= Self.maximumDecodedBytes else {
            throw WebBookFilePolicy.failure("内嵌文件超过 64 MiB 解码上限")
        }
        let file = try WebBookFileOutput()
        defer { file.cleanup() }
        publishProgress(force: true)

        var chunk = Data()
        chunk.reserveCapacity(Self.chunkBytes)
        var encodedBytes = 0
        var padding = 0
        for byte in base64.utf8 {
            encodedBytes += 1
            guard encodedBytes <= Self.maximumEncodedBytes else {
                throw WebBookFilePolicy.failure("内嵌文件编码超过 96 MiB 上限")
            }
            // Whitespace-only runs must be just as cancellable as data-bearing chunks.
            if encodedBytes % Self.chunkBytes == 0 { try gate.check() }
            switch byte {
            case 9...13, 32:
                continue
            case 61:
                let position = chunk.count % 4
                guard
                    (padding == 0 && (position == 2 || position == 3))
                        || (padding == 1 && position == 3)
                else { throw WebBookFilePolicy.failure("内嵌文件 Base64 padding 无效") }
                padding += 1
                chunk.append(byte)
            case 43, 47, 48...57, 65...90, 97...122:
                guard padding == 0 else { throw WebBookFilePolicy.failure("内嵌文件 Base64 padding 后存在数据") }
                chunk.append(byte)
                if chunk.count == Self.chunkBytes {
                    try write(chunk, to: file)
                    chunk.removeAll(keepingCapacity: true)
                }
            default:
                throw WebBookFilePolicy.failure("内嵌文件包含非法 Base64 字符")
            }
        }
        try gate.check()
        let remainder = chunk.count % 4
        if padding > 0 {
            guard remainder == 0 else { throw WebBookFilePolicy.failure("内嵌文件 Base64 padding 不完整") }
        } else {
            guard remainder != 1 else { throw WebBookFilePolicy.failure("内嵌文件 Base64 长度无效") }
            if remainder > 0 { chunk.append(contentsOf: repeatElement(UInt8(61), count: 4 - remainder)) }
        }
        if !chunk.isEmpty { try write(chunk, to: file) }
        guard receivedBytes > 0 else { throw WebBookFilePolicy.failure("内嵌文件为空") }
        guard receivedBytes == expectedBytes else {
            throw WebBookFilePolicy.failure("内嵌文件实际长度与声明不符")
        }
        try gate.check()
        try file.synchronizeAndClose(bytes: receivedBytes)
        // Filename/type hints do not validate content. Use the same production import parsers as HTTP.
        let name = WebBookFilePolicy.filename(fallback: fileName)
        let url = try file.commit(name: name, cancellation: gate)
        // No throwing work or Task cancellation checks may follow the atomic commit.
        return WebBookFileReceipt(url: url, bytes: receivedBytes, total: expectedBytes)
    }

    private func write(_ chunk: Data, to file: WebBookFileOutput) throws {
        try autoreleasepool {
            try gate.check()
            guard let decoded = Data(base64Encoded: chunk), !decoded.isEmpty else {
                throw WebBookFilePolicy.failure("内嵌文件 Base64 解码失败")
            }
            let count = Int64(decoded.count)
            guard count <= Self.maximumDecodedBytes - receivedBytes else {
                throw WebBookFilePolicy.failure("内嵌文件超过 64 MiB 解码上限")
            }
            guard count <= expectedBytes - receivedBytes else {
                throw WebBookFilePolicy.failure("内嵌文件实际长度超出声明")
            }
            try file.write(decoded, cancellation: gate)
            receivedBytes += count
            publishProgress()
        }
    }

    private func publishProgress(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now
        let bytes = receivedBytes
        let total = expectedBytes
        DispatchQueue.main.async { [weak progress] in progress?.report(bytes, total) }
    }
}
