import UIKit

/// TipConfigDialog / dialog_tip_config.xml at Legado 5f5d314.
/// Use the presenter's explicit reader day/night palette, not the app window's palette.
@MainActor
final class AndroidReaderTipConfigSheetViewController: UIViewController {
    private struct LayoutState: Equatable {
        let bounds: CGRect
        let safeFrame: CGRect
        let category: UIContentSizeCategory
        let contentSize: CGSize
    }

    private final class SelectionSession {
        weak var dialog: UIViewController?
        var isValid = true
        var hasSubmitted = false
    }

    private var values: ReaderTipValues
    private let onChange: (ReaderTipChange) -> Void
    private let onFinish: () async throws -> Void
    private let outsideControl = UIControl()
    private let panelView = UIView()
    private let scrollView = ReaderTipScrollView()
    private lazy var bodyView = ReaderTipBodyView(values: values)
    private var lastLayoutState: LayoutState?
    private var isClosing = false
    private var selectionSession: SelectionSession?
    private var interactionEpoch = UUID()
    private var closeAttempt: UUID?
    private var pendingSaveError: Error?
    private var hasBoundSource = false
    private var sourceWasRemoved = false
    private var isForegroundSuspended = false
    private weak var sourcePresenter: UIViewController?
    private weak var sourceController: UIViewController?
    private weak var sourceWindow: UIWindow?
    private weak var sourceRootController: UIViewController?
    private var sourceBookBinding: ReaderAppearanceBookBinding?

