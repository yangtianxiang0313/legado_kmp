import shared
import UIKit

extension Notification.Name {
    static let readerTapZoneActionsDidChange = Notification.Name("reader.tapZoneActionsDidChange")
}

extension ReaderContainerViewController {
    func installReaderGestures() {
        let localSettings = ReaderLocalSettings.load()
        let tapGesture = ReaderTapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        tapGesture.maximumMovement = localSettings.touchSensitivity.tapAllowableMovement
        tapGesture.onTouchDown = { [weak self] in self?.beginReaderBodyTouch() ?? false }
        let longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleReaderLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.6
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleReaderPan(_:)))
        let menuFallbackGesture = UITapGestureRecognizer(target: self, action: #selector(handleReaderMenuFallbackTap(_:)))
        menuFallbackGesture.numberOfTouchesRequired = 2
        menuFallbackGesture.cancelsTouchesInView = true
        tapGesture.require(toFail: longPressGesture)
        tapGesture.require(toFail: menuFallbackGesture)
        tapGesture.require(toFail: panGesture)
        panGesture.require(toFail: longPressGesture)
        if let backGesture = navigationController?.interactivePopGestureRecognizer {
            panGesture.require(toFail: backGesture)
            longPressGesture.require(toFail: backGesture)
            scrollPagerView.prioritizeNavigationBackGesture(backGesture)
        }
        readerTapGesture = tapGesture
        renderView.addGestureRecognizer(tapGesture)
        renderView.addGestureRecognizer(longPressGesture)
        renderView.addGestureRecognizer(panGesture)
        renderView.addGestureRecognizer(menuFallbackGesture)

        let scrollTapGesture = ReaderTapGestureRecognizer(target: self, action: #selector(handleReaderTap(_:)))
        scrollTapGesture.maximumMovement = localSettings.touchSensitivity.tapAllowableMovement
        scrollTapGesture.onTouchDown = { [weak self] in self?.beginReaderBodyTouch() ?? false }
        let scrollLongPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleReaderLongPress(_:)))
        scrollLongPressGesture.minimumPressDuration = 0.6
        let scrollMenuFallbackGesture = UITapGestureRecognizer(target: self, action: #selector(handleReaderMenuFallbackTap(_:)))
        scrollMenuFallbackGesture.numberOfTouchesRequired = 2
        scrollMenuFallbackGesture.cancelsTouchesInView = true
        scrollTapGesture.require(toFail: scrollLongPressGesture)
        scrollTapGesture.require(toFail: scrollMenuFallbackGesture)
        scrollPagerView.prioritizeTextSelectionGesture(scrollLongPressGesture)
        if let backGesture = navigationController?.interactivePopGestureRecognizer {
            scrollLongPressGesture.require(toFail: backGesture)
        }
        self.scrollTapGesture = scrollTapGesture
        scrollPagerView.addGestureRecognizer(scrollTapGesture)
        scrollPagerView.addGestureRecognizer(scrollLongPressGesture)
        scrollPagerView.addGestureRecognizer(scrollMenuFallbackGesture)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTapZoneActionsDidChange(_:)),
            name: .readerTapZoneActionsDidChange,
            object: nil
        )
    }

    @objc func handleReaderTap(_ gesture: UITapGestureRecognizer) {
        resetReaderScreenTimeoutTimer()
        guard !readerBodyTouchDismissedSelection(for: gesture) else { return }
        if textSelectionCoordinator.isSelecting {
            dismissTextSelectionMenu(clearSelection: true)
            return
        }
        if isMenuVisible {
            setMenuVisible(false)
            return
        }
        let point = gesture.location(in: view)
        if ReaderLocalSettings.load().previewImageByClick, showImagePreviewIfLoaded(at: point) {
            return
        }
        performTapZoneAction(readerTapAction(at: point), at: renderView.convert(point, from: view))
    }

    @objc private func handleReaderMenuFallbackTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        guard !readerBodyTouchDismissedSelection(for: gesture) else { return }
        if textSelectionCoordinator.isSelecting {
            dismissTextSelectionMenu(clearSelection: true)
            return
        }
        showReaderActionMenu()
    }

    private func readerBodyTouchDismissedSelection(for gesture: UIGestureRecognizer) -> Bool {
        gesture.view?.gestureRecognizers?.contains(where: {
            ($0 as? ReaderTapGestureRecognizer)?.didDismissSelectionOnTouch == true
        }) ?? false
    }

    private func readerTapAction(at point: CGPoint) -> ReaderTapAction {
        let actions = (tapZoneActionsOverride ?? runtimeConfig?.reader.tapZoneActions ?? ReaderTapZoneActions.legadoDefaultActions).androidMenuSafeActions
        let tapFrame = view.bounds
        guard tapFrame.width > 0, tapFrame.height > 0 else { return .menu }
        guard tapFrame.contains(point) else { return .menu }

        let width = max(tapFrame.width, 1)
        let height = max(tapFrame.height, 1)
        let pointInPage = CGPoint(x: point.x - tapFrame.minX, y: point.y - tapFrame.minY)
        for zone in androidTapZones(width: width, height: height, actions: actions) where zone.rect.contains(pointInPage) {
            return ReaderTapAction(rawValue: Int(zone.action)) ?? .menu
        }
        return .menu
    }

    private func androidTapZones(width: CGFloat, height: CGFloat, actions: ReaderTapZoneActions) -> [(rect: CGRect, action: Int32)] {
        let left = width * 0.33
        let middleRight = width * 0.66
        let rightTopStart = width * 0.36
        let top = height * 0.33
        let middleBottom = height * 0.66
        return [
            (CGRect(x: left, y: top, width: middleRight - left, height: middleBottom - top), actions.middleCenter),
            (CGRect(x: left, y: middleBottom, width: middleRight - left, height: height - middleBottom), actions.bottomCenter),
            (CGRect(x: 0, y: middleBottom, width: left, height: height - middleBottom), actions.bottomLeft),
            (CGRect(x: middleRight, y: middleBottom, width: width - middleRight, height: height - middleBottom), actions.bottomRight),
            (CGRect(x: 0, y: top, width: left, height: middleBottom - top), actions.middleLeft),
            (CGRect(x: middleRight, y: top, width: width - middleRight, height: middleBottom - top), actions.middleRight),
            (CGRect(x: 0, y: 0, width: left, height: top), actions.topLeft),
            (CGRect(x: left, y: 0, width: middleRight - left, height: top), actions.topCenter),
            (CGRect(x: rightTopStart, y: 0, width: width - rightTopStart, height: top), actions.topRight),
        ]
    }

    @objc private func handleTapZoneActionsDidChange(_ notification: Notification) {
        guard let actions = notification.object as? ReaderTapZoneActions else { return }
        tapZoneActionsOverride = actions.androidMenuSafeActions
    }

    private func performTapZoneAction(_ action: ReaderTapAction, at point: CGPoint) {
        switch action {
        case .disabled:
            break
        case .menu:
            showReaderActionMenu()
        case .nextPage:
            turnPageByTap(next: true, point: point)
        case .previousPage:
            turnPageByTap(next: false, point: point)
        case .nextChapter:
            openNextChapter()
        case .previousChapter:
            openPreviousChapter(toLast: false)
        case .previousParagraph:
            skipReadAloudParagraph(previous: true)
        case .nextParagraph:
            skipReadAloudParagraph(previous: false)
        case .addBookmark:
            addBookmarkAtCurrentPage()
        case .editContent:
            showContentEditor()
        case .replaceRule:
            showReplaceRuleMenu()
        case .chapterList:
            showChapterPicker()
        case .searchContent:
            showSearchMenu()
        case .syncProgress:
            syncReadingProgress()
        case .readAloud:
            toggleReadAloudPlayback()
        }
    }

    func addBookmarkAtCurrentPage() {
        guard let page = pages[safe: currentPageIndex] else {
            showToast("当前页面还没有可添加的书签")
            return
        }
        ReaderBookmarkCreationCoordinator.present(
            in: self,
            chapterIndex: chapterIndex,
            chapterPosition: page.characterOffset,
            text: page.pageText,
            trimsText: true
        )
    }

    private func showContentEditor() {
        contentEditingCoordinator.present()
    }

    func syncReadingProgress() {
        progressSyncCoordinator.synchronizeManually()
    }

    func showImagePreviewIfLoaded(at point: CGPoint) -> Bool {
        guard let target = imageTarget(at: point) else { return false }
        imageInteractionCoordinator.presentPreview(url: target.url, image: target.image, requestRule: target.requestRule)
        return true
    }

    func showImageActionMenuIfNeeded(at point: CGPoint) -> Bool {
        guard let target = imageTarget(at: point) else { return false }
        imageInteractionCoordinator.presentMenu(
            url: target.url, image: target.image, anchor: CGRect(origin: point, size: .zero), requestRule: target.requestRule)
        return true
    }

    private func imageTarget(at point: CGPoint) -> (url: URL, image: UIImage?, requestRule: String?)? {
        if isScrollPageMode {
            guard let target = scrollPagerView.imageTarget(at: view.convert(point, to: scrollPagerView)) else { return nil }
            currentPageIndex = target.pageIndex
            return (target.url, target.image, target.requestRule)
        }
        guard pages.indices.contains(currentPageIndex) else { return nil }
        let pointInRender = renderView.convert(point, from: view)
        guard let target = renderView.layoutTarget(at: pointInRender),
              let page = pages[safe: currentPageIndex + target.pageOffset],
              let fragment = page.imageFragment(at: target.layoutPoint),
              case let .remoteImage(url, _) = fragment.source
        else {
            return nil
        }
        return (url, renderView.loadedImage(for: url, pageOffset: target.pageOffset), fragment.requestRule)
    }

}

