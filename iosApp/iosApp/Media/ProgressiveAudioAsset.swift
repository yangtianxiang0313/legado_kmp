import AVFoundation
import UniformTypeIdentifiers

protocol MediaAudioResourceLoading: AVAssetResourceLoaderDelegate {
    var queue: DispatchQueue { get }
    var failure: MediaAudioError? { get }
    func cancel()
    func observeFailure(_ handler: @escaping @Sendable (MediaAudioError) -> Void)
    func observePlaybackURL(_ handler: @escaping @Sendable (URL) -> Void)
}

/// Retain with the item and cancel when replacing it. Book audio can opt into GET range windows;
/// POST and full-response fallback spool up to 128 MiB. No HLS/DASH/DRM or source response scripts.
/// Response cookies are not written to the shared repository; chapter checks remain in shared.
final class ProgressiveAudioAsset {
    let asset: AVURLAsset
    private let loader: any MediaAudioResourceLoading

    init(request: URLRequest, allowsRangeRequests: Bool = false) throws {
        if allowsRangeRequests, (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil {
            loader = try RangedAudioResourceLoader(request: request)
        } else {
            loader = try ProgressiveAudioResourceLoader(request: request)
        }
        // The resource URL is opaque: it never exposes the remote path, query, or credentials to AVFoundation.
        let url = URL(string: "legado-audio://media/\(UUID().uuidString)")!
        asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }

    func cancel() {
        asset.cancelLoading()
        loader.cancel()
    }

    func observeFailure(_ handler: @escaping @Sendable (MediaAudioError) -> Void) { loader.observeFailure(handler) }

    func observePlaybackURL(_ handler: @escaping @Sendable (URL) -> Void) { loader.observePlaybackURL(handler) }

    var failure: MediaAudioError? { loader.failure }

    deinit { loader.cancel() }
}

final class ProgressiveAudioResourceLoader: NSObject, MediaAudioResourceLoading,
    MediaHTTPTransferDelegate, @unchecked Sendable
{
    let queue: DispatchQueue
    private let initialRequest: URLRequest
    private let spool: MediaAudioSpool
    private let transfer: MediaHTTPTransfer
    private var cacheReadLease: MediaAudioDiskCacheLease?
    private var cacheWriter: SequentialAudioCacheWriter?
    private var cacheResponse: HTTPURLResponse?
    private var cacheLookupPerformed = false
    private var cacheGeneration: UInt64 = 0
    private let inheritedCacheGeneration: UInt64?
    private var deliveredCacheResponse = false
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var length: Int64?
    private var received: Int64 = 0
    private var contentType = UTType.data.identifier
    private var responseReceived = false
    private var complete = false
    private let failureSnapshot: MediaAudioFailureSnapshot
    private var terminalError: MediaAudioError? { didSet { failureSnapshot.set(terminalError) } }
    var failure: MediaAudioError? { failureSnapshot.get() }
    private var cancelled = false
    private var failureHandler: (@Sendable (MediaAudioError) -> Void)?
    private var reportedFailure = false
    private var draining = false
    private var needsHTTPRelay = false
    private var relay: ProgressiveAudioHTTPRelay?
    private var relayTask: Task<Void, Never>?
    private var relayID = UUID()
    private var playbackURLHandler: (@Sendable (URL) -> Void)?
    private var reportedPlaybackURL = false
    private struct HTTPRead {
        let offset: Int64
        let count: Int
        let cancellation: ProgressiveAudioHTTPReadCancellation
        let continuation: CheckedContinuation<Data?, Error>
    }
    private var httpReads: [UUID: HTTPRead] = [:]

    init(
        request: URLRequest, failureSnapshot: MediaAudioFailureSnapshot = MediaAudioFailureSnapshot(),
        cacheGeneration: UInt64? = nil
    ) throws {
        let queue = DispatchQueue(label: "io.legado.media.spool")
        self.queue = queue
        self.failureSnapshot = failureSnapshot
        inheritedCacheGeneration = cacheGeneration
        initialRequest = try MediaHTTPTransfer.validated(request)
        transfer = try MediaHTTPTransfer(request: initialRequest, maximumBytes: 128 * 1024 * 1024, queue: queue)
        spool = try MediaAudioSpool()
        super.init()
        if let suffix = request.url?.pathExtension, !suffix.isEmpty,
            let type = UTType(filenameExtension: suffix), type.conforms(to: .audio) || type.conforms(to: .movie)
        {
            contentType = type.identifier
        }
        transfer.receiver = self
    }

    func cancel() { queue.async { [self] in cancelOnQueue() } }

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
            reportPlaybackURL()
        }
    }

    private func reportPlaybackURL() {
        guard !reportedPlaybackURL, !cancelled, terminalError == nil,
            let url = relay?.url, let playbackURLHandler
        else { return }
        reportedPlaybackURL = true
        playbackURLHandler(url)
    }

    private func reportFailure() {
        guard !reportedFailure, let terminalError, let failureHandler else { return }
        if case .cancelled = terminalError { return }
        reportedFailure = true
        failureHandler(terminalError)
    }

    func adopt(_ pending: [AVAssetResourceLoadingRequest]) {
        queue.async { [self] in
            for request in pending where !request.isCancelled && !request.isFinished {
                if cancelled {
                    request.finishLoading(with: MediaAudioError.cancelled)
                } else if requests.count >= 32 {
                    request.finishLoading(with: MediaAudioError.storage)
                } else {
                    requests.append(request)
                }
            }
            if !requests.isEmpty { startLoading(); drain() }
        }
    }

    func discard(_ request: AVAssetResourceLoadingRequest) {
        queue.async { [self] in requests.removeAll { $0 === request } }
    }

    private func cancelOnQueue() {
        guard !cancelled else { return }
        cancelled = true
        terminalError = .cancelled
        stopHTTPRelay()
        releaseCache()
        transfer.cancel()
        drain()
        closeSpool()
    }

    private func closeSpool() {
        spool.close()
    }

    private var canCache: Bool { initialRequest.httpMethod == "GET" && initialRequest.httpBody == nil }

    private func startLoading() {
        guard !cancelled, terminalError == nil else { return }
        if !cacheLookupPerformed {
            cacheLookupPerformed = true
            cacheGeneration = inheritedCacheGeneration ?? MediaAudioDiskCache.shared.generation
            if canCache, let lease = MediaAudioDiskCache.shared.lookup(request: initialRequest) {
                if lease.isComplete, lease.representation.length > 0,
                    lease.representation.length <= 128 * 1024 * 1024
                {
                    cacheReadLease = lease
                    length = lease.representation.length
                    received = lease.representation.length
                    contentType = lease.representation.contentType
                    responseReceived = true
                    complete = true
                } else {
                    // A partial entry is not a sequential response and must never imply EOF.
                    lease.close()
                }
            }
        }
        if cacheReadLease == nil, !complete { transfer.start() }
    }

    private func releaseCache() {
        cacheReadLease?.close()
        cacheReadLease = nil
        cacheWriter?.close()
        cacheWriter = nil
        cacheResponse = nil
    }

    private func retryWithoutCache() {
        releaseCache()
        length = nil
        received = 0
        responseReceived = false
        complete = false
        contentType = UTType.data.identifier
        if let suffix = initialRequest.url?.pathExtension, let type = UTType(filenameExtension: suffix),
            type.conforms(to: .audio) || type.conforms(to: .movie)
        {
            contentType = type.identifier
        }
        // Keep the initial lookup consumed: retry only the original validated GET, never a POST.
        startLoading()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !cancelled else { loadingRequest.finishLoading(with: MediaAudioError.cancelled); return true }
        guard requests.count < 32 else { loadingRequest.finishLoading(with: MediaAudioError.storage); return true }
        requests.append(loadingRequest)
        startLoading()
        drain()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === loadingRequest }
    }

    func mediaTransfer(received response: HTTPURLResponse, contentLength: Int64?) {
        guard !cancelled, !complete, terminalError == nil, !responseReceived else { return }
        responseReceived = true
        length = contentLength
        if contentLength == nil { startHTTPRelay(contentType: response.mimeType ?? "application/octet-stream") }
        if let mime = response.mimeType, let type = UTType(mimeType: mime),
            type.conforms(to: .audio) || type.conforms(to: .movie)
        {
            contentType = type.identifier
        }
        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        if canCache, response.statusCode == 200, encoding == nil || encoding == "identity" {
            if let contentLength, contentLength > 0 {
                cacheWriter = SequentialAudioCacheWriter(
                    request: initialRequest, response: response, length: contentLength, contentType: contentType,
                    generation: cacheGeneration)
            } else if contentLength == nil {
                // Chunked playback stays live; its representation can only be persisted after EOF.
                cacheResponse = response
            }
        }
        drain()
    }

    func mediaTransfer(received data: Data) {
        guard !cancelled, !complete, terminalError == nil, responseReceived else { return }
        do {
            try spool.append(data)
            cacheWriter?.append(offset: received, data: data)
            received += Int64(data.count)
            drainHTTPReads()
            drain()
        } catch {
            terminalError = (error as? MediaAudioError) ?? .storage
            stopHTTPRelay()
            releaseCache()
            transfer.cancel()
            drain()
            closeSpool()
            reportFailure()
        }
    }

    func mediaTransfer(completed error: MediaAudioError?) {
        guard !cancelled, !complete else { return }
        complete = true
        if terminalError == nil { terminalError = error }
        if terminalError == nil, !responseReceived || received == 0 { terminalError = .empty }
        if terminalError == nil, let length, length != received { terminalError = .network }
        if terminalError == nil {
            length = received
            if let response = cacheResponse {
                cacheWriter = SequentialAudioCacheWriter(
                    request: initialRequest, response: response, length: received, contentType: contentType,
                    generation: cacheGeneration)
                cacheWriter?.copyCompletedSpool(spool)
            } else {
                cacheWriter?.finish(spool: spool, received: received)
            }
        }
        cacheWriter?.close()
        cacheWriter = nil
        cacheResponse = nil
        drainHTTPReads()
        drain()
        if terminalError != nil { stopHTTPRelay(); closeSpool() }
        reportFailure()
    }

    private func drain() {
        guard !draining else { return }
        draining = true
        defer {
            draining = false
            if terminalError != nil, !requests.isEmpty { drain() }
        }
        let pending = requests
        requests = []
        if needsHTTPRelay, terminalError == nil {
            // AVFoundation cannot follow this custom scheme to HTTP. The owning player
            // adopts the private URL while retaining this same transfer and spool.
            requests = pending.filter { !$0.isCancelled && !$0.isFinished }
            reportPlaybackURL()
            return
        }
        for (index, request) in pending.enumerated() {
            guard !request.isCancelled, !request.isFinished else { continue }
            if let error = terminalError { request.finishLoading(with: error); continue }
            guard responseReceived else { requests.append(request); continue }
            guard let length else { requests.append(request); continue }
            if let information = request.contentInformationRequest {
                information.contentType = contentType
                information.contentLength = length
                information.isByteRangeAccessSupported = true
                information.isEntireLengthAvailableOnDemand = complete
            }
            guard let data = request.dataRequest else {
                if cacheReadLease != nil { deliveredCacheResponse = true }
                request.finishLoading()
                continue
            }
            guard data.requestedOffset >= 0, data.requestedLength >= 0, data.currentOffset >= 0 else {
                request.finishLoading(with: MediaAudioError.invalidRequest); continue
            }
            let offset = max(data.currentOffset, data.requestedOffset)
            let end: Int64
            if data.requestsAllDataToEndOfResource {
                end = length
            } else {
                let sum = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                guard !sum.overflow, data.requestedOffset >= 0 else {
                    request.finishLoading(with: MediaAudioError.invalidRequest); continue
                }
                end = min(sum.partialValue, length)
            }
            var cursor = offset
            do {
                // Bound each in-memory read even if AVFoundation requests the entire resource.
                while !request.isCancelled, cursor < min(received, end) {
                    let count = Int(min(64 * 1024, min(received, end) - cursor))
                    let bytes: Data
                    if let cacheReadLease {
                        guard let cached = try cacheReadLease.read(offset: cursor, count: count),
                            !cached.isEmpty, cached.count <= count
                        else { throw MediaAudioError.storage }
                        bytes = cached
                        deliveredCacheResponse = true
                    } else {
                        bytes = try spool.read(offset: cursor, count: count)
                    }
                    data.respond(with: bytes)
                    cursor += Int64(bytes.count)
                }
                if request.isCancelled { continue }
                if cursor >= end || (complete && cursor >= received) {
                    if cacheReadLease != nil { deliveredCacheResponse = true }
                    request.finishLoading()
                } else {
                    requests.append(request)
                }
            } catch {
                if cacheReadLease != nil, !deliveredCacheResponse, canCache {
                    requests.append(request)
                    requests.append(contentsOf: pending.dropFirst(index + 1))
                    retryWithoutCache()
                    return
                }
                terminalError = .storage
                releaseCache()
                transfer.cancel()
                request.finishLoading(with: MediaAudioError.storage)
                closeSpool()
                reportFailure()
            }
        }
    }

    private func startHTTPRelay(contentType: String) {
        guard !needsHTTPRelay else { return }
        needsHTTPRelay = true
        let id = UUID()
        relayID = id
        let idle = Int64(max(1, min(300, initialRequest.timeoutInterval.rounded(.up))))
        relayTask = Task { [weak self] in
            do {
                let relay = try await ProgressiveAudioHTTPRelay.start(
                    contentType: contentType, idleTimeoutSeconds: idle,
                    currentLength: { [weak self] in
                        guard let self else { throw CancellationError() }
                        return try await relayLength()
                    },
                    read: { [weak self] offset, count in
                        guard let self else { throw CancellationError() }
                        return try await readForHTTP(offset: offset, count: count)
                    })
                guard let self else { relay.cancel(); return }
                queue.async { [weak self] in
                    guard let self, self.relayID == id, !self.cancelled, self.terminalError == nil else {
                        relay.cancel(); return
                    }
                    self.relayTask = nil
                    self.relay = relay
                    self.reportPlaybackURL()
                    self.drain()
                }
            } catch {
                guard let self else { return }
                queue.async { [weak self] in
                    guard let self, self.relayID == id, !self.cancelled, self.terminalError == nil else { return }
                    self.relayTask = nil
                    self.terminalError = .network
                    self.transfer.cancel()
                    self.stopHTTPRelay()
                    self.drain()
                    self.reportFailure()
                }
            }
        }
    }

    private func relayLength() async throws -> Int64? {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                if let error = terminalError {
                    continuation.resume(throwing: error)
                } else if cancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(returning: length)
                }
            }
        }
    }

    private func readForHTTP(offset: Int64, count: Int) async throws -> Data? {
        let id = UUID(), cancellation = ProgressiveAudioHTTPReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        try cancellation.check()
                        guard offset >= 0, count > 0, count <= 32 * 1024, httpReads.count < 8 else {
                            throw MediaAudioError.invalidRequest
                        }
                        httpReads[id] = HTTPRead(
                            offset: offset, count: count, cancellation: cancellation, continuation: continuation)
                        drainHTTPReads()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
            self.queue.async { [self] in
                httpReads.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
        }
    }

    private func drainHTTPReads() {
        for (id, read) in Array(httpReads) {
            do {
                try read.cancellation.check()
                if let error = terminalError { throw error }
                if cancelled { throw CancellationError() }
                if read.offset < received {
                    let bytes = try spool.read(offset: read.offset, count: Int(min(Int64(read.count), received - read.offset)))
                    httpReads.removeValue(forKey: id)?.continuation.resume(returning: bytes)
                } else if complete {
                    httpReads.removeValue(forKey: id)?.continuation.resume(returning: nil)
                }
            } catch {
                httpReads.removeValue(forKey: id)?.continuation.resume(throwing: error)
            }
        }
    }

    private func stopHTTPRelay() {
        relayID = UUID()
        relayTask?.cancel()
        relayTask = nil
        relay?.cancel()
        relay = nil
        let reads = Array(httpReads.values)
        httpReads.removeAll()
        for read in reads { read.continuation.resume(throwing: terminalError ?? .cancelled) }
    }

    deinit {
        relayTask?.cancel()
        relay?.cancel()
        cacheReadLease?.close()
        cacheWriter?.close()
    }
}

