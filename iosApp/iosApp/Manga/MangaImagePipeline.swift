import Foundation
import UIKit
import shared

@MainActor
final class MangaImagePipeline {
    private struct RequestKey: Hashable {
        let imageURL: String
        let pixelWidth: Int
        let displayStyle: MangaImageDisplayStyle
        let colorFilter: MangaColorFilter
        let generation: UUID?
    }

    private final class CacheKey: NSObject {
        let request: RequestKey

        init(_ request: RequestKey) { self.request = request }

        override var hash: Int { request.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            (object as? CacheKey)?.request == request
        }
    }

    private struct Job {
        let id: UUID
        let task: Task<MangaImagePresentation, Error>
        var consumers: Set<UUID>
    }

    private let bookURL: String
    private let cache = NSCache<CacheKey, MangaImagePresentation>()
    private var cacheCosts: [RequestKey: Int] = [:]
    private var cacheRecency: [RequestKey] = []
    private var cacheCost = 0
    private let permits = MangaImagePermits()
    private static let preparationPermit = MangaImagePermits(count: 1)
    private var imageFacade: BookImageFacade?
    private var jobs: [RequestKey: Job] = [:]
    private var imageGenerations: [String: UUID] = [:]

    init(bookURL: String) {
        self.bookURL = bookURL
        cache.totalCostLimit = 48 * 1024 * 1024
        cache.countLimit = 24
    }

    func load(
        imageURL: String, pixelWidth: Int, refresh: Bool = false,
        displayStyle: MangaImageDisplayStyle = .original,
        colorFilter: MangaColorFilter = .init()
    ) async throws -> UIImage {
        let presentation = try await loadPresentation(
            imageURL: imageURL, pixelWidth: pixelWidth, refresh: refresh,
            displayStyle: displayStyle, colorFilter: colorFilter)
        guard let image = presentation.bitmap ?? presentation.tiled?.preview else { throw Self.imageFailure() }
        return image
    }

