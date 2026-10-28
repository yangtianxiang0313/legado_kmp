import Foundation
import shared

final class ReaderChapterRequestGate {
    struct Ticket {
        fileprivate let id: UUID
        let bookURL: String
        let facade: ReaderFacade
    }

    private let lock = NSLock()
    private var bookURL: String
    private var facade: ReaderFacade?
    private var latestTicketID: UUID?
    private var latestRequestFinished = false
    private var activeSubscription: FlowSubscription?
    private var isSuspended = false

    init(bookURL: String) {
        self.bookURL = bookURL
    }

    func bind(bookURL: String, facade: ReaderFacade?) {
        let previous = withLock {
            let previous = invalidateLocked()
            self.bookURL = bookURL
            self.facade = facade
            return previous
        }
        previous?.cancel()
    }

    func begin() throws -> Ticket {
        try Task.checkCancellation()
        var previous: FlowSubscription?
        let ticket = try withLock {
            guard isSuspended == false else { throw CancellationError() }
            guard let facade else {
                throw NSError(
                    domain: "io.legado.kmp.ios",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.Reader.unavailable]
                )
            }
            let ticket = Ticket(id: UUID(), bookURL: bookURL, facade: facade)
            previous = invalidateLocked()
            latestTicketID = ticket.id
            return ticket
        }
        previous?.cancel()
        return ticket
    }

    func register(_ subscription: FlowSubscription, for ticket: Ticket) {
        let isCurrent = withLock {
            guard !isSuspended, latestTicketID == ticket.id else { return false }
            if !latestRequestFinished {
                activeSubscription = subscription
            }
            return true
        }
        if !isCurrent {
            subscription.cancel()
        }
    }

    func finish(_ ticket: Ticket) {
        withLock {
            guard latestTicketID == ticket.id else { return }
            latestRequestFinished = true
            activeSubscription = nil
        }
    }

    func check(_ ticket: Ticket) throws {
        try Task.checkCancellation()
        try withLock {
            guard isSuspended == false, latestTicketID == ticket.id else {
                throw CancellationError()
            }
        }
    }

    func resume() {
        withLock { isSuspended = false }
    }

    func suspend() {
        let previous = withLock {
            isSuspended = true
            return invalidateLocked()
        }
        previous?.cancel()
    }

    func cancel() {
        let previous = withLock { invalidateLocked() }
        previous?.cancel()
    }

    private func invalidateLocked() -> FlowSubscription? {
        latestTicketID = nil
        latestRequestFinished = false
        let previous = activeSubscription
        activeSubscription = nil
        return previous
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
