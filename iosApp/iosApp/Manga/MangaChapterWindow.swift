import Foundation
import shared

struct MangaWindowPageKey: Hashable {
    let chapterURL: String
    let chapterIndex: Int
    let position: Int
}

struct MangaWindowPage {
    let chapter: MangaReaderChapter
    let position: Int

    var page: MangaPage { chapter.pages[position] }
    var chapterIndex: Int { Int(chapter.chapterIndex) }
    var key: MangaWindowPageKey {
        let url = chapter.chapters.indices.contains(chapterIndex) ? chapter.chapters[chapterIndex].url : ""
        return MangaWindowPageKey(
            chapterURL: url.isEmpty ? "\(chapter.book.bookUrl)#manga-chapter-\(chapterIndex)" : url,
            chapterIndex: chapterIndex,
            position: position)
    }
}

// BookChapter equality is URL-only. Window identity must include every directory row and its index.
struct MangaChapterWindowIdentity: Equatable {
    struct Entry: Equatable {
        let bookURL: String
        let index: Int
        let url: String
        let isVolume: Bool

        init(_ chapter: BookChapter) {
            bookURL = chapter.bookUrl
            index = Int(chapter.index)
            url = chapter.url
            isVolume = chapter.isVolume
        }
    }

    let bookURL: String
    let origin: String
    let entries: [Entry]

    init(_ chapter: MangaReaderChapter) {
        bookURL = chapter.book.bookUrl
        origin = chapter.book.origin
        entries = chapter.chapters.map(Entry.init)
    }

    var isValid: Bool {
        !entries.isEmpty
            && entries.enumerated().allSatisfy { offset, entry in
                entry.bookURL == bookURL && entry.index == offset
            }
    }
}

/// ReadManga.buildMangaContent / moveToNextChapter / moveToPrevChapter at 5f5d31404.
/// Only the caller accepts an activated chapter and records its image position.
@MainActor
final class MangaChapterWindow {
    private struct NeighborTask {
        let id: UUID
        let task: Task<Void, Never>
    }

    private let adapter: MangaReaderAdapter
    private let searchLimit = 32
    private var identity: MangaChapterWindowIdentity?
    private var retained: [Int: MangaReaderChapter] = [:]
    private var emptyChapters: Set<Int> = []
    private var failedChapters: Set<Int> = []
    private var tasks: [Int: NeighborTask] = [:]
    private var generation = UUID()
    private var adapterGeneration: UUID
    private var isSuspended = false

    private(set) var pages: [MangaWindowPage] = []
    private(set) var current: MangaReaderChapter?
    var onChange: (() -> Void)?
    var onFailure: ((Int, Error) -> Void)?

    init(adapter: MangaReaderAdapter) {
        self.adapter = adapter
        adapterGeneration = adapter.neighborGeneration
    }

    deinit {
        for pending in tasks.values { pending.task.cancel() }
    }

    func reset(_ chapter: MangaReaderChapter) {
        stopTasks()
        isSuspended = false
        let nextIdentity = MangaChapterWindowIdentity(chapter)
        if identity != nextIdentity {
            retained.removeAll()
            emptyChapters.removeAll()
            failedChapters.removeAll()
        }
        identity = nextIdentity
        current = chapter
        if chapter.pages.isEmpty {
            if chapter.isVolume { emptyChapters.insert(Int(chapter.chapterIndex)) }
        } else {
            emptyChapters.remove(Int(chapter.chapterIndex))
            retained[Int(chapter.chapterIndex)] = chapter
        }
        trimAndPublish()
        fillNeighbors()
    }

    @discardableResult
    func activate(chapterIndex: Int) -> MangaReaderChapter? {
        guard !isSuspended, let identity, adapterGeneration == adapter.neighborGeneration,
            adapter.canLoadNeighbors(identity), let chapter = retained[chapterIndex],
            MangaChapterWindowIdentity(chapter) == identity
        else { return nil }
        if Int(current?.chapterIndex ?? -1) != chapterIndex {
            stopTasks()
            current = chapter
        }
        let revision = generation
        trimAndPublish()
        guard generation == revision else { return nil }
        fillNeighbors()
        return chapter
    }

    func suspend() {
        isSuspended = true
        stopTasks()
    }

    func resume() {
        if adapterGeneration != adapter.neighborGeneration { stopTasks() }
        isSuspended = false
        adapterGeneration = adapter.neighborGeneration
        fillNeighbors()
    }

