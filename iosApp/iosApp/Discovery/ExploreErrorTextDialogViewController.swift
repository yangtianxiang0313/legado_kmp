import UIKit

/// ExploreAdapter -> TextDialog("ERROR", kind.url), TEXT mode only, at Legado 5f5d314.
@MainActor
final class ExploreErrorTextDialogViewController: UIViewController {
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let toolbar = ExploreErrorTextToolbarView()
    private let textView = ExploreErrorTextView(frame: .zero, textContainer: nil)
    private let displayText: String
    private weak var owner: UIViewController?
    private weak var ownerWindow: UIWindow?
    private weak var ownerRoot: UIViewController?
    private weak var originPresenter: UIViewController?
    private var hasBoundPresenter = false
    private var isVisible = false
    private var isClosing = false
    private var sceneSuspended = false
    private var ownerInvalidated = false
    private var lastInteractionEnabled: Bool?

    init(text: String, owner: UIViewController) {
        displayText = Self.textForDisplay(text)
        self.owner = owner
        let window = owner.viewIfLoaded?.window
        ownerWindow = window
        ownerRoot = window?.rootViewController
        super.init(nibName: nil, bundle: nil)
        title = "ERROR"
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canClose else { return nil }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeDialog)),
            UIKeyCommand(input: ".", modifierFlags: .command, action: #selector(closeDialog)),
        ].map {
            $0.discoverabilityTitle = ExploreErrorTextStrings.close
            $0.wantsPriorityOverSystemBehavior = true
            return $0
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        textView.text = displayText
        textView.refreshTypography()
        updateInteraction()
        for name in [
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didActivateNotification, UIScene.didDisconnectNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(presentationStateChanged(_:)), name: name, object: nil)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !hasBoundPresenter {
            originPresenter = presentingViewController
            hasBoundPresenter = true
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        sceneSuspended = ownerWindow?.windowScene?.activationState != .foregroundActive
        reconcileOwner()
        // UIKit clears its presentation flags/coordinator after viewDidAppear returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible, !self.isClosing else { return }
            self.reconcileOwner()
            guard self.canClose, !self.ownerInvalidated else { return }
            if !self.textView.isFirstResponder { self.becomeFirstResponder() }
            UIAccessibility.post(notification: .screenChanged, argument: self.toolbar.titleLabel)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        updateInteraction()
        resignFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Resource qualifiers belong to the host viewport, not the 90%-height panel.
        toolbar.updateLayout(availableSize: view.bounds.size)
        reconcileOwner()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canClose else { return false }
        closeDialog()
        return true
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }), canClose {
            closeDialog()
        } else {
            super.pressesEnded(presses, with: event)
        }
    }

    private func configureViews() {
        let isEInk = UserDefaults.standard.string(forKey: "theme_mode") == "E_INK"
        view.backgroundColor = UIColor.black.withAlphaComponent(isEInk ? 0 : 0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "discovery.errorText.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(closeDialog), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.clipsToBounds = true
        dialogView.isAccessibilityElement = false
        dialogView.accessibilityViewIsModal = true
        toolbar.closeButton.addTarget(self, action: #selector(closeDialog), for: .touchUpInside)
        textView.isAccessibilityElement = true
        textView.accessibilityIdentifier = "discovery.errorText.text"

        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(toolbar)
        dialogView.addSubview(textView)
        view.accessibilityElements = [dialogView]
        dialogView.accessibilityElements = [toolbar, textView]
        for child in [outsideControl, dialogView, toolbar, textView] {
            child.translatesAutoresizingMaskIntoConstraints = false
        }
        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            outsideControl.topAnchor.constraint(equalTo: view.topAnchor),
            outsideControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outsideControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outsideControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            // MATCH_PARENT width; use iOS's available height without Android system-bar replicas.
            dialogView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dialogView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dialogView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            dialogView.heightAnchor.constraint(equalTo: safeArea.heightAnchor, multiplier: 0.9),
            toolbar.topAnchor.constraint(equalTo: dialogView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: dialogView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: dialogView.trailingAnchor),
            textView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            textView.bottomAnchor.constraint(equalTo: dialogView.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: dialogView.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: dialogView.safeAreaLayoutGuide.trailingAnchor),
        ])
    }

    private var sceneIsActive: Bool {
        guard let window = ownerWindow else { return false }
        return !sceneSuspended && window.isKeyWindow && !window.isHidden && window.alpha > 0.01
            && window.windowScene?.activationState == .foregroundActive
    }

    private var ownerIsCurrent: Bool {
        guard let owner, let window = ownerWindow, let root = ownerRoot,
            window.rootViewController === root, owner.isVisibleInNavigationStack
        else { return false }
        var candidate: UIViewController? = owner
        while let controller = candidate {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent,
                controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false,
                (controller.viewIfLoaded?.alpha ?? 0) > 0.01
            else { return false }
            if let navigation = controller.parent as? UINavigationController,
                navigation.topViewController !== controller
            {
                return false
            }
            if let tabs = controller.parent as? UITabBarController,
                tabs.selectedViewController !== controller
            {
                return false
            }
            candidate = controller.parent
        }
        return true
    }

    private var ownsTopPresentation: Bool {
        guard let presenter = originPresenter else { return false }
        // Never send dismiss to an owner that may now be presenting a different page.
        return presentingViewController === presenter && presenter.presentedViewController === self
            && presentedViewController == nil && !isBeingDismissed && !isBeingPresented
            && !presenter.isBeingDismissed && viewIfLoaded?.window === ownerWindow
            && transitionCoordinator == nil
    }

    private var canClose: Bool {
        isVisible && !isClosing && sceneIsActive && ownsTopPresentation
    }

    private func reconcileOwner() {
        guard hasBoundPresenter, isVisible, !isClosing else { return }
        // Inactive scenes pause input, not the immutable text/selection/scroll snapshot.
        if sceneIsActive, !ownerIsCurrent { ownerInvalidated = true }
        updateInteraction()
        if ownerInvalidated, canClose { dismissOwnedDialog(animated: false) }
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = canClose && !ownerInvalidated && ownerIsCurrent
        guard lastInteractionEnabled != enabled else { return }
        lastInteractionEnabled = enabled
        outsideControl.isEnabled = enabled
        toolbar.closeButton.isEnabled = enabled
        // Keep isSelectable unchanged: toggling it would discard native selection state.
        textView.isUserInteractionEnabled = enabled
        if !enabled {
            toolbar.closeButton.cancelPendingActivation()
            outsideControl.cancelTracking(with: nil)
        }
    }

    @objc private func presentationStateChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene {
            guard scene === ownerWindow?.windowScene else { return }
            if notification.name == UIScene.didDisconnectNotification { ownerInvalidated = true }
            sceneSuspended = notification.name != UIScene.didActivateNotification
        } else if let window = notification.object as? UIWindow {
            guard window === ownerWindow else { return }
            sceneSuspended =
                notification.name == UIWindow.didResignKeyNotification
                || window.windowScene?.activationState != .foregroundActive
        } else {
            return
        }
        reconcileOwner()
        if !sceneIsActive {
            textView.resignFirstResponder()
            resignFirstResponder()
        } else if canClose, !ownerInvalidated, !textView.isFirstResponder {
            becomeFirstResponder()
        }
    }

    @objc private func closeDialog() {
        guard canClose else { return }
        let animated =
            UserDefaults.standard.string(forKey: "theme_mode") != "E_INK"
            && !UIAccessibility.isReduceMotionEnabled
        dismissOwnedDialog(animated: animated)
    }

    private func dismissOwnedDialog(animated: Bool) {
        guard canClose else { return }
        isClosing = true
        updateInteraction()
        textView.resignFirstResponder()
        resignFirstResponder()
        // The root's existing present observer owns coverage recovery; no callback duplicates it.
        super.dismiss(animated: animated)
    }

    private static func textForDisplay(_ text: String) -> String {
        let limit = 32 * 1024
        guard text.utf16.count >= limit else { return text }
        // Kotlin String.length/substring count UTF-16, not Swift grapheme clusters.
        // Swift repairs a surrogate split at the boundary to a replacement character.
        return String(decoding: text.utf16.prefix(limit), as: UTF16.self) + "\n\n数据太大，无法全部显示…"
    }
}