    init(
        values: ReaderTipValues,
        onChange: @escaping (ReaderTipChange) -> Void,
        onFinish: @escaping () async throws -> Void
    ) {
        self.values = values
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canInteract, selectionSession == nil else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
        escape.discoverabilityTitle = L10n.Common.close
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        bodyView.onChange = { [weak self] change in self?.commit(change) }
        bodyView.onSelect = { [weak self] selection in self?.openSelection(selection) }
        observeForegroundChanges()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteDidChange), name: .androidReplicaThemeDidChange, object: nil)
        applyPalette()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        bindSourceIfNeeded()
        if let sourcePresenter { overrideUserInterfaceStyle = sourcePresenter.traitCollection.userInterfaceStyle }
        applyPalette()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        dismissInvalidSelection()
        restoreInfoFocus()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isPresentationBeingRemoved else { return }
        sourceWasRemoved = true
        interactionEpoch = UUID()
        invalidateSelection()
        resignFirstResponder()
        let epoch = interactionEpoch
        transitionCoordinator?.animate(alongsideTransition: nil) { [weak self] context in
            guard let self, context.isCancelled, self.interactionEpoch == epoch else { return }
            self.sourceWasRemoved = false
            self.restoreInfoFocus()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil {
            sourceWasRemoved = true
            interactionEpoch = UUID()
            invalidateSelection()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyPalette()
        presentedViewController?.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        view.setNeedsLayout()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract, selectionSession == nil else { return false }
        close()
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }

        // MATCH_PARENT keeps Android's default 16dp window-background inset.
        let width = max(1, min(safeFrame.width, view.bounds.width - 32))
        let contentWidth = max(width, ReaderTipBodyView.minimumContentWidth)
        let contentHeight = max(
            1,
            ceil(
                bodyView.sizeThatFits(
                    CGSize(width: contentWidth, height: .greatestFiniteMagnitude)
                ).height))
        let state = LayoutState(
            bounds: view.bounds, safeFrame: safeFrame,
            category: traitCollection.preferredContentSizeCategory,
            contentSize: CGSize(width: contentWidth, height: contentHeight))
        // Scrolling and slider updates must not rebuild the body or reset its viewport.
        guard state != lastLayoutState else { return }
        lastLayoutState = state

        let height = min(safeFrame.height, contentHeight)
        panelView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)
        scrollView.frame = panelView.bounds
        bodyView.frame = CGRect(origin: .zero, size: state.contentSize)
        scrollView.contentSize = state.contentSize
        // Leave the recognizer enabled even when the body fits; changing it can cancel a pan.
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else { return }
        let offset = CGPoint(
            x: min(max(0, scrollView.contentOffset.x), max(0, contentWidth - width)),
            y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "readerAppearance.tip.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(close), for: .touchUpInside)

        panelView.layer.cornerRadius = 3
        panelView.clipsToBounds = true
        panelView.accessibilityViewIsModal = true

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "readerAppearance.tip.scrollView"

        view.addSubview(outsideControl)
        view.addSubview(panelView)
        panelView.addSubview(scrollView)
        scrollView.addSubview(bodyView)
    }

    private func applyPalette() {
        // BaseDialogFragment uses ThemeStore.backgroundColor(), including custom day/night colors.
        panelView.backgroundColor = ReaderPaletteColor.theme(
            "backgroundColor", traits: traitCollection,
            fallback: ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0xFF21_2121 : 0xFFF5_F5F5)
        bodyView.apply(palette: ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection))
    }

    @objc private func themePaletteDidChange() {
        applyPalette()
    }

    private func commit(_ change: ReaderTipChange) {
        guard canInteract, let change = change.normalized, values.apply(change) else { return }
        bodyView.update(values: values)
        view.setNeedsLayout()
        onChange(change)
    }

    private func openSelection(_ selection: ReaderTipSelection) {
        guard canInteract, selectionSession == nil else { return }
        if let slot = selection.slot {
            let options = ReaderTipValues.slotOptions
            presentChoices(items: options.map(\.title)) { [weak self] index in
                guard options.indices.contains(index) else { return }
                self?.commit(.slot(slot, options[index].value))
            }
            return
        }
        switch selection {
        case .headerMode:
            presentChoices(items: ["状态栏显示时隐藏", "显示", "隐藏"]) { [weak self] index in
                self?.commit(.headerMode(Int32(index)))
            }
        case .footerMode:
            presentChoices(items: ["显示", "隐藏"]) { [weak self] index in
                self?.commit(.footerMode(Int32(index)))
            }
        case .tipColor:
            presentChoices(items: ["跟随内容", "自定义"]) { [weak self] index in
                if index == 0 {
                    self?.commit(.tipColor(nil))
                } else {
                    self?.openColorPicker(for: .tipColor)
                }
            }
        case .dividerColor:
            presentChoices(items: ["默认", "跟随内容", "自定义"]) { [weak self] index in
                switch index {
                case 0: self?.commit(.dividerColor(nil))
                case 1: self?.commit(.dividerColor(ReaderTipValues.followTextColor))
                default: self?.openColorPicker(for: .dividerColor)
                }
            }
        default:
            break
        }
    }

    private func presentChoices(items: [String], onSelect: @escaping (Int) -> Void) {
        guard canInteract, selectionSession == nil else { return }
        let session = SelectionSession()
        selectionSession = session
        let controller = ReaderStyleChoiceDialogViewController(titleText: "", items: items) { [weak self] index in
            guard let self, self.accepts(session), self.presentedViewController == nil,
                items.indices.contains(index)
            else { return }
            session.hasSubmitted = true
            // Release only this choice before opening its custom-color successor.
            self.selectionSession = nil
            onSelect(index)
            self.restoreInfoFocus()
        }
        controller.canSelect = { [weak self] in self?.accepts(session) == true }
        controller.onClose = { [weak self] in self?.finishSelection(session) }
        presentSelection(controller, session: session)
    }

    private func openColorPicker(for selection: ReaderTipSelection) {
        guard canInteract, selectionSession == nil else { return }
        switch selection {
        case .tipColor, .dividerColor: break
        default: return
        }
        let session = SelectionSession()
        selectionSession = session
        // TipConfigDialog never calls setColor; TYPE_CUSTOM starts at the builder's black default.
        let picker = ReaderColorPickerDialogViewController(
            color: .black,
            onClose: { [weak self] in self?.finishSelection(session) },
            onSelect: { [weak self] color in
                guard let self, self.accepts(session), self.presentedViewController == nil,
                    let hex = self.opaqueHex(for: color)
                else { return }
                session.hasSubmitted = true
                switch selection {
                case .tipColor:
                    if self.values.tipColorHex != hex { self.commit(.tipColor(hex)) }
                case .dividerColor:
                    if self.values.tipDividerColorHex != hex { self.commit(.dividerColor(hex)) }
                default:
                    break
                }
            })
        // TYPE_CUSTOM keeps edits local; the picker checks this both before and after detachment.
        picker.canSubmit = { [weak self] in self?.accepts(session) == true }
        presentSelection(picker, session: session)
    }

    private func presentSelection(_ controller: UIViewController, session: SelectionSession) {
        session.dialog = controller
        controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        present(controller, animated: true) { [weak self] in
            guard let self, self.selectionSession === session else { return }
            if !self.isSourceCurrent(allowing: controller) { session.isValid = false }
            self.dismissInvalidSelection()
        }
    }

    private func accepts(_ session: SelectionSession) -> Bool {
        selectionSession === session && session.isValid && !session.hasSubmitted && !isClosing
            && isSourceCurrent(allowing: session.dialog)
    }

    private func finishSelection(_ session: SelectionSession) {
        guard selectionSession === session else { return }
        selectionSession = nil
        restoreInfoFocus()
    }

    private func invalidateSelection() {
        selectionSession?.isValid = false
        dismissInvalidSelection()
    }

    private func dismissInvalidSelection() {
        guard let session = selectionSession, !session.isValid, let dialog = session.dialog,
            presentedViewController === dialog, dialog.presentingViewController === self,
            dialog.presentedViewController == nil, !dialog.isBeingPresented, !dialog.isBeingDismissed,
            !isPresentationBeingRemoved
        else { return }
        // Never dismiss a detached old dialog: UIKit could forward that call to a newer presentation.
        dialog.dismiss(animated: false)
    }

    private func opaqueHex(for color: UIColor) -> String? {
        let resolved = color.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            guard resolved.getWhite(&white, alpha: &alpha) else { return nil }
            red = white
            green = white
            blue = white
        }
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        // UIColor(hex:) accepts #RRGGBB or Android #AARRGGBB, never #RRGGBBAA.
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    @objc private func close() {
        guard canInteract, selectionSession == nil, closeAttempt == nil else { return }
        let attempt = UUID()
        let epoch = interactionEpoch
        closeAttempt = attempt
        pendingSaveError = nil
        setClosing(true)
        // Keep this controller alive until its pending writes finish; no parent-owned weak task.
        Task { @MainActor [self] in
            do {
                try await onFinish()
                guard closeAttempt == attempt else { return }
                closeAttempt = nil
                guard interactionEpoch == epoch, isSourceCurrent() else {
                    setClosing(false)
                    restoreInfoFocus()
                    return
                }
                resignFirstResponder()
                dismiss(animated: true)
            } catch {
                guard closeAttempt == attempt else { return }
                closeAttempt = nil
                setClosing(false)
                pendingSaveError = error
                restoreInfoFocus()
            }
        }
    }

    private func setClosing(_ closing: Bool) {
        isClosing = closing
        outsideControl.isEnabled = !closing
        bodyView.isUserInteractionEnabled = !closing
        scrollView.isUserInteractionEnabled = !closing
    }

    private func showSaveErrorIfNeeded() {
        guard canInteract, selectionSession == nil, let error = pendingSaveError else { return }
        pendingSaveError = nil
        let epoch = interactionEpoch
        let alert = UIAlertController(
            title: L10n.Common.loadFailedTitle, message: error.userFacingMessage, preferredStyle: .alert)
        alert.overrideUserInterfaceStyle = .unspecified
        alert.addAction(
            UIAlertAction(title: L10n.Common.retry, style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, self.interactionEpoch == epoch,
                    self.isSourceCurrent(allowing: alert), self.presentedViewController === alert,
                    alert.presentingViewController === self
                else { return }
                // Wait for this alert, never an untracked presentation, before retrying the write barrier.
                alert.dismiss(animated: true) { [weak self] in
                    guard let self, self.interactionEpoch == epoch else { return }
                    self.close()
                }
            })
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .cancel))
        present(alert, animated: true)
    }

    private var canInteract: Bool { !isClosing && isSourceCurrent() }

    private func restoreInfoFocus() {
        let epoch = interactionEpoch
        DispatchQueue.main.async { [weak self] in
            guard let self, self.interactionEpoch == epoch,
                self.canInteract, self.selectionSession == nil
            else { return }
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.bodyView.accessibilityFocusElement)
            self.showSaveErrorIfNeeded()
        }
    }

    private func bindSourceIfNeeded() {
        guard !hasBoundSource, let presenter = presentingViewController else { return }
        hasBoundSource = true
        sourcePresenter = presenter
        sourceController = currentSource(from: presenter)
        sourceWindow = presenter.viewIfLoaded?.window
        sourceRootController = sourceWindow?.rootViewController
        var current = sourceController
        while let controller = current {
            if let reader = controller as? ReaderContainerViewController {
                sourceBookBinding = ReaderAppearanceBookBinding(reader: reader)
                break
            }
            current = controller.parent ?? controller.presentingViewController
        }
    }

    private func currentSource(from presenter: UIViewController) -> UIViewController {
        var source = presenter
        while true {
            if let navigation = source as? UINavigationController, let top = navigation.topViewController {
                source = top
            } else if let tabs = source as? UITabBarController, let selected = tabs.selectedViewController {
                source = selected
            } else {
                return source
            }
        }
    }

    private var isPresentationBeingRemoved: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func isSourceCurrent(allowing dialog: UIViewController? = nil) -> Bool {
        guard hasBoundSource, !sourceWasRemoved, !isForegroundSuspended,
            UIApplication.shared.applicationState == .active,
            let presenter = sourcePresenter, presentingViewController === presenter,
            let source = sourceController, currentSource(from: presenter) === source,
            !source.isBeingPresented, !source.isBeingDismissed, !source.isMovingFromParent,
            let window = sourceWindow, !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            let root = sourceRootController, window.rootViewController === root,
            viewIfLoaded?.window === window, presenter.viewIfLoaded?.window === window,
            source.viewIfLoaded?.window === window, sourceBookBinding?.isCurrent != false
        else { return false }

        var current: UIViewController? = self
        var expectedPresentation = dialog
        var lastController: UIViewController?
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController, presented !== expectedPresentation { return false }
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

    private func observeForegroundChanges() {
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(suspendInteraction(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(resumeInteraction(_:)), name: name, object: nil)
        }
    }

    private func belongsToSource(_ notification: Notification) -> Bool {
        guard let scene = notification.object as? UIScene else { return true }
        return scene === sourceWindow?.windowScene
    }

    @objc private func suspendInteraction(_ notification: Notification) {
        guard belongsToSource(notification) else { return }
        isForegroundSuspended = true
        interactionEpoch = UUID()
        invalidateSelection()
        resignFirstResponder()
    }

    @objc private func resumeInteraction(_ notification: Notification) {
        guard belongsToSource(notification) else { return }
        isForegroundSuspended = false
        dismissInvalidSelection()
        restoreInfoFocus()
    }
}

private final class ReaderTipScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UISlider { return false }
        return view is UIControl || super.touchesShouldCancel(in: view)
    }
}
