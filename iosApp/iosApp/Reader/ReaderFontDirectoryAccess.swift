import Darwin
import Foundation

enum ReaderFontDirectoryAccess {
    private static let fontLimit = 64 * 1024 * 1024
    private static let bookmarkLimit = 1024 * 1024

    struct Identity: Equatable {
        let device: dev_t
        let number: ino_t

        init(_ status: stat) {
            device = status.st_dev
            number = status.st_ino
        }
    }

    struct Stamp: Equatable {
        let identity: Identity
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ status: stat) {
            identity = Identity(status)
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    struct Scan {
        let identity: Identity
        let filenames: [String]
        let bookmark: Data?
    }

    struct FontFile {
        let stamp: Stamp
        fileprivate let descriptor: Int32

        fileprivate func data() throws -> Data {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            var data = Data()
            while let chunk = try handle.read(upToCount: min(1024 * 1024, fontLimit - data.count + 1)), !chunk.isEmpty {
                guard data.count + chunk.count <= fontLimit else { throw ReaderFontDirectoryError.tooLarge }
                data.append(chunk)
            }
            var status = stat()
            guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
            guard Stamp(status) == stamp, data.count == stamp.size else { throw ReaderFontDirectoryError.fileChanged }
            return data
        }
    }

    static func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        guard !bookmark.isEmpty, bookmark.count <= bookmarkLimit else { throw ReaderFontDirectoryError.invalidBookmark }
        var stale = false
        var options: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting, .withoutImplicitStartAccessing]
        #if targetEnvironment(macCatalyst)
            options.insert(.withSecurityScope)
        #endif
        let url = try URL(resolvingBookmarkData: bookmark, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw ReaderFontDirectoryError.invalidBookmark }
        return (url, stale)
    }

    static func scan(_ url: URL, makeBookmark: Bool) throws -> Scan {
        try scoped(url) {
            let original = try openDirectory(url)
            defer { Darwin.close(original) }
            var originalStatus = stat()
            guard Darwin.fstat(original, &originalStatus) == 0 else { throw posixError() }
            let identity = Identity(originalStatus)
            return try coordinated(url) { readable in
                let descriptor = try openDirectory(readable)
                defer { Darwin.close(descriptor) }
                try requireIdentity(descriptor, identity)
                let filenames = try listFonts(descriptor)
                let bookmark: Data?
                if makeBookmark {
                    // iOS embeds the picker URL's implicit security scope; .withSecurityScope is unavailable there.
                    #if targetEnvironment(macCatalyst)
                        let options: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                    #else
                        let options: URL.BookmarkCreationOptions = [.minimalBookmark]
                    #endif
                    let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
                    guard !data.isEmpty, data.count <= bookmarkLimit else { throw ReaderFontDirectoryError.invalidBookmark }
                    let restored = try resolve(data)
                    try scoped(restored.url) {
                        let restoredDirectory = try openDirectory(restored.url)
                        defer { Darwin.close(restoredDirectory) }
                        try requireIdentity(restoredDirectory, identity)
                    }
                    bookmark = data
                } else {
                    bookmark = nil
                }
                let current = try openDirectory(url)
                defer { Darwin.close(current) }
                try requireIdentity(current, identity)
                return Scan(identity: identity, filenames: filenames, bookmark: bookmark)
            }
        }
    }

    static func withFont<Value>(
        in url: URL, identity: Identity, filename: String, _ work: (FontFile) throws -> Value
    ) throws -> Value {
        guard isFontFilename(filename), (filename as NSString).lastPathComponent == filename else {
            throw ReaderFontDirectoryError.staleEntry
        }
        return try scoped(url) {
            let directory = try openDirectory(url)
            defer { Darwin.close(directory) }
            try requireIdentity(directory, identity)
            var targetStatus = stat()
            let inspected = filename.withCString { Darwin.fstatat(directory, $0, &targetStatus, AT_SYMLINK_NOFOLLOW) }
            guard inspected == 0 else { throw posixError() }
            guard targetStatus.st_mode & S_IFMT == S_IFREG else { throw ReaderFontDirectoryError.invalidFile }
            let target = url.appendingPathComponent(filename, isDirectory: false)
            return try coordinated(target) { readable in
                // A coordinator may relocate an item, but it cannot authorize a different directory or filename.
                guard readable.deletingLastPathComponent().standardizedFileURL == url.standardizedFileURL,
                    readable.lastPathComponent.utf8.elementsEqual(filename.utf8)
                else { throw ReaderFontDirectoryError.directoryChanged }
                let currentDirectory = try openDirectory(url)
                defer { Darwin.close(currentDirectory) }
                try requireIdentity(currentDirectory, identity)
                let descriptor = filename.withCString {
                    Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
                }
                guard descriptor >= 0 else { throw posixError() }
                defer { Darwin.close(descriptor) }
                var status = stat()
                guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
                guard status.st_mode & S_IFMT == S_IFREG else { throw ReaderFontDirectoryError.invalidFile }
                guard status.st_size > 0 else { throw ReaderFontDirectoryError.emptyFile }
                guard status.st_size <= fontLimit else { throw ReaderFontDirectoryError.tooLarge }
                let file = FontFile(stamp: Stamp(status), descriptor: descriptor)
                let result = try work(file)
                var after = stat()
                guard Darwin.fstat(descriptor, &after) == 0 else { throw posixError() }
                guard Stamp(after) == file.stamp else { throw ReaderFontDirectoryError.fileChanged }
                return result
            }
        }
    }

    static func withTemporaryFont<Value>(
        _ file: FontFile, filename: String, root: URL, _ work: (URL) throws -> Value
    ) throws -> Value {
        guard root.isFileURL else { throw ReaderFontDirectoryError.invalidTemporaryDirectory }
        let data = try file.data()
        let folder = root.appendingPathComponent("reader-font-library-" + UUID().uuidString, isDirectory: true)
        guard Darwin.mkdir(folder.path, mode_t(0o700)) == 0 else { throw posixError() }
        defer { try? FileManager.default.removeItem(at: folder) }
        // Keep the original filename for catalog merge/selection, isolated from other imports.
        let staged = folder.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: staged, options: .withoutOverwriting)
        return try work(staged)
    }

    private static func listFonts(_ descriptor: Int32) throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0 else { throw posixError() }
        guard let stream = Darwin.fdopendir(duplicate) else {
            let error = posixError()
            Darwin.close(duplicate)
            throw error
        }
        defer { Darwin.closedir(stream) }
        var filenames: [String] = []
        while true {
            errno = 0
            guard let entry = Darwin.readdir(stream) else {
                if errno != 0 { throw posixError() }
                break
            }
            let length = Int(entry.pointee.d_namlen)
            let filename = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: length + 1) { String(cString: $0) }
            }
            guard isFontFilename(filename) else { continue }
            var status = stat()
            let result = filename.withCString { Darwin.fstatat(descriptor, $0, &status, AT_SYMLINK_NOFOLLOW) }
            if result != 0 {
                if errno == ENOENT { continue }
                throw posixError()
            }
            // No recursion, symlink traversal, or font parsing during listing.
            if status.st_mode & S_IFMT == S_IFREG { filenames.append(filename) }
        }
        return filenames.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private static func isFontFilename(_ filename: String) -> Bool {
        ["ttf", "otf"].contains((filename as NSString).pathExtension.lowercased())
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL else { throw ReaderFontDirectoryError.invalidDirectory }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private static func requireIdentity(_ descriptor: Int32, _ expected: Identity) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else { throw posixError() }
        guard Identity(status) == expected else { throw ReaderFontDirectoryError.directoryChanged }
    }

    private static func scoped<Value>(_ url: URL, _ work: () throws -> Value) rethrows -> Value {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // App-container URLs need no scope; external grants are enforced by the coordinated read/open.
        return try work()
    }

    private static func coordinated<Value>(_ url: URL, _ work: (URL) throws -> Value) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, Error>?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            result = Result { try work(readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw ReaderFontDirectoryError.coordinationFailed }
        return try result.get()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum ReaderFontDirectoryError: LocalizedError {
    case invalidBookmark, staleBookmark, invalidDirectory, directoryChanged, staleEntry
    case invalidFile, emptyFile, tooLarge, fileChanged, unavailableFont
    case invalidTemporaryDirectory, coordinationFailed

    var errorDescription: String? {
        switch self {
        case .invalidBookmark: return "字体目录授权记录损坏，请重新选择字体目录。"
        case .staleBookmark: return "字体目录授权记录已过期，请重新加载或重新选择字体目录。"
        case .invalidDirectory: return "请选择可读取的字体目录，不能使用目录链接。"
        case .directoryChanged: return "字体目录已移动或被替换，请重新加载或重新选择字体目录。"
        case .staleEntry: return "此字体来自旧的目录列表，请重新加载后选择。"
        case .invalidFile: return "请选择普通字体文件，不能使用目录或文件链接。"
        case .emptyFile: return "字体文件为空，请选择其他字体。"
        case .tooLarge: return "字体文件过大，最多支持 64 MiB。"
        case .fileChanged: return "字体文件在读取时发生变化，请重新加载后重试。"
        case .unavailableFont: return "已导入的字体无法读取或注册，请重新导入。"
        case .invalidTemporaryDirectory: return "无法访问字体导入临时目录。"
        case .coordinationFailed: return "无法协调读取字体目录或文件，请重新选择字体目录。"
        }
    }
}
