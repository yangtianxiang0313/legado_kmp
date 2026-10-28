import UIKit

/// ReadBook.saveCurrentBookProgress / ReadBookActivity.restoreLastBookProcess at 5f5d314.
struct ReaderJumpHistory {
    struct Location: Equatable {
        let bookURL: String
        let chapterURL: String
        let chapterIndex: Int
        let position: Int
    }

    private(set) var location: Location?
    private(set) var restoreDecision: Bool?

    mutating func remember(_ location: Location) {
        guard self.location == nil, restoreDecision != false else { return }
        self.location = location
    }

    mutating func decide(_ restore: Bool) {
        restoreDecision = restore
        if !restore { location = nil }
    }

    mutating func clearLocation() { location = nil }

    mutating func bookDidChange(to bookURL: String) {
        if location?.bookURL != bookURL { location = nil }
    }
}

@MainActor
final class ReaderJumpNavigationCoordinator {
    private struct ChapterTarget: Equatable {
        let index: Int
        let bookURL: String
        let url: String
        let absoluteURL: String
    }

    @MainActor
    private struct RequestContext {
        let bookURL: String
        let boundBookURL: String?
        let origin: String?
        let chapterIndex: Int
        let chapterURL: String?
        let requestedIndex: Int?
        let actionIndex: Int
        let actionURL: String?
        let chapters: [ChapterTarget]

        init(_ reader: ReaderContainerViewController) {
            bookURL = reader.bookURL
            boundBookURL = reader.book?.bookUrl
            origin = reader.book?.origin
            chapterIndex = reader.chapterIndex
            chapterURL = reader.currentChapterURL
            requestedIndex = reader.chapterMessageCoordinator.requestedIndex
            actionIndex = reader.readerActionChapterIndex
            actionURL = reader.readerActionChapterURL
            chapters = Self.chapterTargets(in: reader)
        }

        func matches(_ reader: ReaderContainerViewController) -> Bool {
            bookURL == reader.bookURL && boundBookURL == reader.book?.bookUrl && origin == reader.book?.origin
                && chapterIndex == reader.chapterIndex && chapterURL == reader.currentChapterURL
                && requestedIndex == reader.chapterMessageCoordinator.requestedIndex
                && actionIndex == reader.readerActionChapterIndex && actionURL == reader.readerActionChapterURL
                && chapters == Self.chapterTargets(in: reader)
        }

        func resolve(_ target: ChapterTarget, in reader: ReaderContainerViewController) -> Int? {
            guard matches(reader), !target.url.isEmpty,
                let offset = reader.chapters.firstIndex(where: {
                    $0.url == target.url && $0.bookUrl == target.bookURL && $0.getAbsoluteURL() == target.absoluteURL
                }), offset == target.index
            else { return nil }
            // Resolve from the current URL mapping, never submit the old slider integer alone.
            let chapter = reader.chapters[offset]
            guard Int(chapter.index) == target.index else { return nil }
            return Int(chapter.index)
        }

        private static func chapterTargets(in reader: ReaderContainerViewController) -> [ChapterTarget] {
            reader.chapters.map {
                ChapterTarget(index: Int($0.index), bookURL: $0.bookUrl, url: $0.url, absoluteURL: $0.getAbsoluteURL())
            }
        }
    }

    private(set) var history = ReaderJumpHistory()
    private(set) var isShowingSearchResults = false
    private var sessionBookURL: String?
    private var hasConfirmedChapterSliderJump = false
    private weak var decisionDialog: ReaderRestoreProgressDialogViewController?
    private var decisionContext: ReaderJumpDecisionPresentation?
    private var preparedSearchLocation: ReaderJumpHistory.Location?

    func bookDidChange(to bookURL: String) {
        if let sessionBookURL, sessionBookURL != bookURL {
            hasConfirmedChapterSliderJump = false
            decisionContext?.invalidate()
        }
        sessionBookURL = bookURL
        if let location = history.location, location.bookURL != bookURL { isShowingSearchResults = false }
        history.bookDidChange(to: bookURL)
        if preparedSearchLocation?.bookURL != bookURL { preparedSearchLocation = nil }
    }

    func prepareSearch(in reader: ReaderContainerViewController) {
        preparedSearchLocation = currentLocation(in: reader)
    }

    func cancelPreparedSearch() { preparedSearchLocation = nil }

    func beginSearchJump(in reader: ReaderContainerViewController) {
        if let preparedSearchLocation, preparedSearchLocation.bookURL == reader.bookURL {
            history.remember(preparedSearchLocation)
        } else {
            remember(in: reader)
        }
        preparedSearchLocation = nil
        isShowingSearchResults = true
    }

    func endSearch() { isShowingSearchResults = false }

    func needsBackInterception(in reader: ReaderContainerViewController) -> Bool {
        isShowingSearchResults || (history.location?.bookURL == reader.bookURL && history.restoreDecision != false)
    }

