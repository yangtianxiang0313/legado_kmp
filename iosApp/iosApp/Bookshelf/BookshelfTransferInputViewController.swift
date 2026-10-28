import UIKit

enum BookshelfTransferInputMode {
    case addURL
    case importBookshelf
}

/// BaseBookshelfFragment.showAddBookByUrlAlert / importBookshelfAlert at Legado 5f5d314.
@MainActor
final class BookshelfTransferInputViewController: UIViewController, UITextViewDelegate {
    var onSubmit: ((String) -> Void)? {
        didSet { updateInteraction() }
    }
    var onSelectFile: (() -> Void)? {
        didSet { updateInteraction() }
    }

    private enum Phase: Equatable {
        case waiting
        case active
        case closing(UUID)
        case finished
    }

    private enum Submission {
        case text(String)
        case file
    }

    private let contentView: BookshelfTransferInputContentView
    private let outsideControl = UIControl()
    private var phase: Phase = .waiting
    private var pendingSubmission: Submission?
    private var isVisible = false
    private var ownsDismissalCompletion = false
    private var externalCompletionScheduled = false
    private var keyboardFrame: CGRect?
    private weak var originPresenter: UIViewController?
    private weak var originContent: UIViewController?
    private weak var originRoot: UIViewController?
    private weak var originWindow: UIWindow?

