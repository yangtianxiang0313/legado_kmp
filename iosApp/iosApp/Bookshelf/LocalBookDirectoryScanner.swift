import Foundation

struct LocalBookDirectoryCandidate: Identifiable, Sendable {
    /// A canonical file URL string, not a content hash or a persistent file identifier.
    let id: String
    let url: URL
    let relativePath: String
    /// Zero with an issue when the provider cannot supply a size without reading contents.
    let byteCount: Int64
    let modifiedAt: Date?
}

struct LocalBookDirectoryScan: Sendable {
    let files: [LocalBookDirectoryCandidate]
    /// fileName holds the relative path, or "." for the root.
    let issues: [LocalBookImportIssue]
    /// Enumerated descendant entries, including directories and rejected entries; excludes root.
    let scannedCount: Int
    /// Rejected visited entries, not an estimate of descendants inside excluded directories.
    let skippedCount: Int
    /// Only traversal budgets set this flag. Access failures are reported separately in issues.
    let isTruncated: Bool
}

enum LocalBookDirectoryScanner {
    // Root is depth zero. Reaching any limit is conservatively reported as truncated,
    // even when the unvisited remainder might turn out to be empty.
    static let maximumDepth = 64
    static let maximumScannedCount = 20_000
    static let maximumCandidateCount = 5_000

    private static let queue = DispatchQueue(label: "io.legado.local-book-directory-scan", qos: .utility)

