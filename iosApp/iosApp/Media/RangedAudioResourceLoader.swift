import AVFoundation
import UniformTypeIdentifiers

/// Protected GET media is fetched in windows, so a distant seek does not download the intervening book.
/// Servers without ranges/strong validators fall back before any partial representation is exposed.
final class RangedAudioResourceLoader: NSObject, MediaAudioResourceLoading, @unchecked Sendable {
    let queue = DispatchQueue(label: "io.legado.media.ranges")
    private let request: URLRequest
    private var pinnedRequest: URLRequest?
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var active: Fetch?
    private var fallback: ProgressiveAudioResourceLoader?
    private var length: Int64?
    private var validator: String?
    private var resourceURL: URL?
    private var cacheLease: MediaAudioDiskCacheLease?
    private var cachedResourceKey: String?
    private var checkedCache = false
    private var cacheGeneration: UInt64?
    private enum CachePreparation { case preflight(Int64), prefix }
    private enum FetchPurpose { case window, preflight, prefix }
    private var cachePreparation: CachePreparation?
    private var representationExposed = false
    private var retriedPreflight416 = false
    private var contentType = UTType.data.identifier
    private var windows: [Window] = []
    private var revision: UInt64 = 0
    private let failureSnapshot = MediaAudioFailureSnapshot()
    private var terminalError: MediaAudioError? { didSet { failureSnapshot.set(terminalError) } }
    var failure: MediaAudioError? { failureSnapshot.get() }
    private var draining = false
    private var failureHandler: (@Sendable (MediaAudioError) -> Void)?
    private var playbackURLHandler: (@Sendable (URL) -> Void)?
    private var reportedFailure = false

    private struct Window {
        let start: Int64
        let data: Data
        var accessed: UInt64
        func contains(_ offset: Int64) -> Bool { offset >= start && offset - start < Int64(data.count) }
    }

    private final class Fetch: MediaHTTPTransferDelegate {
        let range: MediaHTTPByteRange
        let purpose: FetchPurpose
        let transfer: MediaHTTPTransfer
        weak var owner: RangedAudioResourceLoader?
        var data = Data()
        var expected: Int64?
        var response: HTTPURLResponse?

        init(range: MediaHTTPByteRange, purpose: FetchPurpose, request: URLRequest, queue: DispatchQueue) throws {
            self.range = range
            self.purpose = purpose
            transfer = try MediaHTTPTransfer(request: request, maximumBytes: 256 * 1024, queue: queue, byteRange: range)
        }

        func mediaTransfer(received response: HTTPURLResponse, contentLength: Int64?) { owner?.received(response, from: self) }
        func mediaTransfer(received bytes: Data) { data.append(bytes) }
        func mediaTransfer(completed error: MediaAudioError?) { owner?.completed(self, error: error) }
    }

    init(request: URLRequest) throws {
        self.request = try MediaHTTPTransfer.validated(request)
        super.init()
        if let suffix = request.url?.pathExtension, let type = UTType(filenameExtension: suffix),
            type.conforms(to: .audio) || type.conforms(to: .movie)
        {
            contentType = type.identifier
        }
    }

    deinit { cacheLease?.close() }

    func cancel() {
        queue.async { [self] in
            fail(.cancelled); fallback?.cancel(); fallback = nil
        }
    }

    func observeFailure(_ handler: @escaping @Sendable (MediaAudioError) -> Void) {
        queue.async { [self] in
            failureHandler = handler
            reportedFailure = false
            reportFailure()
        }
    }

    func observePlaybackURL(_ handler: @escaping @Sendable (URL) -> Void) {
        queue.async { [self] in
            playbackURLHandler = handler
            fallback?.observePlaybackURL(handler)
        }
    }

    private func reportFailure() {
        guard !reportedFailure, let terminalError, let failureHandler else { return }
        if case .cancelled = terminalError { return }
        reportedFailure = true
        failureHandler(terminalError)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        if let terminalError {
            loadingRequest.finishLoading(with: terminalError)
        } else if let fallback {
            fallback.adopt([loadingRequest])
        } else if pending.count >= 32 {
            loadingRequest.finishLoading(with: MediaAudioError.storage)
        } else {
            pending.append(loadingRequest); drain()
        }
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        fallback?.discard(loadingRequest)
        pending.removeAll { $0 === loadingRequest }
        if pending.isEmpty {
            let old = active
            active = nil
            old?.transfer.cancel()
        }
    }