    @discardableResult
    func handleBack(in reader: ReaderContainerViewController) -> Bool {
        bookDidChange(to: reader.bookURL)
        let closedSearch = isShowingSearchResults
        if closedSearch {
            isShowingSearchResults = false
            reader.searchMenu.setVisible(false, currentChapterIndex: reader.chapterIndex)
            reader.clearSearchSelection()
        }
        guard let location = history.location, history.restoreDecision != false else { return closedSearch }
        guard decisionDialog == nil, canPresent(in: reader) else { return true }
        if history.restoreDecision == true {
            restore(location, in: reader)
            return true
        }
        let request = RequestContext(reader)
        presentDecision(
            in: reader,
            isCurrent: { [weak self] reader in
                self?.history.location == location && reader.bookURL == location.bookURL && request.matches(reader)
            },
            onDecision: { [weak self] restore, reader in
                guard let self else { return }
                self.history.decide(restore)
                if restore { self.restore(location, in: reader) }
            })
        return true
    }

    func skipSliderValue(_ value: Int, behavior: ReaderProgressBehavior, in reader: ReaderContainerViewController) {
        bookDidChange(to: reader.bookURL)
        guard decisionDialog == nil, canPresent(in: reader) else {
            reader.updateMenuState()
            return
        }
        switch behavior {
        case .page:
            guard reader.canNavigateReaderPages, !reader.pages.isEmpty else { return }
            reader.currentPageIndex = min(max(value, 0), reader.pages.count - 1)
            reader.renderCurrentPage()
            reader.updateMenuState()
        case .chapter:
            let count = ReaderSimulatedReadingPolicy.count(in: reader)
            guard count > 0 else { return }
            let target = min(max(value, 0), count - 1)
            guard target != reader.readerActionChapterIndex else {
                reader.updateMenuState()
                return
            }
            if hasConfirmedChapterSliderJump {
                jump(to: target, in: reader)
                return
            }
            let request = RequestContext(reader)
            let chapter = request.chapters[target]
            reader.updateMenuState()
            guard request.resolve(chapter, in: reader) != nil else { return }
            presentDecision(
                in: reader,
                title: L10n.Reader.chapterSliderConfirmTitle, message: L10n.Reader.chapterSliderConfirmMessage,
                isCurrent: { request.resolve(chapter, in: $0) != nil },
                onDecision: { [weak self] confirmed, reader in
                    guard let self, confirmed, let index = request.resolve(chapter, in: reader) else { return }
                    self.hasConfirmedChapterSliderJump = true
                    self.jump(to: index, in: reader)
                })
        }
    }