    /// The caller must retain root's security scope until selection and import have finished.
    /// Progress runs on the worker queue as (visited descendant entries, candidate files).
    /// Cancellation throws only after coordinated access, enumeration and the scan scope end.
    static func scan(
        root: URL,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> LocalBookDirectoryScan {
        let cancellation = LocalBookDirectoryScanCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result: Result<LocalBookDirectoryScan, Error> = await withCheckedContinuation { continuation in
                queue.async {
                    let result = autoreleasepool {
                        Result {
                            try LocalBookDirectoryScanWorker(cancellation: cancellation, progress: progress).scan(root)
                        }
                    }
                    // Only the worker resumes this continuation, including on cancellation.
                    continuation.resume(returning: result)
                }
            }
            try Task.checkCancellation()
            return try result.get()
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class LocalBookDirectoryScanCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var coordinator: NSFileCoordinator?

    func cancel() {
        lock.lock()
        cancelled = true
        let coordinator = self.coordinator
        lock.unlock()
        coordinator?.cancel()
    }

    func check() throws {
        lock.lock()
        let cancelled = self.cancelled
        lock.unlock()
        if cancelled { throw CancellationError() }
    }

    func register(_ coordinator: NSFileCoordinator) throws {
        lock.lock()
        let cancelled = self.cancelled
        if !cancelled { self.coordinator = coordinator }
        lock.unlock()
        if cancelled {
            coordinator.cancel()
            throw CancellationError()
        }
    }

    func unregister(_ coordinator: NSFileCoordinator) {
        lock.lock()
        if self.coordinator === coordinator { self.coordinator = nil }
        lock.unlock()
    }
}

private final class LocalBookDirectoryScanWorker {
    private static let classificationKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isAliasFileKey, .isPackageKey, .isHiddenKey,
    ]
    private static let metadataKeys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
    private static let sortLocale = Locale(identifier: "en_US_POSIX")

    private let cancellation: LocalBookDirectoryScanCancellation
    private let progress: @Sendable (Int, Int) -> Void
    private let manager = FileManager()
    private let coordinator = NSFileCoordinator(filePresenter: nil)
    private var rootComponents: [String] = []
    private var seen: Set<String> = []
    private var pendingDirectories: [(url: URL, depth: Int)] = []
    private var files: [LocalBookDirectoryCandidate] = []
    private var issues: [LocalBookImportIssue] = []
    private var scannedCount = 0
    private var skippedCount = 0
    private var isTruncated = false
    private var stoppedAtCountLimit = false
    private var lastReportedCount = 0
    private var lastReportedCandidates = 0

    init(cancellation: LocalBookDirectoryScanCancellation, progress: @escaping @Sendable (Int, Int) -> Void) {
        self.cancellation = cancellation
        self.progress = progress
    }

    func scan(_ root: URL) throws -> LocalBookDirectoryScan {
        do {
            return try scanSynchronously(root)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try cancellation.check()
            throw failure(readErrorMessage(error))
        }
    }

    private func scanSynchronously(_ root: URL) throws -> LocalBookDirectoryScan {
        try cancellation.check()
        guard isLocalFileURL(root) else { throw failure("请选择有效的本地文件夹。") }

        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        try cancellation.register(coordinator)
        defer { cancellation.unregister(coordinator) }
        try cancellation.check()
        progress(0, 0)

        // Retain the root read while visiting descendants so coordinated root moves cannot
        // invalidate our boundary. Each child also gets its own metadata read on this same
        // coordinator: a directory read alone does not coordinate writes to contained items.
        try coordinate(at: root) { readable in
            var root = readable.standardizedFileURL
            guard self.isLocalFileURL(root) else { throw self.failure("文件提供程序返回了无效的文件夹地址。") }
            root.removeAllCachedResourceValues()
            let values = try root.resourceValues(forKeys: Self.classificationKeys)
            try self.requireUnlinked(values)
            guard values.isDirectory == true else { throw self.failure("所选项目不是文件夹。") }
            guard values.isHidden == false, !root.lastPathComponent.hasPrefix("."), values.isPackage == false else {
                throw self.failure("不扫描隐藏文件夹、文件包或无法确认这些属性的文件夹。")
            }

            // Canonicalize ancestors outside the selected root (for example /var -> /private/var).
            // Links within the selected tree are rejected rather than resolved and followed.
            root = root.resolvingSymlinksInPath().standardizedFileURL
            self.rootComponents = root.pathComponents
            self.seen.insert(self.identity(root))
            self.pendingDirectories.append((root, 0))
            // Child accessors must return before visiting another directory: nested coordination
            // exhausts the utility thread stack well before a legitimate deep tree reaches its cap.
            while !self.stoppedAtCountLimit, let directory = self.pendingDirectories.popLast() {
                try self.cancellation.check()
                do {
                    try self.enumerate(directory.url, depth: directory.depth)
                } catch {
                    try self.cancellation.check()
                    self.skippedCount += 1
                    self.addIssue(at: directory.url, message: self.readErrorMessage(error))
                }
            }
        }

        try cancellation.check()
        files.sort {
            let order = Self.comparePaths($0.relativePath, $1.relativePath)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        issues.sort {
            let order = Self.comparePaths($0.fileName, $1.fileName)
            return order == .orderedSame ? $0.message < $1.message : order == .orderedAscending
        }
        try cancellation.check()
        reportProgress(force: true)
        try cancellation.check()
        return LocalBookDirectoryScan(
            files: files, issues: issues, scannedCount: scannedCount, skippedCount: skippedCount,
            isTruncated: isTruncated
        )
    }

    private func enumerate(_ directory: URL, depth: Int) throws {
        try cancellation.check()
        guard scannedCount < LocalBookDirectoryScanner.maximumScannedCount else {
            truncate(at: directory, message: "已达到 20,000 个扫描项目的上限，结果可能不完整。", stop: true)
            return
        }
        // A directory listing is directory contents, not just immediately available metadata.
        // Coordinate that read normally so providers can populate the listing; regular book
        // files never receive this option and their contents are never requested.
        try coordinate(at: directory, options: [.withoutChanges]) { readable in
            guard self.isLocalFileURL(readable) else {
                throw self.failure("文件提供程序返回了无效的文件夹地址。")
            }
            let current = readable.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
            guard current.pathComponents == directory.pathComponents else {
                throw self.failure("等待读取目录期间文件夹位置发生变化，请重新扫描。")
            }
            var uncached = current
            uncached.removeAllCachedResourceValues()
            let values = try uncached.resourceValues(forKeys: Self.classificationKeys)
            try self.requireUnlinked(values)
            guard values.isDirectory == true, values.isHidden == false, values.isPackage == false else {
                throw self.failure("文件夹属性已变化或无法确认，已跳过读取。")
            }
            try self.enumerateContents(current, depth: depth)
        }
    }

    private func enumerateContents(_ directory: URL, depth: Int) throws {
        try cancellation.check()
        // Never materialize contentsOfDirectory: a single wide folder must obey the node budget.
        // No prefetch avoids reading metadata before the individual child's coordinated accessor.
        var enumerationError: (URL, Error)?
        let enumerator = manager.enumerator(
            at: directory, includingPropertiesForKeys: [],
            options: [.skipsSubdirectoryDescendants, .skipsPackageDescendants]
        ) { url, error in
            enumerationError = (url, error)
            return false
        }
        guard let enumerator else {
            let error = enumerationError?.1 ?? failure("无法读取文件夹中的项目。")
            addIssue(at: enumerationError?.0 ?? directory, message: readErrorMessage(error))
            return
        }

        while !stoppedAtCountLimit {
            try cancellation.check()
            guard let item = enumerator.nextObject() else { break }
            try cancellation.check()
            scannedCount += 1
            if let url = item as? URL {
                try autoreleasepool { try visit(url, depth: depth + 1) }
            } else {
                skippedCount += 1
                addIssue(at: directory, message: "文件提供程序返回了无效的目录项目，已跳过。")
            }
            reportProgress()
            if !stoppedAtCountLimit, scannedCount >= LocalBookDirectoryScanner.maximumScannedCount {
                truncate(at: directory, message: "已达到 20,000 个扫描项目的上限，结果可能不完整。", stop: true)
            }
        }
        try cancellation.check()
        if let (url, error) = enumerationError {
            // Preserve entries already obtained from this directory; other branches may continue.
            addIssue(at: url, message: readErrorMessage(error))
        }
    }

    private func visit(_ source: URL, depth: Int) throws {
        do {
            guard isLocalFileURL(source), let parts = relativeComponents(source), !parts.isEmpty else {
                throw failure("项目位于所选文件夹之外，已跳过。")
            }
            if parts.contains(where: { $0.hasPrefix(".") }) {
                skippedCount += 1
                return
            }
            try coordinate(at: source) { readable in
                let url = try self.checkedDescendant(readable)
                guard url.pathComponents == source.standardizedFileURL.pathComponents else {
                    // A moved entry could now have a package/hidden ancestor we never visited.
                    throw self.failure("等待读取文件属性期间项目位置发生变化，已跳过。")
                }
                var uncached = url
                uncached.removeAllCachedResourceValues()
                let values = try uncached.resourceValues(forKeys: Self.classificationKeys)
                try self.requireUnlinked(values)
                guard values.isHidden != nil else { throw self.failure("无法确认项目是否隐藏，已跳过。") }
                if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                    self.skippedCount += 1
                    return
                }
                guard values.isDirectory != nil, values.isRegularFile != nil else {
                    throw self.failure("无法确认项目类型，已跳过。")
                }
                guard self.seen.insert(self.identity(url)).inserted else {
                    self.skippedCount += 1
                    return
                }
                if values.isDirectory == true {
                    guard let isPackage = values.isPackage else {
                        throw self.failure("无法确认文件夹是否为文件包，已跳过。")
                    }
                    if isPackage {
                        self.skippedCount += 1
                    } else if depth >= LocalBookDirectoryScanner.maximumDepth {
                        self.skippedCount += 1
                        self.truncate(at: url, message: "已达到 64 层目录深度的上限，更深层项目未扫描。", stop: false)
                    } else {
                        self.pendingDirectories.append((url, depth))
                    }
                } else if values.isRegularFile == true,
                    LocalBookFormats.importExtensions.contains(url.pathExtension.lowercased())
                {
                    try self.appendCandidate(url)
                } else {
                    self.skippedCount += 1
                }
            }
        } catch {
            try cancellation.check()
            skippedCount += 1
            addIssue(at: source, message: readErrorMessage(error))
        }
    }

    private func appendCandidate(_ url: URL) throws {
        try cancellation.check()
        var byteCount: Int64 = 0
        var modifiedAt: Date?
        do {
            let values = try url.resourceValues(forKeys: Self.metadataKeys)
            if let size = values.fileSize, size >= 0 {
                byteCount = Int64(size)
            } else {
                addIssue(at: url, message: "无法获取文件大小，暂以 0 字节显示。")
            }
            modifiedAt = values.contentModificationDate
        } catch {
            try cancellation.check()
            addIssue(at: url, message: "无法获取文件大小或修改时间，大小暂以 0 字节显示。\(readErrorMessage(error))")
        }
        try cancellation.check()
        guard let parts = relativeComponents(url), !parts.isEmpty else {
            throw failure("文件位于所选文件夹之外，已跳过。")
        }
        files.append(
            LocalBookDirectoryCandidate(
                id: identity(url), url: url, relativePath: parts.joined(separator: "/"),
                byteCount: byteCount, modifiedAt: modifiedAt
            )
        )
        if files.count >= LocalBookDirectoryScanner.maximumCandidateCount {
            truncate(at: url, message: "已达到 5,000 个候选文件的上限，结果可能不完整。", stop: true)
        }
    }

    private func coordinate(
        at url: URL,
        options: NSFileCoordinator.ReadingOptions = [.withoutChanges, .immediatelyAvailableMetadataOnly],
        read: (URL) throws -> Void
    ) throws {
        try cancellation.check()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        // Never request alias/symlink resolution or an upload snapshot.
        coordinator.coordinate(
            readingItemAt: url, options: options, error: &coordinationError
        ) { readable in
            result = Result {
                try self.cancellation.check()
                try read(readable)
            }
        }
        try cancellation.check()
        guard let result else {
            throw coordinationError ?? failure("未能获得文件提供程序的协调读取权限。")
        }
        try result.get()
        if let coordinationError {
            addIssue(at: url, message: readErrorMessage(coordinationError))
        }
    }

    private func checkedDescendant(_ source: URL) throws -> URL {
        guard isLocalFileURL(source) else { throw failure("文件提供程序返回了无效的项目地址。") }
        let normalized = source.standardizedFileURL
        guard let parts = relativeComponents(normalized), !parts.isEmpty else {
            throw failure("项目位于所选文件夹之外，已跳过。")
        }
        guard !parts.contains(where: { $0.hasPrefix(".") }) else {
            throw failure("项目位于隐藏文件夹中，已跳过。")
        }
        let resolved = normalized.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathComponents == normalized.pathComponents else {
            throw failure("项目或其上级文件夹包含符号链接，已跳过。")
        }
        guard relativeComponents(resolved)?.isEmpty == false else {
            throw failure("项目位于所选文件夹之外，已跳过。")
        }
        return resolved
    }

    private func requireUnlinked(_ values: URLResourceValues) throws {
        guard values.isSymbolicLink == false, values.isAliasFile == false else {
            throw failure("不扫描符号链接、替身或无法确认链接属性的项目。")
        }
    }

    private func relativeComponents(_ url: URL) -> [String]? {
        let parts = url.standardizedFileURL.pathComponents
        guard !rootComponents.isEmpty, parts.starts(with: rootComponents) else { return nil }
        return Array(parts.dropFirst(rootComponents.count))
    }

    private func isLocalFileURL(_ url: URL) -> Bool {
        url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
            && url.query == nil && url.fragment == nil
    }

    private func addIssue(at url: URL, message: String) {
        let parts = relativeComponents(url)
        let path = parts.flatMap { $0.isEmpty ? nil : $0.joined(separator: "/") } ?? "."
        issues.append(LocalBookImportIssue(fileName: path, message: message))
    }

    private func truncate(at url: URL, message: String, stop: Bool) {
        isTruncated = true
        stoppedAtCountLimit = stoppedAtCountLimit || stop
        addIssue(at: url, message: message)
    }

    private func reportProgress(force: Bool = false) {
        guard force || scannedCount - lastReportedCount >= 64 || files.count - lastReportedCandidates >= 32 else {
            return
        }
        lastReportedCount = scannedCount
        lastReportedCandidates = files.count
        progress(scannedCount, files.count)
    }

    private static func comparePaths(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let natural = lhs.compare(
            rhs, options: [.numeric, .caseInsensitive, .widthInsensitive], range: nil, locale: sortLocale
        )
        return natural == .orderedSame ? lhs.compare(rhs, options: .literal) : natural
    }

    private func identity(_ url: URL) -> String {
        URL(fileURLWithPath: url.path, isDirectory: false).standardizedFileURL.absoluteString
    }

    private func readErrorMessage(_ error: Error) -> String {
        let error = error as NSError
        if error.domain == "io.legado.local-book-directory-scan" { return error.localizedDescription }
        if error.domain == NSCocoaErrorDomain {
            switch error.code {
            case NSFileReadNoPermissionError:
                return "没有读取权限，请重新选择文件夹并授权。"
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return "文件或文件夹已不存在，可能已被移动或删除。"
            default:
                break
            }
        }
        return "无法读取项目，文件提供程序可能暂时不可用（错误码：\(error.code)）。"
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.local-book-directory-scan", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
