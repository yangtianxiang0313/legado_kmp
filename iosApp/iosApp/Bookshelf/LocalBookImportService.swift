import Foundation
import shared

struct PreparedLocalBookImport {
    let fileName: String
    let localFile: PreparedLocalBookFile?
    let archive: ArchiveBookListing?

    var entries: [ArchiveBookEntry] { archive?.entries ?? [] }
}

/// UI-independent entry point. After preparation, always call discard when the operation ends.
enum LocalBookImportService {
    static func prepare(from url: URL) async throws -> PreparedLocalBookImport {
        let file = try await LocalBookFileStore.prepare(from: url)
        do {
            try Task.checkCancellation()
            if LocalBookArchiveType.isArchive(fileExtension: url.pathExtension) {
                let facade = try archiveFacade()
                let archive = try await LocalBookArchivePreparation.prepare(path: file.url.path, facade: facade)
                await LocalBookFileStore.discard(file)
                // The shared storage now owns an immutable original, independent of picker/security scope.
                return PreparedLocalBookImport(fileName: url.lastPathComponent, localFile: nil, archive: archive)
            }
            return PreparedLocalBookImport(fileName: url.lastPathComponent, localFile: file, archive: nil)
        } catch {
            await LocalBookFileStore.discard(file)
            throw error
        }
    }

    static func importBook(
        _ prepared: PreparedLocalBookImport,
        entryPath: String? = nil,
        groupID: Int64 = 0
    ) async throws -> Book {
        try Task.checkCancellation()
        if let archive = prepared.archive {
            let selected = entryPath ?? (archive.entries.count == 1 ? archive.entries.first?.path : nil)
            guard let selected, archive.entries.contains(where: { $0.path == selected }) else {
                throw failure("请选择压缩包内需要导入的一本书")
            }
            let facade = try archiveFacade()
            return try await SharedLocalBookImportAsync.value { onResult in
                facade.prepareEntryImportRequest(
                    archiveId: archive.archiveId, entryPath: selected,
                    groupId: max(0, groupID), onResult: onResult
                )
            }
        }
        guard let file = prepared.localFile else { throw failure("本地导入文件已失效") }
        let facade = try SharedRuntime.bookshelfFacade().get()
        if let key = storageKey(file.url.path) {
            let books = try await facade.loadBooksAsync(groupId: -1)
            try Task.checkCancellation()
            if let existing = books.first(where: { $0.isLocal && storageKey($0.bookUrl) == key }) {
                await LocalBookFileStore.retain(file)
                return existing
            }
        }
        let book = try await facade.importLocalBookAsync(path: file.url.path, groupId: max(0, groupID))
        // An acknowledged commit wins over a late Swift Task cancellation.
        await LocalBookFileStore.retain(file)
        return book
    }

    static func discard(_ prepared: PreparedLocalBookImport) async {
        if let file = prepared.localFile { await LocalBookFileStore.discard(file) }
        // Never delete shared retained originals here: other books and recovery may already own them.
    }

    private static func archiveFacade() throws -> ArchiveBookImportFacade {
        try SharedRuntime.bootstrap().get()
        return try ArchiveBookImportFacade.companion.create()
    }

    private static func storageKey(_ path: String) -> String? {
        let marker = "/Library/Application Support/LocalBooks/"
        guard let range = path.range(of: marker) else { return nil }
        return String(path[range.upperBound...])
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.local-book-import", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
