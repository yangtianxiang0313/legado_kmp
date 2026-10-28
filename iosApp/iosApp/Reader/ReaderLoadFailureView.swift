import UIKit

final class ReaderLoadFailureView: UIView, UIGestureRecognizerDelegate {
    /// The body region in this overlay's local coordinates; nil uses bounds.
    var contentFrame: CGRect? {
        didSet {
            guard contentFrame != oldValue else { return }
            setNeedsLayout()
        }
    }

    var isShowingLoading: Bool { presentation?.kind == .loading && !isHidden }
    var isShowingFailure: Bool { presentation?.kind == .failure && !isHidden }

    private enum Kind {
        case failure
        case loading
    }

    private struct Presentation {
        let kind: Kind
        let onRetry: (() -> Void)?
        let onBack: (() -> Void)?
        let onMenu: () -> Void
    }

    private let messageView = ReaderMessageTextView(frame: .zero, textContainer: nil)
    private let menuTapGestureRecognizer = UITapGestureRecognizer()
    private var presentation: Presentation?
    private var interactionID: UUID?
    private var tapInteractionID: UUID?
    private weak var interactionWindow: UIWindow?
    private var needsAccessibilityAnnouncement = false
    private var isApplicationSuspended = false
    private var isSceneSuspended = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        isHidden = true
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "reader.loadFailure"

