import UIKit
import shared

@MainActor
final class MangaReaderLayoutPrefetcher {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var attempted: Set<String> = []
    private var revision = UUID()
    private var pixelWidth = 0
    private var displayStyle: MangaImageDisplayStyle = .original
    private var pixelColorFilter = MangaColorFilter()

    deinit { tasks.values.forEach { $0.cancel() } }

    func cancel() {
        revision = UUID()
        for (url, task) in tasks {
            task.cancel()
            attempted.remove(url)
        }
        tasks.removeAll()
    }

    func reset() {
        cancel()
        attempted.removeAll()
    }

    func update(
        pages: [MangaPage], visible: [Int], position: Int, direction: Int, count: Int,
        pixelWidth: Int, displayStyle: MangaImageDisplayStyle,
        colorFilter: MangaColorFilter = .init(), pipeline: MangaImagePipeline
    ) {
        let count = min(100, max(0, count))
        guard count > 0, !pages.isEmpty else { cancel(); return }
        let displayStyle = displayStyle.normalized
        let pixelColorFilter = MangaColorFilter(r: colorFilter.r, g: colorFilter.g, b: colorFilter.b, a: colorFilter.a)
        if self.pixelWidth != pixelWidth || self.displayStyle != displayStyle || self.pixelColorFilter != pixelColorFilter {
            reset()
            self.pixelWidth = pixelWidth
            self.displayStyle = displayStyle
            self.pixelColorFilter = pixelColorFilter
        }
        let visible = visible.filter { pages.indices.contains($0) }
        let edge = direction < 0 ? visible.min() ?? position : visible.max() ?? position
        let step = direction < 0 ? -1 : 1
        let targets = (1...count).map { edge + $0 * step }.filter { pages.indices.contains($0) }
        let urls = Set(targets.map { pages[$0].mImageUrl })
        // Let an in-flight prefetch become the visible cell's consumer without restarting its image job.
        let retained = urls.union(visible.map { pages[$0].mImageUrl })
        for url in Array(tasks.keys) where !retained.contains(url) {
            tasks.removeValue(forKey: url)?.cancel()
            attempted.remove(url)
        }
        let revision = revision
        for position in targets {
            let url = pages[position].mImageUrl
            guard !attempted.contains(url), tasks[url] == nil else { continue }
            attempted.insert(url)
            tasks[url] = Task { [weak self] in
                do {
                    // Warm validated originals, not a decoded/tiled presentation for every off-screen page.
                    try await pipeline.prefetch(imageURL: url)
                } catch {
                    // A visible cell owns retry/error UI; prefetch failures must not retry on every scroll event.
                }
                guard let self, self.revision == revision, !Task.isCancelled else { return }
                self.tasks.removeValue(forKey: url)
            }
        }
    }
}
