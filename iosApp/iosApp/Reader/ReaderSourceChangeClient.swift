import Dispatch
import Foundation
import shared

final class ReaderSourceChangeClient {
    private typealias Binding = (bookURL: String, generation: UUID)

    private struct PreparedBinding {
        weak var prepared: PreparedBookSourceChange?
        let binding: Binding
    }

    private struct ChapterPreparation {
        let id = UUID()
        let binding: Binding
        let candidateBookURL: String
        let sourceURL: String
        let chapterIndex: Int
        var chapterCount = 0
    }

    private let binding: () -> Binding
    private let facade: () -> BookDetailFacade?
    private let sourceExists: (String) async throws -> Bool
    private let flushProgress: () async -> Void
    private var preparedBindings: [ObjectIdentifier: PreparedBinding] = [:]
    private var chapterPreparation: ChapterPreparation?

    init(
        binding: @escaping () -> (bookURL: String, generation: UUID),
        facade: @escaping () -> BookDetailFacade?,
        sourceExists: @escaping (String) async throws -> Bool = { sourceURL in
            let facade = try SharedRuntime.sourceManagementFacade().get()
            return try await facade.getSourceAsync(sourceUrl: sourceURL) != nil
        },
        flushProgress: @escaping () async -> Void
    ) {
        self.binding = binding
        self.facade = facade
        self.sourceExists = sourceExists
        self.flushProgress = flushProgress
    }

    @MainActor
    func isCurrentSourceMissing() async throws -> Bool {
        let snapshot = binding()
        try checkActive(snapshot)
        let facade = try requireFacade()

        do {
            let book = try await facade.resolveBookAsync(bookUrl: snapshot.bookURL)
            try checkActive(snapshot)
            guard let book else { return false }
            guard book.bookUrl == snapshot.bookURL else { throw CancellationError() }
            guard !book.isLocal else { return false }
            let sourceURL = book.origin
            let exists = try await sourceExists(sourceURL)
            try checkActive(snapshot)

            // The source can change without a reader rebind while the lookup is suspended.
            let currentBook = try await facade.resolveBookAsync(bookUrl: snapshot.bookURL)
            try checkActive(snapshot)
            guard let currentBook, currentBook.bookUrl == snapshot.bookURL,
                currentBook.origin == sourceURL, !currentBook.isLocal
            else { throw CancellationError() }
            return !exists
        } catch {
            try checkActive(snapshot)
            throw error
        }
    }

    @MainActor
    func createSourceChangeSearchSession(
        onCandidate: @escaping (BookSourceChangeCandidate) -> Void,
        onProgress: @escaping (SourceChangeSearchProgress) -> Void,
        onFinished: @escaping () -> Void
    ) async throws -> SourceChangeSearchSession {
        let snapshot = binding()
        try checkActive(snapshot)
        let facade = try requireFacade()
        let callbackGate = ReaderSourceChangeCallbackGate()
        let forward: (@escaping @MainActor () -> Void) -> Void = { [weak self] callback in
            DispatchQueue.main.async { [weak self] in
                guard let self, callbackGate.isActive, self.matches(snapshot) else { return }
                callback()
            }
        }

        return try await withTaskCancellationHandler {
            do {
                let session = try await facade.createSourceChangeSearchSessionAsync(
                    bookUrl: snapshot.bookURL,
                    fromReader: true,
                    onCandidate: { candidate in forward { onCandidate(candidate) } },
                    onProgress: { progress in forward { onProgress(progress) } },
                    onFinished: { forward { onFinished() } }
                )
                guard callbackGate.isActive, !Task.isCancelled, matches(snapshot) else {
                    callbackGate.invalidate()
                    session.dispose()
                    throw CancellationError()
                }
                return session
            } catch {
                callbackGate.invalidate()
                try checkActive(snapshot)
                throw error
            }
        } onCancel: {
            callbackGate.invalidate()
        }
    }

    @MainActor
    func prepareSourceChange(
        candidateBookUrl: String,
        sourceUrl: String
    ) async throws -> PreparedBookSourceChange {
        let snapshot = binding()
        try checkActive(snapshot)
        chapterPreparation = nil
        let facade = try requireFacade()
        await flushProgress()
        try checkActive(snapshot)

        do {
            let prepared: PreparedBookSourceChange = try await SharedCancellableAsync.value { completion in
                facade.prepareSourceChangeRequest(
                    bookUrl: snapshot.bookURL,
                    candidateBookUrl: candidateBookUrl,
                    sourceUrl: sourceUrl
                ) { result in
                    if result.isCancelled {
                        completion(nil, CancellationError())
                    } else if result.errorCode != nil || result.errorMessage != nil {
                        completion(
                            nil,
                            Self.preparationError(
                                errorCode: result.errorCode,
                                errorMessage: result.errorMessage
                            ))
                    } else {
                        completion(result.prepared, nil)
                    }
                }
            }
            try checkActive(snapshot)
            guard prepared.originalBookUrl == snapshot.bookURL else { throw CancellationError() }
            // Retain generation checks for live preparations even after a rebind away and back.
            preparedBindings = preparedBindings.filter { $0.value.prepared != nil }
            preparedBindings[ObjectIdentifier(prepared)] = PreparedBinding(prepared: prepared, binding: snapshot)
            return prepared
        } catch {
            try checkActive(snapshot)
            throw error
        }
    }

