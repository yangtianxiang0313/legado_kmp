import UIKit
import shared

/// DictDialog.kt / dialog_dict.xml at Legado 5f5d314.
/// The host supplies real, cancellable dictionary operations and owns URL routing.
@MainActor
final class ReaderDictionaryDialogViewController: UIViewController, UITextViewDelegate {
    /// Side-effect-free Reader identity gate, independent of scene/presentation availability.
    var canSubmit: (() -> Bool)? {
        didSet {
            guard isViewLoaded else { return }
            if canSubmit?() == false { suspendRequest() }
            updateInteraction()
            resumeRequestIfNeeded()
        }
    }

    private enum Request {
        case rules
        case definition
    }

    private enum State {
        case loading
        case definition
        case emptyRules
        case emptyDefinition
        case failure(String, Request)
    }

    private let word: String
    private let loadRules: () async throws -> [DictRule]
    private let lookup: (DictRule, String) async throws -> String
    private let onOpenURL: ((URL) -> Void)?
    private var rules: [DictRule] = []
    private var selectedIndex: Int?
    private var state: State = .loading
    private var requestTask: Task<Void, Never>?
    private var generation = UUID()
    private var pendingRequest: Request? = .rules
    private var activeRequest: Request?
    private var importedDefinition: NSAttributedString?
    private var isVisible = false
    private var isClosing = false
    private var isDeliveringLink = false
    private var isSceneSuspended = false
    private var pendingDefinitionOffset: CGPoint?

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let viewport = ReaderEffectiveReplaceScrollView()
    private let contentView = UIView()
    private let tabs = ReaderDictionaryDialogTabStrip()
    private let bodyView = UIView()
    private let definitionView = UITextView()
    private let statusScrollView = ReaderEffectiveReplaceScrollView()
    private let statusLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let loadingView = ReaderDictionaryDialogLoadingView()