    func cancel() {
        isSuspended = true
        stopTasks()
        current = nil
        identity = nil
        retained.removeAll()
        emptyChapters.removeAll()
        failedChapters.removeAll()
        pages = []
        onChange?()
    }

    func retryNeighbors() {
        if adapterGeneration != adapter.neighborGeneration { stopTasks() }
        failedChapters.removeAll()
        fillNeighbors()
    }

    private func stopTasks() {
        generation = UUID()
        for pending in tasks.values { pending.task.cancel() }
        tasks.removeAll()
        adapter.cancelNeighbors()
        adapterGeneration = adapter.neighborGeneration
    }

    private func trimAndPublish() {
        guard let current, let identity else {
            retained.removeAll()
            pages = []
            onChange?()
            return
        }
        let index = Int(current.chapterIndex)
        let candidates = retained.filter { candidateIndex, chapter in
            !chapter.pages.isEmpty && MangaChapterWindowIdentity(chapter) == identity
                && canReach(candidateIndex, from: index)
        }
        var kept: [Int: MangaReaderChapter] = [:]
        if !current.pages.isEmpty { kept[index] = current }
        if let previous = candidates.keys.filter({ $0 < index }).max() { kept[previous] = candidates[previous] }
        if let next = candidates.keys.filter({ $0 > index }).min() { kept[next] = candidates[next] }
        retained = kept
        emptyChapters = emptyChapters.filter { abs($0 - index) <= searchLimit }
        pages = retained.keys.sorted().flatMap { chapterIndex -> [MangaWindowPage] in
            guard let chapter = retained[chapterIndex] else { return [] }
            return chapter.pages.indices.map { MangaWindowPage(chapter: chapter, position: $0) }
        }
        onChange?()
    }

    private func canReach(_ candidate: Int, from index: Int) -> Bool {
        guard candidate != index else { return true }
        guard abs(candidate - index) <= searchLimit else { return false }
        return ((min(candidate, index) + 1)..<max(candidate, index)).allSatisfy { emptyChapters.contains($0) }
    }

    private func fillNeighbors() {
        guard !isSuspended, let current, let identity, identity.isValid,
            identity.entries.indices.contains(Int(current.chapterIndex)),
            adapterGeneration == adapter.neighborGeneration, adapter.canLoadNeighbors(identity)
        else { return }
        let index = Int(current.chapterIndex)
        for direction in [-1, 1] {
            guard tasks[direction] == nil,
                !retained.keys.contains(where: { direction < 0 ? $0 < index : $0 > index })
            else { continue }
            startNeighbor(direction: direction, index: index, identity: identity)
        }
    }

    private func startNeighbor(direction: Int, index: Int, identity: MangaChapterWindowIdentity) {
        let id = UUID()
        let revision = generation
        let adapterRevision = adapterGeneration
        let adapter = adapter
        let limit = searchLimit
        let task = Task { @MainActor [weak self] in
            defer {
                if self?.tasks[direction]?.id == id { self?.tasks.removeValue(forKey: direction) }
            }
            for offset in 1...limit {
                let requestedIndex = index + direction * offset
                guard identity.entries.indices.contains(requestedIndex),
                    self?.accepts(revision, adapterRevision: adapterRevision) == true,
                    self?.failedChapters.contains(requestedIndex) == false
                else { return }
                if self?.emptyChapters.contains(requestedIndex) == true { continue }
                do {
                    let prepared = try await adapter.loadNeighbor(index: requestedIndex, expectedOrigin: identity.origin)
                    guard let self, self.accepts(revision, adapterRevision: adapterRevision),
                        Int(prepared.chapterIndex) == requestedIndex, MangaChapterWindowIdentity(prepared) == identity
                    else { return }
                    if prepared.pages.isEmpty {
                        guard prepared.isVolume else { return }
                        self.emptyChapters.insert(requestedIndex)
                        continue
                    }
                    self.retained[requestedIndex] = prepared
                    self.trimAndPublish()
                    return
                } catch {
                    guard let self, !(error is CancellationError),
                        self.accepts(revision, adapterRevision: adapterRevision)
                    else { return }
                    self.failedChapters.insert(requestedIndex)
                    if self.tasks[direction]?.id == id { self.tasks.removeValue(forKey: direction) }
                    self.onFailure?(requestedIndex, error)
                    return
                }
            }
        }
        tasks[direction] = NeighborTask(id: id, task: task)
    }

    private func accepts(_ revision: UUID, adapterRevision: UUID) -> Bool {
        !Task.isCancelled && !isSuspended && generation == revision && adapterGeneration == adapterRevision
            && adapter.neighborGeneration == adapterRevision
    }
}
