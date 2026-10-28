import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Shared by the main-actor coordinator and its serial file worker.
final class ReaderImageExportRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var fileCoordinator: NSFileCoordinator?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let coordinator = fileCoordinator
        lock.unlock()
        coordinator?.cancel()
    }

    func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    func register(_ coordinator: NSFileCoordinator) throws {
        lock.lock()
        let wasCancelled = cancelled
        if !wasCancelled { fileCoordinator = coordinator }
        lock.unlock()
        if wasCancelled {
            coordinator.cancel()
            throw CancellationError()
        }
    }

    func unregister(_ coordinator: NSFileCoordinator) {
        lock.lock()
        if fileCoordinator === coordinator { fileCoordinator = nil }
        lock.unlock()
    }
}

enum ReaderImageExportFiles {
    struct Image: Sendable {
        let data: Data
        let stem: String
        let fileExtension: String
    }

    struct Folder: Sendable {
        let url: URL
        let bookmark: Data
    }

    private static let queue = DispatchQueue(label: "io.legado.reader-image-export.files", qos: .userInitiated)

    static func prepare(data: Data, sourceURL: URL, request: ReaderImageExportRequest) async throws -> Image {
        try await perform {
            try request.checkCancellation()
            guard !data.isEmpty,
                let source = CGImageSourceCreateWithData(data as CFData, nil),
                CGImageSourceGetCount(source) > 0,
                CGImageSourceGetStatus(source) == .statusComplete,
                CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
                let identifier = CGImageSourceGetType(source),
                let type = UTType(identifier as String), type.conforms(to: .image),
                let fileExtension = type.preferredFilenameExtension,
                !fileExtension.isEmpty,
                fileExtension.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) })
            else { throw ExportError.invalidImage }
            try request.checkCancellation()
            return Image(data: data, stem: cleanStem(sourceURL), fileExtension: fileExtension.lowercased())
        }
    }

    static func resolve(bookmark: Data?, request: ReaderImageExportRequest) async throws -> Folder? {
        try await perform {
            try request.checkCancellation()
            guard let bookmark else { return nil }
            do {
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil,
                    bookmarkDataIsStale: &stale)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                try requireDirectory(url)
                let refreshed = stale ? try makeBookmark(url) : bookmark
                try request.checkCancellation()
                return Folder(url: url, bookmark: refreshed)
            } catch {
                try request.checkCancellation()
                // Expired or revoked bookmarks go back through Files, never an app-local fallback directory.
                return nil
            }
        }
    }

    static func remember(folder: URL, request: ReaderImageExportRequest) async throws -> Folder {
        try await perform {
            try request.checkCancellation()
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            try requireDirectory(folder)
            let bookmark = try makeBookmark(folder)
            try request.checkCancellation()
            return Folder(url: folder, bookmark: bookmark)
        }
    }

    static func write(_ image: Image, folder: URL, request: ReaderImageExportRequest) async throws -> URL {
        try await perform {
            try request.checkCancellation()
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            try requireDirectory(folder)
            let coordinator = NSFileCoordinator(filePresenter: nil)
            try request.register(coordinator)
            defer { request.unregister(coordinator) }

            for _ in 0..<8 {
                try request.checkCancellation()
                let name = "\(image.stem)-\(UUID().uuidString.lowercased()).\(image.fileExtension)"
                let destination = folder.appendingPathComponent(name, isDirectory: false)
                var coordinationError: NSError?
                var result: Result<URL, Error>?
                coordinator.coordinate(
                    writingItemAt: destination, options: [], error: &coordinationError
                ) { writable in
                    result = Result {
                        try request.checkCancellation()
                        try writeExclusively(image.data, to: writable, request: request)
                        return writable
                    }
                }
                try request.checkCancellation()
                if let coordinationError { throw coordinationError }
                guard let result else { throw ExportError.coordinationFailed }
                do {
                    return try result.get()
                } catch let error as POSIXError where error.code == .EEXIST {
                    continue
                }
            }
            throw ExportError.uniqueNameFailed
        }
    }

    private static func makeBookmark(_ url: URL) throws -> Data {
        // iOS document-picker URLs carry their security scope in minimal bookmarks.
        try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private static func requireDirectory(_ url: URL) throws {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ExportError.invalidFolder
        }
    }

    private static func cleanStem(_ sourceURL: URL) -> String {
        let component = sourceURL.lastPathComponent
        let raw = (component as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping
        let forbidden = CharacterSet.controlCharacters.union(.illegalCharacters).union(.newlines)
            .union(CharacterSet(charactersIn: "/\\:*?\"<>|\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"))
        let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map { forbidden.contains($0) ? "_" : $0 }))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        var stem = ""
        var byteCount = 0
        for character in cleaned {
            let length = String(character).utf8.count
            if byteCount + length > 128 { break }
            stem.append(character)
            byteCount += length
        }
        stem = stem.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return stem.isEmpty ? "image" : stem
    }

    private static func writeExclusively(_ data: Data, to url: URL, request: ReaderImageExportRequest) throws {
        try request.checkCancellation()
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        var identity = stat()
        var hasIdentity = false
        var closed = false
        var finished = false
        defer {
            if !closed { Darwin.close(descriptor) }
            if !finished, hasIdentity {
                var current = stat()
                // Only unlink the unfinished file created by this request, never a user's replacement.
                if Darwin.lstat(url.path, &current) == 0,
                    current.st_dev == identity.st_dev, current.st_ino == identity.st_ino
                {
                    Darwin.unlink(url.path)
                }
            }
        }
        guard Darwin.fstat(descriptor, &identity) == 0 else { throw posixError() }
        hasIdentity = true
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let address = buffer.baseAddress else { throw ExportError.invalidImage }
            var offset = 0
            while offset < buffer.count {
                try request.checkCancellation()
                let count = Darwin.write(descriptor, address.advanced(by: offset), min(256 * 1024, buffer.count - offset))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        try request.checkCancellation()
        guard Darwin.fsync(descriptor) == 0 else { throw posixError() }
        closed = true
        guard Darwin.close(descriptor) == 0 else { throw posixError() }
        try request.checkCancellation()
        finished = true
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    private static func perform<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    private enum ExportError: LocalizedError {
        case invalidImage
        case invalidFolder
        case coordinationFailed
        case uniqueNameFailed

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "图片数据不完整或无法识别真实格式"
            case .invalidFolder: return "无法访问图片保存文件夹，请重新选择文件夹"
            case .coordinationFailed: return "无法协调文件夹写入"
            case .uniqueNameFailed: return "无法创建唯一的图片文件名"
            }
        }
    }
}
