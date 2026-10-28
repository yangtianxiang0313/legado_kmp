import SafariServices
import UIKit

extension ReaderContainerViewController {
    @discardableResult
    func beginReaderBodyTouch() -> Bool {
        guard canPerformNavigationAction, canNavigateReaderPages, !isMenuVisible else { return false }
        resetReaderScreenTimeoutTimer()
        guard
            textSelectionCoordinator.isSelecting
                || (shouldPresentSearchSelection && pendingSearchSelectionRange != nil)
        else { return false }
        // ACTION_DOWN cancels selection, but keeps search-result glyphs until the next edit/exit.
        searchSelectionRequestID = UUID()
        shouldPresentSearchSelection = false
        dismissTextSelectionMenu(clearSelection: true)
        return true
    }

    @objc func handleReaderLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else {
            textSelectionCoordinator.moveInitialSelection(to: gesture.location(in: view), state: gesture.state)
            return
        }
        guard !isAutoPageRunning else { return }
        cancelPageTurnForContentChange()
        if showImageActionMenuIfNeeded(at: gesture.location(in: view)) {
            return
        }
        guard ReaderLocalSettings.load().textSelectable else {
            showToast(L10n.Reader.textSelectableDetail)
            return
        }
        guard pages.indices.contains(currentPageIndex) else {
            showToast(L10n.Reader.selectionPageUnavailable)
            return
        }

        let pageIndex: Int
        let page: ReaderPageLayout
        let contentPoint: CGPoint
        if isScrollPageMode {
            guard let target = scrollPagerView.selectionTarget(at: gesture.location(in: scrollPagerView)),
                pages.indices.contains(target.pageIndex)
            else {
                dismissTextSelectionMenu(clearSelection: true)
                showToast(L10n.Reader.selectionNoTextAtPosition)
                return
            }
            pageIndex = target.pageIndex
            page = pages[target.pageIndex]
            contentPoint = target.contentPoint
            currentPageIndex = target.pageIndex
        } else {
            guard let target = renderView.layoutTarget(at: gesture.location(in: renderView)),
                let targetPage = pages[safe: currentPageIndex + target.pageOffset]
            else {
                dismissTextSelectionMenu(clearSelection: true)
                showToast(L10n.Reader.selectionNoTextAtPosition)
                return
            }
            pageIndex = currentPageIndex + target.pageOffset
            page = targetPage
            contentPoint = target.layoutPoint
        }
        guard let target = page.wordRange(at: contentPoint) else {
            dismissTextSelectionMenu(clearSelection: true)
            showToast(L10n.Reader.selectionNoTextAtPosition)
            return
        }

        textSelectionCoordinator.begin(range: target.range, pageIndex: pageIndex, initiallyDragging: true)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    func dismissTextSelectionMenu(clearSelection: Bool) {
        if textSelectionCoordinator.isSearchResultSelection {
            searchSelectionRequestID = UUID()
            shouldPresentSearchSelection = false
        }
        textSelectionCoordinator.dismiss(clearSelection: clearSelection)
    }

    func handleTextSelection(
        _ action: AndroidReaderTextActionMenuView.Action, range: NSRange, selectedText: String
    ) {
        let text = selectedText
        guard !text.isEmpty else {
            showToast(L10n.Reader.selectionEmpty)
            dismissTextSelectionMenu(clearSelection: true)
            return
        }

        switch action {
        case .replace:
            dismissTextSelectionMenu(clearSelection: true)
            replaceRuleCoordinator.openSelection(text: text)
        case .copy:
            UIPasteboard.general.string = text
            showToast(L10n.Reader.selectionCopied)
            dismissTextSelectionMenu(clearSelection: true)
        case .bookmark:
            addSelectionBookmark(range: range, text: text)
        case .readAloud:
            readAloudService.speakText(text)
            dismissTextSelectionMenu(clearSelection: true)
        case .dictionary:
            dismissTextSelectionMenu(clearSelection: true)
            showDictionary(word: text)
        case .search:
            dismissTextSelectionMenu(clearSelection: true)
            showSearchContent(query: text)
        case .browser:
            openBrowserSearch(for: text)
            dismissTextSelectionMenu(clearSelection: true)
        case .share:
            shareSelectedText(text)
        }
    }

