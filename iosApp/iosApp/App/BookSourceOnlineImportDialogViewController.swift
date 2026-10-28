import UIKit
import shared

/// BookSourceActivity.showImportDialog / dialog_edit_text.xml at Legado 5f5d314.
/// Import resolution belongs to the caller; this UI passes the complete input unchanged.
/// Only confirmed URL history is persisted here, separately from imported sources.
/// onDismiss runs once after dismissal, before a successful onReady, so the host can clear its modal gate.
@MainActor
final class BookSourceOnlineImportDialogViewController: UIViewController, UITextViewDelegate, UIGestureRecognizerDelegate {
    private enum Phase: Equatable {
        case waiting
        case active
        case preparing(UUID)
        case closing(UUID)
        case finished
    }

    private let initialText: String
    private var onSubmit: ((String) async throws -> SourceImportPreview)?
    private var onReady: ((SourceImportPreview) -> Void)?
    private var onDismiss: (() -> Void)?
    private var phase: Phase = .waiting
    private var prepareTask: Task<Void, Never>?
    private var pendingPreview: SourceImportPreview?
    private var preparedPreview: SourceImportPreview?
    private var isPresentationSuspended = false
    private weak var returnPresenter: UIViewController?
    private weak var returnWindow: UIWindow?
    private var ownsDismissalCompletion = false
    private var externalCompletionScheduled = false
    private var isVisible = false
    private var keyboardFrame: CGRect?
    private var needsRevealCaret = false
    private var needsRevealError = false
    private var historySuppressed = false
    private let urlHistory = BookSourceOnlineImportURLHistory()

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let scrollView = BookSourceOnlineImportScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let entryView = BookSourceOnlineImportInputView()
    private let errorLabel = UILabel()
    private let historyView = BookSourceOnlineImportHistoryView()
    private let footerView = UIView()
    private let cancelControl = BookSourceOnlineImportActionControl(
        title: L10n.Common.cancel, identifier: "sourceManagement.importUrl.cancel")
    private let confirmControl = BookSourceOnlineImportActionControl(
        title: L10n.Common.ok, identifier: "sourceManagement.importUrl.confirm")