        messageView.accessibilityIdentifier = "reader.loadFailure.message"
        addSubview(messageView)
        menuTapGestureRecognizer.addTarget(self, action: #selector(menuTapped(_:)))
        menuTapGestureRecognizer.delegate = self
        menuTapGestureRecognizer.cancelsTouchesInView = false
        menuTapGestureRecognizer.isEnabled = false
        addGestureRecognizer(menuTapGestureRecognizer)

        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(becameUnavailable(_:)), name: name, object: nil)
        }
        for name in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(becameAvailable(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            refreshInteraction()
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            guard isUserInteractionEnabled != oldValue else { return }
            refreshInteraction()
        }
    }

    override var alpha: CGFloat {
        didSet {
            guard alpha != oldValue else { return }
            refreshInteraction()
        }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if superview !== newSuperview { invalidateInteraction() }
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        setNeedsLayout()
        refreshInteraction()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow { invalidateInteraction() }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isSceneSuspended = window?.windowScene.map { $0.activationState != .foregroundActive } ?? false
        refreshInteraction()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        messageView.setViewportFrame(messageFrame)
        messageView.layoutIfNeeded()
        if needsAccessibilityAnnouncement, let interactionID,
            canInteract(interactionID: interactionID), !messageView.bounds.isEmpty
        {
            needsAccessibilityAnnouncement = false
            UIAccessibility.post(notification: .screenChanged, argument: messageView)
        }
    }

    func show(
        message: String,
        theme: ReaderThemeController,
        onRetry: @escaping () -> Void,
        onBack: @escaping () -> Void,
        onMenu: @escaping () -> Void = {}
    ) {
        show(
            message: message,
            theme: theme,
            presentation: Presentation(kind: .failure, onRetry: onRetry, onBack: onBack, onMenu: onMenu)
        )
    }

    func showLoading(message: String, theme: ReaderThemeController, onMenu: @escaping () -> Void) {
        show(
            message: message,
            theme: theme,
            presentation: Presentation(kind: .loading, onRetry: nil, onBack: nil, onMenu: onMenu)
        )
    }

    func hideLoading() {
        guard presentation?.kind == .loading else { return }
        hide()
    }

    func hide() {
        invalidateInteraction()
        presentation = nil
        needsAccessibilityAnnouncement = false
        accessibilityViewIsModal = false
        messageView.clearMessage()
        isHidden = true
    }

    func apply(theme: ReaderThemeController) {
        messageView.apply(theme: theme)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard let interactionID else { return false }
        return performBack(interactionID: interactionID)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive _: UITouch) -> Bool {
        guard gestureRecognizer === menuTapGestureRecognizer,
            let interactionID, canInteract(interactionID: interactionID)
        else { return false }
        tapInteractionID = interactionID
        return true
    }

    private var messageFrame: CGRect {
        let region = contentFrame ?? bounds
        guard region.origin.x.isFinite, region.origin.y.isFinite,
            region.width.isFinite, region.height.isFinite, region.width > 0, region.height > 0
        else { return .zero }
        let clipped = region.intersection(bounds)
        return clipped.isNull ? .zero : clipped
    }

    private var isAvailable: Bool {
        guard presentation != nil, let window, !isApplicationSuspended, !isSceneSuspended,
            UIApplication.shared.applicationState == .active,
            window.windowScene.map({ $0.activationState == .foregroundActive }) != false
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled,
                !view.accessibilityElementsHidden || view === self
            else { return false }
            ancestor = view.superview
        }
        return true
    }

    private func canInteract(interactionID: UUID) -> Bool {
        self.interactionID == interactionID && window === interactionWindow
            && !accessibilityElementsHidden && isAvailable
    }

    private func show(message: String, theme: ReaderThemeController, presentation: Presentation) {
        invalidateInteraction()
        self.presentation = presentation
        needsAccessibilityAnnouncement = true
        accessibilityViewIsModal = true
        messageView.setMessage(message, theme: theme)
        setNeedsLayout()
        if isHidden {
            isHidden = false
        } else {
            refreshInteraction()
        }
    }

    private func invalidateInteraction() {
        interactionID = nil
        tapInteractionID = nil
        interactionWindow = nil
        menuTapGestureRecognizer.isEnabled = false
        accessibilityElementsHidden = true
        accessibilityCustomActions = nil
        messageView.accessibilityCustomActions = nil
        messageView.onEscape = nil
    }

    private func refreshInteraction() {
        invalidateInteraction()
        guard let presentation, isAvailable else { return }
        let id = UUID()
        interactionID = id
        interactionWindow = window
        accessibilityElementsHidden = false
        var actions: [UIAccessibilityCustomAction] = []
        if presentation.kind == .failure {
            actions.append(
                UIAccessibilityCustomAction(name: "刷新") { [weak self] _ in
                    self?.performRetry(interactionID: id) ?? false
                })
            messageView.onEscape = { [weak self] in
                self?.performBack(interactionID: id) ?? false
            }
        }
        actions.append(
            UIAccessibilityCustomAction(name: "阅读菜单") { [weak self] _ in
                self?.openMenu(interactionID: id) ?? false
            })
        accessibilityCustomActions = actions
        messageView.accessibilityCustomActions = actions
        menuTapGestureRecognizer.isEnabled = true
        if needsAccessibilityAnnouncement { setNeedsLayout() }
    }

    private func performRetry(interactionID: UUID) -> Bool {
        guard canInteract(interactionID: interactionID), presentation?.kind == .failure,
            let onRetry = presentation?.onRetry
        else { return false }
        onRetry()
        return true
    }

    private func performBack(interactionID: UUID) -> Bool {
        guard canInteract(interactionID: interactionID), presentation?.kind == .failure,
            let onBack = presentation?.onBack
        else { return false }
        onBack()
        return true
    }

    private func openMenu(interactionID: UUID) -> Bool {
        guard canInteract(interactionID: interactionID), let onMenu = presentation?.onMenu else { return false }
        onMenu()
        return true
    }

    @objc private func menuTapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let id = tapInteractionID else { return }
        tapInteractionID = nil
        _ = openMenu(interactionID: id)
    }

    @objc private func becameUnavailable(_ notification: Notification) {
        if let scene = notification.object as? UIScene {
            guard scene === window?.windowScene else { return }
            isSceneSuspended = true
        } else {
            isApplicationSuspended = true
        }
        invalidateInteraction()
    }

    @objc private func becameAvailable(_ notification: Notification) {
        if let scene = notification.object as? UIScene {
            guard scene === window?.windowScene else { return }
            isSceneSuspended = false
        } else {
            isApplicationSuspended = false
        }
        refreshInteraction()
    }
}
