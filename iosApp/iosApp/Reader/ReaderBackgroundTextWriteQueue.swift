import Foundation
import shared

/// Live controls merge into one desired style; only one persisted snapshot is in flight.
@MainActor
final class ReaderBackgroundTextWriteQueue {
    private(set) var style: ReaderStylePreferences
    private var savedStyle: ReaderStylePreferences
    private let save: (ReaderStylePreferences) async throws -> Void
    private var revision = 0
    private var savedRevision = 0
    private var worker: Task<Void, Never>?
    private var failure: Error?
    private var awaitsConfirmation = false

    var onChange: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var isPending: Bool { worker != nil || revision != savedRevision }

    init(style: ReaderStylePreferences, save: @escaping (ReaderStylePreferences) async throws -> Void) {
        self.style = style
        savedStyle = style
        self.save = save
    }

    func update(_ transform: (ReaderStylePreferences) -> ReaderStylePreferences) {
        style = transform(style)
        revision += 1
        failure = nil
        startWorker()
        onChange?()
    }

    func absorb(_ style: ReaderStylePreferences) {
        guard !isPending else { return }
        if awaitsConfirmation {
            guard style.isEqual(savedStyle) else { return }
            awaitsConfirmation = false
        }
        self.style = style
        savedStyle = style
        onChange?()
    }

    func retry() {
        failure = nil
        startWorker()
    }

    func acceptSnapshot(_ style: ReaderStylePreferences) {
        guard !isPending else { return }
        self.style = style
        savedStyle = style
        awaitsConfirmation = false
        onChange?()
    }

    func discardFailedChanges() {
        guard worker == nil else { return }
        style = savedStyle
        revision = savedRevision
        failure = nil
        onChange?()
    }

    func flush() async throws {
        while let worker { await worker.value }
        if let failure { throw failure }
    }

    private func startWorker() {
        guard worker == nil, revision != savedRevision else { return }
        // Completed writes remain real even if the panel closes during persistence.
        worker = Task { [self] in
            while revision != savedRevision {
                let target = style
                let targetRevision = revision
                do {
                    try await save(target)
                    savedStyle = target
                    savedRevision = targetRevision
                    awaitsConfirmation = true
                } catch {
                    failure = error
                    worker = nil
                    onChange?()
                    onFailure?(error)
                    return
                }
            }
            worker = nil
            onChange?()
        }
    }
}
