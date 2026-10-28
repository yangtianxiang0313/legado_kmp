import UIKit
import shared

/// ReadStyleDialog displays ReadBook.pageAnim(), and selecting a global value removes the book override.
@MainActor
final class ReaderAppearanceBookBinding {
    private weak var reader: ReaderContainerViewController?
    private let bookURL: String
    private let origin: String?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        bookURL = reader.bookURL
        origin = reader.book?.origin
    }

    var isCurrent: Bool {
        guard let reader, reader.bookURL == bookURL, reader.book?.bookUrl == bookURL,
            reader.book?.origin == origin,
            reader.navigationController?.topViewController === reader,
            reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
        else { return false }
        return !reader.isBeingDismissed && !reader.isMovingFromParent
            && reader.navigationController?.isBeingDismissed != true
    }

    func effectiveAnimation(globalValue: Int) -> Int {
        guard isCurrent else { return globalValue }
        return reader?.currentReaderPageAnimationOverrideValue() ?? globalValue
    }

    var isImageBook: Bool { reader?.book?.isImage == true }

    func saveAnimation(_ value: Int, saveGlobal: () async throws -> Void) async throws {
        guard (0...4).contains(value), isCurrent, let reader,
            !reader.pageAnimationSelectionCoordinator.isSaving, !reader.bookSettingsCoordinator.isSaving
        else { throw CancellationError() }
        reader.stageProgress(immediate: true)
        await reader.screen.flushReadingProgressNow()
        guard isCurrent else { throw CancellationError() }
        let facade = try SharedRuntime.bookDetailFacade().get()
        guard let latest = try await facade.resolveBookAsync(bookUrl: bookURL), latest.origin == origin, isCurrent else {
            throw CancellationError()
        }
        try await saveGlobal()
        guard isCurrent else { return }
        // The stores are independent. A metadata failure leaves its actual override selected for retry.
        if let override = latest.config.pageAnim?.intValue, override >= 0 {
            let updated = try await facade.setPageAnimationAsync(bookUrl: bookURL, pageAnimation: -1)
            guard isCurrent, updated.origin == origin, updated.bookUrl == bookURL else { return }
            reader.book = updated
        } else {
            reader.book = latest
        }
        if isCurrent { reader.refreshReaderRuntimeConfigPresentationSoon() }
    }
}
