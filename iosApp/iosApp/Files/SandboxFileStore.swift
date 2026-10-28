import Foundation

struct SandboxFileEntry: Sendable {
    let url: URL
    let isDirectory: Bool
    let size: Int64
    let modified: Date?
}

/// Owns one incoming URL's scope, including time spent waiting for startup or unlock.
final class SandboxFileReadLease: @unchecked Sendable {
    let source: URL
    private let lock = NSLock()
    private var accessing: Bool
    private var closed = false
    private var reader: NSFileCoordinator?

    init(_ source: URL) {
        self.source = source
        accessing = source.isFileURL && source.startAccessingSecurityScopedResource()
    }

    deinit {
        if accessing { source.stopAccessingSecurityScopedResource() }
    }

    var isReading: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reader != nil
    }

    func cancel() {
        lock.lock()
        closed = true
        let coordinator = reader
        let stop = coordinator == nil && accessing
        if stop { accessing = false }
        lock.unlock()
        coordinator?.cancel()
        if stop { source.stopAccessingSecurityScopedResource() }
    }

    func checkCancellation() throws {
        lock.lock()
        let cancelled = closed
        lock.unlock()
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
    }

    fileprivate func beginReading(_ coordinator: NSFileCoordinator) throws {
        lock.lock()
        guard !closed, reader == nil else {
            lock.unlock()
            throw CancellationError()
        }
        reader = coordinator
        lock.unlock()
    }

    fileprivate func endReading(_ coordinator: NSFileCoordinator) {
        lock.lock()
        guard reader === coordinator else { lock.unlock(); return }
        reader = nil
        closed = true
        let stop = accessing
        accessing = false
        lock.unlock()
        if stop { source.stopAccessingSecurityScopedResource() }
    }
}

actor SandboxFileStore {
    static let shared = SandboxFileStore()
    let root: URL
    private let manager = FileManager.default

    init(root: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    func list(_ directory: URL) throws -> [SandboxFileEntry] {
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = try checked(directory)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
        ]
        return try manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )
        .compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { return nil }
            return SandboxFileEntry(
                url: url, isDirectory: values.isDirectory == true,
                size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    func createFolder(named name: String, in directory: URL) throws {
        let target = try destination(name, in: directory)
        try manager.createDirectory(at: target, withIntermediateDirectories: false)
    }

    func rename(_ source: URL, to name: String) throws {
        let source = try checked(source, allowRoot: false)
        let target = try destination(name, in: source.deletingLastPathComponent())
        try manager.moveItem(at: source, to: target)
    }

    func transfer(_ source: URL, into directory: URL, moving: Bool) throws {
        let source = try checked(source, allowRoot: false)
        let directory = try checked(directory)
        guard !directory.path.hasPrefix(source.path + "/"), directory != source else { throw failure("不能将文件夹放入自身") }
        let target = try destination(source.lastPathComponent, in: directory)
        if moving { try manager.moveItem(at: source, to: target) } else { try manager.copyItem(at: source, to: target) }
    }

    func remove(_ url: URL) throws {
        try manager.removeItem(at: checked(url, allowRoot: false))
    }

    func validatedFile(_ url: URL) throws -> URL {
        let url = try checked(url, allowRoot: false)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw failure("请选择文件") }
        return url
    }

    func importFile(_ source: URL, into directory: URL, uniquing: Bool = false) throws -> URL {
        let lease = SandboxFileReadLease(source)
        defer { lease.cancel() }
        return try importFile(lease, into: directory, uniquing: uniquing)
    }

    /// The caller acquires the lease at delivery, not when this actor eventually starts copying.
    func importFile(_ lease: SandboxFileReadLease, into directory: URL, uniquing: Bool = false) throws -> URL {
        let source = lease.source
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try lease.beginReading(coordinator)
        defer { lease.endReading(coordinator) }
        guard source.isFileURL else { throw failure("无效的文件地址") }
        try lease.checkCancellation()
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let directory = try checked(directory)
        let name = try checkedName(source.lastPathComponent)
        var target = directory.appendingPathComponent(name)
        if uniquing {
            let ext = source.pathExtension
            let stem = source.deletingPathExtension().lastPathComponent
            var index = 2
            while manager.fileExists(atPath: target.path) {
                target = directory.appendingPathComponent("\(stem) (\(index))" + (ext.isEmpty ? "" : ".\(ext)"))
                index += 1
            }
        } else if manager.fileExists(atPath: target.path) {
            throw failure("已存在同名文件")
        }
        let staging = directory.appendingPathComponent(".incoming-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        var coordinationError: NSError?
        var copyResult: Result<Void, Error>?
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
            copyResult = Result {
                try lease.checkCancellation()
                let values = try readable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure("只能导入普通文件") }
                try manager.copyItem(at: readable, to: staging)
                try lease.checkCancellation()
            }
        }
        try lease.checkCancellation()
        if let coordinationError { throw coordinationError }
        if let copyResult { try copyResult.get() } else { throw coordinationError ?? failure("无法读取文件") }
        try manager.moveItem(at: staging, to: target)
        // The committed sandbox copy survives cancellation, even before the caller resumes.
        return target
    }

    private func checked(_ url: URL, allowRoot: Bool = true) throws -> URL {
        guard url.isFileURL else { throw failure("无效的文件地址") }
        let normalized = url.standardizedFileURL
        let resolved = normalized.resolvingSymlinksInPath()
        guard normalized == resolved, (allowRoot && resolved == root) || resolved.path.hasPrefix(root.path + "/"),
            !resolved.pathComponents.dropFirst(root.pathComponents.count).contains(where: { $0.hasPrefix(".") })
        else {
            throw failure("不能访问应用文件目录之外的内容")
        }
        return resolved
    }

    private func destination(_ name: String, in directory: URL) throws -> URL {
        let directory = try checked(directory)
        let target = directory.appendingPathComponent(try checkedName(name))
        guard !manager.fileExists(atPath: target.path) else { throw failure("已存在同名文件") }
        return target
    }

    private func checkedName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("."), value.utf8.count <= 240,
            !value.contains("/"), !value.contains("\\"), !value.contains(":"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw failure("名称不能为空或包含路径、控制字符")
        }
        return value
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.files", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class SandboxFileClipboard {
    var source: URL?
    var moving = false
}
