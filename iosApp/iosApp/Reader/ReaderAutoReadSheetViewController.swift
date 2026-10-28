import UIKit

/// AutoReadDialog / dialog_auto_read.xml at Legado 5f5d314.
/// Present directly, with the reader's explicit day/night trait override.
final class ReaderAutoReadSheetViewController: UIViewController {
    private enum ClosingCommand {
        case chapterList
        case mainMenu
        case stop
    }

    var onClose: (() -> Void)?

    private var currentSpeed: Int
    private let onStop: () -> Void
    private let onOpenChapterList: () -> Void
    private let onOpenMainMenu: () -> Void
    private let onOpenPageAnimation: () -> Void
    private let onSpeedSelected: (Int) -> Void
    private let outsideControl = UIControl()
    private let panelView = UIView()
    private let scrollView = ReaderAutoReadDialogScrollView()
    private lazy var bodyView = ReaderAutoReadDialogBodyView(currentSpeed: currentSpeed)
    private var isPresentationReady = false
    private var isClosing = false
    private var isDismissalUnderway = false
    private var didNotifyClose = false
    private var isDetachCheckScheduled = false
    private var isOpeningPageAnimation = false
    private var appearanceGeneration = 0
    private var pendingCommand: ClosingCommand?

    init(
        currentSpeed: Int,
        onStop: @escaping () -> Void,
        onOpenChapterList: @escaping () -> Void,
        onOpenMainMenu: @escaping () -> Void,
        onOpenPageAnimation: @escaping () -> Void,
        onSpeedSelected: @escaping (Int) -> Void
    ) {
        self.currentSpeed = min(max(currentSpeed, 1), 120)
        self.onStop = onStop
        self.onOpenChapterList = onOpenChapterList
        self.onOpenMainMenu = onOpenMainMenu
        self.onOpenPageAnimation = onOpenPageAnimation
        self.onSpeedSelected = onSpeedSelected
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
        escape.discoverabilityTitle = L10n.Common.close
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.autoRead.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(close), for: .touchUpInside)
        panelView.backgroundColor = ReaderAutoReadDialogBodyView.panelBackgroundColor
        panelView.clipsToBounds = true
        panelView.accessibilityViewIsModal = true

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true

        view.addSubview(outsideControl)
        view.addSubview(panelView)
        panelView.addSubview(scrollView)
        scrollView.addSubview(bodyView)
        bodyView.onCommand = { [weak self] command in
            self?.handleCommand(command)
        }
        bodyView.onSpeedSelected = { [weak self] speed in
            guard let self, self.canInteract else { return }
            self.currentSpeed = speed
            self.onSpeedSelected(speed)
        }
        bodyView.updateFonts(compatibleWith: traitCollection)
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isDismissalUnderway = false
        appearanceGeneration += 1
        refreshAfterPresentation(generation: appearanceGeneration)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearanceGeneration += 1
        isPresentationReady = false
        updateInteraction()
        if isClosing || isBeingDismissed || presentingViewController?.isBeingDismissed == true {
            isDismissalUnderway = true
            transitionCoordinator?.animate(alongsideTransition: nil) { [self] context in
                if context.isCancelled {
                    isClosing = false
                    isDismissalUnderway = false
                    pendingCommand = nil
                    appearanceGeneration += 1
                    refreshAfterPresentation(generation: appearanceGeneration)
                } else {
                    scheduleDetachNotification()
                }
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isClosing || isDismissalUnderway || presentingViewController == nil {
            scheduleDetachNotification()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        bodyView.updateFonts(compatibleWith: traitCollection)
        view.setNeedsLayout()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        finish(command: nil)
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let width = view.bounds.width
        let availableHeight = max(0, view.bounds.height - view.safeAreaInsets.top)
        guard width > 0, availableHeight > 0 else { return }
        let contentHeight = bodyView.sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        let bottomInset = min(view.safeAreaInsets.bottom, availableHeight)
        let height = min(contentHeight + bottomInset, availableHeight)
        let viewportHeight = max(0, height - bottomInset)
        panelView.frame = CGRect(x: 0, y: view.bounds.maxY - height, width: width, height: height)
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        bodyView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = bodyView.bounds.size
        let needsScroll = contentHeight > viewportHeight
        if scrollView.isScrollEnabled != needsScroll { scrollView.isScrollEnabled = needsScroll }
        scrollView.showsVerticalScrollIndicator = needsScroll
        let offsetY = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight))
        if scrollView.contentOffset != CGPoint(x: 0, y: offsetY) {
            scrollView.contentOffset = CGPoint(x: 0, y: offsetY)
        }
    }

