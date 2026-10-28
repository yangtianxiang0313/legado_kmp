import Foundation
import shared

final class CacheExportFileLease: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let lock = NSLock()
    private var ownsDirectory = true

    init(fileName: String) throws {
        guard !fileName.isEmpty, fileName != ".", fileName != "..", fileName.utf8.count <= 220,
            !fileName.contains("/"), !fileName.contains("\\"),
            fileName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw NSError(
                domain: "io.legado.cache.export", code: -4,
                userInfo: [NSLocalizedDescriptionKey: "导出文件名无效"])
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "legado-cache-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent(fileName)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit { cleanup() }

    func cleanup() {
        lock.lock()
        let shouldRemove = ownsDirectory
        ownsDirectory = false
        lock.unlock()
        if shouldRemove { try? FileManager.default.removeItem(at: directory) }
    }

    // Compatibility callers receiving only a URL retain the old responsibility to remove its directory.
    func transferToURLCaller() -> URL {
        lock.lock()
        ownsDirectory = false
        lock.unlock()
        return url
    }
}

enum CacheExportFiles {
    private static let queue = DispatchQueue(label: "io.legado.cache-export-files", qos: .userInitiated)

    static func write(_ bytes: KotlinByteArray, to url: URL) async throws {
        let payload = CacheExportBytes(bytes)
        let cancellation = CacheExportWriteCancellation()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try writeChunks(payload.bytes, to: url, cancellation: cancellation)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }

    private static func writeChunks(
        _ bytes: KotlinByteArray, to url: URL, cancellation: CacheExportWriteCancellation
    ) throws {
        try cancellation.check()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw NSError(
                domain: "io.legado.cache.export", code: -3,
                userInfo: [NSLocalizedDescriptionKey: "无法创建导出文件"])
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let count = Int(bytes.size)
        var offset = 0
        while offset < count {
            try cancellation.check()
            let length = min(32 * 1024, count - offset)
            var chunk = Data(count: length)
            chunk.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
                let target = buffer.bindMemory(to: Int8.self)
                for index in 0..<length { target[index] = bytes.get(index: Int32(offset + index)) }
            }
            try handle.write(contentsOf: chunk)
            offset += length
        }
        try cancellation.check()
        try handle.close()
    }
}

// Kotlin owns the immutable result; only this serial writer reads its bytes after the terminal callback.
private final class CacheExportBytes: @unchecked Sendable {
    let bytes: KotlinByteArray
    init(_ bytes: KotlinByteArray) { self.bytes = bytes }
}

private final class CacheExportWriteCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }
}
