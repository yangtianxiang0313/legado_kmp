import AVFoundation
import UniformTypeIdentifiers

protocol MediaAudioResourceLoading: AVAssetResourceLoaderDelegate {
    var queue: DispatchQueue { get }
    func cancel()
    func observeFailure(_ handler: @escaping @Sendable (MediaAudioError) -> Void)
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

    deinit { loader.cancel() }
}

final class ProgressiveAudioResourceLoader: NSObject, MediaAudioResourceLoading,
    MediaHTTPTransferDelegate, @unchecked Sendable
{
    let queue: DispatchQueue
    private let spool: MediaAudioSpool
    private let transfer: MediaHTTPTransfer
    private var requests: [AVAssetResourceLoadingRequest] = []
    private var length: Int64?
    private var received: Int64 = 0
    private var contentType = UTType.data.identifier
    private var responseReceived = false
    private var complete = false
    private var terminalError: MediaAudioError?
    private var cancelled = false
    private var failureHandler: (@Sendable (MediaAudioError) -> Void)?
    private var reportedFailure = false

    init(request: URLRequest) throws {
        let queue = DispatchQueue(label: "io.legado.media.spool")
        self.queue = queue
        transfer = try MediaHTTPTransfer(request: request, maximumBytes: 128 * 1024 * 1024, queue: queue)
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
            failureHandler = handler; reportFailure()
        }
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
            if !requests.isEmpty { transfer.start(); drain() }
        }
    }

    func discard(_ request: AVAssetResourceLoadingRequest) {
        queue.async { [self] in requests.removeAll { $0 === request } }
    }

    private func cancelOnQueue() {
        guard !cancelled else { return }
        cancelled = true
        terminalError = .cancelled
        transfer.cancel()
        drain()
        closeSpool()
    }

    private func closeSpool() {
        spool.close()
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard !cancelled else { loadingRequest.finishLoading(with: MediaAudioError.cancelled); return true }
        guard requests.count < 32 else { loadingRequest.finishLoading(with: MediaAudioError.storage); return true }
        requests.append(loadingRequest)
        transfer.start()
        drain()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        requests.removeAll { $0 === loadingRequest }
    }

    func mediaTransfer(received response: HTTPURLResponse, contentLength: Int64?) {
        responseReceived = true
        length = contentLength
        if let mime = response.mimeType, let type = UTType(mimeType: mime),
            type.conforms(to: .audio) || type.conforms(to: .movie)
        {
            contentType = type.identifier
        }
        drain()
    }

    func mediaTransfer(received data: Data) {
        guard !cancelled, terminalError == nil else { return }
        do {
            try spool.append(data)
            received += Int64(data.count)
            drain()
        } catch {
            terminalError = (error as? MediaAudioError) ?? .storage
            transfer.cancel()
            drain()
            closeSpool()
            reportFailure()
        }
    }

    func mediaTransfer(completed error: MediaAudioError?) {
        guard !complete else { return }
        complete = true
        if terminalError == nil { terminalError = error }
        if terminalError == nil, let length, length != received { terminalError = .network }
        if terminalError == nil { length = received }
        drain()
        if terminalError != nil { closeSpool() }
        reportFailure()
    }

    private func drain() {
        let pending = requests
        requests = []
        for request in pending {
            guard !request.isCancelled, !request.isFinished else { continue }
            if let error = terminalError { request.finishLoading(with: error); continue }
            guard responseReceived else { requests.append(request); continue }
            if let information = request.contentInformationRequest {
                information.contentType = contentType
                // Open-ended chunked responses must not wait for EOF before the decoder can read.
                // finishLoading at EOF supplies the actual end of a data request; no guessed duration is used.
                information.contentLength = length ?? Int64.max
                information.isByteRangeAccessSupported = length != nil
            }
            guard let data = request.dataRequest else { request.finishLoading(); continue }
            let offset = max(data.currentOffset, data.requestedOffset)
            let end: Int64
            if data.requestsAllDataToEndOfResource {
                end = length ?? Int64.max
            } else {
                let sum = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
                guard !sum.overflow, data.requestedOffset >= 0 else {
                    request.finishLoading(with: MediaAudioError.invalidRequest); continue
                }
                end = min(sum.partialValue, length ?? Int64.max)
            }
            var cursor = offset
            do {
                // Bound each in-memory read even if AVFoundation requests the entire resource.
                while !request.isCancelled, cursor < min(received, end) {
                    let count = Int(min(64 * 1024, min(received, end) - cursor))
                    let bytes = try spool.read(offset: cursor, count: count)
                    data.respond(with: bytes)
                    cursor += Int64(bytes.count)
                }
                if request.isCancelled { continue }
                if cursor >= end || (complete && cursor >= received) { request.finishLoading() } else { requests.append(request) }
            } catch {
                terminalError = .storage
                transfer.cancel()
                request.finishLoading(with: MediaAudioError.storage)
                closeSpool()
                reportFailure()
            }
        }
    }
}