    /// Synchronize the real persisted value, including a failed-save rollback.
    /// A speed drag defers the visual update until its tracking session ends.
    func updateSpeed(_ speed: Int) {
        currentSpeed = min(max(speed, 1), 120)
        guard isViewLoaded else { return }
        bodyView.updateSpeed(currentSpeed)
    }

    private var canInteract: Bool {
        isPresentationReady && !isClosing && !isBeingDismissed && !isOpeningPageAnimation
            && presentedViewController == nil && viewIfLoaded?.window != nil
    }

    private func updateInteraction() {
        let enabled = canInteract
        outsideControl.isEnabled = enabled
        bodyView.setInteractionEnabled(enabled)
    }

    private func refreshAfterPresentation(generation: Int) {
        // UIKit may still report isBeingPresented inside viewDidAppear.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            guard let self, self.appearanceGeneration == generation,
                !self.isClosing, !self.didNotifyClose, self.viewIfLoaded?.window != nil
            else { return }
            if self.isBeingPresented {
                self.refreshAfterPresentation(generation: generation)
                return
            }
            guard !self.isBeingDismissed, self.presentedViewController == nil else { return }
            self.isPresentationReady = true
            self.updateInteraction()
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.bodyView.initialAccessibilityElement)
        }
    }

    @objc private func close() {
        finish(command: nil)
    }

    private func handleCommand(_ command: ReaderAutoReadDialogBodyView.Command) {
        switch command {
        case .chapterList: finish(command: .chapterList)
        case .mainMenu: finish(command: .mainMenu)
        case .stop: finish(command: .stop)
        case .settings: openPageAnimation()
        }
    }

    private func openPageAnimation() {
        guard canInteract else { return }
        isOpeningPageAnimation = true
        appearanceGeneration += 1
        updateInteraction()
        onOpenPageAnimation()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentedViewController == nil else { return }
            self.pageAnimationDidClose()
        }
    }

    func pageAnimationDidClose() {
        guard !isClosing, !isDismissalUnderway, !didNotifyClose,
            presentedViewController == nil, presentingViewController != nil, viewIfLoaded?.window != nil
        else { return }
        isOpeningPageAnimation = false
        appearanceGeneration += 1
        refreshAfterPresentation(generation: appearanceGeneration)
    }

    private func finish(command: ClosingCommand?) {
        guard canInteract, presentingViewController != nil else { return }
        isClosing = true
        isDismissalUnderway = true
        pendingCommand = command
        updateInteraction()
        resignFirstResponder()
        dismiss(animated: true) { [self] in
            scheduleDetachNotification()
        }
    }

    private func scheduleDetachNotification() {
        guard !didNotifyClose, !isDetachCheckScheduled else { return }
        isDetachCheckScheduled = true
        // Retain through detachment, including an external presenter dismissal.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in
            isDetachCheckScheduled = false
            guard !didNotifyClose else { return }
            guard presentingViewController == nil, parent == nil, viewIfLoaded?.window == nil else {
                if isClosing || isDismissalUnderway { scheduleDetachNotification() }
                return
            }
            didNotifyClose = true
            let command = pendingCommand
            pendingCommand = nil
            // The reader must process the command before restoring page state.
            switch command {
            case .chapterList: onOpenChapterList()
            case .mainMenu: onOpenMainMenu()
            case .stop: onStop()
            case nil: break
            }
            onClose?()
        }
    }
}

private final class ReaderAutoReadDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        // Scrolling may cancel a command button, never an in-progress speed drag.
        if view is UISlider { return false }
        return view is UIControl || super.touchesShouldCancel(in: view)
    }
}