private enum ExploreErrorTextStrings {
    static let close = NSLocalizedString(
        "discovery.error_text.close", value: "关闭", comment: "Legado TextDialog close action")
}

private final class ExploreErrorTextToolbarView: NavigationToolbarView {
    let titleLabel = AndroidExploreTextLabel()
    let closeButton = ExploreAndroidSelectableButton(frame: .zero)
    private var availableSize: CGSize = .zero
    private var toolbarHeight: NSLayoutConstraint?
    private var titleLeading: NSLayoutConstraint?
    private var actionTrailing: NSLayoutConstraint?

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        titleLabel.text = "ERROR"
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = [.header, .staticText]
        titleLabel.isAccessibilityElement = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        closeButton.feedback = .bounded
        closeButton.setTitle(ExploreErrorTextStrings.close, for: .normal)
        closeButton.isAccessibilityElement = true
        closeButton.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        closeButton.titleLabel?.adjustsFontForContentSizeCategory = false
        closeButton.titleLabel?.numberOfLines = 1
        closeButton.accessibilityIdentifier = "discovery.errorText.close"
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        for child in [titleLabel, closeButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        accessibilityElements = [titleLabel, closeButton]
        let height = heightAnchor.constraint(equalToConstant: 56)
        let leading = titleLabel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 20)
        let trailing = closeButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor)
        toolbarHeight = height
        titleLeading = leading
        actionTrailing = trailing
        NSLayoutConstraint.activate([
            height, leading, trailing,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -4),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            closeButton.topAnchor.constraint(equalTo: topAnchor),
            closeButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        refreshTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func updateLayout(availableSize: CGSize) {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0, self.availableSize != availableSize
        else { return }
        self.availableSize = availableSize
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
        titleLeading?.constant = padding + AndroidToolbarLayout.contentInsetStart(for: availableSize) + 4
        actionTrailing?.constant = -padding
        updateHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.legibilityWeight != traitCollection.legibilityWeight
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            refreshTypography()
        }
    }

    private func refreshTypography() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let actionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        closeButton.titleLabel?.font = actionFont
        let padding = AndroidExploreTextMetrics.padding(font: actionFont, scale: traitCollection.displayScale)
        closeButton.contentEdgeInsets = UIEdgeInsets(top: 4 + padding.top, left: 8, bottom: 4 + padding.bottom, right: 8)
        titleLabel.invalidateIntrinsicContentSize()
        updateHeight()
    }

    private func updateHeight() {
        guard let font = closeButton.titleLabel?.font else { return }
        let titlePadding = titleLabel.fontPadding
        let titleHeight =
            titleLabel.font.lineHeight + titlePadding.top + titlePadding.bottom
            + AndroidToolbarLayout.titleVerticalMargins
        let actionHeight = font.lineHeight + closeButton.contentEdgeInsets.top + closeButton.contentEdgeInsets.bottom
        // Base.V7.Widget.AppCompat.Toolbar minHeight=?actionBarSize: land 48/default 56/sw600 64.
        let height = ceil(max(AndroidToolbarLayout.minimumHeight(for: availableSize), titleHeight, actionHeight))
        if toolbarHeight?.constant != height { toolbarHeight?.constant = height }
    }
}

