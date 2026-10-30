import Darwin
import Foundation

enum RemoteBookFileUploadPolicy {
    static let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let maximumDuration: TimeInterval = 24 * 60 * 60
    static let idleTimeout: TimeInterval = 120

    static func request(_ original: URLRequest, byteCount: Int64) throws -> URLRequest {
        guard (1...maximumBytes).contains(byteCount) else { throw RemoteBookFileUploadFailure.make(.invalidSize) }
        guard original.httpMethod == "PUT", original.httpBody == nil, original.httpBodyStream == nil,
            let url = original.url, url.baseURL == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = parts.host, !host.isEmpty,
            parts.user == nil, parts.password == nil, parts.fragment == nil,
            parts.port.map({ (1...65535).contains($0) }) ?? true,
            !url.absoluteString.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw RemoteBookFileUploadFailure.make(.invalidRequest) }

        var headers: [String: String] = [:]
        for (name, value) in original.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            guard ["authorization", "content-type", "accept-encoding", "content-length"].contains(key),
                headers[key] == nil, !value.isEmpty, value.utf8.count <= 16 * 1024,
                value.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }),
                value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            else { throw RemoteBookFileUploadFailure.make(.invalidRequest) }
            headers[key] = value
        }
        if let authorization = headers["authorization"] {
            guard authorization.hasPrefix("Basic "),
                let decoded = Data(base64Encoded: String(authorization.dropFirst(6))), !decoded.isEmpty
            else { throw RemoteBookFileUploadFailure.make(.invalidRequest) }
        }
        if let length = headers["content-length"], decimal(length) != byteCount {
            throw RemoteBookFileUploadFailure.make(.invalidRequest)
        }
        if let encoding = headers["accept-encoding"], encoding.lowercased() != "identity" {
            throw RemoteBookFileUploadFailure.make(.invalidRequest)
        }
        if let contentType = headers["content-type"], !contentType.contains("/") {
            throw RemoteBookFileUploadFailure.make(.invalidRequest)
        }

        // Rebuild rather than inheriting cookies, arbitrary headers or a body from the bridge.
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: idleTimeout)
        request.httpMethod = "PUT"
        request.httpShouldHandleCookies = false
        request.httpShouldUsePipelining = false
        request.setValue(headers["authorization"], forHTTPHeaderField: "Authorization")
        request.setValue(headers["content-type"] ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue(String(byteCount), forHTTPHeaderField: "Content-Length")
        return request
    }

    static func decimal(_ value: String) -> Int64? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return Int64(value)
    }
}

/// Pins the original inode; the caller's immutable store lease pins the path used by fromFile.
final class RemoteBookFileUploadSource: @unchecked Sendable {
    private struct Stamp: Equatable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let mode: mode_t
        let links: nlink_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ value: stat) {
            device = value.st_dev
            inode = value.st_ino
            size = value.st_size
            mode = value.st_mode
            links = value.st_nlink
            modifiedSeconds = value.st_mtimespec.tv_sec
            modifiedNanoseconds = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec
            changedNanoseconds = value.st_ctimespec.tv_nsec
        }
    }

    let url: URL
    let byteCount: Int64
    private let stamp: Stamp
    private var descriptor: Int32

    init(url: URL, byteCount: Int64) throws {
        guard (1...RemoteBookFileUploadPolicy.maximumBytes).contains(byteCount) else {
            throw RemoteBookFileUploadFailure.make(.invalidSize)
        }
        let descriptor = try Self.openFile(url)
        var retained = false
        defer { if !retained { Darwin.close(descriptor) } }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0,
            value.st_mode & S_IFMT == S_IFREG, value.st_nlink > 0
        else { throw RemoteBookFileUploadFailure.make(.invalidFile) }
        guard value.st_size == byteCount else { throw RemoteBookFileUploadFailure.make(.invalidSize) }
        self.url = url
        self.byteCount = byteCount
        self.descriptor = descriptor
        stamp = Stamp(value)
        retained = true
        do {
            try verify()
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    func verify() throws {
        var held = stat()
        guard descriptor >= 0, Darwin.fstat(descriptor, &held) == 0, Stamp(held) == stamp else {
            throw RemoteBookFileUploadFailure.make(.fileChanged)
        }
        do {
            let current = try Self.openFile(url)
            defer { Darwin.close(current) }
            var value = stat()
            guard Darwin.fstat(current, &value) == 0, Stamp(value) == stamp else {
                throw RemoteBookFileUploadFailure.make(.fileChanged)
            }
        } catch {
            throw RemoteBookFileUploadFailure.make(.fileChanged)
        }
    }

    private static func openFile(_ url: URL) throws -> Int32 {
        guard url.isFileURL, url.baseURL == nil,
            let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
            parts.host == nil || parts.host == "", parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil,
            url.path.hasPrefix("/"), !url.path.hasSuffix("/"),
            !url.path.unicodeScalars.contains(where: { $0.value == 0 })
        else { throw RemoteBookFileUploadFailure.make(.invalidFile) }

        let path = url.path
        let home = NSHomeDirectory()
        // The OS-supplied sandbox root is trusted (iOS may spell it through /var).
        // Every caller-controlled directory below that root, and every other path, is opened without following links.
        let inHome = path.hasPrefix(home + "/")
        let root = inHome ? home : "/"
        let suffix = inHome ? String(path.dropFirst(home.count + 1)) : String(path.dropFirst())
        let components = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw RemoteBookFileUploadFailure.make(.invalidFile)
        }
        var directory = Darwin.open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw RemoteBookFileUploadFailure.make(.invalidFile) }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(directory, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else { throw RemoteBookFileUploadFailure.make(.invalidFile) }
            Darwin.close(directory)
            directory = next
        }
        let descriptor = components[components.count - 1].withCString {
            Darwin.openat(directory, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw RemoteBookFileUploadFailure.make(.invalidFile) }
        var value = stat()
        guard Darwin.fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_nlink > 0 else {
            Darwin.close(descriptor)
            throw RemoteBookFileUploadFailure.make(.invalidFile)
        }
        return descriptor
    }
}