/// Serial transfers reserve one writer per URL so unvalidated full bodies cannot interleave.
/// Range writers can still share a version carrying the same strong HTTP validator.
private final class SequentialAudioCacheWriter {
    private final class Reservations: @unchecked Sendable {
        let lock = NSLock()
        var keys: Set<String> = []
    }

    private static let reservations = Reservations()
    private let reservation: String
    private let length: Int64
    private var lease: MediaAudioDiskCacheLease?
    private var fenceOffset: Int64 = 0
    private var written: Int64 = 0
    private var buffer = Data()
    private var bufferOffset: Int64 = 0
    private var closed = false

    init?(request: URLRequest, response: HTTPURLResponse, length: Int64, contentType: String, generation: UInt64) {
        guard request.httpMethod == "GET", request.httpBody == nil, request.url != nil,
            response.url != nil, length > 0, length <= 128 * 1024 * 1024
        else { return nil }
        guard let key = MediaAudioDiskCachePolicy.requestKey(request) else { return nil }
        Self.reservations.lock.lock()
        let reserved = Self.reservations.keys.insert(key).inserted
        Self.reservations.lock.unlock()
        guard reserved else { return nil }
        reservation = key
        self.length = length
        let validator = MediaHTTPByteRange.strongValidator(response)
        guard
            let lease = MediaAudioDiskCache.shared.store(
                request: request, response: response, contentType: contentType, length: length, validator: validator,
                generation: generation)
        else {
            close()
            return nil
        }
        if lease.isComplete {
            lease.close()
            close()
            return nil
        }
        self.lease = lease
        do {
            guard let missing = try missingOffset(in: lease) else { close(); return nil }
            fenceOffset = missing
        } catch { close(); return nil }
    }