final class ReaderTapGestureRecognizer: UITapGestureRecognizer {
    var maximumMovement: CGFloat = 14
    var onTouchDown: (() -> Bool)?
    private(set) var didDismissSelectionOnTouch = false

    private var startPoint: CGPoint?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if startPoint == nil {
            startPoint = touches.first?.location(in: view)
            didDismissSelectionOnTouch = onTouchDown?() ?? false
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if exceededMovement(in: touches) {
            state = .failed
            return
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        // A coalesced final location can differ from the last delivered move.
        if exceededMovement(in: touches) {
            state = .failed
            return
        }
        super.touchesEnded(touches, with: event)
    }

    private func exceededMovement(in touches: Set<UITouch>) -> Bool {
        guard let startPoint, let point = touches.first?.location(in: view) else { return false }
        return Self.exceedsMovementLimit(from: startPoint, to: point, limit: maximumMovement)
    }

    static func exceedsMovementLimit(from start: CGPoint, to end: CGPoint, limit: CGFloat) -> Bool {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite,
            limit.isFinite, limit >= 0
        else { return true }
        return hypot(end.x - start.x, end.y - start.y) > limit
    }

    override func reset() {
        startPoint = nil
        // The two-finger fallback can finish after this recognizer fails and resets.
        // Replace the dismissal flag only when the next touch sequence begins.
        super.reset()
    }
}

private enum ReaderTapAction: Int {
    case disabled = -1
    case menu = 0
    case nextPage = 1
    case previousPage = 2
    case nextChapter = 3
    case previousChapter = 4
    case previousParagraph = 5
    case nextParagraph = 6
    case addBookmark = 7
    case editContent = 8
    case replaceRule = 9
    case chapterList = 10
    case searchContent = 11
    case syncProgress = 12
    case readAloud = 13
}