    @MainActor
    func commitSourceChange(_ prepared: PreparedBookSourceChange) async throws -> BookDetailRefreshResult {
        let snapshot = binding()
        try checkActive(snapshot)
        guard snapshot.bookURL == prepared.originalBookUrl else { throw CancellationError() }
        guard let preparation = preparedBindings[ObjectIdentifier(prepared)], preparation.prepared === prepared else {
            throw CancellationError()
        }
        try checkActive(preparation.binding)
        let facade = try requireFacade()
        preparedBindings.removeValue(forKey: ObjectIdentifier(prepared))
        // Commit owns its cancellation policy; never discard a completed persistent write.
        return try await SharedAsync.value { completion in
            facade.commitSourceChange(prepared: prepared, completionHandler: completion)
        }
    }

    @MainActor
    func changeSource(candidateBookUrl: String, sourceUrl: String) async throws -> BookDetailRefreshResult {
        let prepared = try await prepareSourceChange(candidateBookUrl: candidateBookUrl, sourceUrl: sourceUrl)
        return try await commitSourceChange(prepared)
    }

    @MainActor
    func loadChapterSourceToc(
        candidateBookUrl: String,
        sourceUrl: String,
        chapterIndex: Int
    ) async throws -> ChapterSourceChangeToc {
        let snapshot = binding()
        try checkActive(snapshot)
        let facade = try requireFacade()
        let preparation = ChapterPreparation(
            binding: snapshot, candidateBookURL: candidateBookUrl, sourceURL: sourceUrl,
            chapterIndex: chapterIndex
        )
        chapterPreparation = preparation
        do {
            let toc: ChapterSourceChangeToc = try await SharedCancellableAsync.value { completion in
                facade.loadChapterSourceTocRequest(
                    bookUrl: snapshot.bookURL,
                    candidateBookUrl: candidateBookUrl,
                    sourceUrl: sourceUrl,
                    currentChapterIndex: Int32(chapterIndex)
                ) { result in
                    if result.isCancelled {
                        completion(nil, CancellationError())
                    } else if result.errorCode != nil || result.errorMessage != nil {
                        completion(
                            nil,
                            Self.preparationError(
                                errorCode: result.errorCode,
                                errorMessage: result.errorMessage
                            ))
                    } else {
                        completion(result.toc, nil)
                    }
                }
            }
            try checkActive(snapshot)
            guard chapterPreparation?.id == preparation.id else { throw CancellationError() }
            chapterPreparation?.chapterCount = toc.chapters.count
            return toc
        } catch {
            if chapterPreparation?.id == preparation.id {
                chapterPreparation = nil
            }
            try checkActive(snapshot)
            throw error
        }
    }

    @MainActor
    func replaceChapterContentFromSource(
        currentChapterIndex: Int,
        candidateBookUrl: String,
        sourceUrl: String,
        candidateChapterIndex: Int
    ) async throws {
        let snapshot = binding()
        try checkActive(snapshot)
        guard let preparation = chapterPreparation,
            preparation.candidateBookURL == candidateBookUrl, preparation.sourceURL == sourceUrl,
            preparation.chapterIndex == currentChapterIndex,
            (0..<preparation.chapterCount).contains(candidateChapterIndex)
        else { throw CancellationError() }
        try checkActive(preparation.binding)
        let facade = try requireFacade()
        chapterPreparation = nil
        // Consume the TOC once; after entry the legacy cache write must finish without a stale-result check.
        _ = try await facade.replaceChapterContentFromSourceAsync(
            bookUrl: snapshot.bookURL,
            currentChapterIndex: Int32(currentChapterIndex),
            candidateBookUrl: candidateBookUrl,
            sourceUrl: sourceUrl,
            candidateChapterIndex: Int32(candidateChapterIndex)
        )
    }

    @MainActor
    func autoChangeSource(chapterIndex: Int) async throws -> BookDetailRefreshResult? {
        guard let facade = facade() else { return nil }
        let snapshot = binding()
        try checkActive(snapshot)
        await flushProgress()
        try checkActive(snapshot)
        // Discovery and persistence remain one legacy operation; preserve its committed result.
        return try await facade.autoChangeSourceAsync(
            bookUrl: snapshot.bookURL,
            chapterIndex: Int32(max(chapterIndex, 0))
        )
    }

    @MainActor
    private func matches(_ snapshot: Binding) -> Bool {
        let current = binding()
        return current.bookURL == snapshot.bookURL && current.generation == snapshot.generation
    }

    @MainActor
    private func checkActive(_ snapshot: Binding) throws {
        try Task.checkCancellation()
        guard matches(snapshot) else { throw CancellationError() }
    }

    @MainActor
    private func requireFacade() throws -> BookDetailFacade {
        guard let facade = facade() else {
            throw NSError(
                domain: "io.legado.kmp.ios",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
            )
        }
        return facade
    }

    private static func preparationError(errorCode: String?, errorMessage: String?) -> NSError {
        var userInfo: [String: Any] = [
            NSLocalizedDescriptionKey: errorMessage ?? errorCode ?? L10n.Shared.emptyValue
        ]
        if let errorCode {
            userInfo["errorCode"] = errorCode
        }
        if let errorMessage {
            userInfo["errorMessage"] = errorMessage
        }
        return NSError(
            domain: "io.legado.kmp.ios",
            code: errorCode.flatMap { Int($0) } ?? -1,
            userInfo: userInfo
        )
    }
}

private final class ReaderSourceChangeCallbackGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }
}