    init(
        initialText: String = "",
        onSubmit: @escaping (String) async throws -> SourceImportPreview,
        onReady: @escaping (SourceImportPreview) -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        self.initialText = initialText
        self.onSubmit = onSubmit
        self.onReady = onReady
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
        title = L10n.SourceManagement.importOnlineAction
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        prepareTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard acceptsInput else { return nil }
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyAppearance()
        updateInteraction()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance), name: .androidReplicaThemeDidChange, object: nil)
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didActivateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard phase != .finished else { return }
        if phase == .waiting { phase = .active }
        isVisible = true
        // A preloaded dialog may still be marked as presenting during viewDidAppear.
        DispatchQueue.main.async { [weak self] in self?.refreshVisiblePresentation() }
    }

    private func refreshVisiblePresentation() {
        guard isVisible, phase != .finished else { return }
        updateInteraction()
        deliverPreparedPreview()
        guard canUsePresentation else { return }
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        resignFirstResponder()
        if isLeavingPresentation, !isClosing, phase != .finished {
            let id = beginClosing(preview: nil)
            externalCompletionScheduled =
                transitionCoordinator?.animate(alongsideTransition: nil) {
                    [weak self] context in
                    guard let self else { return }
                    self.externalCompletionScheduled = false
                    if context.isCancelled {
                        self.resumeCancelledDismissal(id: id)
                    } else {
                        self.finishDismissal(id: id, mayDeliverPreview: false)
                    }
                } ?? false
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard case .closing(let id) = phase, !ownsDismissalCompletion, !externalCompletionScheduled else { return }
        finishDismissal(id: id, mayDeliverPreview: false)
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController != nil, !isLeavingPresentation {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        guard phase != .finished else {
            completion?()
            return
        }
        let id = beginClosing(preview: nil)
        ownsDismissalCompletion = true
        super.dismiss(animated: flag) { [self] in
            finishDismissal(id: id, mayDeliverPreview: false)
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canUsePresentation else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyAppearance()
        needsRevealCaret = entryView.textView.isFirstResponder
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableFrame
        guard available.width > 0, available.height > 0 else { return }
        let width = min(available.width, view.bounds.width * dialogWidthFraction)
        let footerHeight = layoutActions(width: width)
        let contentHeight = layoutForm(width: width, maximumHeight: max(0, available.height - footerHeight))
        let height = min(available.height, contentHeight + footerHeight)
        dialogView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2,
            width: width, height: height)

        // Normally keep actions outside the scrolling form. In an extremely short AX window,
        // scroll everything rather than clipping actions or forcing the field over the footer.
        let pinsFooter = height >= footerHeight + min(48, entryView.bounds.height)
        let footerParent = pinsFooter ? dialogView : contentView
        if footerView.superview !== footerParent { footerParent.addSubview(footerView) }
        footerView.frame = CGRect(
            x: 0, y: pinsFooter ? height - footerHeight : contentHeight, width: width, height: footerHeight)
        let scrollHeight = pinsFooter ? height - footerHeight : height
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: scrollHeight)
        let scrollContentHeight = contentHeight + (pinsFooter ? 0 : footerHeight)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: scrollContentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = scrollContentHeight > scrollHeight
        let offset = CGPoint(
            x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, scrollContentHeight - scrollHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        contentView.accessibilityElements =
            pinsFooter
            ? [titleLabel, entryView, errorLabel, historyView]
            : [titleLabel, entryView, errorLabel, historyView, footerView]
        dialogView.accessibilityElements = pinsFooter ? [scrollView, footerView] : [scrollView]
        entryView.layoutIfNeeded()
        revealPendingContent()
    }

    private var availableFrame: CGRect {
        var frame = view.safeAreaLayoutGuide.layoutFrame
        if let keyboardFrame, let window = view.window {
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inView = view.convert(inWindow, from: window)
            let intersection = frame.intersection(inView)
            if !intersection.isNull, intersection.width > 0 {
                frame.size.height = max(1, intersection.minY - frame.minY)
            }
        }
        let inset = min(16, max(0, (frame.height - 1) / 2))
        return frame.insetBy(dx: 0, dy: inset)
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func layoutForm(width: CGFloat, maximumHeight: CGFloat) -> CGFloat {
        let titleWidth = max(1, width - 48)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
            ).height)
        titleLabel.frame = CGRect(x: 24, y: 20, width: titleWidth, height: titleHeight)
        let inputWidth = max(1, width - 32)
        let inputHeight = entryView.sizeThatFits(CGSize(width: inputWidth, height: 0)).height
        entryView.frame = CGRect(x: 16, y: titleLabel.frame.maxY + 12, width: inputWidth, height: inputHeight)
        var bottom = entryView.frame.maxY
        if !errorLabel.isHidden {
            let errorWidth = max(1, width - 40)
            let errorHeight = ceil(
                errorLabel.sizeThatFits(
                    CGSize(width: errorWidth, height: .greatestFiniteMagnitude)
                ).height)
            errorLabel.frame = CGRect(x: 20, y: bottom + 4, width: errorWidth, height: errorHeight)
            bottom = errorLabel.frame.maxY
        }
        if !historyView.isHidden {
            let historyHeight = historyView.height(maximum: maximumHeight - bottom - 8)
            historyView.frame = CGRect(x: 16, y: bottom, width: inputWidth, height: historyHeight)
            bottom = historyView.frame.maxY
        }
        return bottom + 8
    }

    private func layoutActions(width: CGFloat) -> CGFloat {
        let availableWidth = max(1, width - 16)
        let cancelWidth = cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        if cancelWidth + confirmWidth + 8 <= availableWidth {
            let height = max(
                cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: 0)).height,
                confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: 0)).height)
            let isRTL = dialogView.effectiveUserInterfaceLayoutDirection == .rightToLeft
            cancelControl.frame = CGRect(
                x: isRTL ? 8 + confirmWidth + 8 : width - 8 - confirmWidth - 8 - cancelWidth,
                y: 4, width: cancelWidth, height: height)
            confirmControl.frame = CGRect(
                x: isRTL ? 8 : width - 8 - confirmWidth, y: 4, width: confirmWidth, height: height)
            return height + 8
        }
        let cancelHeight = cancelControl.sizeThatFits(CGSize(width: availableWidth, height: 0)).height
        let confirmHeight = confirmControl.sizeThatFits(CGSize(width: availableWidth, height: 0)).height
        cancelControl.frame = CGRect(x: 8, y: 4, width: availableWidth, height: cancelHeight)
        confirmControl.frame = CGRect(x: 8, y: 4 + cancelHeight, width: availableWidth, height: confirmHeight)
        return cancelHeight + confirmHeight + 8
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "sourceManagement.importUrl.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceManagement.importUrl.title"
        entryView.textView.text = initialText
        entryView.textView.delegate = self
        let historyTap = UITapGestureRecognizer(target: self, action: #selector(historyInputTapped))
        historyTap.delegate = self
        historyTap.cancelsTouchesInView = false
        historyTap.delaysTouchesEnded = false
        entryView.textView.addGestureRecognizer(historyTap)
        historyView.onSelect = { [weak self] value in self?.selectHistory(value) }
        historyView.onDelete = { [weak self] value in
            guard let self, self.phase == .active, self.canUsePresentation else { return }
            self.urlHistory.remove(value)
            self.refreshHistory(resetScroll: false)
            UIAccessibility.post(
                notification: .layoutChanged, argument: self.historyView.isHidden ? self.entryView.textView : nil)
        }
        errorLabel.numberOfLines = 0
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.accessibilityIdentifier = "sourceManagement.importUrl.error"
        errorLabel.isHidden = true
        footerView.accessibilityIdentifier = "sourceManagement.importUrl.actions"
        footerView.accessibilityElements = [cancelControl, confirmControl]
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.scrollsToTop = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "sourceManagement.importUrl.form"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(submit), for: .touchUpInside)
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        for item in [titleLabel, entryView, errorLabel, historyView] { contentView.addSubview(item) }
        for control in [cancelControl, confirmControl] { footerView.addSubview(control) }
    }

    @objc private func applyAppearance() {
        let palette = ReaderTocPalette(traits: traitCollection)
        dialogView.backgroundColor = palette.background
        footerView.backgroundColor = palette.background
        titleLabel.textColor = palette.primaryText
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 20, weight: .medium), compatibleWith: traitCollection)
        errorLabel.textColor = palette.accent
        errorLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(
            for: .systemFont(ofSize: 13), compatibleWith: traitCollection)
        entryView.apply(traits: traitCollection)
        historyView.apply(traits: traitCollection)
        cancelControl.apply(traits: traitCollection)
        confirmControl.apply(traits: traitCollection)
        view.setNeedsLayout()
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool {
        phase == .active && canUsePresentation
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        entryView.refreshState()
        historySuppressed = false
        urlHistory.reload()
        refreshHistory()
        needsRevealCaret = true
        view.setNeedsLayout()
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        entryView.refreshState()
        refreshHistory()
    }

    func textViewDidChange(_ textView: UITextView) {
        entryView.refreshState()
        entryView.showsError = false
        errorLabel.text = nil
        errorLabel.isHidden = true
        needsRevealError = false
        historySuppressed = false
        refreshHistory()
        needsRevealCaret = textView.isFirstResponder
        view.setNeedsLayout()
    }

    @objc private func historyInputTapped() {
        guard phase == .active, canUsePresentation else { return }
        historySuppressed = false
        urlHistory.reload()
        refreshHistory()
        needsRevealCaret = entryView.textView.isFirstResponder
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer.view === entryView.textView
    }

    private func refreshHistory(resetScroll: Bool = true) {
        let textView = entryView.textView
        let canSuggest =
            phase == .active && isVisible && textView.isFirstResponder
            && textView.markedTextRange == nil && !historySuppressed
        historyView.update(values: canSuggest ? urlHistory.matching(textView.text ?? "") : [], resetScroll: resetScroll)
        view.setNeedsLayout()
    }

    private func selectHistory(_ value: String) {
        guard phase == .active, canUsePresentation else { return }
        let textView = entryView.textView
        guard let range = textView.textRange(from: textView.beginningOfDocument, to: textView.endOfDocument) else { return }
        textView.replace(range, withText: value)
        textView.selectedRange = NSRange(location: (textView.text ?? "").utf16.count, length: 0)
        textViewDidChange(textView)
        historySuppressed = true
        refreshHistory()
        needsRevealCaret = textView.isFirstResponder
        UIAccessibility.post(notification: .layoutChanged, argument: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.isFirstResponder, textView.selectedTextRange?.isEmpty == true else { return }
        needsRevealCaret = true
        view.setNeedsLayout()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        phase == .active && canUsePresentation
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard acceptsInput, isVisible else { return }
        keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        needsRevealCaret = entryView.textView.isFirstResponder
        view.setNeedsLayout()
        let duration =
            (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
            options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
        ) { self.view.layoutIfNeeded() }
    }

    @objc private func keyboardFrameDidChange() {
        guard acceptsInput, isVisible else { return }
        needsRevealCaret = entryView.textView.isFirstResponder
        view.setNeedsLayout()
    }

    private func revealPendingContent() {
        if needsRevealError, !errorLabel.isHidden {
            needsRevealError = false
            let rect = errorLabel.convert(errorLabel.bounds, to: contentView).insetBy(dx: 0, dy: -8)
            scrollView.scrollRectToVisible(
                CGRect(
                    x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, scrollView.bounds.height)),
                animated: false)
            return
        }
        guard needsRevealCaret else { return }
        needsRevealCaret = false
        let textView = entryView.textView
        guard textView.isFirstResponder, let selection = textView.selectedTextRange else { return }
        textView.layoutIfNeeded()
        let caret = textView.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        var revealRect = textView.convert(caret, to: contentView).insetBy(dx: 0, dy: -8)
        if !historyView.isHidden {
            let firstRow = CGRect(
                x: historyView.frame.minX, y: historyView.frame.minY,
                width: historyView.bounds.width, height: historyView.firstRowHeight)
            let combined = revealRect.union(firstRow)
            // Reveal a real suggestion with the caret when both fit, without covering either.
            if combined.height <= scrollView.bounds.height { revealRect = combined }
        }
        scrollView.scrollRectToVisible(revealRect, animated: false)
    }

    private var acceptsInput: Bool {
        switch phase {
        case .active, .preparing: return true
        case .waiting, .closing, .finished: return false
        }
    }

    private var isClosing: Bool {
        if case .closing = phase { return true }
        return false
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private var canUsePresentation: Bool {
        guard acceptsInput, isVisible, !isPresentationSuspended,
            UIApplication.shared.applicationState == .active, !isBeingPresented, !isLeavingPresentation,
            presentedViewController == nil, transitionCoordinator?.isInteractive != true,
            let window = viewIfLoaded?.window, let presenter = presentingViewController
        else { return false }
        return isCurrentPresenter(presenter, in: window)
    }

    private func isCurrentPresenter(_ presenter: UIViewController, in window: UIWindow) -> Bool {
        guard !window.isHidden, window.isKeyWindow,
            UIApplication.shared.applicationState == .active, window.windowScene?.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window
        else { return false }
        var controller: UIViewController? = presenter
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return false }
            controller = current.parent ?? current.presentingViewController
        }
        return true
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let active = canUsePresentation
        let editing = phase == .active && active
        outsideControl.isEnabled = active
        cancelControl.isEnabled = active
        confirmControl.isEnabled = editing
        entryView.textView.isEditable = editing
        entryView.textView.isSelectable = active
        scrollView.isUserInteractionEnabled = active
        if case .preparing = phase { confirmControl.setBusy(active) } else { confirmControl.setBusy(false) }
        entryView.refreshState()
        refreshHistory(resetScroll: false)
    }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== viewIfLoaded?.window?.windowScene { return }
        isPresentationSuspended =
            notification.name == UIApplication.willResignActiveNotification
            || notification.name == UIScene.willDeactivateNotification
        updateInteraction()
        deliverPreparedPreview()
    }

    @objc private func submit() {
        guard phase == .active, canUsePresentation, let onSubmit else { return }
        let payload = entryView.textView.text ?? ""
        urlHistory.record(payload)
        let id = UUID()
        preparedPreview = nil
        phase = .preparing(id)
        errorLabel.isHidden = true
        errorLabel.text = nil
        entryView.showsError = false
        view.endEditing(true)
        updateInteraction()
        view.setNeedsLayout()
        prepareTask = Task { @MainActor [weak self] in
            do {
                let preview = try await onSubmit(payload)
                guard !Task.isCancelled else { return }
                self?.prepared(preview, id: id)
            } catch {
                guard !Task.isCancelled else { return }
                self?.preparationFailed(error, id: id)
            }
        }
    }

    private func prepared(_ preview: SourceImportPreview, id: UUID) {
        guard phase == .preparing(id) else { return }
        prepareTask = nil
        preparedPreview = preview
        deliverPreparedPreview()
    }

    private func deliverPreparedPreview() {
        guard case .preparing = phase, let preview = preparedPreview, canUsePresentation else { return }
        preparedPreview = nil
        close(preview: preview)
    }

    private func preparationFailed(_ error: Error, id: UUID) {
        guard phase == .preparing(id) else { return }
        prepareTask = nil
        phase = .active
        updateInteraction()
        errorLabel.text = error.localizedDescription
        errorLabel.isHidden = false
        entryView.showsError = true
        needsRevealError = true
        view.setNeedsLayout()
        if canUsePresentation {
            UIAccessibility.post(notification: .announcement, argument: error.localizedDescription)
        }
    }

    @objc private func cancel() {
        guard canUsePresentation else { return }
        close(preview: nil)
    }

    private func close(preview: SourceImportPreview?) {
        guard canUsePresentation else { return }
        let id = beginClosing(preview: preview)
        ownsDismissalCompletion = true
        view.endEditing(true)
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            finishDismissal(id: id, mayDeliverPreview: preview != nil)
        }
    }

    private func beginClosing(preview: SourceImportPreview?) -> UUID {
        let id: UUID
        if case .closing(let currentID) = phase {
            id = currentID
        } else {
            id = UUID()
            returnPresenter = presentingViewController
            returnWindow = viewIfLoaded?.window
        }
        phase = .closing(id)
        pendingPreview = preview
        preparedPreview = nil
        prepareTask?.cancel()
        prepareTask = nil
        needsRevealCaret = false
        needsRevealError = false
        updateInteraction()
        return id
    }

    private func resumeCancelledDismissal(id: UUID) {
        guard phase == .closing(id) else { return }
        phase = .active
        pendingPreview = nil
        returnPresenter = nil
        returnWindow = nil
        ownsDismissalCompletion = false
        isVisible = viewIfLoaded?.window != nil
        updateInteraction()
        if canUsePresentation { becomeFirstResponder() }
    }

    private func finishDismissal(id: UUID, mayDeliverPreview: Bool) {
        guard phase == .closing(id) else { return }
        let preview = pendingPreview
        let ready = onReady
        let dismissed = onDismiss
        let presenter = returnPresenter
        let window = returnWindow
        phase = .finished
        prepareTask?.cancel()
        prepareTask = nil
        pendingPreview = nil
        onSubmit = nil
        onReady = nil
        onDismiss = nil
        returnPresenter = nil
        returnWindow = nil
        updateInteraction()
        dismissed?()
        guard mayDeliverPreview, let preview, presentingViewController == nil, viewIfLoaded?.window == nil,
            let presenter, let window, presenter.presentedViewController == nil,
            isCurrentPresenter(presenter, in: window)
        else { return }
        ready?(preview)
    }
}