    init(
        word: String,
        loadRules: @escaping () async throws -> [DictRule],
        lookup: @escaping (DictRule, String) async throws -> String,
        onOpenURL: ((URL) -> Void)? = nil
    ) {
        self.word = word
        self.loadRules = loadRules
        self.lookup = lookup
        self.onOpenURL = onOpenURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        requestTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(close))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        let back = UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(close))
        back.discoverabilityTitle = L10n.Reader.backAction
        return [escape, back]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyAppearance()
        show(.loading)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIScene.willDeactivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate(_:)), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        isClosing = false
        isSceneSuspended = view.window?.windowScene?.activationState != .foregroundActive
        updateInteraction()
        becomeFirstResponder()
        if word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            close()
            return
        }
        resumeRequestIfNeeded()
        UIAccessibility.post(notification: .screenChanged, argument: tabs.isHidden ? loadingView : tabs)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        tabs.cancelPendingTracking()
        if isLeavingPresentation { isClosing = true }
        suspendRequest()
        updateInteraction()
        resignFirstResponder()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        // A host may present a URL destination over this dialog, then dismiss only that child.
        if presentedViewController != nil, !isLeavingPresentation {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        isClosing = true
        isVisible = false
        suspendRequest()
        updateInteraction()
        super.dismiss(animated: flag, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard isPresentationInteractive else { return false }
        close()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyAppearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        // MATCH_PARENT window, then abc_dialog_material_background's four 16dp insets.
        let available = safeFrame.insetBy(
            dx: min(16, max(0, (safeFrame.width - 1) / 2)),
            dy: min(16, max(0, (safeFrame.height - 1) / 2)))
        guard available.width > 0, available.height > 0 else { return }
        let width = available.width
        let headerHeight = ReaderDictionaryDialogTabStrip.height + ReaderDictionaryDialogTabStrip.bottomPadding
        let naturalBodyHeight = bodyHeight(for: width)
        let height = min(available.height, headerHeight + naturalBodyHeight)
        dialogView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        viewport.frame = dialogView.bounds

        // Only exceptionally short windows scroll the tabs too; normally the body alone scrolls.
        let scrollsChrome = headerHeight + min(60, naturalBodyHeight) > height
        let bodyHeight = scrollsChrome ? min(60, naturalBodyHeight) : max(0, height - headerHeight)
        let contentHeight = headerHeight + bodyHeight
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        tabs.frame = CGRect(x: 0, y: 0, width: width, height: ReaderDictionaryDialogTabStrip.height)
        bodyView.frame = CGRect(x: 0, y: headerHeight, width: width, height: bodyHeight)
        viewport.contentSize = contentView.bounds.size
        viewport.isScrollEnabled = scrollsChrome
        let offset = CGPoint(x: 0, y: min(max(0, viewport.contentOffset.y), max(0, contentHeight - height)))
        if viewport.contentOffset != offset { viewport.contentOffset = offset }

        let savedDefinitionOffset = pendingDefinitionOffset ?? definitionView.contentOffset
        definitionView.frame = bodyView.bounds
        definitionView.layoutIfNeeded()
        let textHeight = ceil(definitionView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        definitionView.isScrollEnabled = textHeight > bodyHeight + 0.5
        let definitionOffset = CGPoint(
            x: 0, y: min(max(0, savedDefinitionOffset.y), max(0, textHeight - bodyHeight)))
        if definitionView.contentOffset != definitionOffset {
            definitionView.setContentOffset(definitionOffset, animated: false)
        }
        if case .definition = state { pendingDefinitionOffset = nil }
        statusScrollView.frame = bodyView.bounds
        layoutStatus(width: width)
        // XML constrains RotateLoading below the tabs, not to the body's vertical center.
        loadingView.frame = CGRect(x: (width - 60) / 2, y: 0, width: 60, height: 60)
        updateInteraction()
    }

    private func configureViews() {
        // BaseDialogFragment retains the platform/AppCompat default 0.6 window dim.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.dictionary.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(close), for: .touchUpInside)
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        bodyView.clipsToBounds = true
        for scrollView in [viewport, statusScrollView] {
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.alwaysBounceVertical = false
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.scrollsToTop = false
            scrollView.delaysContentTouches = false
        }
        tabs.onSelect = { [weak self] index in
            guard let self, self.canInteract else { return }
            self.loadDefinition(at: index, preservingPosition: false)
        }
        tabs.canInteract = { [weak self] in self?.canInteract == true }
        viewport.panGestureRecognizer.addTarget(self, action: #selector(viewportPanChanged(_:)))
        definitionView.delegate = self
        definitionView.isEditable = false
        definitionView.isSelectable = true
        definitionView.dataDetectorTypes = []
        definitionView.backgroundColor = .clear
        definitionView.textContainerInset = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        definitionView.textContainer.lineFragmentPadding = 0
        definitionView.textContainer.widthTracksTextView = true
        definitionView.contentInsetAdjustmentBehavior = .never
        definitionView.alwaysBounceVertical = false
        definitionView.scrollsToTop = false
        definitionView.accessibilityIdentifier = "reader.dictionary.definition"
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.textColor = AndroidReplicaTheme.secondaryText
        statusLabel.accessibilityIdentifier = "reader.dictionary.status"
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 8
        configuration.title = L10n.Common.retry
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)
        retryButton.configuration = configuration
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        retryButton.accessibilityIdentifier = "reader.dictionary.retry"
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(viewport)
        viewport.addSubview(contentView)
        contentView.addSubview(tabs)
        contentView.addSubview(bodyView)
        bodyView.addSubview(definitionView)
        bodyView.addSubview(statusScrollView)
        statusScrollView.addSubview(statusLabel)
        statusScrollView.addSubview(retryButton)
        bodyView.addSubview(loadingView)
    }

    private func applyAppearance() {
        dialogView.backgroundColor = AndroidReplicaTheme.background
        tabs.applyAppearance()
        statusLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
        definitionView.tintColor = AndroidReplicaTheme.accent
        definitionView.linkTextAttributes = [
            .foregroundColor: AndroidReplicaTheme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        if let importedDefinition {
            let selection = definitionView.selectedRange
            let offset = definitionView.contentOffset
            definitionView.attributedText = ReaderDictionaryDialogHTMLRenderer.styled(importedDefinition, traits: traitCollection)
            definitionView.selectedRange = selection
            definitionView.setContentOffset(offset, animated: false)
            pendingDefinitionOffset = offset
        }
        var configuration = retryButton.configuration
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, weight: 500, compatibleWith: traitCollection)
        configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = font
            return attributes
        }
        configuration?.baseForegroundColor = AndroidReplicaTheme.accent
        retryButton.configuration = configuration
        loadingView.setNeedsLayout()
        view.setNeedsLayout()
    }

    private func bodyHeight(for width: CGFloat) -> CGFloat {
        switch state {
        case .loading, .definition:
            // inVisible() keeps the XML's 60dp loader in measurement after lookup.
            let textHeight = ceil(definitionView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
            return max(60, textHeight)
        case .emptyRules, .emptyDefinition, .failure:
            return statusHeight(for: width)
        }
    }

    private func statusHeight(for width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 32)
        let labelHeight = ceil(statusLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let retryHeight = retryButton.isHidden ? 0 : 8 + retrySize(for: textWidth).height
        return max(60, 32 + labelHeight + retryHeight)
    }

    private func retrySize(for width: CGFloat) -> CGSize {
        let size = retryButton.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: min(width, max(44, size.width)), height: max(44, size.height))
    }

    private func layoutStatus(width: CGFloat) {
        let textWidth = max(1, width - 32)
        let labelHeight = ceil(statusLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        statusLabel.frame = CGRect(x: 16, y: 16, width: textWidth, height: labelHeight)
        let retrySize = retrySize(for: textWidth)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        retryButton.frame = CGRect(
            x: rtl ? width - 16 - retrySize.width : 16, y: statusLabel.frame.maxY + 8,
            width: retrySize.width, height: retrySize.height)
        statusScrollView.contentSize = CGSize(width: width, height: statusHeight(for: width))
        statusScrollView.isScrollEnabled = statusScrollView.contentSize.height > statusScrollView.bounds.height
        let offset = CGPoint(
            x: 0,
            y: min(
                max(0, statusScrollView.contentOffset.y),
                max(0, statusScrollView.contentSize.height - statusScrollView.bounds.height)))
        if statusScrollView.contentOffset != offset { statusScrollView.setContentOffset(offset, animated: false) }
    }

    private func show(_ newState: State) {
        state = newState
        tabs.isHidden = false
        definitionView.isHidden = true
        statusScrollView.isHidden = true
        retryButton.isHidden = true
        loadingView.setLoading(false)
        switch newState {
        case .loading:
            // DictDialog retains the last definition while RotateLoading is visible.
            definitionView.isHidden = importedDefinition == nil
            loadingView.setLoading(canInteract)
        case .definition:
            definitionView.isHidden = false
        case .emptyRules:
            statusLabel.text = NSLocalizedString(
                "reader.dictionary.empty_rules", value: "暂无已启用词典规则", comment: "No enabled dictionary rules")
            statusScrollView.isHidden = false
        case .emptyDefinition:
            statusLabel.text = NSLocalizedString(
                "reader.dictionary.empty_definition", value: "暂无释义", comment: "Empty dictionary result")
            statusScrollView.isHidden = false
        case .failure(let message, _):
            statusLabel.text = message
            statusScrollView.isHidden = false
            retryButton.isHidden = false
        }
        statusScrollView.setContentOffset(.zero, animated: false)
        view.setNeedsLayout()
        updateInteraction()
    }

    private var canInteract: Bool {
        isPresentationInteractive && canSubmit?() != false
    }

    private var isPresentationInteractive: Bool {
        isVisible && !isClosing && !isBeingDismissed && !isSceneSuspended
            && !isLeavingPresentation && presentedViewController == nil && !isDeliveringLink
            && UIApplication.shared.applicationState == .active && viewIfLoaded?.window?.isKeyWindow == true
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private func accepts(_ token: UUID) -> Bool {
        token == generation && canSubmit?() != false && isVisible && !isClosing && !isLeavingPresentation
            && !isSceneSuspended && UIApplication.shared.applicationState == .active
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = canInteract
        outsideControl.isEnabled = isPresentationInteractive
        tabs.setControlsEnabled(enabled)
        retryButton.isEnabled = enabled
        definitionView.isUserInteractionEnabled = enabled
        if case .loading = state { loadingView.setLoading(enabled) }
    }

    private func invalidateRequest() {
        generation = UUID()
        requestTask?.cancel()
        requestTask = nil
        activeRequest = nil
    }

    private func loadRuleList() {
        guard canInteract else {
            pendingRequest = .rules
            return
        }
        invalidateRequest()
        tabs.cancelPendingTracking()
        pendingRequest = nil
        activeRequest = .rules
        let token = generation
        let loader = loadRules
        show(.loading)
        requestTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let loaded = try await loader()
                try Task.checkCancellation()
                guard let self, self.accepts(token) else { return }
                self.requestTask = nil
                self.activeRequest = nil
                let previousRule = self.selectedIndex.flatMap { self.rules[safe: $0] }
                let refreshed = loaded.enumerated().filter { $0.element.enabled }.sorted {
                    if $0.element.sortNumber == $1.element.sortNumber { return $0.offset < $1.offset }
                    return $0.element.sortNumber < $1.element.sortNumber
                }.map(\.element)
                // Reordering/reloading must preserve the selected rule, not an old numeric index.
                let retainedIndex = previousRule.flatMap { previous in
                    refreshed.firstIndex {
                        $0.name == previous.name && $0.urlRule == previous.urlRule && $0.showRule == previous.showRule
                    }
                }
                guard self.accepts(token), self.canSubmit?() != false else { return }
                self.rules = refreshed
                self.tabs.setTitles(refreshed.map(\.name), selecting: retainedIndex ?? 0)
                if self.rules.isEmpty {
                    self.selectedIndex = nil
                    self.importedDefinition = nil
                    self.definitionView.attributedText = nil
                    self.show(.emptyRules)
                } else {
                    self.loadDefinition(at: retainedIndex ?? 0, preservingPosition: retainedIndex != nil)
                }
            } catch {
                guard !Task.isCancelled, let self, self.accepts(token) else { return }
                self.requestTask = nil
                self.activeRequest = nil
                self.show(.failure(error.userFacingMessage, .rules))
            }
        }
    }

    private func loadDefinition(at index: Int, preservingPosition: Bool = true) {
        guard canSubmit?() != false, rules.indices.contains(index) else { return }
        selectedIndex = index
        tabs.select(index)
        invalidateRequest()
        if !preservingPosition {
            pendingDefinitionOffset = .zero
            definitionView.setContentOffset(.zero, animated: false)
            viewport.setContentOffset(.zero, animated: false)
        }
        show(.loading)
        guard canInteract else {
            pendingRequest = .definition
            return
        }
        pendingRequest = nil
        activeRequest = .definition
        let token = generation
        let rule = rules[index]
        let lookup = lookup
        let word = word
        requestTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let html = try await lookup(rule, word)
                try Task.checkCancellation()
                guard self?.accepts(token) == true else { return }
                let imported = try ReaderDictionaryDialogHTMLRenderer.render(html)
                try Task.checkCancellation()
                // The system HTML importer can pump the run loop: check again after importing.
                guard let self, self.accepts(token), self.canSubmit?() != false, self.selectedIndex == index else { return }
                self.requestTask = nil
                self.activeRequest = nil
                self.importedDefinition = imported
                self.pendingDefinitionOffset = preservingPosition ? self.definitionView.contentOffset : .zero
                self.definitionView.attributedText = ReaderDictionaryDialogHTMLRenderer.styled(imported, traits: self.traitCollection)
                self.show(imported.length == 0 ? .emptyDefinition : .definition)
            } catch {
                guard !Task.isCancelled, let self, self.accepts(token), self.selectedIndex == index else { return }
                self.requestTask = nil
                self.activeRequest = nil
                self.show(.failure(error.userFacingMessage, .definition))
            }
        }
    }

    private func suspendRequest() {
        if requestTask != nil { pendingRequest = activeRequest ?? (selectedIndex == nil ? .rules : .definition) }
        invalidateRequest()
        loadingView.setLoading(false)
    }

    private func resumeRequestIfNeeded() {
        guard canInteract, let pendingRequest else { return }
        switch pendingRequest {
        case .rules: loadRuleList()
        case .definition:
            if let selectedIndex { loadDefinition(at: selectedIndex) }
        }
    }

    @objc private func retry() {
        guard canInteract, case .failure(_, let request) = state else { return }
        switch request {
        case .rules: loadRuleList()
        case .definition:
            if let selectedIndex { loadDefinition(at: selectedIndex) }
        }
    }

    @objc private func close() {
        guard isPresentationInteractive else { return }
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        isSceneSuspended = true
        tabs.cancelPendingTracking()
        suspendRequest()
        updateInteraction()
    }

    @objc private func sceneDidActivate(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        isSceneSuspended = false
        updateInteraction()
        resumeRequestIfNeeded()
    }

    @objc private func viewportPanChanged(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began || recognizer.state == .changed { tabs.cancelPendingTracking() }
    }

    func textView(
        _ textView: UITextView, shouldInteractWith url: URL, in _: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        guard textView === definitionView, canInteract, interaction == .invokeDefaultAction,
            case .definition = state, let onOpenURL
        else { return false }
        isDeliveringLink = true
        updateInteraction()
        defer {
            isDeliveringLink = false
            updateInteraction()
        }
        onOpenURL(url)
        // Also suppress native long-press previews and automatic URL opening.
        return false
    }
}
