import Foundation
import shared

/// The HTTP owner supplies one decoded multipart file and calls stop on every service stop/restart.
/// Domain failures (including cancellation) use the standard failure envelope; only JSON encoding throws.
/// Both commit and Android /addLocalBook return data: true, never a partial Book dictionary.
@MainActor
final class ForegroundWebUpload {
    private var generation = UUID()
    private var uploads: [String: Upload] = [:]
    private var cleanups: [String: Upload] = [:]
    private var cancelledIDs: [String: ContinuousClock.Instant] = [:]

    private final class Upload {
        let id: String
        let generation: UUID
        let fileName: String
        let expiresAt = ContinuousClock.now.advanced(by: .seconds(300))
        var preparation: Task<PreparedLocalBookImport, Error>?
        var prepared: PreparedLocalBookImport?
        var commit: Task<Void, Error>?
        var entryPath: String?
        var entryPaths: [String] = []
        var committed = false
        var invalidated = false
        var expiry: Task<Void, Never>?
        var cleanup: Task<Void, Never>?

        init(id: String, generation: UUID, fileName: String) {
            self.id = id
            self.generation = generation
            self.fileName = fileName
        }
    }

    /// Non-ZIP entries contain the original filename as path; ZIP paths are native listing identities.
    func prepare(fileName: String, data: Data, uploadID: String? = nil) async throws -> Data {
        var input: Upload?
        do {
            let upload = try await prepareUpload(fileName: fileName, data: data, uploadID: uploadID)
            input = upload
            guard let prepared = upload.prepared else { throw CancellationError() }
            let entries: [[String: String]]
            if prepared.archive != nil {
                entries = prepared.entries.map { ["path": $0.path, "name": $0.fileName] }
            } else {
                entries = [["path": upload.fileName, "name": upload.fileName]]
            }
            let value = try Self.envelope([
                "uploadId": upload.id, "fileName": upload.fileName, "entries": entries,
            ])
            try Task.checkCancellation()
            return value
        } catch {
            if let input {
                invalidate(input)
                await input.cleanup?.value
            }
            return try Self.failureEnvelope(error)
        }
    }

    /// Omit entryPath only for a single entry. Concurrent confirmations share one native import.
    /// An ordinary import failure keeps the same ID retryable until its original deadline.
    func commit(uploadID: String, entryPath: String? = nil) async throws -> Data {
        guard let key = try? Self.canonicalID(uploadID), let upload = uploads[key] else {
            return try Self.failureEnvelope(Self.failure("上传不存在或已过期，请重新上传"))
        }
        do {
            try await commitUpload(upload, entryPath: entryPath)
            return try Self.envelope(true)
        } catch {
            return try Self.failureEnvelope(error)
        }
    }

    /// Idempotent. Cancellation waits for the native terminal result; an acknowledged commit wins.
    func discard(uploadID: String) async throws -> Data {
        let key = try Self.canonicalID(uploadID)
        pruneCancelledIDs()
        // A cancellation can overtake multipart decoding or the prepare response itself.
        if cancelledIDs.count >= 128, let oldest = cancelledIDs.min(by: { $0.value < $1.value })?.key {
            cancelledIDs.removeValue(forKey: oldest)
        }
        cancelledIDs[key] = ContinuousClock.now.advanced(by: .seconds(300))
        if let upload = uploads[key] ?? cleanups[key] {
            invalidate(upload)
            await upload.cleanup?.value
        }
        return try Self.envelope(true)
    }

    /// Android /addLocalBook: no selection UI and data: true. Multi-book ZIPs must use prepare/commit.
    func importDirect(fileName: String, data: Data) async throws -> Data {
        var upload: Upload?
        do {
            let input = try await prepareUpload(fileName: fileName, data: data)
            upload = input
            if let prepared = input.prepared, prepared.archive != nil, prepared.entries.count != 1 {
                throw Self.failure("压缩包包含多本书，请先上传并选择其中一本")
            }
            try await commitUpload(input, entryPath: nil)
            invalidate(input)
            await input.cleanup?.value
            return try Self.envelope(true)
        } catch {
            if let upload {
                invalidate(upload)
                await upload.cleanup?.value
            }
            return try Self.failureEnvelope(error)
        }
    }

