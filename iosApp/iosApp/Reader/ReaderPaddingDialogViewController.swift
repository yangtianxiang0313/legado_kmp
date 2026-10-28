import UIKit

/// PaddingConfigDialog / dialog_read_padding.xml at Legado 5f5d314.
/// The presenter supplies the reader's explicit day/night trait override.
final class ReaderPaddingDialogViewController: UIViewController {
    var canInteract: (() -> Bool)?
    private struct LayoutState: Equatable {
        let bounds: CGRect
        let safeFrame: CGRect
        let category: UIContentSizeCategory
        let minimumContentWidth: CGFloat
        let isEInk: Bool
    }

    private var draft: ReaderPaddingValues
    private let onChange: (ReaderPaddingValues) -> Void
    private let onFinish: () async throws -> Void
    private let outsideControl = UIControl()
    private let panelView = UIView()
    private let scrollView = ReaderPaddingScrollView()
    private lazy var bodyView = ReaderPaddingBodyView(values: draft)
    private var isClosing = false
    private var lastLayoutState: LayoutState?
    private var isPresentationVisible = false
    private weak var presentationScene: UIWindowScene?
    private var isSceneActive = false

    init(
        values: ReaderPaddingValues,
        onChange: @escaping (ReaderPaddingValues) -> Void,
        onFinish: @escaping () async throws -> Void
    ) {
        draft = values
        self.onChange = onChange
        self.onFinish = onFinish
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
        escape.discoverabilityTitle = L10n.Common.close
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        configureChanges()
        bodyView.canInteract = { [weak self] in self?.canUseControls == true }
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(sceneActivationChanged(_:)), name: name, object: nil)
        }
        refreshInteractionAvailability()
        applyPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyPalette()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isPresentationVisible = true
        presentationScene = view.window?.windowScene
        isSceneActive = presentationScene?.activationState == .foregroundActive
        refreshInteractionAvailability()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: bodyView.initialAccessibilityElement)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isPresentationVisible = false
        refreshInteractionAvailability()
    }

    @objc private func sceneActivationChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === presentationScene else { return }
        isSceneActive = notification.name == UIScene.didActivateNotification
        refreshInteractionAvailability()
    }

    private var canUseControls: Bool {
        isPresentationVisible && isSceneActive && !isClosing && !isBeingPresented && !isBeingDismissed
            && presentedViewController == nil && canInteract?() != false
    }

    func refreshInteractionAvailability() {
        guard isViewLoaded else { return }
        let enabled = isPresentationVisible && isSceneActive && !isClosing && canInteract?() != false
        bodyView.setInteractionEnabled(enabled)
        bodyView.isUserInteractionEnabled = enabled
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyPalette()
        view.setNeedsLayout()
    }

    override func accessibilityPerformEscape() -> Bool {
        close()
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }
        let layoutState = LayoutState(
            bounds: view.bounds, safeFrame: safeFrame,
            category: traitCollection.preferredContentSizeCategory,
            minimumContentWidth: bodyView.minimumContentWidth, isEInk: ReaderPaletteColor.isEInk)
        // A pan can trigger layout; do not reset the viewport or its recognizer during that pan.
        guard layoutState != lastLayoutState else { return }
        lastLayoutState = layoutState

        // Android's 0.9 window still has its default 16dp background inset per side.
        let width = max(1, min(safeFrame.width, view.bounds.width * 0.9) - 32)
        // BaseDialogFragment adds 2dp root padding around centered E-Ink dialogs.
        let borderInset: CGFloat = ReaderPaletteColor.isEInk ? 2 : 0
        let viewportWidth = max(1, width - borderInset * 2)
        let contentWidth = max(viewportWidth, bodyView.minimumContentWidth)
        let contentHeight = bodyView.sizeThatFits(
            CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
        ).height
        let height = min(safeFrame.height, contentHeight + borderInset * 2)
        let viewportHeight = max(1, height - borderInset * 2)
        panelView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)
        scrollView.frame = CGRect(
            x: borderInset, y: borderInset, width: viewportWidth, height: viewportHeight)
        bodyView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scrollView.contentSize = bodyView.bounds.size
        let canScroll = contentHeight > viewportHeight || contentWidth > viewportWidth
        if scrollView.isScrollEnabled != canScroll { scrollView.isScrollEnabled = canScroll }
        let offset = CGPoint(
            x: min(max(0, scrollView.contentOffset.x), max(0, contentWidth - viewportWidth)),
            y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
    }

    private func configureViews() {
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "readerAppearance.padding.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(close), for: .touchUpInside)

        panelView.clipsToBounds = true
        panelView.accessibilityViewIsModal = true

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.bounces = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.canCancelContentTouches = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.accessibilityIdentifier = "readerAppearance.padding.scrollView"

        view.addSubview(outsideControl)
        view.addSubview(panelView)
        panelView.addSubview(scrollView)
        scrollView.addSubview(bodyView)
    }

    private func configureChanges() {
        bodyView.onFieldChange = { [weak self] field, value in
            guard let self, self.canUseControls, (self.draft.values[field] ?? 0) != value else { return }
            self.draft.values[field] = value
            self.onChange(self.draft)
            self.view.setNeedsLayout()
        }
        bodyView.onHeaderLineChange = { [weak self] value in
            guard let self, self.canUseControls, self.draft.showHeaderLine != value else { return }
            self.draft.showHeaderLine = value
            self.onChange(self.draft)
            self.view.setNeedsLayout()
        }
        bodyView.onFooterLineChange = { [weak self] value in
            guard let self, self.canUseControls, self.draft.showFooterLine != value else { return }
            self.draft.showFooterLine = value
            self.onChange(self.draft)
            self.view.setNeedsLayout()
        }
    }

    private func applyPalette() {
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        panelView.backgroundColor = ReaderPaletteColor.theme(
            "backgroundColor", traits: traitCollection, fallback: isNight ? 0xFF21_2121 : 0xFFF5_F5F5)
        let isEInk = ReaderPaletteColor.isEInk
        panelView.layer.cornerRadius = isEInk ? 2 : 3
        panelView.layer.borderWidth = isEInk ? 1 : 0
        panelView.layer.borderColor = isEInk ? ReaderPaletteColor.argb(0x6666_6666).cgColor : nil
        scrollView.indicatorStyle = isNight ? .white : .black
        bodyView.apply(palette: ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection))
    }

    @objc private func close() {
        guard !isClosing, !isBeingPresented, !isBeingDismissed,
            presentingViewController != nil, presentedViewController == nil
        else { return }
        setClosing(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.onFinish()
                self.resignFirstResponder()
                let presenter = self.presentingViewController
                let window = self.view.window
                let canRestoreFocus = self.canInteract
                self.dismiss(animated: !ReaderPaletteColor.isEInk && !UIAccessibility.isReduceMotionEnabled) {
                    [weak presenter, weak window] in
                    guard let presenter, let window, window.isKeyWindow,
                        window.windowScene?.activationState == .foregroundActive,
                        presenter.viewIfLoaded?.window === window, presenter.presentedViewController == nil,
                        canRestoreFocus?() != false
                    else { return }
                    presenter.becomeFirstResponder()
                    UIAccessibility.post(notification: .screenChanged, argument: nil)
                }
            } catch {
                self.setClosing(false)
                self.presentError(error)
            }
        }
    }

    private func setClosing(_ closing: Bool) {
        isClosing = closing
        outsideControl.isEnabled = !closing
        refreshInteractionAvailability()
        scrollView.isUserInteractionEnabled = !closing
    }
}

private final class ReaderPaddingScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UISlider { return false }
        return view is UIControl || super.touchesShouldCancel(in: view)
    }
}
