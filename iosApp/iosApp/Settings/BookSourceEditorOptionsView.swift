import UIKit

final class BookSourceEditorOptionsView: UIView {
    var sourceType: Int = 0 {
        didSet {
            dismissTypeMenu()
            updateSourceType()
        }
    }

    var enabled: Bool = true {
        didSet { enabledButton.isSelected = enabled }
    }

    var enabledExplore: Bool = true {
        didSet { exploreButton.isSelected = enabledExplore }
    }

    var enabledCookieJar: Bool = true {
        didSet { cookieButton.isSelected = enabledCookieJar }
    }

    var onChange: (() -> Void)?

    override var isUserInteractionEnabled: Bool {
        didSet {
            for button in optionButtons { button.isEnabled = isUserInteractionEnabled }
            if !isUserInteractionEnabled { dismissTypeMenu() }
        }
    }

    // The four entries and their persisted values match Legado 5f5d314.
    private static let sourceTypes: [(value: Int, title: String)] = [
        (0, "文本"), (1, "音频"), (2, "图片"), (3, "文件"),
    ]

    private let scrollView = BookSourceEditorOptionsScrollView()
    private let typeLabel = UILabel()
    private let typeButton = BookSourceEditorOptionControl(style: .spinner)
    private let enabledButton = BookSourceEditorOptionControl(style: .checkbox)
    private let exploreButton = BookSourceEditorOptionControl(style: .checkbox)
    private let cookieButton = BookSourceEditorOptionControl(style: .checkbox)
    private var typeMenu: ReaderOverflowMenuView?
    private var menuGeneration: UInt = 0
    private lazy var presentation: AndroidSearchPresentationState = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updatePresentation()
    }

    private var optionButtons: [BookSourceEditorOptionControl] {
        [typeButton, enabledButton, exploreButton, cookieButton]
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AndroidReplicaTheme.background
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = true

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.isDirectionalLockEnabled = true
        scrollView.canCancelContentTouches = true
        addSubview(scrollView)

        typeLabel.text = "类型："
        typeLabel.textColor = AndroidReplicaTheme.secondaryText
        typeLabel.numberOfLines = 1
        typeLabel.adjustsFontSizeToFitWidth = false
        typeLabel.isAccessibilityElement = false
        scrollView.addSubview(typeLabel)

        typeButton.accessibilityLabel = L10n.SourceEdit.typeTitle
        typeButton.accessibilityIdentifier = UIIdentifiers.SourceEdit.typeField
        typeButton.addTarget(self, action: #selector(showTypeMenu), for: .touchUpInside)
        configureCheckbox(enabledButton, title: L10n.SourceEdit.enabledTitle, identifier: "sourceEdit.option.enabled")
        configureCheckbox(exploreButton, title: L10n.SourceEdit.exploreTab, identifier: "sourceEdit.option.enabledExplore")
        configureCheckbox(cookieButton, title: L10n.SourceEdit.cookieJarTitle, identifier: "sourceEdit.option.enabledCookieJar")
        enabledButton.addTarget(self, action: #selector(toggleEnabled), for: .touchUpInside)
        exploreButton.addTarget(self, action: #selector(toggleExplore), for: .touchUpInside)
        cookieButton.addTarget(self, action: #selector(toggleCookieJar), for: .touchUpInside)
        for button in optionButtons { scrollView.addSubview(button) }
        accessibilityElements = optionButtons

        updateFonts()
        updateSourceType()
        enabledButton.isSelected = enabled
        exploreButton.isSelected = enabledExplore
        cookieButton.isSelected = enabledCookieJar
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(44, ceil(typeFont.lineHeight) + 16))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentation.update()
        scrollView.frame = bounds
        let views: [UIView] = [typeLabel, typeButton, enabledButton, exploreButton, cookieButton]
        let widths = views.map { ceil($0.intrinsicContentSize.width) }
        let contentWidth = widths.reduce(16, +)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var x: CGFloat = 8
        for (view, width) in zip(views, widths) {
            view.frame = CGRect(
                x: isRTL ? contentWidth - x - width : x,
                y: 0, width: width, height: bounds.height)
            x += width
        }
        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        scrollView.isScrollEnabled = contentWidth > bounds.width
        let offset = min(max(0, scrollView.contentOffset.x), max(0, contentWidth - bounds.width))
        if scrollView.contentOffset != CGPoint(x: offset, y: 0) {
            scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshPalette()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.layoutDirection != traitCollection.layoutDirection
        {
            dismissTypeMenu()
            updateFonts()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
        if window == nil { dismissTypeMenu() }
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview { dismissTypeMenu() }
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
        updatePresentation()
    }

    private func updatePresentation() {
        guard !presentation.isActive else { return }
        dismissTypeMenu()
        for button in optionButtons {
            button.cancelTracking(with: nil)
            button.isHighlighted = false
        }
    }

    @objc private func refreshPalette() {
        backgroundColor = AndroidReplicaTheme.background
        typeLabel.textColor = AndroidReplicaTheme.secondaryText
        for button in optionButtons { button.refreshPalette() }
    }

    private var optionFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
    }

    private var typeFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traitCollection)
    }

    private func updateFonts() {
        let font = optionFont
        typeLabel.font = font
        typeButton.setFont(typeFont)
        for button in [enabledButton, exploreButton, cookieButton] { button.setFont(font) }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func configureCheckbox(_ button: BookSourceEditorOptionControl, title: String, identifier: String) {
        button.title = title
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
    }

    private func updateSourceType() {
        let title = Self.sourceTypes.first(where: { $0.value == sourceType })?.title ?? "未知 (\(sourceType))"
        typeButton.title = title
        typeButton.accessibilityValue = title
        setNeedsLayout()
    }

    private func canActivate(_ control: UIControl) -> Bool {
        guard presentation.isActive, control.isEnabled,
            !scrollView.isDragging, !scrollView.isDecelerating
        else { return false }
        var ancestor: UIView? = control
        while let view = ancestor {
            guard view.isUserInteractionEnabled, !view.isHidden, view.alpha > 0 else { return false }
            if let control = view as? UIControl, !control.isEnabled { return false }
            ancestor = view.superview
        }
        return true
    }

    @objc private func showTypeMenu() {
        guard canActivate(typeButton), let host = window else { return }
        dismissTypeMenu()
        let generation = menuGeneration
        let previousType = sourceType
        let items = Self.sourceTypes.map { option in
            ReaderOverflowMenuView.Item(
                identifier: "sourceEdit.type.\(option.value)", title: option.title
            ) { [weak self] in
                guard let self, self.menuGeneration == generation,
                    self.sourceType == previousType, self.canActivate(self.typeButton)
                else { return }
                self.dismissTypeMenu()
                guard self.sourceType != option.value else { return }
                self.sourceType = option.value
                self.onChange?()
            }
        }
        let menu = ReaderOverflowMenuView(
            items: items, anchorView: typeButton,
            interfaceStyle: traitCollection.userInterfaceStyle, placement: .automatic)
        menu.accessibilityIdentifier = "sourceEdit.typeMenu"
        menu.canActivateItem = { [weak self] in
            guard let self else { return false }
            return self.menuGeneration == generation && self.sourceType == previousType
                && self.canActivate(self.typeButton)
        }
        // ReaderOverflowMenuView dismisses before invoking an item's handler.
        menu.onDismiss = { [weak self] in
            guard let self, self.menuGeneration == generation else { return }
            self.typeMenu = nil
        }
        typeMenu = menu
        menu.present(in: host)
    }

    private func dismissTypeMenu() {
        menuGeneration &+= 1
        let menu = typeMenu
        typeMenu = nil
        menu?.dismiss()
    }

    @objc private func toggleEnabled() {
        guard canActivate(enabledButton) else { return }
        enabled.toggle()
        onChange?()
    }

    @objc private func toggleExplore() {
        guard canActivate(exploreButton) else { return }
        enabledExplore.toggle()
        onChange?()
    }

    @objc private func toggleCookieJar() {
        guard canActivate(cookieButton) else { return }
        enabledCookieJar.toggle()
        onChange?()
    }
}

private final class BookSourceEditorOptionControl: UIControl {
    enum Style {
        case spinner
        case checkbox
    }

    var title: String = "" {
        didSet {
            titleLabel.text = title
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override var isSelected: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool { didSet { updateAppearance() } }
    override var isHighlighted: Bool { didSet { updateAppearance() } }

    private let style: Style
    private let titleLabel = UILabel()
    private let glyphView = UIImageView()

    init(style: Style) {
        self.style = style
        super.init(frame: .zero)
        isAccessibilityElement = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.lineBreakMode = .byClipping
        glyphView.contentMode = .scaleAspectFit
        for view in [titleLabel, glyphView] {
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            addSubview(view)
        }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let textSize = titleLabel.intrinsicContentSize
        return CGSize(
            width: max(44, ceil(textSize.width) + 40),
            height: max(44, ceil(textSize.height) + 16))
    }

    func setFont(_ font: UIFont) {
        titleLabel.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let isCheckbox = style == .checkbox
        let textWidth = max(0, bounds.width - 40)
        let textX: CGFloat = isCheckbox ? 32 : 8
        titleLabel.frame = CGRect(
            x: isRTL ? bounds.width - textX - textWidth : textX,
            y: 0, width: textWidth, height: bounds.height)
        let glyphSize: CGFloat = isCheckbox ? 32 : 8
        let glyphX = isCheckbox ? (32 - glyphSize) / 2 : bounds.width - 16 - glyphSize / 2
        glyphView.frame = CGRect(
            x: isRTL ? bounds.width - glyphX - glyphSize : glyphX,
            y: (bounds.height - glyphSize) / 2, width: glyphSize, height: glyphSize)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, isUserInteractionEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func updateAppearance() {
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        if style == .checkbox {
            glyphView.image = UIImage(named: isSelected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
                .withRenderingMode(.alwaysTemplate)
            glyphView.tintColor = isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
            accessibilityValue = isSelected ? "已勾选" : "未勾选"
        } else {
            glyphView.image = UIImage(systemName: "arrowtriangle.down.fill")
            glyphView.tintColor = AndroidReplicaTheme.secondaryText
        }
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        alpha = isEnabled ? 1 : 0.38
        backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear
    }

    func refreshPalette() { updateAppearance() }
}

private final class BookSourceEditorOptionsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