    init(mode: BookshelfTransferInputMode, initialText: String = "") {
        contentView = BookshelfTransferInputContentView(mode: mode, initialText: initialText)
        super.init(nibName: nil, bundle: nil)
        title = contentView.titleLabel.text
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard phase == .active else { return nil }
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "bookshelf.transfer"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.textView.delegate = self
        contentView.cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.submitControl.addTarget(self, action: #selector(submit), for: .touchUpInside)
        contentView.fileControl.addTarget(self, action: #selector(selectFile), for: .touchUpInside)
        view.addSubview(outsideControl)
        view.addSubview(contentView)
        contentView.applyAppearance(traits: traitCollection)
        updateInteraction()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if phase == .waiting {
            originPresenter = presentingViewController
            originWindow = view.window
            originRoot = view.window?.rootViewController
            if let presenter = presentingViewController, let window = view.window {
                originContent = visibleContent(of: presenter, in: window)
            }
            phase = .active
        }
        isVisible = true
        updateInteraction()
        guard canInteract else { return }
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: contentView.titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        view.endEditing(true)
        resignFirstResponder()
        if isLeavingPresentation, !isClosing, phase != .finished {
            let id = beginClosing(submission: nil)
            externalCompletionScheduled =
                transitionCoordinator?.animate(alongsideTransition: nil) {
                    [weak self] context in
                    guard let self else { return }
                    self.externalCompletionScheduled = false
                    if context.isCancelled {
                        self.resumeCancelledDismissal(id: id)
                    } else {
                        self.finishDismissal(id: id, deliverSubmission: false)
                    }
                } ?? false
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard case .closing(let id) = phase,
            !ownsDismissalCompletion, !externalCompletionScheduled
        else { return }
        finishDismissal(id: id, deliverSubmission: false)
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
        let id = beginClosing(submission: nil)
        ownsDismissalCompletion = true
        viewIfLoaded?.endEditing(true)
        resignFirstResponder()
        super.dismiss(animated: flag) { [self] in
            finishDismissal(id: id, deliverSubmission: false)
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyAppearance(traits: traitCollection)
        contentView.revealCaretOnNextLayout()
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableFrame
        guard available.width > 0, available.height > 0 else { return }
        let width = min(available.width, view.bounds.width * dialogWidthFraction)
        let height = min(available.height, contentView.preferredHeight(width: width))
        contentView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2,
            width: width, height: height)
        contentView.setNeedsLayout()
    }

    private var availableFrame: CGRect {
        var frame = view.safeAreaLayoutGuide.layoutFrame
        if let keyboardFrame, let window = view.window {
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inView = view.convert(inWindow, from: window)
            let overlap = frame.intersection(inView)
            if !overlap.isNull, overlap.width > 0 {
                frame.size.height = max(1, overlap.minY - frame.minY)
            }
        }
        return frame.insetBy(dx: 0, dy: min(16, max(0, (frame.height - 1) / 2)))
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

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard phase == .active, isVisible else { return }
        keyboardFrame =
            notification.name == UIResponder.keyboardWillHideNotification
            ? nil
            : (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        contentView.revealCaretOnNextLayout()
        view.setNeedsLayout()
        let duration =
            (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curve =
            (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
            options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
        ) { self.view.layoutIfNeeded() }
    }

    func textViewShouldBeginEditing(_ textView: UITextView) -> Bool { canInteract }

    func textViewDidBeginEditing(_ textView: UITextView) {
        contentView.refreshInput()
        contentView.revealCaretOnNextLayout()
        view.setNeedsLayout()
    }

    func textViewDidEndEditing(_ textView: UITextView) { contentView.refreshInput() }

    func textViewDidChange(_ textView: UITextView) {
        contentView.clearError()
        contentView.refreshInput()
        contentView.revealCaretOnNextLayout()
        view.setNeedsLayout()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard textView.isFirstResponder, textView.selectedTextRange?.isEmpty == true else { return }
        contentView.revealCaretOnNextLayout()
        view.setNeedsLayout()
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

    private var originIsCurrent: Bool {
        guard let presenter = originPresenter, let window = originWindow,
            !window.isHidden, window.windowScene?.activationState == .foregroundActive,
            window.rootViewController === originRoot,
            presenter.viewIfLoaded?.window === window,
            let originContent, visibleContent(of: presenter, in: window) === originContent
        else { return false }
        var controller: UIViewController? = presenter
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return false }
            controller = current.parent ?? current.presentingViewController
        }
        return true
    }

    private func visibleContent(of controller: UIViewController, in window: UIWindow) -> UIViewController {
        let child: UIViewController?
        if let navigation = controller as? UINavigationController {
            child = navigation.topViewController
        } else if let tabs = controller as? UITabBarController {
            child = tabs.selectedViewController
        } else {
            child = controller.children.last {
                $0.viewIfLoaded?.window === window && $0.viewIfLoaded?.isHidden == false
            }
        }
        guard let child else { return controller }
        return visibleContent(of: child, in: window)
    }

    private var canInteract: Bool {
        phase == .active && isVisible && !isBeingPresented && !isLeavingPresentation
            && transitionCoordinator?.isInteractive != true && presentedViewController == nil
            && viewIfLoaded?.window === originWindow
            && presentingViewController === originPresenter && originIsCurrent
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = phase == .active && isVisible
        outsideControl.isEnabled = enabled
        contentView.cancelControl.isEnabled = enabled
        contentView.submitControl.isEnabled = enabled && onSubmit != nil
        contentView.fileControl.isEnabled = enabled && contentView.showsFileAction && onSelectFile != nil
        contentView.textView.isEditable = enabled
        contentView.textView.isSelectable = enabled
    }

    @objc private func submit() {
        guard canInteract, onSubmit != nil else { return }
        // Commit marked text through UIKit; never rewrite or truncate the editor's contents.
        view.endEditing(true)
        let text = contentView.textView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            contentView.showEmptyError()
            view.setNeedsLayout()
            return
        }
        close(submission: .text(text))
    }

    @objc private func selectFile() {
        guard canInteract, contentView.showsFileAction, onSelectFile != nil else { return }
        close(submission: .file)
    }

    @objc private func cancel() {
        guard canInteract else { return }
        close(submission: nil)
    }

    private func close(submission: Submission?) {
        guard canInteract else { return }
        view.endEditing(true)
        resignFirstResponder()
        let id = beginClosing(submission: submission)
        ownsDismissalCompletion = true
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            finishDismissal(id: id, deliverSubmission: true)
        }
    }

    private func beginClosing(submission: Submission?) -> UUID {
        let id: UUID
        if case .closing(let currentID) = phase { id = currentID } else { id = UUID() }
        phase = .closing(id)
        pendingSubmission = submission
        updateInteraction()
        return id
    }

    private func resumeCancelledDismissal(id: UUID) {
        guard phase == .closing(id) else { return }
        phase = .active
        pendingSubmission = nil
        ownsDismissalCompletion = false
        isVisible = viewIfLoaded?.window != nil
        updateInteraction()
        if canInteract { becomeFirstResponder() }
    }

    private func finishDismissal(id: UUID, deliverSubmission: Bool) {
        guard phase == .closing(id) else { return }
        let mayDeliver =
            deliverSubmission && originIsCurrent
            && presentingViewController == nil && viewIfLoaded?.window == nil
            && originPresenter?.presentedViewController == nil
        let submission = pendingSubmission
        let submit = onSubmit
        let selectFile = onSelectFile
        phase = .finished
        pendingSubmission = nil
        onSubmit = nil
        onSelectFile = nil
        originPresenter = nil
        originContent = nil
        originRoot = nil
        originWindow = nil
        updateInteraction()
        guard mayDeliver, let submission else { return }
        switch submission {
        case .text(let text): submit?(text)
        case .file: selectFile?()
        }
    }
}
