import UIKit

/// activity_source_debug.xml / book_source_debug.xml at Legado 5f5d314.
final class BookSourceDebugPageView: UIView {
    let toolbar = AndroidSearchToolbarView(
        placeholder: "搜索书名、作者", showsMoreButton: true)
    let scanButton = UIButton(type: .custom)
    let tableView = UITableView(frame: .zero, style: .plain)
    let helpView = BookSourceDebugHelpView()

    private let toolbarBackground = UIView()
    private let loadingView = BookSourceDebugLoadingView()
    private lazy var viewport = BookSourceDebugViewport(
        tableView: tableView, loadingView: loadingView, helpView: helpView)
    private var presentationActive = false
    var onLayout: (() -> Void)?
    var onViewportWillChange: (() -> Void)? {
        get { viewport.onWillChange }
        set { viewport.onWillChange = newValue }
    }
    var onViewportDidChange: (() -> Void)? {
        get { viewport.onDidChange }
        set { viewport.onDidChange = newValue }
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        accessibilityIdentifier = "bookSource.debug.page"
        configureTable()
        configureScanButton()
        toolbar.setTrailingAccessory(scanButton, width: 48)

        for child in [toolbarBackground, toolbar, viewport] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbarBackground.topAnchor.constraint(equalTo: topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            viewport.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            viewport.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            viewport.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            viewport.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        applyPalette()
        showHelp(true)
        setLoading(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        loadingView.setPresentationActive(active && helpView.isHidden)
    }

    func setLoading(_ loading: Bool) {
        loadingView.setLoading(loading)
    }

    func showHelp(_ visible: Bool) {
        tableView.accessibilityElementsHidden = visible
        loadingView.isAccessibilityElement = !visible
        loadingView.setPresentationActive(presentationActive && !visible)
        guard helpView.isHidden == visible else { return }
        helpView.invalidatePendingActions()
        helpView.isHidden = !visible
        viewport.setNeedsLayout()
    }

    override func layoutSubviews() {
        toolbar.updateLayout(availableSize: bounds.size)
        super.layoutSubviews()
        onLayout?()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyPalette()
    }

    private func configureTable() {
        tableView.register(BookSourceDebugLogCell.self, forCellReuseIdentifier: BookSourceDebugLogCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 24
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorStyle = .none
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.contentInset = .zero
        tableView.directionalLayoutMargins = .zero
        tableView.cellLayoutMarginsFollowReadableWidth = false
        tableView.allowsSelection = false
        tableView.keyboardDismissMode = .none
        tableView.accessibilityIdentifier = "bookSource.debug.logs"
    }

    private func configureScanButton() {
        let image = UIImage(named: "SourceDebugAndroidScan")?.withRenderingMode(.alwaysTemplate)
        scanButton.configuration = nil
        scanButton.adjustsImageWhenHighlighted = false
        scanButton.adjustsImageWhenDisabled = false
        scanButton.setImage(image, for: .normal)
        scanButton.setImage(image, for: .disabled)
        scanButton.imageView?.contentMode = .center
        scanButton.backgroundColor = .clear
        scanButton.isExclusiveTouch = true
        scanButton.accessibilityLabel = "扫描二维码"
        scanButton.accessibilityIdentifier = "bookSource.debug.scan"
        scanButton.addInteraction(UIToolTipInteraction(defaultToolTip: "扫描二维码"))
    }

    @objc private func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        let primary = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        toolbarBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground
        let light = ReaderPaletteColor.isLight(primary)
        scanButton.tintColor = UIColor(white: light ? 0 : 1, alpha: (light ? 138.0 : 179.0) / 255)
        tableView.indicatorStyle = ReaderPaletteColor.isNightResource(traits: traitCollection) ? .white : .black
        loadingView.applyPalette()
    }

}

private final class BookSourceDebugViewport: UIView {
    var onWillChange: (() -> Void)?
    var onDidChange: (() -> Void)?
    private let tableView: UITableView
    private let loadingView: UIView
    private let helpView: BookSourceDebugHelpView

    init(tableView: UITableView, loadingView: UIView, helpView: BookSourceDebugHelpView) {
        self.tableView = tableView
        self.loadingView = loadingView
        self.helpView = helpView
        super.init(frame: .zero)
        clipsToBounds = true
        // activity_source_debug.xml draws help above both logs and RotateLoading.
        addSubview(tableView)
        addSubview(loadingView)
        addSubview(helpView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let changed = tableView.frame.size != bounds.size
        if changed { onWillChange?() }
        tableView.frame = bounds
        loadingView.frame = CGRect(x: bounds.midX - 18, y: bounds.minY + 6, width: 36, height: 36)
        let size = helpView.sizeThatFits(bounds.size)
        helpView.frame = CGRect(
            x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(bounds.height, size.height))
        if changed { onDidChange?() }
    }
}

/// RotateLoading: 36pt slot, 2pt round strokes, paired arcs and a 2pt shadow.
private final class BookSourceDebugLoadingView: UIView {
    private let rotatingLayer = CALayer()
    private let arcs = [CAShapeLayer(), CAShapeLayer()]
    private let shadows = [CAShapeLayer(), CAShapeLayer()]
    private var isLoading = false
    private var presentationActive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityLabel = "正在调试"
        accessibilityTraits = .updatesFrequently
        accessibilityIdentifier = "bookSource.debug.loading"
        layer.addSublayer(rotatingLayer)
        for arc in shadows + arcs {
            arc.fillColor = UIColor.clear.cgColor
            arc.lineWidth = 2
            arc.lineCap = .round
            rotatingLayer.addSublayer(arc)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAnimations),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        let center = NotificationCenter.default
        for name in [
            UIScene.didActivateNotification, UIScene.willDeactivateNotification,
            UIScene.didEnterBackgroundNotification, UIScene.didDisconnectNotification,
        ] {
            center.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIWindow.didBecomeKeyNotification,
            UIWindow.didResignKeyNotification,
        ] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
        setLoading(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        isHidden = !loading
        updateAnimations()
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        updateAnimations()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow !== window { stopAnimations() }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimations()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        updateAnimations()
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === window?.windowScene else { return }
        if notification.name == UIScene.didActivateNotification {
            updateAnimations()
        } else {
            stopAnimations()
        }
    }

    @objc private func environmentChanged(_ notification: Notification) {
        if let changedWindow = notification.object as? UIWindow, changedWindow !== window { return }
        if notification.name == UIApplication.willResignActiveNotification
            || notification.name == UIApplication.didEnterBackgroundNotification
            || notification.name == UIWindow.didResignKeyNotification
        {
            stopAnimations()
        } else {
            updateAnimations()
        }
    }

    func applyPalette() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let color = ReaderTocPalette(traits: traitCollection).accent.cgColor
        for arc in arcs { arc.strokeColor = color }
        CATransaction.commit()
    }

    private func stopAnimations() {
        rotatingLayer.removeAllAnimations()
        for arc in arcs + shadows { arc.removeAllAnimations() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotatingLayer.frame = bounds
        for (index, arc) in arcs.enumerated() {
            let start = CGFloat(10 + index * 180) * .pi / 180
            let path = UIBezierPath(
                arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                radius: max(0, min(bounds.width, bounds.height) / 2 - 4),
                startAngle: start, endAngle: start + 160 * .pi / 180, clockwise: true
            ).cgPath
            arc.frame = bounds
            arc.path = path
            arc.strokeColor = ReaderTocPalette(traits: traitCollection).accent.cgColor
            shadows[index].frame = bounds.offsetBy(dx: 2, dy: 2)
            shadows[index].path = path
            shadows[index].strokeColor = UIColor.black.withAlphaComponent(26.0 / 255).cgColor
        }
        CATransaction.commit()
    }

    @objc private func updateAnimations() {
        guard isLoading, presentationActive, superview != nil,
            let window, window.isKeyWindow,
            window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active,
            !UIAccessibility.isReduceMotionEnabled
        else {
            stopAnimations()
            return
        }
        guard rotatingLayer.animation(forKey: "rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 0.6
        rotation.repeatCount = .infinity
        rotatingLayer.add(rotation, forKey: "rotation")
        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweep.values = [10.0 / 160, 1, 10.0 / 160]
        sweep.keyTimes = [0, NSNumber(value: 2.0 / 3), 1]
        sweep.duration = 1.875
        sweep.repeatCount = .infinity
        for arc in arcs + shadows { arc.add(sweep, forKey: "sweep") }
    }
}
