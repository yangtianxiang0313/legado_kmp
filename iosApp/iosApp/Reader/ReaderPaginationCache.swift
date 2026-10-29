import UIKit

struct ReaderPaginationCacheStatistics {
    let entryCount: Int
    let estimatedCost: Int
    let entryLimit: Int
    let costLimit: Int
}

final class ReaderPaginationCache<Key: Hashable> {
    private struct Entry {
        let result: ReaderLayoutEngine.PaginationResult
        let cost: Int
    }

    private let entryLimit: Int
    private let costLimit: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var leastToMostRecent: [Key] = []
    private var estimatedCost = 0
    private var memoryWarningObserver: NSObjectProtocol?

    // Retain a few adjacent chapters/style variants, not a reading session's history.
    init(entryLimit: Int = 6, costLimit: Int = 8 * 1024 * 1024) {
        self.entryLimit = max(entryLimit, 0)
        self.costLimit = max(costLimit, 0)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAll()
        }
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    var statistics: ReaderPaginationCacheStatistics {
        lock.lock()
        defer { lock.unlock() }
        return ReaderPaginationCacheStatistics(
            entryCount: entries.count,
            estimatedCost: estimatedCost,
            entryLimit: entryLimit,
            costLimit: costLimit
        )
    }

    func value(for key: Key) -> ReaderLayoutEngine.PaginationResult? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[key] else { return nil }
        markMostRecentlyUsed(key)
        return entry.result
    }

    func insert(
        _ result: ReaderLayoutEngine.PaginationResult,
        for key: Key,
        cancellation: ReaderPaginationCancellation? = nil
    ) {
        guard entryLimit > 0, costLimit > 0 else { return }
        let cost = Self.cost(of: result, limit: costLimit, isCancelled: { cancellation?.isCancelled == true })
        let commit = {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.removeEntry(for: key)
            // An oversized result still belongs to the caller; do not flush other entries for it.
            guard let cost else { return }
            while self.entries.count >= self.entryLimit || cost > self.costLimit - self.estimatedCost {
                guard let oldest = self.leastToMostRecent.first else { return }
                self.removeEntry(for: oldest)
            }
            self.entries[key] = Entry(result: result, cost: cost)
            self.leastToMostRecent.append(key)
            self.estimatedCost += cost
        }
        if let cancellation {
            cancellation.ifNotCancelled(commit)
        } else {
            commit()
        }
    }

    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll(keepingCapacity: false)
        leastToMostRecent.removeAll(keepingCapacity: false)
        estimatedCost = 0
    }

    private func markMostRecentlyUsed(_ key: Key) {
        leastToMostRecent.removeAll { $0 == key }
        leastToMostRecent.append(key)
    }

    private func removeEntry(for key: Key) {
        if let entry = entries.removeValue(forKey: key) {
            estimatedCost -= entry.cost
        }
        leastToMostRecent.removeAll { $0 == key }
    }

    private static func cost(
        of result: ReaderLayoutEngine.PaginationResult,
        limit: Int,
        isCancelled: () -> Bool
    ) -> Int? {
        var cost = CostBudget(limit: limit)
        // Array growth headroom, entry/key bookkeeping, and per-page string/array headers.
        guard cost.add(512),
            cost.add(MemoryLayout<Key>.stride, bytesPerItem: 2),
            cost.add(result.pages.count, bytesPerItem: MemoryLayout<ReaderPageLayout>.stride * 2 + 128)
        else { return nil }

        for page in result.pages {
            guard !isCancelled() else { return nil }
            guard cost.addText(page.chapterTitle), cost.addText(page.previewText),
                cost.add(
                    page.textFragments.count, bytesPerItem: MemoryLayout<ReaderTextLayoutFragment>.stride * 2 + 256),
                cost.add(
                    page.attachmentFragments.count,
                    bytesPerItem: MemoryLayout<ReaderAttachmentLayoutFragment>.stride * 2 + 128)
            else { return nil }

            for fragment in page.textFragments {
                guard !isCancelled() else { return nil }
                let text = fragment.attributedText
                guard cost.add(text.length, bytesPerItem: 4) else { return nil }
                // Kern changes create runs; charge each dictionary and its style/value objects.
                var fits = true
                text.enumerateAttributes(in: NSRange(location: 0, length: text.length), options: []) { _, _, stop in
                    if isCancelled() || cost.add(512) == false {
                        fits = false
                        stop.pointee = true
                    }
                }
                guard fits else { return nil }
            }

            for fragment in page.attachmentFragments {
                guard !isCancelled() else { return nil }
                if case .remoteImage(let url, let altText) = fragment.source {
                    guard cost.addText(url.absoluteString) else { return nil }
                    if let altText, cost.addText(altText) == false { return nil }
                }
            }
        }
        return cost.total
    }

    private struct CostBudget {
        let limit: Int
        private(set) var total = 0

        mutating func add(_ count: Int, bytesPerItem: Int = 1) -> Bool {
            // Check against remaining space before multiplication/addition to avoid Int overflow.
            guard count >= 0, bytesPerItem > 0, count <= (limit - total) / bytesPerItem else {
                return false
            }
            total += count * bytesPerItem
            return true
        }

        mutating func addText(_ text: String) -> Bool {
            // UTF-16 payload plus backing/bridging headroom; shared strings are charged conservatively.
            add(text.utf16.count, bytesPerItem: 4)
        }
    }
}
