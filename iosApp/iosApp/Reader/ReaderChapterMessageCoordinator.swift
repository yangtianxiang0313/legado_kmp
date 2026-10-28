import UIKit

@MainActor
final class ReaderChapterMessageCoordinator {
    private struct Context {
        let id: UUID
        let bookURL: String
        let index: Int
    }

    private weak var reader: ReaderContainerViewController?
    private var context: Context?
    private var awaitsPageRender = false
    private var successMessage: String?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
    }

    var requestedIndex: Int? {
        guard let context, let reader else { return nil }
        guard context.bookURL == reader.bookURL else {
            hide()
            return nil
        }
        return context.index
    }

    func loading(index: Int, message: String? = nil) {
        guard let reader else { return }
        let context = begin(index: index, in: reader)
        reader.loadFailureView.showLoading(
            message: message ?? NSLocalizedString("加载数据中…", comment: "Reader chapter loading message"),
            theme: reader.readerRenderTheme(),
            onMenu: { [weak self] in
                self?.openMenu(for: context, isFailure: false)
            }
        )
        updateGeometry()
        reader.updateMenuState()
    }

    func failure(message: String, index: Int) {
        guard let reader else { return }
        let context = begin(index: index, in: reader)
        reader.stopAutoPage(showMessage: false)
        reader.setMenuVisible(false)
        reader.searchMenu.setVisible(false, currentChapterIndex: reader.chapterIndex)
        reader.loadFailureView.show(
            message: message,
            theme: reader.readerRenderTheme(),
            onRetry: { [weak self] in
                guard let self, let reader = self.actionReader(for: context, isFailure: true) else { return }
                reader.chapterLoadCoordinator.retry(in: reader, fallbackIndex: context.index)
            },
            onBack: { [weak self] in
                guard let self, let reader = self.actionReader(for: context, isFailure: true) else { return }
                reader.performReaderBackAction()
                self.updateGeometry()
            },
            onMenu: { [weak self] in
                self?.openMenu(for: context, isFailure: true)
            }
        )
        updateGeometry()
        reader.updateMenuState()
    }

    func hide() {
        context = nil
        awaitsPageRender = false
        successMessage = nil
        guard let reader else { return }
        reader.loadFailureView.hide()
        reader.loadFailureView.contentFrame = nil
        setChapterMessageVisible(false, in: reader)
        reader.updateMenuState()
    }

    func preparingPage(index: Int) {
        guard let reader else { return }
        if context?.bookURL != reader.bookURL || context?.index != index || !reader.loadFailureView.isShowingLoading {
            loading(index: index)
        }
        awaitsPageRender = true
    }

    func queueSuccessMessage(_ message: String) {
        guard reader?.loadFailureView.isShowingLoading == true else { return }
        successMessage = message
    }

    func finishLoading(afterRendering: Bool = false, cancelled: Bool = false) {
        guard let reader else {
            context = nil
            return
        }
        guard reader.loadFailureView.isShowingLoading else { return }
        if afterRendering {
            guard awaitsPageRender, context?.index == reader.chapterIndex, !reader.pages.isEmpty else { return }
        } else if awaitsPageRender && !cancelled {
            return
        }
        let message = afterRendering ? successMessage : nil
        context = nil
        awaitsPageRender = false
        successMessage = nil
        reader.loadFailureView.hideLoading()
        reader.loadFailureView.contentFrame = nil
        setChapterMessageVisible(false, in: reader)
        reader.updateMenuState()
        if let message, reader.canPerformNavigationAction { reader.showToast(message) }
    }

    func updateGeometry() {
        guard let reader, let context else { return }
        guard context.bookURL == reader.bookURL else {
            hide()
            return
        }
        let overlay = reader.loadFailureView
        if reader.isScrollPageMode && !reader.scrollPagerView.isHidden {
            overlay.contentFrame = reader.scrollPagerView.convert(
                reader.scrollPagerView.chapterMessageContentFrame, to: overlay
            )
        } else {
            overlay.contentFrame = reader.renderView.convert(
                reader.renderView.chapterMessageContentFrame, to: overlay
            )
        }
        overlay.accessibilityViewIsModal = !reader.isMenuVisible
    }

    private func begin(index: Int, in reader: ReaderContainerViewController) -> Context {
        let context = Context(id: UUID(), bookURL: reader.bookURL, index: index)
        self.context = context
        awaitsPageRender = false
        successMessage = nil
        reader.cancelPageTurnForContentChange()
        reader.dismissTextSelectionMenu(clearSelection: true)
        // Like TextPageFactory(msg), replace only the body; retain background and chrome.
        setChapterMessageVisible(true, in: reader)
        return context
    }

    private func setChapterMessageVisible(_ visible: Bool, in reader: ReaderContainerViewController) {
        reader.renderView.setChapterMessageVisible(visible)
        reader.scrollPagerView.setChapterMessageVisible(visible)
    }

    private func actionReader(for context: Context, isFailure: Bool) -> ReaderContainerViewController? {
        guard self.context?.id == context.id, let reader else { return nil }
        guard context.bookURL == reader.bookURL else {
            hide()
            return nil
        }
        guard reader.canPerformNavigationAction,
            reader.loadFailureView.window === reader.viewIfLoaded?.window,
            isFailure ? reader.loadFailureView.isShowingFailure : reader.loadFailureView.isShowingLoading
        else { return nil }
        return reader
    }

    private func openMenu(for context: Context, isFailure: Bool) {
        guard let reader = actionReader(for: context, isFailure: isFailure) else { return }
        reader.setMenuVisible(true)
        updateGeometry()
        reader.updateMenuState()
    }
}
