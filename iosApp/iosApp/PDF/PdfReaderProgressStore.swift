import Foundation
import shared

@MainActor
final class PdfReaderProgressStore {
    private let bookURL: String
    private let reader: ReaderFacade
    private let queue: ReaderProgressQueue
    private var lifecycle: Task<Void, Never>?
    private var active = false
    var onError: ((String) -> Void)?

    init(bookURL: String) throws {
        self.bookURL = bookURL
        reader = try SharedRuntime.readerFacade().get()
        queue = ReaderProgressQueue(bookURL: bookURL)
        queue.bind(bookURL: bookURL, facade: reader)
    }

    func begin() {
        guard !active else { return }
        active = true
        let preceding = lifecycle
        lifecycle = Task { [reader, bookURL] in
            await preceding?.value
            reader.beginReadSession(bookUrl: bookURL)
        }
    }

    func save(page: Int) {
        queue.stage(.init(chapterIndex: page, chapterTitle: "Page \(page + 1)", chapterPosition: 0), immediate: false)
    }

    func flush() async throws { try await queue.flushForExit() }

    func end() {
        guard active else { return }
        active = false
        let previousLifecycle = lifecycle
        let reader = reader
        let bookURL = bookURL
        // Do not cancel an acknowledged page write when the reader is popped or backgrounded.
        lifecycle = Task { [self] in
            await previousLifecycle?.value
            do {
                try await queue.flushForExit()
            } catch {
                onError?(error.userFacingMessage)
            }
            do {
                try await SharedAsync.void { reader.endReadSession(bookUrl: bookURL, completionHandler: $0) }
            } catch {
                onError?(error.userFacingMessage)
            }
        }
    }
}