private final class ExploreErrorTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        backgroundColor = .clear
        textColor = AndroidReplicaTheme.secondaryText
        tintColor = AndroidReplicaTheme.accent
        isEditable = false
        isSelectable = true
        isScrollEnabled = true
        alwaysBounceVertical = false
        scrollsToTop = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        automaticallyAdjustsScrollIndicatorInsets = false
        contentInset = .zero
        self.textContainer.lineFragmentPadding = 0
        self.textContainer.widthTracksTextView = true
        self.textContainer.heightTracksTextView = false
        self.textContainer.lineBreakMode = .byWordWrapping
        adjustsFontForContentSizeCategory = false
        dataDetectorTypes = []
        allowsEditingTextAttributes = false
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func refreshTypography() {
        let nextFont = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        let padding = AndroidExploreTextMetrics.padding(font: nextFont, scale: traitCollection.displayScale)
        let inset = UIEdgeInsets(top: 12 + padding.top, left: 12, bottom: 12 + padding.bottom, right: 12)
        guard font != nextFont || textContainerInset != inset else { return }
        let selection = selectedRange
        let offset = contentOffset
        // Never reassign text on layout/rotation/appearance changes; UIKit owns selection and scrolling.
        if font != nextFont { font = nextFont }
        if textContainerInset != inset { textContainerInset = inset }
        if selectedRange != selection { selectedRange = selection }
        if contentOffset != offset { setContentOffset(offset, animated: false) }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.legibilityWeight != traitCollection.legibilityWeight
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            refreshTypography()
        }
    }
}