    func append(offset: Int64, data: Data) {
        guard !closed, lease != nil else { return }
        guard offset == written, Int64(data.count) <= length - offset else { close(); return }
        var cursor = 0
        while cursor < data.count {
            let count = min(256 * 1024 - buffer.count, data.count - cursor)
            let start = data.startIndex + cursor
            buffer.append(data.subdata(in: start..<start + count))
            cursor += count
            written += Int64(count)
            if buffer.count == 256 * 1024, !flushBuffer() { close(); return }
        }
    }

    private func flushBuffer() -> Bool {
        guard !buffer.isEmpty else { return true }
        // An existing range may already include the tail. Fence an actual hole until successful EOF.
        let prefixEnd = Int(min(Int64(buffer.count), max(0, fenceOffset - bufferOffset)))
        let suffixStart = Int(min(Int64(buffer.count), max(0, fenceOffset + 1 - bufferOffset)))
        guard write(offset: bufferOffset, data: buffer, from: 0, to: prefixEnd),
            write(offset: bufferOffset, data: buffer, from: suffixStart, to: buffer.count)
        else { return false }
        bufferOffset += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
        return true
    }

    func finish(spool: MediaAudioSpool, received: Int64) {
        guard !closed, received == length, written == length, flushBuffer(), let lease else { close(); return }
        do {
            let fence = try spool.read(offset: fenceOffset, count: 1)
            guard fence.count == 1, lease.write(offset: fenceOffset, data: fence) else { close(); return }
        } catch { close() }
    }