    func loadPresentation(
        imageURL: String, pixelWidth: Int, refresh: Bool = false,
        displayStyle: MangaImageDisplayStyle = .original,
        colorFilter: MangaColorFilter = .init()
    ) async throws -> MangaImagePresentation {
        try Task.checkCancellation()
        let width = max(320, min(4096, pixelWidth))
        let style = displayStyle.normalized
        // Window brightness and unknown config fields do not change decoded pixels.
        let filter = MangaColorFilter(r: colorFilter.r, g: colorFilter.g, b: colorFilter.b, a: colorFilter.a)
        if refresh {
            // A refreshed original invalidates every size/effect, including late receivers.
            imageGenerations[imageURL] = UUID()
            for key in Array(jobs.keys) where key.imageURL == imageURL {
                jobs.removeValue(forKey: key)?.task.cancel()
            }
            for key in Array(cacheCosts.keys) where key.imageURL == imageURL { forget(key) }
        }
        let key = RequestKey(
            imageURL: imageURL, pixelWidth: width, displayStyle: style,
            colorFilter: filter, generation: imageGenerations[imageURL])
        if !refresh, let image = cache.object(forKey: CacheKey(key)) {
            cacheRecency.removeAll { $0 == key }
            cacheRecency.append(key)
            return image
        }
        if !refresh {
            for candidate in cacheRecency.reversed()
            where candidate.imageURL == imageURL && candidate.generation == key.generation
                && candidate.displayStyle == style && candidate.colorFilter == filter
            {
                guard let image = cache.object(forKey: CacheKey(candidate)), let tiled = image.tiled,
                    tiled.pixelSize.width >= CGFloat(width) || tiled.pixelSize.width >= CGFloat(image.sourcePixelWidth)
                else { continue }
                // A full-source-width strip also serves larger zoom requests without another preparation.
                cacheRecency.removeAll { $0 == candidate }
                cacheRecency.append(candidate)
                return image
            }
        }
        let consumer = UUID()
        if var job = jobs[key] {
            job.consumers.insert(consumer)
            jobs[key] = job
            return try await receive(job, key: key, consumer: consumer)
        }
        let facade = try facade()
        let permits = permits
        let preparationPermit = Self.preparationPermit
        let url = bookURL
        let id = UUID()
        let task = Task<MangaImagePresentation, Error> {
            try await permits.acquire()
            let path: String?
            do {
                path = try await SharedAsync.optionalValue { completion in
                    facade.loadMangaImageFile(bookUrl: url, imageUrl: imageURL, refresh: refresh, completionHandler: completion)
                }
                await permits.release()
            } catch {
                await permits.release()
                throw error
            }
            try Task.checkCancellation()
            guard let path else { throw Self.imageFailure() }
            try await preparationPermit.acquire()
            defer { Task { await preparationPermit.release() } }
            try Task.checkCancellation()
            let decoding = Task.detached(priority: .userInitiated) {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
                    return try MangaImageTileStore.prepare(data, pixelWidth: width, displayStyle: style, colorFilter: filter)
                }
            }
            let image = try await withTaskCancellationHandler {
                try await decoding.value
            } onCancel: {
                decoding.cancel()
            }
            try Task.checkCancellation()
            return image
        }
        let job = Job(id: id, task: task, consumers: [consumer])
        jobs[key] = job
        return try await receive(job, key: key, consumer: consumer)
    }

    private func receive(_ job: Job, key: RequestKey, consumer: UUID) async throws -> MangaImagePresentation {
        defer { releaseConsumer(key: key, jobID: job.id, consumer: consumer, cancel: Task.isCancelled) }
        let image = try await withTaskCancellationHandler {
            try await job.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.releaseConsumer(key: key, jobID: job.id, consumer: consumer, cancel: true)
            }
        }
        try Task.checkCancellation()
        // Retain the generation until every consumer settles, so refresh can invalidate late receivers.
        guard jobs[key]?.id == job.id, !job.task.isCancelled else { throw CancellationError() }
        if image.cacheCost <= cache.totalCostLimit {
            forget(key)
            while !cacheRecency.isEmpty
                && (cacheRecency.count >= cache.countLimit || cacheCost > cache.totalCostLimit - image.cacheCost)
            {
                forget(cacheRecency[0])
            }
            cacheCosts[key] = image.cacheCost
            cacheRecency.append(key)
            cacheCost += image.cacheCost
            cache.setObject(image, forKey: CacheKey(key), cost: image.cacheCost)
        }
        return image
    }

    private func releaseConsumer(key: RequestKey, jobID: UUID, consumer: UUID, cancel: Bool) {
        guard var job = jobs[key], job.id == jobID else { return }
        guard job.consumers.remove(consumer) != nil else { return }
        if job.consumers.isEmpty {
            jobs.removeValue(forKey: key)
            if cancel { job.task.cancel() }
        } else {
            jobs[key] = job
        }
    }

    func cancelAll() {
        jobs.values.forEach { $0.task.cancel() }
        jobs.removeAll()
    }

    func clearMemory() {
        cache.removeAllObjects()
        cacheCosts.removeAll()
        cacheRecency.removeAll()
        cacheCost = 0
    }

    private func forget(_ key: RequestKey) {
        cache.removeObject(forKey: CacheKey(key))
        if let cost = cacheCosts.removeValue(forKey: key) { cacheCost -= cost }
        cacheRecency.removeAll { $0 == key }
    }

    func prefetch(imageURL: String) async throws {
        let facade = try facade()
        try await permits.acquire(priority: false)
        defer { Task { await permits.release() } }
        try Task.checkCancellation()
        let cached: KotlinBoolean = try await SharedAsync.value { completion in
            facade.cacheImageToDisk(bookUrl: bookURL, src: imageURL, completionHandler: completion)
        }
        guard cached.boolValue else { throw Self.imageFailure() }
    }

    private func facade() throws -> BookImageFacade {
        if let imageFacade { return imageFacade }
        let facade = try SharedRuntime.bookImageFacade().get()
        imageFacade = facade
        return facade
    }

    nonisolated private static func imageFailure() -> NSError {
        NSError(domain: "io.legado.manga.image", code: 1, userInfo: [NSLocalizedDescriptionKey: "图片加载或解码失败"])
    }
}

private actor MangaImagePermits {
    private var available: Int
    private var waiting: [(UUID, CheckedContinuation<Void, Error>, Bool)] = []

    init(count: Int = 2) { available = count }

    func acquire(priority: Bool = true) async throws {
        try Task.checkCancellation()
        if available > 0 {
            available -= 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    if priority, let firstPrefetch = waiting.firstIndex(where: { !$0.2 }) {
                        waiting.insert((id, continuation, priority), at: firstPrefetch)
                    } else {
                        waiting.append((id, continuation, priority))
                    }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        if waiting.isEmpty {
            available += 1
        } else {
            waiting.removeFirst().1.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(throwing: CancellationError())
    }
}
