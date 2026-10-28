import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One resource request, one serial disk/decoder worker, and no shared cookie or credential store.
final class RssArticleImageLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let byteLimit = 32 * 1024 * 1024
    private static let pixelLimit: Int64 = 40_000_000
    private let queue = DispatchQueue(label: "io.legado.rss.article-image", qos: .userInitiated)
    private let cancellationLock = NSLock()
    private var cancelled = false

    // Everything below is confined to queue, including URLSession delegate callbacks.
    private var continuation: CheckedContinuation<RssArticleImageFile, Error>?
    private var session: URLSession?
    private var dataTask: URLSessionDataTask?
    private var preparedRequest: URLRequest?
    private var response: HTTPURLResponse?
    private var output: FileHandle?
    private var file: RssArticleImageFile?
    private var received = 0
    private var redirects = 0
    private var started = false
    private var prepareRedirect: (@MainActor (URL) async throws -> URLRequest)?
    private var redirectTask: Task<Void, Never>?
    private var redirectID: UUID?
    private var redirectCompletion: ((URLRequest?) -> Void)?

    var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    func load(
        _ request: URLRequest, expectedURL: URL,
        prepareRedirect: (@MainActor (URL) async throws -> URLRequest)? = nil
    ) async throws -> RssArticleImageFile {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard !self.started else {
                        continuation.resume(throwing: Self.failure("图片请求已经开始"))
                        return
                    }
                    self.started = true
                    self.prepareRedirect = prepareRedirect
                    self.continuation = continuation
                    do {
                        try self.checkCancellation()
                        guard let url = request.url, url == expectedURL, Self.accepts(url),
                            (request.httpMethod ?? "GET").uppercased() == "GET",
                            request.httpBody == nil, request.httpBodyStream == nil
                        else { throw Self.failure("图片资源必须使用独立的 GET 请求") }

                        var prepared = request
                        prepared.httpMethod = "GET"
                        prepared.httpShouldHandleCookies = false
                        prepared.cachePolicy = .reloadIgnoringLocalCacheData
                        prepared.timeoutInterval = 30
                        for name in [
                            "Range", "If-Range", "If-None-Match", "If-Modified-Since", "Content-Length", "Transfer-Encoding",
                            "Host",
                        ] {
                            prepared.setValue(nil, forHTTPHeaderField: name)
                        }
                        self.preparedRequest = prepared
                        let file = try RssArticleImageFile()
                        self.file = file
                        guard FileManager.default.createFile(atPath: file.url.path, contents: nil) else {
                            throw Self.failure("无法创建图片临时文件")
                        }
                        self.output = try FileHandle(forWritingTo: file.url)

                        let configuration = URLSessionConfiguration.ephemeral
                        configuration.httpCookieStorage = nil
                        configuration.httpShouldSetCookies = false
                        configuration.httpCookieAcceptPolicy = .never
                        configuration.urlCredentialStorage = nil
                        configuration.urlCache = nil
                        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                        configuration.timeoutIntervalForRequest = 30
                        configuration.timeoutIntervalForResource = 90
                        configuration.waitsForConnectivity = false
                        configuration.httpMaximumConnectionsPerHost = 1
                        let delegateQueue = OperationQueue()
                        delegateQueue.maxConcurrentOperationCount = 1
                        delegateQueue.underlyingQueue = self.queue
                        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
                        self.session = session
                        let task = session.dataTask(with: prepared)
                        self.dataTask = task
                        task.resume()
                    } catch {
                        self.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        queue.async { self.finish(.failure(CancellationError())) }
    }

    func urlSession(
        _: URLSession, dataTask _: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            try checkCancellation()
            guard continuation != nil, let response = response as? HTTPURLResponse,
                let url = response.url, Self.accepts(url),
                let initial = preparedRequest?.url, Self.sameOrigin(initial, url)
            else { throw Self.failure("图片响应无效") }
            guard response.statusCode == 200 else {
                throw Self.failure("图片下载失败：HTTP \(response.statusCode)")
            }
            guard response.expectedContentLength <= Int64(Self.byteLimit) else {
                throw Self.failure("图片超过 32 MiB，无法处理")
            }
            guard Self.imageType(for: response.mimeType) != nil else {
                throw Self.failure("服务器未返回受支持的图片 MIME 类型")
            }
            self.response = response
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        guard continuation != nil else { return }
        do {
            try checkCancellation()
            guard response != nil, let output else { throw Self.failure("图片响应无效") }
            // The actual (possibly decompressed) stream, not just Content-Length, is bounded.
            guard data.count <= Self.byteLimit - received else {
                throw Self.failure("图片超过 32 MiB，无法处理")
            }
            try output.write(contentsOf: data)
            received += data.count
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard continuation != nil else { return }
        do {
            try checkCancellation()
            if let error { throw error }
            try output?.close()
            output = nil
            guard received > 0, let response, let file else { throw Self.failure("图片响应为空") }
            let fileExtension = try validate(file: file, response: response)
            try checkCancellation()
            try file.name(using: Self.filename(response: response, fileExtension: fileExtension))
            try checkCancellation()
            finish(.success(file))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        do {
            try checkCancellation()
            guard continuation != nil, let preparedRequest, let initial = preparedRequest.url,
                let target = request.url, Self.accepts(target)
            else { throw Self.failure("图片重定向地址无效") }
            guard Self.sameOrigin(initial, target) else {
                throw Self.failure("图片重定向到了其他站点；为保护源请求头和 Cookie，已停止下载")
            }
            guard redirects < 5 else { throw Self.failure("图片重定向次数过多") }
            redirects += 1
            if let prepareRedirect {
                let id = UUID()
                redirectID = id
                redirectCompletion = completionHandler
                redirectTask = Task { [weak self] in
                    do {
                        let refreshed = try await prepareRedirect(target)
                        try Task.checkCancellation()
                        guard let self else { return }
                        self.queue.async {
                            guard self.redirectID == id else { return }
                            do {
                                try self.checkCancellation()
                                guard refreshed.url == target, (refreshed.httpMethod ?? "GET").uppercased() == "GET",
                                    refreshed.httpBody == nil, refreshed.httpBodyStream == nil
                                else { throw Self.failure("图片重定向请求无效") }
                                var next = refreshed
                                next.httpMethod = "GET"
                                next.httpShouldHandleCookies = false
                                next.cachePolicy = .reloadIgnoringLocalCacheData
                                next.timeoutInterval = 30
                                for name in [
                                    "Range", "If-Range", "If-None-Match", "If-Modified-Since", "Content-Length",
                                    "Transfer-Encoding", "Host",
                                ] {
                                    next.setValue(nil, forHTTPHeaderField: name)
                                }
                                self.preparedRequest = next
                                self.completeRedirect(next)
                            } catch {
                                self.completeRedirect(nil)
                                self.finish(.failure(error))
                            }
                        }
                    } catch {
                        guard let self else { return }
                        self.queue.async {
                            guard self.redirectID == id else { return }
                            self.completeRedirect(nil)
                            self.finish(.failure(error))
                        }
                    }
                }
                return
            }
            // Never use URLSession's synthesized redirect request or replay an article's body.
            var redirected = preparedRequest
            redirected.url = target
            redirected.httpMethod = "GET"
            redirected.httpBody = nil
            redirected.httpBodyStream = nil
            redirected.httpShouldHandleCookies = false
            // Without a scope-aware preparation callback, never replay the original path's cookies.
            redirected.setValue(nil, forHTTPHeaderField: "Cookie")
            completionHandler(redirected)
        } catch {
            completionHandler(nil)
            finish(.failure(error))
        }
    }

    func urlSession(
        _: URLSession, task _: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // TLS gets normal system trust evaluation; HTTP auth never consults ambient credentials.
        completionHandler(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    func urlSession(
        _: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    private func validate(file: RssArticleImageFile, response: HTTPURLResponse) throws -> String {
        try checkCancellation()
        guard
            let source = CGImageSourceCreateWithURL(
                file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
            CGImageSourceGetStatus(source) == .statusComplete,
            let identifier = CGImageSourceGetType(source), let actual = UTType(identifier as String),
            actual.conforms(to: .image), let declared = Self.imageType(for: response.mimeType),
            actual.conforms(to: declared) || declared.conforms(to: actual),
            let fileExtension = actual.preferredFilenameExtension,
            !fileExtension.isEmpty, fileExtension.utf8.count <= 12,
            fileExtension.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { throw Self.failure("图片格式、MIME 或文件完整性校验失败") }

        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 512 else { throw Self.failure("图片帧数超出处理预算") }
        var pixels: Int64 = 0
        // Budget every frame before decoding any of them, including animated images.
        for index in 0..<count {
            try checkCancellation()
            guard CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let width = Self.dimension(properties[kCGImagePropertyPixelWidth]),
                let height = Self.dimension(properties[kCGImagePropertyPixelHeight]),
                width <= (Self.pixelLimit - pixels) / height
            else { throw Self.failure("图片不完整或总像素超过 4000 万") }
            pixels += width * height
        }
        var decodedPixels: Int64 = 0
        for index in 0..<count {
            try autoreleasepool {
                try checkCancellation()
                guard
                    let image = CGImageSourceCreateImageAtIndex(
                        source, index,
                        [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                    image.width > 0, image.height > 0,
                    Int64(image.width) <= (Self.pixelLimit - decodedPixels) / Int64(image.height),
                    CGImageSourceGetStatusAtIndex(source, index) == .statusComplete,
                    CGImageSourceGetStatus(source) == .statusComplete
                else { throw Self.failure("图片无法完整解码") }
                decodedPixels += Int64(image.width) * Int64(image.height)
                CGImageSourceRemoveCacheAtIndex(source, index)
            }
        }
        return fileExtension.lowercased()
    }

    private func checkCancellation() throws {
        if isCancelled { throw CancellationError() }
    }

    private func finish(_ result: Result<RssArticleImageFile, Error>) {
        let continuation = continuation
        self.continuation = nil
        redirectTask?.cancel()
        redirectTask = nil
        completeRedirect(nil)
        prepareRedirect = nil
        try? output?.close()
        output = nil
        file = nil
        response = nil
        preparedRequest = nil
        dataTask = nil
        let session = session
        self.session = nil
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }

    private func completeRedirect(_ request: URLRequest?) {
        let completion = redirectCompletion
        redirectCompletion = nil
        redirectID = nil
        redirectTask = nil
        completion?(request)
    }

    private static func accepts(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    private static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && (left.port ?? (left.scheme?.lowercased() == "https" ? 443 : 80))
                == (right.port ?? (right.scheme?.lowercased() == "https" ? 443 : 80))
    }

    private static func imageType(for mime: String?) -> UTType? {
        guard let mime = mime?.lowercased(), mime.hasPrefix("image/") else { return nil }
        let normalized = ["image/jpg": "image/jpeg", "image/x-png": "image/png"][mime] ?? mime
        guard let type = UTType(mimeType: normalized), type.conforms(to: .image) else { return nil }
        return type
    }

    private static func dimension(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber else { return nil }
        let number = value.doubleValue
        guard number.isFinite, number >= 1, number <= Double(pixelLimit), number.rounded(.towardZero) == number else {
            return nil
        }
        return value.int64Value
    }

    private static func filename(response: HTTPURLResponse, fileExtension: String) -> String {
        let proposed = response.suggestedFilename ?? response.url?.lastPathComponent ?? "image"
        let component =
            proposed.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? "image"
        let stem = (component as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_()"))
        var safe = ""
        for scalar in stem.unicodeScalars {
            let part = allowed.contains(scalar) ? String(scalar) : "_"
            guard safe.utf8.count + part.utf8.count <= 96 else { break }
            safe += part
        }
        safe = safe.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        return "\(safe.isEmpty ? "image" : safe).\(fileExtension)"
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "io.legado.rss.article-image", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Retain this lease until the actual consumer completes. Only its private temporary directory is removed.
final class RssArticleImageFile: @unchecked Sendable {
    private static let cleanupQueue = DispatchQueue(label: "io.legado.rss.article-image.cleanup", qos: .utility)
    private let directory: URL
    private(set) var url: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RssImage-\(UUID().uuidString)", isDirectory: true)
        url = directory.appendingPathComponent("incoming")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    fileprivate func name(using filename: String) throws {
        let target = directory.appendingPathComponent(filename, isDirectory: false)
        guard target.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw RssArticleImageLoader.failure("图片文件名无效")
        }
        try FileManager.default.moveItem(at: url, to: target)
        url = target
    }

    deinit {
        let directory = directory
        guard directory.lastPathComponent.hasPrefix("RssImage-"),
            directory.deletingLastPathComponent().standardizedFileURL
                == FileManager.default.temporaryDirectory.standardizedFileURL
        else { return }
        Self.cleanupQueue.async { try? FileManager.default.removeItem(at: directory) }
    }
}