    func copyCompletedSpool(_ spool: MediaAudioSpool) {
        guard !closed else { return }
        do {
            while written < length {
                let count = Int(min(64 * 1024, length - written))
                let bytes = try spool.read(offset: written, count: count)
                guard !bytes.isEmpty, bytes.count <= count else { close(); return }
                append(offset: written, data: bytes)
                guard !closed else { return }
            }
            finish(spool: spool, received: written)
        } catch { close() }
    }

    private func missingOffset(in lease: MediaAudioDiskCacheLease) throws -> Int64? {
        if let tail = try lease.read(offset: length - 1, count: 1) {
            guard tail.count == 1 else { throw MediaAudioError.storage }
        } else {
            return length - 1
        }
        var offset: Int64 = 0
        while offset < length {
            let count = Int(min(64 * 1024, length - offset))
            guard let bytes = try lease.read(offset: offset, count: count) else { return offset }
            guard !bytes.isEmpty, bytes.count <= count else { throw MediaAudioError.storage }
            offset += Int64(bytes.count)
        }
        return nil
    }

    private func write(offset: Int64, data: Data, from start: Int, to end: Int) -> Bool {
        guard let lease else { return false }
        var cursor = start
        while cursor < end {
            let next = min(cursor + 256 * 1024, end)
            guard lease.write(offset: offset + Int64(cursor), data: data.subdata(in: cursor..<next)) else { return false }
            cursor = next
        }
        return true
    }

    func close() {
        guard !closed else { return }
        closed = true
        // Revoke only this generation; a concurrent newer response must remain untouched.
        if let lease, lease.representation.validator == nil, !lease.isComplete { lease.invalidate() }
        lease?.close()
        lease = nil
        buffer.removeAll()
        Self.release(reservation)
    }

    private static func release(_ key: String) {
        reservations.lock.lock()
        reservations.keys.remove(key)
        reservations.lock.unlock()
    }

    deinit { close() }
}