    private func addSelectionBookmark(range: NSRange, text: String) {
        dismissTextSelectionMenu(clearSelection: true)
        ReaderBookmarkCreationCoordinator.present(
            in: self,
            chapterIndex: chapterIndex,
            chapterPosition: range.location,
            text: text,
            trimsText: false
        )
    }

    private func openBrowserSearch(for text: String) {
        guard presentedViewController == nil else {
            showToast(L10n.Reader.operationBusy)
            dismissTextSelectionMenu(clearSelection: true)
            return
        }
        guard let url = browserURL(for: text) else {
            showToast(L10n.Reader.selectionBrowserUnavailable)
            dismissTextSelectionMenu(clearSelection: true)
            return
        }
        present(SFSafariViewController(url: url), animated: true)
    }

    private func browserURL(for text: String) -> URL? {
        // String.isAbsUrl accepts only explicit HTTP(S) prefixes; bare domains are search queries.
        let lowercased = text.lowercased()
        if lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") {
            guard let url = URL(string: text), url.host?.isEmpty == false else { return nil }
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }

    private func shareSelectedText(_ text: String) {
        guard presentedViewController == nil else {
            showToast(L10n.Reader.operationBusy)
            dismissTextSelectionMenu(clearSelection: true)
            return
        }
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        configurePopover(activityVC.popoverPresentationController)
        present(activityVC, animated: true) { [weak self] in
            self?.showToast(L10n.Reader.selectionShareReady)
        }
        dismissTextSelectionMenu(clearSelection: true)
    }

    private func configurePopover(_ popover: UIPopoverPresentationController?) {
        guard let popover else { return }
        popover.sourceView = view
        if let menu = textSelectionMenu {
            popover.sourceRect = view.convert(menu.bounds, from: menu)
        } else {
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
    }
}

enum TextSelectionMenuPlacement {
    static func frame(
        for menu: AndroidReaderTextActionMenuView, start: CGRect, end: CGRect, safeFrame: CGRect,
        pixelScale: CGFloat, preservedOrigin: CGPoint? = nil
    ) -> CGRect? {
        frame(
            size: fittingSize(for: menu, width: safeFrame.width), start: start, end: end,
            safeFrame: safeFrame, pixelScale: pixelScale, expanded: menu.expandsAllActions,
            preservedOrigin: preservedOrigin)
    }

    static func frame(
        size desiredSize: CGSize, start: CGRect, end: CGRect, safeFrame: CGRect,
        pixelScale: CGFloat, expanded: Bool, preservedOrigin: CGPoint? = nil
    ) -> CGRect? {
        guard
            [
                start.minX, start.minY, start.maxY, end.minX, end.maxY,
                safeFrame.minX, safeFrame.minY, safeFrame.width, safeFrame.height,
                desiredSize.width, desiredSize.height, pixelScale,
            ].allSatisfy({ $0.isFinite }),
            safeFrame.width > 0, safeFrame.height > 0, desiredSize.width > 0, desiredSize.height > 0,
            pixelScale > 0
        else { return nil }
        let size = CGSize(width: min(safeFrame.width, desiredSize.width), height: min(safeFrame.height, desiredSize.height))
        let origin: CGPoint
        if let preservedOrigin, preservedOrigin.x.isFinite, preservedOrigin.y.isFinite {
            origin = preservedOrigin
        } else {
            // TextActionMenu.show uses a literal 500 physical-pixel threshold and 24dp cursors.
            let startBottom = start.maxY + 24
            let endBottom = end.maxY + 24
            if (expanded ? start.minY : startBottom) * pixelScale > 500 {
                origin = CGPoint(x: start.minX, y: start.minY - size.height)
            } else if (endBottom - startBottom) * pixelScale > 500 {
                origin = CGPoint(x: start.minX, y: startBottom)
            } else {
                origin = CGPoint(x: end.minX, y: endBottom)
            }
        }
        // PopupWindow clips to its display. iOS additionally avoids its device-specific occlusions.
        return CGRect(
            x: min(max(origin.x, safeFrame.minX), safeFrame.maxX - size.width),
            y: min(max(origin.y, safeFrame.minY), safeFrame.maxY - size.height),
            width: size.width, height: size.height)
    }

    private static func fittingSize(for menu: AndroidReaderTextActionMenuView, width: CGFloat) -> CGSize {
        menu.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}