    private func received(_ response: HTTPURLResponse, from fetch: Fetch) {
        guard active === fetch, terminalError == nil else { return }
        let isPreflight: Bool
        if case .preflight = fetch.purpose { isPreflight = !representationExposed } else { isPreflight = false }
        guard response.statusCode == 206 else {
            if length == nil || isPreflight {
                if isPreflight { discardCachedRepresentation() }
                useSequentialFallback()
            } else {
                cacheLease?.invalidate()
                fail(.network)
            }
            return
        }
        do {
            let range = try fetch.range.responseRange(response)
            guard let version = MediaHTTPByteRange.strongValidator(response) else {
                if length == nil || isPreflight {
                    if isPreflight { discardCachedRepresentation() }
                    useSequentialFallback()
                } else {
                    cacheLease?.invalidate()
                    fail(.network)
                }
                return
            }
            var effectiveRequest = fetch.transfer.effectiveRequest
            guard let url = response.url, effectiveRequest.url == url else { fail(.network); return }
            for header in ["Range", "If-Range", "Content-Range"] {
                effectiveRequest.setValue(nil, forHTTPHeaderField: header)
            }
            effectiveRequest = try MediaHTTPTransfer.validated(effectiveRequest)
            if let length {
                let sameResource =
                    response.url.map { url in
                        resourceURL.map { $0 == url } ?? (cachedResourceKey == MediaAudioDiskCache.resourceKey(url))
                    } ?? false
                if length != range.total || validator != version || !sameResource {
                    guard isPreflight else {
                        cacheLease?.invalidate()
                        fail(.network); return
                    }
                    discardCachedRepresentation()
                    // Keep delivery blocked until the replacement's prefix comes from this same final URI.
                    cachePreparation = .prefix
                }
            }
            if self.length == nil {
                length = range.total
                validator = version
                if let mime = response.mimeType, let type = UTType(mimeType: mime),
                    type.conforms(to: .audio) || type.conforms(to: .movie)
                {
                    contentType = type.identifier
                }
            }
            if pinnedRequest == nil {
                // A disk hit must not restore source credentials on a redirected cache miss.
                pinnedRequest = effectiveRequest
                resourceURL = url
                cachedResourceKey = MediaAudioDiskCache.resourceKey(url)
            }
            fetch.response = response
            fetch.expected = range.end - fetch.range.start + 1
            drain()
        } catch { fail(.network) }
    }

    private func completed(_ fetch: Fetch, error: MediaAudioError?) {
        guard active === fetch, terminalError == nil else { return }
        active = nil
        if let error {
            if case .http(416) = error, case .preflight = fetch.purpose,
                !representationExposed, !retriedPreflight416, fetch.range.start > 0
            {
                // A cached hole can lie beyond a shortened representation. Rebootstrap only once.
                retriedPreflight416 = true
                discardCachedRepresentation()
                cachePreparation = .prefix
                drain()
            } else {
                fail(error)
            }
            return
        }
        guard let expected = fetch.expected, expected == Int64(fetch.data.count), !fetch.data.isEmpty else {
            fail(.network); return
        }
        if let response = fetch.response, let length {
            let lease = MediaAudioDiskCache.shared.store(
                request: request, response: response, contentType: contentType, length: length, validator: validator,
                generation: cacheGeneration)
            cacheLease?.close()
            cacheLease = lease
            if lease?.write(offset: fetch.range.start, data: fetch.data) == false {
                lease?.close()
                cacheLease = nil
            }
        }
        revision &+= 1
        windows.append(Window(start: fetch.range.start, data: fetch.data, accessed: revision))
        while windows.reduce(0, { $0 + $1.data.count }) > 8 * 1024 * 1024 {
            guard let index = windows.indices.min(by: { windows[$0].accessed < windows[$1].accessed }) else { break }
            windows.remove(at: index)
        }
        switch fetch.purpose {
        case .preflight:
            if case .some(.prefix) = cachePreparation {
                if fetch.range.start == 0 { cachePreparation = nil }
            } else {
                cachePreparation = nil
            }
        case .prefix: cachePreparation = nil
        case .window: break
        }
        drain()
    }

    private func discardCachedRepresentation() {
        // Revoke just this lease, not a concurrent session's newer version under the same request key.
        cacheLease?.invalidate()
        cacheLease?.close()
        cacheLease = nil
        length = nil
        validator = nil
        resourceURL = nil
        cachedResourceKey = nil
        pinnedRequest = nil
        windows.removeAll()
        cachePreparation = nil
        contentType = UTType.data.identifier
        if let suffix = request.url?.pathExtension, let type = UTType(filenameExtension: suffix),
            type.conforms(to: .audio) || type.conforms(to: .movie)
        {
            contentType = type.identifier
        }
        // Keep the original cacheGeneration: clearing the cache must fence all later writes.
    }

    private func useSequentialFallback() {
        let old = active
        active = nil
        old?.transfer.cancel()
        do {
            let loader = try ProgressiveAudioResourceLoader(
                request: request, failureSnapshot: failureSnapshot, cacheGeneration: cacheGeneration)
            if let playbackURLHandler { loader.observePlaybackURL(playbackURLHandler) }
            loader.observeFailure { [weak self] error in
                guard let self else { return }
                self.queue.async { [weak self] in self?.fail(error) }
            }
            fallback = loader
            cachePreparation = nil
            let requests = pending
            pending.removeAll()
            windows.removeAll()
            cacheLease?.close()
            cacheLease = nil
            loader.adopt(requests)
        } catch { fail((error as? MediaAudioError) ?? .network) }
    }

