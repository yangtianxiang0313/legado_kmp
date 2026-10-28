import UIKit
import shared

enum ReaderAutoChangeSourcePreference {
    private static let sharedKey = "auto_change_source"
    private static let legacyKey = "autoChangeSource"

    static func isEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: sharedKey) != nil {
            return defaults.bool(forKey: sharedKey)
        }
        if defaults.object(forKey: legacyKey) != nil {
            return defaults.bool(forKey: legacyKey)
        }
        return true
    }

    static func setEnabled(_ isEnabled: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(isEnabled, forKey: sharedKey)
        defaults.set(isEnabled, forKey: legacyKey)
    }
}

extension ReaderContainerViewController {
    func hideReaderLoadFailure() {
        chapterMessageCoordinator.hide()
    }

    func showReaderLoadFailure(message: String, requestedIndex: Int) {
        loadingIndicator.stopAnimating()
        guard canPresentReaderLoadFailure else { return }
        chapterMessageCoordinator.failure(message: message, index: requestedIndex)
    }

    private var canPresentReaderLoadFailure: Bool {
        guard Task.isCancelled == false,
            isMovingFromParent == false,
            isBeingDismissed == false,
            navigationController?.isBeingDismissed != true,
            presentedViewController == nil
        else { return false }
        if let navigationController {
            return navigationController.topViewController === self
        }
        return viewIfLoaded?.window != nil
    }

    @MainActor
    func handleChapterLoadFailure(_ error: Error, requestedIndex: Int) async {
        guard !(error is CancellationError), canPresentReaderLoadFailure else { return }
        await handleReaderLoadFailure(message: error.userFacingMessage, requestedIndex: requestedIndex)
    }

    @MainActor
    func applyChapterPayloadOrAutoChange(
        _ payload: ReaderChapterPayload,
        requestedIndex: Int,
        restorePosition: Int?
    ) async {
        guard !Task.isCancelled, !isMovingFromParent, !isBeingDismissed,
            navigationController?.topViewController === self
        else { return }
        guard !payload.hasReadableContent else {
            applyPayload(payload, restorePosition: restorePosition)
            loadingIndicator.stopAnimating()
            return
        }

        await handleReaderLoadFailure(message: L10n.ContentState.emptyTable, requestedIndex: requestedIndex)
    }

    @MainActor
    private func handleReaderLoadFailure(message: String, requestedIndex: Int) async {
        guard canPresentReaderLoadFailure else { return }
        let originalBookURL = bookURL
        do {
            // Android auto-switches only when the original source no longer exists.
            let sourceIsMissing = shouldAttemptAutoChangeSource() ? try await screen.isCurrentSourceMissing() : false
            guard canPresentReaderLoadFailure, bookURL == originalBookURL else { return }
            guard sourceIsMissing, shouldAttemptAutoChangeSource() else {
                showReaderLoadFailure(message: message, requestedIndex: requestedIndex)
                return
            }
            await performAutoChangeSource(requestedIndex: requestedIndex, originalFailureMessage: message)
        } catch {
            guard !(error is CancellationError), canPresentReaderLoadFailure, bookURL == originalBookURL else { return }
            // A failed local lookup is not evidence of a missing source.
            showReaderLoadFailure(message: message, requestedIndex: requestedIndex)
        }
    }

    @MainActor
    private func performAutoChangeSource(requestedIndex: Int, originalFailureMessage: String) async {
        guard canPresentReaderLoadFailure else {
            loadingIndicator.stopAnimating()
            return
        }
        isAutoChangingSource = true
        chapterMessageCoordinator.loading(
            index: requestedIndex,
            message: NSLocalizedString("正在自动换源", comment: "Android source_auto_changing"))
        defer {
            isAutoChangingSource = false
            loadingIndicator.stopAnimating()
        }
        var retryIndex = requestedIndex
        var didCommitSourceChange = false
        let originalBookURL = bookURL
        let navigationTargets = navigationController?.viewControllers ?? []

        do {
            let result = try await screen.autoChangeSource(chapterIndex: requestedIndex)
            guard let result else {
                guard canPresentReaderLoadFailure else { return }
                showReaderLoadFailure(
                    message: "\(originalFailureMessage)\n\n\(L10n.Reader.autoChangeSourceFailed)", requestedIndex: requestedIndex
                )
                return
            }

            didCommitSourceChange = true
            adoptSourceChangeResult(result)
            publishCommittedSourceChange(result, replacing: originalBookURL, to: navigationTargets)
            guard canPresentReaderLoadFailure else { return }

            let normalizedIndex = Int(result.book.durChapterIndex).coerceInChapterRange(chapterCount: result.chapters.count)
            retryIndex = normalizedIndex
            let payload = try await screen.loadChapter(index: normalizedIndex)
            guard canPresentReaderLoadFailure else { return }
            guard payload.hasReadableContent else {
                showReaderLoadFailure(message: L10n.ContentState.emptyTable, requestedIndex: normalizedIndex)
                return
            }
            applyPayload(payload, restorePosition: 0)
            showToast(L10n.Reader.autoChangeSourceSuccess)
        } catch {
            guard !(error is CancellationError), canPresentReaderLoadFailure else { return }
            let message =
                didCommitSourceChange
                ? error.userFacingMessage
                : "\(originalFailureMessage)\n\n\(L10n.Reader.autoChangeSourceFailed): \(error.userFacingMessage)"
            showReaderLoadFailure(message: message, requestedIndex: retryIndex)
        }
    }

    private func shouldAttemptAutoChangeSource() -> Bool {
        ReaderAutoChangeSourcePreference.isEnabled()
            && isAutoChangingSource == false
            && book?.isLocal != true
    }
}

extension Int {
    fileprivate func coerceInChapterRange(chapterCount: Int) -> Int {
        guard chapterCount > 0 else { return Swift.max(self, 0) }
        return Swift.min(Swift.max(self, 0), chapterCount - 1)
    }
}
