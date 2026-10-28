import UIKit

final class ReaderBackgroundImageStripView: UIView {
    static let height: CGFloat = 100

    var onImport: (() -> Void)?
    var onSelect: ((ReaderBackgroundImageCatalog.Item) -> Void)?
    var canInteract: (() -> Bool)? {
        didSet { if !interactionAllowed { cancelPendingTracking() } }
    }

    private let scrollView = ReaderBackgroundImageScrollView()
    private let stackView = UIStackView()
    private let importButton = ReaderBackgroundImageButton(
        title: "选择图片", identifier: "reader.background.import", isImport: true)
    private var imageButtons: [ReaderBackgroundImageButton] = []
    private var selectedPath: String?
    private var imagesEnabled = true
    private var thumbnailScale: CGFloat = 0
    private var observedPans: [UIPanGestureRecognizer] = []

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.height)
    }

    func configure(selectedPath: String?, enabled: Bool) {
        if self.selectedPath != selectedPath || imagesEnabled != enabled { cancelPendingTracking() }
        self.selectedPath = selectedPath
        imagesEnabled = enabled
        updateButtons()
    }

    func cancelPendingTracking() {
        importButton.cancelPendingTracking()
        for button in imageButtons { button.cancelPendingTracking() }
    }

    override var isHidden: Bool {
        didSet { if isHidden { cancelPendingTracking() } }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { if !isUserInteractionEnabled { cancelPendingTracking() } }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if window !== newWindow {
            cancelPendingTracking()
            stopObservingPans()
        }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if superview !== newSuperview {
            cancelPendingTracking()
            stopObservingPans()
        }
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if window != nil { observeScrollPans() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { observeScrollPans() }
        loadThumbnailsIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        loadThumbnailsIfNeeded()
    }

    private func setUp() {
        backgroundColor = .clear
        isAccessibilityElement = false
        tintColor = UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(white: 0, alpha: 222.0 / 255) }
        for name in [
            UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
            UIWindow.didResignKeyNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(interactionDeactivated(_:)), name: name, object: nil)
        }

        scrollView.backgroundColor = .clear
        scrollView.isAccessibilityElement = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.canCancelContentTouches = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.spacing = 0
        stackView.isAccessibilityElement = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        importButton.canInteract = { [weak self] in self?.interactionAllowed == true }
        importButton.onActivate = { [weak self] in self?.onImport?() }
        stackView.addArrangedSubview(importButton)

        for item in ReaderBackgroundImageCatalog.items {
            let button = ReaderBackgroundImageButton(
                title: item.title, identifier: "reader.background.\(item.id)", isImport: false)
            button.canInteract = { [weak self] in self?.interactionAllowed == true }
            button.onActivate = { [weak self] in self?.onSelect?(item) }
            imageButtons.append(button)
            stackView.addArrangedSubview(button)
        }

        // dialog_read_bg_text.xml: 6pt outside fifteen fixed 66 x 88pt items.
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 6),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -6),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 6),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -6),
            stackView.heightAnchor.constraint(equalToConstant: 88),
        ])
        loadThumbnailsIfNeeded()
    }

    private var interactionAllowed: Bool {
        guard imagesEnabled, let window, !window.isHidden, window.isKeyWindow,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive, canInteract?() != false
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 || !view.isUserInteractionEnabled { return false }
            if let scroll = view as? UIScrollView, Self.isScrolling(scroll) { return false }
            ancestor = view.superview
        }
        return !Self.isScrolling(scrollView)
    }

    private static func isScrolling(_ scroll: UIScrollView) -> Bool {
        let state = scroll.panGestureRecognizer.state
        return scroll.isDragging || scroll.isDecelerating || state == .began || state == .changed
    }

    private func observeScrollPans() {
        stopObservingPans()
        var ancestor: UIView? = scrollView
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                let pan = scroll.panGestureRecognizer
                pan.addTarget(self, action: #selector(scrollPanChanged(_:)))
                observedPans.append(pan)
            }
            ancestor = view.superview
        }
    }

    private func stopObservingPans() {
        for pan in observedPans { pan.removeTarget(self, action: #selector(scrollPanChanged(_:))) }
        observedPans.removeAll()
    }

    @objc private func scrollPanChanged(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began || pan.state == .changed || pan.state == .ended || pan.state == .cancelled {
            cancelPendingTracking()
        }
    }

    @objc private func interactionDeactivated(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        if let source = notification.object as? UIWindow, source !== window { return }
        cancelPendingTracking()
    }

    private func loadThumbnailsIfNeeded() {
        let scale = max(1, window?.screen.scale ?? traitCollection.displayScale)
        guard thumbnailScale != scale else { return }
        thumbnailScale = scale
        for (item, button) in zip(ReaderBackgroundImageCatalog.items, imageButtons) {
            button.setPreviewImage(
                ReaderBackgroundImageCatalog.thumbnail(
                    for: item, maximumPixelSize: Int(ceil(88 * scale))))
        }
        updateButtons()
    }

    private func updateButtons() {
        importButton.configure(selected: false, enabled: imagesEnabled)
        for (item, button) in zip(ReaderBackgroundImageCatalog.items, imageButtons) {
            button.configure(selected: selectedPath == item.storedPath, enabled: imagesEnabled)
        }
    }
}

private final class ReaderBackgroundImageButton: UIButton {
    var canInteract: (() -> Bool)?
    var onActivate: (() -> Void)?
    private let previewImageView = UIImageView()
    private let nameLabel = UILabel()
    private let isImport: Bool
    private var permitsTouchCommit = false
    private var touchOrigin = CGPoint.zero
    private var trackingID = UUID()
    private var trackingPress: UIPress?
    private var isCancellingTracking = false

    init(title: String, identifier: String, isImport: Bool) {
        self.isImport = isImport
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        addInteraction(UIToolTipInteraction(defaultToolTip: title))

        previewImageView.backgroundColor = .clear
        previewImageView.clipsToBounds = true
        // BgAdapter.centerCrop() overrides XML fitCenter only for ordinary images.
        previewImageView.contentMode = isImport ? .scaleAspectFit : .scaleAspectFill
        previewImageView.isAccessibilityElement = false
        previewImageView.isUserInteractionEnabled = false
        if isImport {
            previewImageView.image = UIImage(named: "ReaderBackgroundAndroidImage")?.withRenderingMode(.alwaysTemplate)
        }
        addSubview(previewImageView)

        nameLabel.text = title
        nameLabel.numberOfLines = 1
        nameLabel.textAlignment = .center
        nameLabel.lineBreakMode = .byClipping
        nameLabel.isAccessibilityElement = false
        nameLabel.isUserInteractionEnabled = false
        nameLabel.clipsToBounds = true
        addSubview(nameLabel)
        addTarget(self, action: #selector(activate), for: .touchUpInside)
        addTarget(self, action: #selector(discardTouch), for: [.touchUpOutside, .touchCancel])

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 66),
            heightAnchor.constraint(equalToConstant: 88),
        ])
        updateTypography()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet { if !isEnabled { cancelPendingTracking() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // item_bg_image.xml: 2dp padding, weighted image, single-line wrap-content caption.
        let inner = CGRect(x: 2, y: 2, width: max(0, bounds.width - 4), height: max(0, bounds.height - 4))
        let captionHeight = min(max(0, inner.height), ceil(nameLabel.font.lineHeight))
        let imageHeight = max(0, inner.height - captionHeight)
        previewImageView.frame = CGRect(x: inner.minX, y: inner.minY, width: max(0, inner.width), height: imageHeight)
        nameLabel.frame = CGRect(x: inner.minX, y: inner.minY + imageHeight, width: max(0, inner.width), height: captionHeight)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateAppearance()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        updateAppearance()
    }

    func setPreviewImage(_ image: UIImage?) {
        previewImageView.image = image?.withRenderingMode(.alwaysOriginal)
    }

    func configure(selected: Bool, enabled: Bool) {
        isSelected = selected
        isEnabled = enabled && (isImport || previewImageView.image != nil)
        accessibilityTraits = selected ? [.button, .selected] : .button
        if !isEnabled { accessibilityTraits.insert(.notEnabled) }
        accessibilityValue = !isImport && previewImageView.image == nil ? "图片不可用" : nil
        updateAppearance()
    }

    private func updateTypography() {
        nameLabel.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: traitCollection)
        setNeedsLayout()
    }

    private func updateAppearance() {
        let primary = tintColor.resolvedColor(with: traitCollection)
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        // BgTextConfigDialog passes secondaryTextColor to every caption, primary to ic_image.
        // This revision's getSecondaryTextColor returns white (not 70% white) on dark surfaces.
        nameLabel.textColor =
            primary.getWhite(&white, alpha: &alpha)
            ? (white >= 0.5 ? .white : UIColor(white: 0, alpha: 138.0 / 255)) : primary
        nameLabel.alpha = isEnabled ? 1 : 0.45
        previewImageView.tintColor = primary
    }

    func cancelPendingTracking() {
        guard !isCancellingTracking else { return }
        isCancellingTracking = true
        defer { isCancellingTracking = false }
        permitsTouchCommit = false
        trackingPress = nil
        trackingID = UUID()
        super.cancelTracking(with: nil)
        isHighlighted = false
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingPress == nil, isEnabled, canInteract?() == true else { return false }
        trackingID = UUID()
        touchOrigin = touch.location(in: self)
        permitsTouchCommit = true
        let accepted = super.beginTracking(touch, with: event)
        if !accepted { cancelPendingTracking() }
        return accepted
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let point = touch.location(in: self)
        guard permitsTouchCommit, canInteract?() == true,
            hypot(point.x - touchOrigin.x, point.y - touchOrigin.y) <= 8
        else {
            cancelPendingTracking()
            return false
        }
        return super.continueTracking(touch, with: event)
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        permitsTouchCommit =
            permitsTouchCommit && canInteract?() == true
            && touch.map { bounds.contains($0.location(in: self)) } == true
        super.endTracking(touch, with: event)
        let id = trackingID
        DispatchQueue.main.async { [weak self] in
            if self?.trackingID == id { self?.permitsTouchCommit = false }
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        cancelPendingTracking()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if let press = presses.first(where: {
            $0.type == .select || $0.key?.keyCode == .keyboardSpacebar
                || $0.key?.keyCode == .keyboardReturnOrEnter || $0.key?.keyCode == .keypadEnter
        }) {
            guard trackingPress == nil, !isTracking, isEnabled, canInteract?() == true else {
                cancelPendingTracking()
                return
            }
            trackingPress = press
            trackingID = UUID()
            permitsTouchCommit = true
        }
        super.pressesBegan(presses, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let endsActivation = trackingPress.map { press in presses.contains(where: { $0 === press }) } == true
        if endsActivation { permitsTouchCommit = permitsTouchCommit && canInteract?() == true }
        super.pressesEnded(presses, with: event)
        if endsActivation {
            trackingPress = nil
            let id = trackingID
            DispatchQueue.main.async { [weak self] in
                if self?.trackingID == id { self?.permitsTouchCommit = false }
            }
        }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        cancelPendingTracking()
        super.pressesCancelled(presses, with: event)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, canInteract?() == true, let onActivate else { return false }
        cancelPendingTracking()
        onActivate()
        return true
    }

    @objc private func activate() {
        guard permitsTouchCommit, isEnabled, canInteract?() == true else {
            cancelPendingTracking()
            return
        }
        cancelPendingTracking()
        onActivate?()
    }

    @objc private func discardTouch() { cancelPendingTracking() }
}

private final class ReaderBackgroundImageScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIControl { return true }
        return super.touchesShouldCancel(in: view)
    }
}
