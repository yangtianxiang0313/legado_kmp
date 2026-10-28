import Foundation
import shared

final class ReaderProgressQueue {
    struct Snapshot: Equatable {
        let chapterIndex: Int
        let chapterTitle: String?
        let chapterPosition: Int
    }

    struct CatalogBarrier: Equatable {
        fileprivate let id = UUID()
    }

    private struct Write {
        let bindingID: UUID
        let bookURL: String
        let facade: ReaderFacade
        let snapshot: Snapshot
    }

    private let lock = NSLock()
    private var bindingID = UUID()
    private var bookURL: String
    private var facade: ReaderFacade?
    private var pending: Snapshot?
    private var lastCommitted: Snapshot?
    private var isReady = false
    private var debounceID: UUID?
    private var debounceTask: Task<Void, Never>?
    private var writerTask: Task<Void, Never>?
    private var catalogBarrier: CatalogBarrier?
    private var isDrainingCatalog = false
    private var acceptsPresentation = true

    init(bookURL: String) {
        self.bookURL = bookURL
    }

    var currentBindingID: UUID {
        withLock { bindingID }
    }

    func bind(bookURL: String, facade: ReaderFacade?) {
        withLock {
            cancelDebounceLocked()
            if bookURL != self.bookURL {
                catalogBarrier = nil
                isDrainingCatalog = false
            }
            bindingID = UUID()
            self.bookURL = bookURL
            self.facade = facade
            pending = nil
            lastCommitted = nil
            isReady = false
            acceptsPresentation = catalogBarrier == nil
            // Keep the writer until its callback returns, even when rebinding to the same URL.
        }
    }

    func beginPresentation(bookURL: String) {
        withLock {
            guard bookURL == self.bookURL else { return }
            cancelDebounceLocked()
            bindingID = UUID()
            pending = nil
            lastCommitted = nil
            isReady = false
            acceptsPresentation = catalogBarrier == nil
            // Keep the old writer serialized; its generation cannot commit into this presentation.
        }
    }

    func stage(_ snapshot: Snapshot, immediate: Bool, bindingID expectedBindingID: UUID? = nil) {
        withLock {
            guard expectedBindingID == nil || expectedBindingID == bindingID else { return }
            guard catalogBarrier == nil, acceptsPresentation else { return }
            if snapshot == lastCommitted {
                pending = nil
                isReady = false
                cancelDebounceLocked()
                return
            }
            if snapshot == pending && immediate == false {
                return
            }
            pending = snapshot
            cancelDebounceLocked()
            isReady = immediate
            if immediate {
                startWriterLocked()
            } else {
                let token = UUID()
                debounceID = token
                debounceTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: AppUI.Reader.progressDebounceNanoseconds)
                    guard Task.isCancelled == false else { return }
                    self?.debounceElapsed(token)
                }
            }
        }
    }

    func flushNow() async {
        let task = withLock {
            cancelDebounceLocked()
            isReady = (acceptsPresentation || isDrainingCatalog) && pending != nil
            startWriterLocked()
            return writerTask
        }
        await task?.value
    }

    func beginCatalogBarrier() throws -> CatalogBarrier {
        try withLock {
            guard catalogBarrier == nil else { throw CancellationError() }
            let barrier = CatalogBarrier()
            catalogBarrier = barrier
            cancelDebounceLocked()
            acceptsPresentation = false
            isDrainingCatalog = true
            // Save the existing checkpoint against the old directory, but reject all subsequent UI stages.
            isReady = pending != nil
            startWriterLocked()
            return barrier
        }
    }

    func drainCatalogBarrier(_ barrier: CatalogBarrier) async -> Bool {
        let task = withLock { catalogBarrier == barrier ? writerTask : nil }
        await task?.value
        return withLock {
            guard catalogBarrier == barrier else { return false }
            isDrainingCatalog = false
            isReady = false
            return writerTask == nil && pending == nil
        }
    }

    @discardableResult
    func finishCatalogBarrier(
        _ barrier: CatalogBarrier, committed: Snapshot?, acceptsPresentation: Bool
    ) -> Bool {
        withLock {
            guard catalogBarrier == barrier else { return false }
            invalidatePresentationLocked()
            catalogBarrier = nil
            lastCommitted = committed
            self.acceptsPresentation = acceptsPresentation
            return true
        }
    }

    func suspendPresentation() {
        withLock { invalidatePresentationLocked() }
    }

    private func invalidatePresentationLocked() {
        cancelDebounceLocked()
        bindingID = UUID()
        pending = nil
        lastCommitted = nil
        isReady = false
        acceptsPresentation = false
        isDrainingCatalog = false
    }

    func flushForExit() async throws {
        let generation = currentBindingID
        await flushNow()
        let committed = withLock { generation == bindingID && pending == nil && writerTask == nil }
        guard committed else {
            throw NSError(
                domain: "io.legado.readerProgress", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "阅读进度尚未保存，请稍后重试"])
        }
    }

    func cancelDebounce() {
        withLock { cancelDebounceLocked() }
    }

    private func debounceElapsed(_ token: UUID) {
        withLock {
            guard debounceID == token else { return }
            debounceID = nil
            debounceTask = nil
            isReady = pending != nil
            startWriterLocked()
        }
    }

    private func cancelDebounceLocked() {
        debounceID = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func startWriterLocked() {
        guard (catalogBarrier == nil && acceptsPresentation) || isDrainingCatalog,
            writerTask == nil, isReady, pending != nil, facade != nil
        else { return }
        writerTask = Task { @MainActor in
            await self.drain()
        }
    }

    private func nextWrite() -> Write? {
        withLock {
            guard (catalogBarrier == nil && acceptsPresentation) || isDrainingCatalog,
                isReady, let snapshot = pending, let facade
            else {
                writerTask = nil
                return nil
            }
            isReady = false
            if snapshot == lastCommitted {
                pending = nil
                writerTask = nil
                return nil
            }
            let write = Write(bindingID: bindingID, bookURL: bookURL, facade: facade, snapshot: snapshot)
            // The old committed value cannot suppress a compensating write while this call is pending.
            lastCommitted = nil
            return write
        }
    }

    @MainActor
    private func drain() async {
        while let write = nextWrite() {
            do {
                try await write.facade.updateReadingProgressAsync(
                    bookUrl: write.bookURL,
                    chapterIndex: Int32(write.snapshot.chapterIndex),
                    chapterTitle: write.snapshot.chapterTitle,
                    chapterPosition: Int32(write.snapshot.chapterPosition)
                )
                finish(write, succeeded: true)
                AutomaticBackupCoordinator.shared.readerDidSaveCheckpoint()
            } catch {
                finish(write, succeeded: false)
                SharedRuntime.log("reader progress flush failed: \(error.localizedDescription)")
            }
        }
    }

    private func finish(_ write: Write, succeeded: Bool) {
        withLock {
            guard write.bindingID == bindingID else { return }
            if succeeded {
                lastCommitted = write.snapshot
                if pending == write.snapshot {
                    pending = nil
                    isReady = false
                    cancelDebounceLocked()
                }
            } else if pending == write.snapshot {
                // Retain the latest value for a later explicit flush, without a tight retry loop.
                isReady = false
            }
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
