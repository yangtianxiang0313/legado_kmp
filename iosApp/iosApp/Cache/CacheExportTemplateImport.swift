import Foundation
import shared

struct CacheExportTemplateSelection: Sendable {
    let snapshot: CacheExportTemplateSnapshot
    let resourceCount: Int32
    let sectionCount: Int32
    let totalBytes: Int64
}

enum CacheExportTemplateImport {
    private static let queue = DispatchQueue(label: "io.legado.cache-export-template", qos: .userInitiated)

    static func load(
        from store: CacheExportTemplateStore, base64Zip: String = "", name: String = ""
    ) async throws -> CacheExportTemplateSelection? {
        try await read {
            let snapshot: CacheExportTemplateSnapshot?
            if base64Zip.isEmpty {
                snapshot = try store.load()
            } else {
                guard base64Zip.utf8.count <= CacheExportTemplateStore.maximumBase64Bytes,
                    let archive = Data(base64Encoded: base64Zip)
                else { throw CacheExportTemplateError.invalidArchive }
                snapshot = try CacheExportTemplateSnapshot(archive: archive, name: name)
            }
            return try snapshot.map { try inspect($0) }
        }
    }

    static func importFile(at url: URL) async throws -> CacheExportTemplateSelection {
        try await read {
            guard url.isFileURL, url.pathExtension.lowercased() == "zip" else {
                throw CacheExportTemplateError.invalidArchive
            }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let sourceValues = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
            guard sourceValues.isSymbolicLink != true, sourceValues.isAliasFile != true else {
                throw CacheExportTemplateError.invalidStorage
            }
            var coordinationError: NSError?
            var result: Result<CacheExportTemplateSelection, Error>?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: url, options: .withoutChanges, error: &coordinationError
            ) { readable in
                result = Result {
                    let values = try readable.resourceValues(forKeys: [.isSymbolicLinkKey, .isAliasFileKey])
                    guard values.isSymbolicLink != true, values.isAliasFile != true else {
                        throw CacheExportTemplateError.invalidStorage
                    }
                    let archive = try CacheExportTemplateStore.readRegularFile(
                        at: readable, maximumBytes: CacheExportTemplateStore.maximumArchiveBytes)
                    // Stage a complete protected private copy while the provider's read access is held.
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "cache-epub-template-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: false,
                        attributes: [
                            .posixPermissions: 0o700,
                            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
                        ])
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let file = directory.appendingPathComponent("template.zip")
                    try archive.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    let owned = try CacheExportTemplateStore.readRegularFile(
                        at: file, maximumBytes: CacheExportTemplateStore.maximumArchiveBytes)
                    return try inspect(CacheExportTemplateSnapshot(archive: owned, name: url.lastPathComponent))
                }
            }
            if let result { return try result.get() }
            if let coordinationError { throw coordinationError }
            throw CacheExportTemplateError.invalidArchive
        }
    }

    static func commit(_ snapshot: CacheExportTemplateSnapshot, to store: CacheExportTemplateStore) async throws {
        // Do not check cancellation after publication: a successful commit must remain a success.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try store.commit(snapshot)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func inspect(_ snapshot: CacheExportTemplateSnapshot) throws -> CacheExportTemplateSelection {
        let info = try BookExportEpubTemplateFacade().inspect(base64Zip: snapshot.base64Zip)
        return CacheExportTemplateSelection(
            snapshot: snapshot, resourceCount: info.resourceCount, sectionCount: info.sectionCount,
            totalBytes: info.totalBytes)
    }

    private static func read<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        // Cancellation never resumes early while a provider read or synchronous shared inspection is running.
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, Error>) in
            queue.async {
                do { continuation.resume(returning: try operation()) } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return value
    }
}