    /// Synchronously invalidates the old generation. New calls belong to a fresh generation.
    /// Cleanup awaits late preparation/import results rather than deleting files still in use.
    func stop() {
        generation = UUID()
        for upload in Array(uploads.values) { invalidate(upload) }
        cancelledIDs.removeAll()
    }

    private func prepareUpload(fileName: String, data: Data, uploadID: String? = nil) async throws -> Upload {
        try Task.checkCancellation()
        try Self.validate(fileName: fileName, data: data)
        for upload in Array(uploads.values) where ContinuousClock.now >= upload.expiresAt {
            invalidate(upload)
        }
        pruneCancelledIDs()
        let id = try Self.canonicalID(uploadID ?? UUID().uuidString)
        guard cancelledIDs[id] == nil, uploads[id] == nil, cleanups[id] == nil else {
            throw Self.failure("上传已取消或编号已使用，请重新上传")
        }
        guard uploads.values.filter({ !$0.committed }).count + cleanups.count < 2, uploads.count < 128 else {
            throw Self.failure("最多同时保留 2 个待确认上传，请先确认或取消")
        }

        let upload = Upload(id: id, generation: generation, fileName: fileName)
        uploads[upload.id] = upload
        let preparation = Task { @MainActor in
            let writing = Task.detached(priority: .utility) {
                try Self.writeTemporaryFile(fileName: fileName, data: data)
            }
            let source = try await withTaskCancellationHandler {
                try await writing.value
            } onCancel: {
                writing.cancel()
            }
            defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
            try Task.checkCancellation()
            return try await LocalBookImportService.prepare(from: source)
        }
        upload.preparation = preparation
        upload.expiry = Task { @MainActor [weak self, weak upload] in
            guard let deadline = upload?.expiresAt else { return }
            do {
                try await ContinuousClock().sleep(until: deadline)
            } catch { return }
            guard let self, let upload else { return }
            self.invalidate(upload)
        }

        do {
            let prepared = try await withTaskCancellationHandler {
                try await preparation.value
            } onCancel: {
                preparation.cancel()
            }
            try Task.checkCancellation()
            try requireCurrent(upload)
            let paths = prepared.archive != nil ? prepared.entries.map(\.path) : [fileName]
            guard !paths.isEmpty, paths.count <= 2000, Set(paths).count == paths.count else {
                throw Self.failure("压缩包书籍列表为空、重复或超过 2000 项")
            }
            for path in paths { try Self.validateEntryPath(path) }
            upload.entryPaths = paths
            upload.prepared = prepared
            return upload
        } catch {
            invalidate(upload)
            await upload.cleanup?.value
            throw error
        }
    }

    private func commitUpload(_ upload: Upload, entryPath: String?) async throws {
        do {
            try Task.checkCancellation()
            try requireCurrent(upload)
            let paths = upload.entryPaths
            guard let selected = entryPath ?? (paths.count == 1 ? paths.first : nil), paths.contains(selected) else {
                throw Self.failure("请选择上传列表中的一本书，不能使用其他文件路径")
            }
            if upload.committed || upload.commit != nil {
                guard upload.entryPath == selected else {
                    throw Self.failure("此上传已确认其他条目，请重新上传")
                }
            }
            if upload.committed { return }
            guard let prepared = upload.prepared else { throw Self.failure("上传尚未准备完成") }

            let committing: Task<Void, Error>
            if let existing = upload.commit {
                committing = existing
            } else {
                upload.entryPath = selected
                committing = Task { @MainActor [self] in
                    do {
                        try Task.checkCancellation()
                        try requireCurrent(upload)
                        _ = try await LocalBookImportService.importBook(
                            prepared, entryPath: prepared.archive != nil ? selected : nil
                        )
                        // Native import has retained the file. Do not check cancellation/generation here.
                        upload.committed = true
                        await LocalBookImportService.discard(prepared)
                        upload.prepared = nil
                        upload.preparation = nil
                        upload.commit = nil
                    } catch {
                        upload.commit = nil
                        upload.entryPath = nil
                        if Task.isCancelled || error is CancellationError { invalidate(upload) }
                        throw error
                    }
                }
                upload.commit = committing
            }
            // Any cancelled waiter cancels the shared in-flight import, but cannot undo a saved book.
            try await withTaskCancellationHandler {
                try await committing.value
            } onCancel: {
                committing.cancel()
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                invalidate(upload)
                await upload.cleanup?.value
            }
            throw error
        }
    }