    private func drain() {
        guard !draining, terminalError == nil, fallback == nil else { return }
        draining = true
        defer { draining = false }
        pending.removeAll { $0.isCancelled || $0.isFinished }
        guard !pending.isEmpty else { return }
        if !checkedCache {
            checkedCache = true
            cacheGeneration = MediaAudioDiskCache.shared.generation
            if let lease = MediaAudioDiskCache.shared.lookup(request: request) {
                cacheLease = lease
                let complete = lease.isComplete
                let missing = complete ? nil : lease.firstMissingOffset
                if complete || (lease.representation.validator != nil && missing != nil) {
                    length = lease.representation.length
                    validator = lease.representation.validator
                    cachedResourceKey = lease.representation.resourceKey
                    contentType = lease.representation.contentType
                    if !complete, let missing, missing >= 0, missing < lease.representation.length {
                        cachePreparation = .preflight(missing)
                    } else if !complete {
                        discardCachedRepresentation()
                    }
                } else {
                    // A corrupt/removed lease may report neither completeness nor a real hole.
                    discardCachedRepresentation()
                }
            }
        }
        if let cachePreparation {
            switch cachePreparation {
            case .preflight(let offset): fetch(at: offset, purpose: .preflight)
            case .prefix: fetch(at: 0, purpose: .prefix)
            }
            return
        }
        guard let length else { fetch(at: 0); return }
        let requests = pending
        pending.removeAll()
        var missing: Int64?
        for (requestIndex, loading) in requests.enumerated() {
            if let information = loading.contentInformationRequest {
                representationExposed = true
                information.contentType = contentType
                information.contentLength = length
                information.isByteRangeAccessSupported = true
            }
            guard let data = loading.dataRequest else { loading.finishLoading(); continue }
            guard data.requestedOffset >= 0, data.requestedLength >= 0, data.currentOffset >= 0 else {
                loading.finishLoading(with: MediaAudioError.invalidRequest); continue
            }
            let sum = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
            guard !sum.overflow else { loading.finishLoading(with: MediaAudioError.invalidRequest); continue }
            let end = data.requestsAllDataToEndOfResource ? length : min(sum.partialValue, length)
            var cursor = max(data.requestedOffset, data.currentOffset)
            while !loading.isCancelled, cursor < end {
                let bytes: Data?
                if let index = windows.firstIndex(where: { $0.contains(cursor) }) {
                    revision &+= 1
                    windows[index].accessed = revision
                    let window = windows[index]
                    let offset = Int(cursor - window.start)
                    let count = min(64 * 1024, window.data.count - offset, Int(end - cursor))
                    bytes = window.data.subdata(in: offset..<offset + count)
                } else {
                    do {
                        bytes = try cacheLease?.read(offset: cursor, count: Int(min(64 * 1024, end - cursor)))
                    } catch {
                        cacheLease?.invalidate()
                        loading.finishLoading(with: MediaAudioError.storage)
                        pending.append(contentsOf: requests.dropFirst(requestIndex + 1))
                        fail(.storage)
                        return
                    }
                }
                guard let bytes, !bytes.isEmpty else { break }
                representationExposed = true
                data.respond(with: bytes)
                cursor += Int64(bytes.count)
            }
            guard !loading.isCancelled else { continue }
            if cursor >= end { loading.finishLoading() } else { pending.append(loading); if missing == nil { missing = cursor } }
        }
        if let missing { fetch(at: missing) }
    }

    private func fetch(at start: Int64, purpose: FetchPurpose = .window) {
        guard active == nil, terminalError == nil, fallback == nil else { return }
        let limit = length ?? Int64.max
        guard start >= 0, start < limit else { fail(.network); return }
        let last = start + (min(Int64(256 * 1024), limit - start) - 1)
        do {
            let fetch = try Fetch(
                range: MediaHTTPByteRange(start: start, end: last, validator: validator),
                purpose: purpose, request: pinnedRequest ?? request, queue: queue)
            fetch.owner = self
            fetch.transfer.receiver = fetch
            active = fetch
            fetch.transfer.start()
        } catch { fail((error as? MediaAudioError) ?? .network) }
    }

    private func fail(_ error: MediaAudioError) {
        guard terminalError == nil else { return }
        terminalError = error
        let old = active
        active = nil
        old?.transfer.cancel()
        cachePreparation = nil
        windows.removeAll()
        cacheLease?.close()
        cacheLease = nil
        let requests = pending
        pending.removeAll()
        for request in requests where !request.isCancelled && !request.isFinished { request.finishLoading(with: error) }
        reportFailure()
    }
}
