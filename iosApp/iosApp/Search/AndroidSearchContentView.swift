import UIKit

/// activity_book_search.xml chrome; search/session ownership stays in the controller.
final class AndroidSearchContentView: UIView {
    let toolbar = AndroidSearchToolbarView()
    let progressView = AndroidSearchLoadingView()
    let tableView = UITableView(frame: .zero, style: .plain)
    let stopButton = AndroidSearchActionButton()
    let emptyRecoveryView = SearchRecoveryFooterView()
    let emptyRecoveryViewport = UIScrollView()
    let inputHelpView = SearchInputHelpView()
    private let toolbarBackground = UIView()
    private var progressHeight: NSLayoutConstraint?
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updatePresentation()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        toolbarBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 128
        tableView.separatorStyle = .none
        // SearchActivity's result scrolling does not clear the query editor's focus.
        tableView.keyboardDismissMode = .none
        tableView.accessibilityIdentifier = "search.results"
        emptyRecoveryView.isHidden = true
        emptyRecoveryViewport.isHidden = true
        emptyRecoveryViewport.backgroundColor = AndroidReplicaTheme.background
        emptyRecoveryViewport.alwaysBounceVertical = false
        emptyRecoveryViewport.keyboardDismissMode = .none
        emptyRecoveryViewport.accessibilityIdentifier = "search.recoveryViewport"
        progressView.isHidden = true
        stopButton.isHidden = true

