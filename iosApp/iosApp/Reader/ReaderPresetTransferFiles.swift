import Foundation

enum ReaderPresetTransferFiles {
    private static let queue = DispatchQueue(label: "io.legado.reader-config-files", qos: .userInitiated)

    static func read(_ source: URL) async throws -> Data {
        try await perform {
            guard source.isFileURL else { throw ReaderPresetTransferResources.error("请选择有效文件") }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            var coordinationError: NSError?
            var result: Result<Data, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: source, options: .withoutChanges, error: &coordinationError
            ) { readable in
                result = Result { try ReaderBackgroundTextFiles.read(readable, limit: ReaderPresetTransferResources.archiveLimit) }
            }
            if let coordinationError { throw coordinationError }
            guard let result else { throw ReaderPresetTransferResources.error("无法读取配置文件") }
            return try result.get()
        }
    }

    static func prepare(_ data: Data) async throws -> ReaderPresetTransferResources.PreparedImport {
        try await perform { try ReaderPresetTransferResources.prepareImport(data) }
    }

    static func makeExport(_ json: String) async throws -> ReaderPresetTransferTemporaryFile {
        try await perform {
            let payload = try ReaderPresetTransferResources.prepareExport(json: json)
            let file = try ReaderPresetTransferTemporaryFile(name: payload.fileName)
            do {
                try payload.data.write(to: file.url, options: .atomic)
                return file
            } catch {
                file.remove()
                throw error
            }
        }
    }

    private static func perform<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: operation)) }
        }
    }
}

final class ReaderPresetTransferTemporaryFile: @unchecked Sendable {
    let url: URL
    private let directory: URL
    private let id = UUID()

    init(name: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderConfig-\(id.uuidString)", isDirectory: true)
        url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    func remove() {
        guard directory.standardizedFileURL.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL,
            directory.lastPathComponent == "ReaderConfig-\(id.uuidString)",
            url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
        else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    deinit { remove() }
}
