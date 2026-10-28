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
    private var contentType = UTType.data.identifier
    private var windows: [Window] = []
    private var revision: UInt64 = 0
    private var terminalError: MediaAudioError?
    private var draining = false
    private var failureHandler: (@Sendable (MediaAudioError) -> Void)?
    private var reportedFailure = false

    private struct Window {
        let start: Int64
        let data: Data
        var accessed: UInt64
        func contains(_ offset: Int64) -> Bool { offset >= start && offset - start < Int64(data.count) }
    }

    private final class Fetch: MediaHTTPTransferDelegate {
        let range: MediaHTTPByteRange
        let transfer: MediaHTTPTransfer
        weak var owner: RangedAudioResourceLoader?
        var data = Data()
        var expected: Int64?

        init(range: MediaHTTPByteRange, request: URLRequest, queue: DispatchQueue) throws {
            self.range = range
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

    func cancel() {
        queue.async { [self] in
            fail(.cancelled); fallback?.cancel(); fallback = nil
        }
    }

    func observeFailure(_ handler: @escaping @Sendable (MediaAudioError) -> Void) {
        queue.async { [self] in
            failureHandler = handler; reportFailure()
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
        guard response.statusCode == 206 else {
            if length == nil { useSequentialFallback() } else { fail(.network) }
            return
        }
        do {
            let range = try fetch.range.responseRange(response)
            guard let version = MediaHTTPByteRange.strongValidator(response) else {
                if length == nil { useSequentialFallback() } else { fail(.network) }
                return
            }
            if let length {
                guard length == range.total, validator == version, response.url == resourceURL else {
                    fail(.network); return
                }
            } else {
                var effectiveRequest = fetch.transfer.effectiveRequest
                guard let url = response.url, effectiveRequest.url == url else { fail(.network); return }
                for header in ["Range", "If-Range", "Content-Range"] {
                    effectiveRequest.setValue(nil, forHTTPHeaderField: header)
                }
                // Preserve the transfer's redirect credential isolation instead of rebuilding from source headers.
                pinnedRequest = try MediaHTTPTransfer.validated(effectiveRequest)
                length = range.total
                validator = version
                resourceURL = url
                if let mime = response.mimeType, let type = UTType(mimeType: mime),
                    type.conforms(to: .audio) || type.conforms(to: .movie)
                {
                    contentType = type.identifier
                }
            }
            fetch.expected = range.end - fetch.range.start + 1
            drain()
        } catch { fail(.network) }
    }

    private func completed(_ fetch: Fetch, error: MediaAudioError?) {
        guard active === fetch, terminalError == nil else { return }
        active = nil
        if let error { fail(error); return }
        guard let expected = fetch.expected, expected == Int64(fetch.data.count), !fetch.data.isEmpty else {
            fail(.network); return
        }
        revision &+= 1
        windows.append(Window(start: fetch.range.start, data: fetch.data, accessed: revision))
        while windows.reduce(0, { $0 + $1.data.count }) > 8 * 1024 * 1024 {
            guard let index = windows.indices.min(by: { windows[$0].accessed < windows[$1].accessed }) else { break }
            windows.remove(at: index)
        }
        drain()
    }

    private func useSequentialFallback() {
        let old = active
        active = nil
        old?.transfer.cancel()
        do {
            let loader = try ProgressiveAudioResourceLoader(request: request)
            loader.observeFailure { [weak self] error in
                guard let self else { return }
                self.queue.async { [weak self] in self?.fail(error) }
            }
            fallback = loader
            let requests = pending
            pending.removeAll()
            windows.removeAll()
            loader.adopt(requests)
        } catch { fail((error as? MediaAudioError) ?? .network) }
    }

    private func drain() {
        guard !draining, terminalError == nil, fallback == nil else { return }
        draining = true
        defer { draining = false }
        pending.removeAll { $0.isCancelled || $0.isFinished }
        guard !pending.isEmpty else { return }
        guard let length else { fetch(at: 0); return }
        let requests = pending
        pending.removeAll()
        var missing: Int64?
        for loading in requests {
            if let information = loading.contentInformationRequest {
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
            while !loading.isCancelled, cursor < end,
                let index = windows.firstIndex(where: { $0.contains(cursor) })
            {
                revision &+= 1
                windows[index].accessed = revision
                let window = windows[index]
                let offset = Int(cursor - window.start)
                let count = min(64 * 1024, window.data.count - offset, Int(end - cursor))
                data.respond(with: window.data.subdata(in: offset..<offset + count))
                cursor += Int64(count)
            }
            guard !loading.isCancelled else { continue }
            if cursor >= end { loading.finishLoading() } else { pending.append(loading); if missing == nil { missing = cursor } }
        }
        if let missing { fetch(at: missing) }
    }

    private func fetch(at start: Int64) {
        guard active == nil, terminalError == nil, fallback == nil else { return }
        let last = min(start + 256 * 1024 - 1, (length ?? Int64.max) - 1)
        guard start >= 0, last >= start else { fail(.network); return }
        do {
            let fetch = try Fetch(
                range: MediaHTTPByteRange(start: start, end: last, validator: validator),
                request: pinnedRequest ?? request, queue: queue)
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
        windows.removeAll()
        let requests = pending
        pending.removeAll()
        for request in requests where !request.isCancelled && !request.isFinished { request.finishLoading(with: error) }
        reportFailure()
    }
}