        for item in [
            toolbarBackground, toolbar, progressView, tableView, emptyRecoveryViewport,
            stopButton, inputHelpView,
        ] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        emptyRecoveryView.translatesAutoresizingMaskIntoConstraints = false
        emptyRecoveryViewport.addSubview(emptyRecoveryView)
        let recoveryHeight = emptyRecoveryView.heightAnchor.constraint(
            equalTo: emptyRecoveryViewport.frameLayoutGuide.heightAnchor)
        recoveryHeight.priority = .defaultLow
        let height = progressView.heightAnchor.constraint(equalToConstant: 0)
        progressHeight = height
        progressView.onVisibilityChange = { [weak self] hidden in
            self?.progressHeight?.constant = hidden ? 0 : 2
        }
        NSLayoutConstraint.activate([
            toolbarBackground.topAnchor.constraint(equalTo: topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            height,
            tableView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            stopButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stopButton.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -16),
            stopButton.widthAnchor.constraint(equalToConstant: 40),
            stopButton.heightAnchor.constraint(equalToConstant: 40),
            emptyRecoveryViewport.topAnchor.constraint(equalTo: tableView.topAnchor),
            emptyRecoveryViewport.leadingAnchor.constraint(equalTo: tableView.leadingAnchor),
            emptyRecoveryViewport.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            emptyRecoveryViewport.bottomAnchor.constraint(equalTo: tableView.bottomAnchor),
            emptyRecoveryView.topAnchor.constraint(equalTo: emptyRecoveryViewport.contentLayoutGuide.topAnchor),
            emptyRecoveryView.leadingAnchor.constraint(equalTo: emptyRecoveryViewport.contentLayoutGuide.leadingAnchor),
            emptyRecoveryView.trailingAnchor.constraint(equalTo: emptyRecoveryViewport.contentLayoutGuide.trailingAnchor),
            emptyRecoveryView.bottomAnchor.constraint(equalTo: emptyRecoveryViewport.contentLayoutGuide.bottomAnchor),
            emptyRecoveryView.widthAnchor.constraint(equalTo: emptyRecoveryViewport.frameLayoutGuide.widthAnchor),
            recoveryHeight,
            inputHelpView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            inputHelpView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            inputHelpView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            inputHelpView.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
        applyPalette()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        presentation.refreshHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Call false before covering/leaving this page, true when it is usable again.
    /// Scene/window/ancestor visibility is additionally enforced without changing search state.
    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyPalette()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    override func layoutSubviews() {
        toolbar.updateLayout(availableSize: bounds.size)
        super.layoutSubviews()
        presentation.update()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyPalette()
    }

    private func updatePresentation() {
        let active = presentation.isActive
        // The root also hosts the search menu. Keep that overlay interactive and
        // AX-visible; the owner separately gates the result list and input help.
        toolbar.setPresentationActive(active)
        progressView.setPresentationActive(active)
        stopButton.setPresentationActive(active)
        emptyRecoveryView.isUserInteractionEnabled = active
        emptyRecoveryView.accessibilityElementsHidden = !active
        emptyRecoveryViewport.isUserInteractionEnabled = active
        emptyRecoveryViewport.accessibilityElementsHidden = !active
    }

    @objc private func applyPalette() {
        // Resolve snapshots again on same-mode changes; no reload or query mutation.
        backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        toolbarBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        tableView.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        emptyRecoveryViewport.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        inputHelpView.backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
    }
}

final class AndroidSearchLoadingView: UIView {
    var onVisibilityChange: ((Bool) -> Void)?
    var progress: Float = 0 {
        didSet {
            let fraction = progress.isFinite ? min(1, max(0, progress)) : 0
            accessibilityValue = "\(Int(fraction * 100))%"
        }
    }
    private let bar = CALayer()
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updateAnimation()
    }

    override var isHidden: Bool {
        didSet {
            onVisibilityChange?(isHidden)
            updateAnimation()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityLabel = L10n.Search.loadingSearch
        accessibilityTraits = .updatesFrequently
        accessibilityIdentifier = "search.progress"
        isUserInteractionEnabled = false
        backgroundColor = .clear
        // RefreshProgressBar.secondColor defaults to 0xffc1c1c1; the search XML
        // supplies no color override. It must not become the custom accent color.
        bar.backgroundColor = UIColor(white: 193 / 255, alpha: 1).cgColor
        layer.addSublayer(bar)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAnimation),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        presentation.refreshHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bar.bounds = CGRect(origin: .zero, size: bounds.size)
        bar.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
        presentation.update()
        updateAnimation()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
    }

    @objc private func updateAnimation() {
        let active = presentation.isActive
        accessibilityElementsHidden = !active
        guard active else {
            bar.removeAnimation(forKey: "search.loading")
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if UIAccessibility.isReduceMotionEnabled {
            bar.removeAnimation(forKey: "search.loading")
            bar.transform = CATransform3DMakeScale(0.35, 1, 1)
        } else {
            bar.transform = CATransform3DIdentity
            guard bar.animation(forKey: "search.loading") == nil else { return }
            // RefreshProgressBar: center expansion, speed 2 of 100 per Android draw.
            let animation = CABasicAnimation(keyPath: "transform.scale.x")
            animation.fromValue = 0
            animation.toValue = 1
            animation.duration = 50.0 / 60.0
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            bar.add(animation, forKey: "search.loading")
        }
    }
}

final class AndroidSearchActionButton: UIButton {
    enum Action { case stop, retry, nextPage }

    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updatePresentation()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        tintColor = .white
        imageView?.contentMode = .center
        layer.cornerRadius = 20
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.24
        layer.shadowRadius = 3
        layer.shadowOffset = CGSize(width: 0, height: 3)
        accessibilityIdentifier = UIIdentifiers.Search.stopButton
        updateAppearance()
        setAction(.stop)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAppearance), name: .androidReplicaThemeDidChange, object: nil)
        presentation.refreshHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var isHighlighted: Bool { didSet { updateAppearance() } }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
        presentation.update()
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(x: contentRect.midX - 12, y: contentRect.midY - 12, width: 24, height: 24)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAppearance()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
    }

    private func updatePresentation() {
        let active = presentation.isActive
        // Keep isEnabled owned by the controller so resuming cannot enable a
        // business-disabled action or change the current stop/retry/next action.
        isUserInteractionEnabled = active
        accessibilityElementsHidden = !active
        if !active {
            cancelTracking(with: nil)
            isHighlighted = false
        }
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard presentation.isActive, isEnabled else { return }
        super.sendAction(action, to: target, for: event)
    }

    override func sendActions(for controlEvents: UIControl.Event) {
        guard presentation.isActive, isEnabled else { return }
        super.sendActions(for: controlEvents)
    }

    func setAction(_ action: Action) {
        let image: UIImage?
        switch action {
        case .stop:
            image = UIImage(named: "ChangeSourceAndroidStop")?.withRenderingMode(.alwaysTemplate)
            accessibilityLabel = L10n.Search.stopSearch
        case .retry:
            image = ReaderMenuAndroidIcon.refresh.image()
            accessibilityLabel = L10n.Common.retry
        case .nextPage:
            image = UIImage(named: "SearchToolbarAndroidPlay")?.withRenderingMode(.alwaysTemplate)
            accessibilityLabel = L10n.Search.nextPage
        }
        setImage(image, for: .normal)
        for tooltip in interactions.compactMap({ $0 as? UIToolTipInteraction }) { removeInteraction(tooltip) }
        addInteraction(UIToolTipInteraction(defaultToolTip: accessibilityLabel ?? ""))
    }

    @objc private func updateAppearance() {
        let color = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let multiplier: CGFloat = isHighlighted ? 0.9 : 1
        backgroundColor = UIColor(
            red: red * multiplier, green: green * multiplier, blue: blue * multiplier, alpha: alpha)
    }
}