    private func requireCurrent(_ upload: Upload) throws {
        guard !upload.invalidated, upload.generation == generation, uploads[upload.id] === upload,
            ContinuousClock.now < upload.expiresAt
        else {
            invalidate(upload)
            throw Self.failure("上传已取消或已过期，请重新上传")
        }
    }

    private func invalidate(_ upload: Upload) {
        guard !upload.invalidated else { return }
        upload.invalidated = true
        if uploads[upload.id] === upload { uploads.removeValue(forKey: upload.id) }
        cleanups[upload.id] = upload
        upload.expiry?.cancel()
        upload.expiry = nil
        upload.preparation?.cancel()
        if !upload.committed { upload.commit?.cancel() }
        let preparation = upload.preparation
        let committing = upload.commit
        upload.cleanup = Task { @MainActor in
            let prepared = try? await preparation?.value
            _ = try? await committing?.value
            if let prepared { await LocalBookImportService.discard(prepared) }
            // Only native leases are released. Shared retained ZIP originals are never removed here.
            upload.prepared = nil
            upload.preparation = nil
            upload.commit = nil
            upload.cleanup = nil
            self.cleanups.removeValue(forKey: upload.id)
        }
    }

    private func pruneCancelledIDs() {
        cancelledIDs = cancelledIDs.filter { ContinuousClock.now < $0.value }
    }

    private nonisolated static func canonicalID(_ value: String) throws -> String {
        guard value.utf8.count == 36, let id = UUID(uuidString: value) else { throw failure("上传编号无效") }
        return id.uuidString.lowercased()
    }

    private nonisolated static func validateEntryPath(_ value: String) throws {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "\\:"))
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard !value.isEmpty, value.utf8.count <= 4096,
            !value.unicodeScalars.contains(where: forbidden.contains),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw failure("压缩包条目路径无效") }
    }

    private nonisolated static func validate(fileName: String, data: Data) throws {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        guard !fileName.isEmpty, fileName.utf8.count <= 240,
            fileName == fileName.trimmingCharacters(in: .whitespacesAndNewlines),
            !fileName.hasPrefix("."), !fileName.hasSuffix("."),
            fileName.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
            (fileName as NSString).lastPathComponent == fileName
        else { throw failure("文件名无效，不能包含路径、控制字符或隐藏文件名") }
        let suffix = (fileName as NSString).pathExtension.lowercased()
        guard LocalBookFormats.importExtensions.contains(suffix) else {
            throw failure(LocalBookFormats.unsupportedMessage)
        }
        guard !data.isEmpty else { throw failure("不能导入空文件") }
        guard data.count <= 32 * 1024 * 1024 else { throw failure("Web 上传文件不能超过 32 MiB") }
    }

    private nonisolated static func writeTemporaryFile(fileName: String, data: Data) throws -> URL {
        try Task.checkCancellation()
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent(
            "ForegroundWebUpload-\(UUID().uuidString)", isDirectory: true
        )
        // No shared staging root, filename-derived directory or sweeping of other uploads/books.
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete]
        )
        do {
            let source = directory.appendingPathComponent(fileName, isDirectory: false)
            guard source.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
                source.lastPathComponent == fileName
            else { throw failure("上传临时文件路径无效") }
            guard
                manager.createFile(
                    atPath: source.path, contents: nil,
                    attributes: [.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete]
                )
            else { throw failure("无法创建上传临时文件") }
            let handle = try FileHandle(forWritingTo: source)
            defer { try? handle.close() }
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                let length = min(1024 * 1024, data.count - offset)
                let start = data.index(data.startIndex, offsetBy: offset)
                let end = data.index(start, offsetBy: length)
                try handle.write(contentsOf: data[start..<end])
                offset += length
            }
            try handle.synchronize()
            try handle.close()
            try Task.checkCancellation()
            return source
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }

    private static func envelope(_ data: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["isSuccess": true, "errorMsg": "", "data": data])
    }

    private static func failureEnvelope(_ error: Error) throws -> Data {
        let message = error is CancellationError ? "上传已取消，请重新上传" : error.userFacingMessage
        return try JSONSerialization.data(withJSONObject: ["isSuccess": false, "errorMsg": message, "data": NSNull()])
    }

    private nonisolated static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.web.upload", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