    private func presentDecision(
        in reader: ReaderContainerViewController,
        title: String = "提醒", message: String = "是否恢复到跳转前的阅读进度？",
        isCurrent: @escaping (ReaderContainerViewController) -> Bool,
        onDecision: @escaping (Bool, ReaderContainerViewController) -> Void
    ) {
        let context = ReaderJumpDecisionPresentation(reader: reader)
        let dialog = ReaderRestoreProgressDialogViewController(title: title, message: message) {
            [weak self, weak reader] confirmed in
            guard let self, let reader, self.decisionContext === context,
                isCurrent(reader), context.canDeliver(confirmed: confirmed)
            else { return }
            onDecision(confirmed, reader)
        }
        dialog.canConfirm = { [weak self, weak reader, weak dialog] in
            guard let self, let reader, let dialog,
                self.decisionContext === context, self.decisionDialog === dialog
            else { return false }
            guard isCurrent(reader) else {
                context.invalidate()
                return false
            }
            return context.canConfirm(dialog: dialog)
        }
        dialog.onClose = { [weak self, weak reader, weak dialog] in
            context.finish()
            if self?.decisionDialog === dialog {
                self?.decisionDialog = nil
                self?.decisionContext = nil
            }
            // Cancellation, stale confirmation and external dismissal all restore the latest progress.
            reader?.updateMenuState()
        }
        dialog.overrideUserInterfaceStyle = reader.readMenu.overflowInterfaceStyle
        decisionContext = context
        decisionDialog = dialog
        reader.present(dialog, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func remember(in reader: ReaderContainerViewController) {
        guard let location = currentLocation(in: reader) else { return }
        history.bookDidChange(to: reader.bookURL)
        history.remember(location)
    }

    private func currentLocation(in reader: ReaderContainerViewController) -> ReaderJumpHistory.Location? {
        guard let chapterURL = reader.currentChapterURL, !chapterURL.isEmpty,
            reader.canNavigateReaderPages
        else { return nil }
        return .init(
            bookURL: reader.bookURL, chapterURL: chapterURL,
            chapterIndex: reader.chapterIndex, position: reader.currentCharacterOffset())
    }

    private func jump(to chapter: Int, in reader: ReaderContainerViewController) {
        remember(in: reader)
        reader.stageProgress(immediate: true)
        reader.loadChapter(index: chapter, restorePosition: 0)
    }

    private func restore(_ location: ReaderJumpHistory.Location, in reader: ReaderContainerViewController) {
        guard reader.bookURL == location.bookURL,
            let chapter = reader.chapters.first(where: { $0.url == location.chapterURL })
        else {
            history.clearLocation()
            reader.showToast("目录已变化，无法恢复跳转前的阅读位置")
            return
        }
        history.clearLocation()
        reader.setMenuVisible(false)
        reader.searchMenu.setVisible(false, currentChapterIndex: reader.chapterIndex)
        reader.clearSearchSelection()
        reader.stageProgress(immediate: true)
        // The chapter loader retains this position for retry if cached/network loading fails.
        reader.loadChapter(index: Int(chapter.index), restorePosition: location.position)
    }

    private func canPresent(in reader: ReaderContainerViewController) -> Bool {
        ReaderJumpDecisionPresentation.canUse(reader)
    }
}

/// Guards selection while the owned modal is attached, then navigation only after detach.
@MainActor
private final class ReaderJumpDecisionPresentation: NSObject {
    private weak var reader: ReaderContainerViewController?
    private weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var dialog: UIViewController?
    private var deliveryMonitor: Timer?
    private var selectedYes = false
    private var isInvalidated = false

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        window = reader.viewIfLoaded?.window
        scene = window?.windowScene
        root = window?.rootViewController
        super.init()
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeHiddenNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presentationInterrupted(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func invalidate() {
        isInvalidated = true
        deliveryMonitor?.invalidate()
        deliveryMonitor = nil
    }

    func finish() {
        invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    func canConfirm(dialog: UIViewController) -> Bool {
        guard isCurrent, let reader, dialog.presentedViewController == nil,
            Self.canUse(reader, allowing: dialog)
        else {
            if selectedYes { invalidate() }
            return false
        }
        if dialog.presentingViewController != nil {
            guard dialog.presentingViewController?.presentedViewController === dialog,
                dialog.viewIfLoaded?.window === window,
                !dialog.isBeingPresented, !dialog.isBeingDismissed, !dialog.isMovingFromParent
            else { return false }
            selectedYes = true
            monitorDelivery(of: dialog)
        } else {
            guard selectedYes, dialog.parent == nil, dialog.viewIfLoaded?.window == nil,
                dialog.viewIfLoaded?.superview == nil
            else { return false }
        }
        return true
    }

    func canDeliver(confirmed: Bool) -> Bool {
        guard isCurrent, let reader, !confirmed || selectedYes else { return false }
        return Self.canUse(reader)
    }

    private var isCurrent: Bool {
        guard !isInvalidated, let reader, let window, let scene, let root else { return false }
        return reader.viewIfLoaded?.window === window && window.windowScene === scene
            && window.rootViewController === root
    }

    private func monitorDelivery(of dialog: UIViewController) {
        self.dialog = dialog
        guard deliveryMonitor == nil else { return }
        let timer = Timer(
            timeInterval: 0.05, target: DeliveryMonitorTarget(owner: self),
            selector: #selector(DeliveryMonitorTarget.tick(_:)), userInfo: nil, repeats: true)
        deliveryMonitor = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func checkPendingDelivery() {
        // A child modal can delay actual detach until it closes; that must not revive an earlier Yes.
        guard isCurrent, let reader, let dialog, dialog.presentedViewController == nil,
            Self.canUse(reader, allowing: dialog)
        else {
            invalidate()
            return
        }
    }

    static func canUse(_ reader: ReaderContainerViewController, allowing dialog: UIViewController? = nil) -> Bool {
        guard reader.navigationController?.topViewController === reader,
            UIApplication.shared.applicationState == .active,
            let window = reader.viewIfLoaded?.window, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            let root = window.rootViewController
        else { return false }
        var current: UIViewController? = reader
        var expectedPresentation: UIViewController?
        var lastController: UIViewController?
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController,
                presented !== expectedPresentation, presented !== dialog
            {
                return false
            }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            lastController = controller
            if let parent = controller.parent {
                expectedPresentation = nil
                current = parent
            } else {
                expectedPresentation = controller
                current = controller.presentingViewController
            }
        }
        return lastController === root
    }

    @objc private func presentationInterrupted(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== self.scene { return }
        if let window = notification.object as? UIWindow, window !== self.window { return }
        // A background trip before choosing must not poison a still-open dialog on return.
        if selectedYes { invalidate() }
    }

    @MainActor
    private final class DeliveryMonitorTarget: NSObject {
        private weak var owner: ReaderJumpDecisionPresentation?

        init(owner: ReaderJumpDecisionPresentation) { self.owner = owner }

        @objc func tick(_ timer: Timer) {
            guard let owner else {
                timer.invalidate()
                return
            }
            owner.checkPendingDelivery()
        }
    }
}