/// Shared by search chrome, including toolbar/loading/FAB uses outside the search page.
/// Coverage cannot be inferred from UIWindow attachment; owners supply that one bit.
final class AndroidSearchPresentationState: NSObject {
    private weak var view: UIView?
    private let onChange: () -> Void
    private var requestedActive = true
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var sceneActive = false
    private var lastActive: Bool?
    private var observations: [NSKeyValueObservation] = []

    init(view: UIView, onChange: @escaping () -> Void) {
        self.view = view
        self.onChange = onChange
        super.init()
        let center = NotificationCenter.default
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            center.addObserver(self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var isActive: Bool {
        guard requestedActive, applicationActive, sceneActive,
            let view, let window = view.window,
            window.windowScene?.activationState == .foregroundActive, !view.bounds.isEmpty
        else { return false }
        var visibleRect = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01 else { return false }
            if current.clipsToBounds {
                visibleRect = visibleRect.intersection(current.convert(current.bounds, to: window))
            }
            guard !visibleRect.isEmpty, !visibleRect.isNull else { return false }
            ancestor = current.superview
        }
        return true
    }

    func setPresentationActive(_ active: Bool) {
        requestedActive = active
        update()
    }

    func refreshHierarchy() {
        observations.removeAll()
        sceneActive = view?.window?.windowScene?.activationState == .foregroundActive
        if view?.window != nil {
            var ancestor = view
            // No timer survives offscreen just to poll for a later return.
            while let current = ancestor {
                observations.append(current.observe(\.isHidden, options: [.new]) { [weak self] _, _ in self?.update() })
                observations.append(current.observe(\.alpha, options: [.new]) { [weak self] _, _ in self?.update() })
                observations.append(current.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.update() })
                observations.append(current.observe(\.center, options: [.new]) { [weak self] _, _ in self?.update() })
                observations.append(current.observe(\.transform, options: [.new]) { [weak self] _, _ in self?.update() })
                observations.append(current.observe(\.clipsToBounds, options: [.new]) { [weak self] _, _ in self?.update() })
                if let scroll = current as? UIScrollView {
                    observations.append(
                        scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.update() })
                }
                ancestor = current.superview
            }
        }
        update()
    }

    func update() {
        let active = isActive
        guard lastActive != active else { return }
        lastActive = active
        onChange()
    }

    @objc private func activationChanged(_ notification: Notification) {
        switch notification.name {
        case UIApplication.didBecomeActiveNotification:
            applicationActive = true
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification:
            applicationActive = false
        default:
            guard let scene = notification.object as? UIScene, scene === view?.window?.windowScene else { return }
            sceneActive = notification.name == UIScene.didActivateNotification
        }
        update()
    }
}
