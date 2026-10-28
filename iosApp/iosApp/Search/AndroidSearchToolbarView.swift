import UIKit

final class AndroidSearchToolbarView: UIView {
    let searchField: UITextField = AndroidSearchToolbarTextField(frame: .zero)
    let backButton = UIButton(type: .custom)
    let submitButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)

    var onBack: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onMore: (() -> Void)?
    var isSubmitButtonEnabled = true {
        didSet { updateQueryControls() }
    }

    private enum Metrics {
        // Legado 5f5d31404 + AppCompat 1.7.1, not UISearchBar metrics.
        static let searchHeight: CGFloat = 30
        static let searchRadius: CGFloat = 35
        static let verticalMargin: CGFloat = 10
        static let touchSize: CGFloat = 44
        static let navigationWidth: CGFloat = 56
        static let iconSize: CGFloat = 24
        static let overflowStartPadding: CGFloat = 6
        static let overflowEndPadding: CGFloat = 10
        static let editFrameMargin: CGFloat = 8
        static let textInset: CGFloat = 8
        static let clearPadding: CGFloat = 8
        static let submitPadding: CGFloat = 16
        static let fontSize: CGFloat = 14

        static let overflowWidth = iconSize + overflowStartPadding + overflowEndPadding
        static let clearWidth = iconSize + 2 * clearPadding
        static let submitWidth = iconSize + 2 * submitPadding
    }

    private let searchBackground = UIView()
    private let searchFocusTarget = UIControl()
    private let clearButton = UIButton(type: .custom)
    private var queryHint = NSLocalizedString(
        "search.toolbar.query", value: "搜索书名、作者", comment: "Search query and hint"
    )
    private var interactionEnabled = true
    private var showsMoreButton = true
    private var contentInsetRight: CGFloat = 0
    private var trailingAccessory: UIView?
    private var trailingAccessoryWidth: CGFloat = 0
    private var availableLayoutSize: CGSize?
    private var horizontalPadding: CGFloat = 0
    private var searchHeight = Metrics.searchHeight
    private var toolbarHeight = AndroidToolbarLayout.minimumHeight(for: .zero)
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var placeholderLayoutDirection: UIUserInterfaceLayoutDirection?
    private var placeholderColor = UIColor.white.withAlphaComponent(0.5)
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updateInteractionState()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    convenience init(placeholder: String, showsMoreButton: Bool, contentInsetRight: CGFloat = 0) {
        self.init(frame: .zero)
        queryHint = placeholder
        self.showsMoreButton = showsMoreButton
        self.contentInsetRight = max(0, contentInsetRight)
        moreButton.isHidden = !showsMoreButton
        searchField.placeholder = placeholder
        searchField.accessibilityLabel = placeholder
        updatePlaceholder()
        updateQueryControls()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: toolbarHeight)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: toolbarHeight)
    }

    func updateLayout(availableSize: CGSize) {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0
        else { return }
        availableLayoutSize = availableSize
        updateLayoutMetrics()
    }

    private func updateLayoutMetrics() {
        // The owner supplies the page size; the toolbar's own bounds are not an orientation context.
        let availableSize = availableLayoutSize ?? .zero
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
        let surfaceHeight = AndroidToolbarLayout.searchSurfaceHeight(
            font: searchField.font ?? .systemFont(ofSize: Metrics.fontSize),
            displayScale: traitCollection.displayScale)
        let height = max(
            AndroidToolbarLayout.minimumHeight(for: availableSize),
            surfaceHeight + 2 * Metrics.verticalMargin)
        let heightChanged = toolbarHeight != height
        let layoutChanged = heightChanged || horizontalPadding != padding || searchHeight != surfaceHeight
        horizontalPadding = padding
        searchHeight = surfaceHeight
        toolbarHeight = height
        if heightChanged {
            minimumHeightConstraint?.constant = height
            invalidateIntrinsicContentSize()
        }
        if layoutChanged { setNeedsLayout() }
    }

    func updateQueryControls() {
        let query = searchField.text ?? ""
        let hasQuery = !query.isEmpty
        let canInteract = interactionEnabled && presentation.isActive
        clearButton.isHidden = !hasQuery
        clearButton.isEnabled = canInteract && hasQuery

        // AppCompat requires focus, even when a nonempty query remains after submit.
        // Without voice search, an empty focused query still shows the go action.
        let showsSubmit = isSubmitButtonEnabled && searchField.isFirstResponder
        submitButton.isHidden = !showsSubmit
        submitButton.isEnabled = canInteract && showsSubmit
        var elements: [UIView] = [backButton, searchField]
        if hasQuery { elements.append(clearButton) }
        if showsSubmit { elements.append(submitButton) }
        if let trailingAccessory, !trailingAccessory.isHidden { elements.append(trailingAccessory) }
        if showsMoreButton { elements.append(moreButton) }
        accessibilityElements = elements
        setNeedsLayout()
    }

    func setInteractionEnabled(_ enabled: Bool) {
        interactionEnabled = enabled
        searchField.isEnabled = enabled
        updateInteractionState()
    }

    /// The owner must suspend covered pages, including non-fullscreen presentations.
    /// This does not change the query, business availability, or first responder.
    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
    }

    private func updateInteractionState() {
        let active = presentation.isActive
        isUserInteractionEnabled = active
        accessibilityElementsHidden = !active
        searchFocusTarget.isEnabled = interactionEnabled && active
        moreButton.isEnabled = interactionEnabled && active
        backButton.isEnabled = active
        trailingAccessory?.isUserInteractionEnabled = interactionEnabled && active
        if !active {
            for button in [backButton, submitButton, clearButton, moreButton] {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
            searchFocusTarget.cancelTracking(with: nil)
        }
        updateQueryControls()
    }

    /// An Android always-visible action occupies its own slot before the overflow button.
    func setTrailingAccessory(_ accessory: UIView?, width: CGFloat) {
        trailingAccessory?.removeFromSuperview()
        trailingAccessory = accessory
        trailingAccessoryWidth = width.isFinite ? max(0, width) : 0
        if let accessory {
            accessory.isUserInteractionEnabled = interactionEnabled && presentation.isActive
            accessory.tintColor = backButton.tintColor
            addSubview(accessory)
        }
        updateQueryControls()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentation.update()
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if placeholderLayoutDirection != effectiveUserInterfaceLayoutDirection {
            updatePlaceholder()
        }
        let content = bounds.inset(
            by: UIEdgeInsets(
                top: 0, left: safeAreaInsets.left + horizontalPadding, bottom: 0,
                right: safeAreaInsets.right + horizontalPadding + contentInsetRight
            ))
        let contentWidth = max(0, content.width)
        // activity_book_search overrides contentInsetStartWithNavigation to zero.
        let navigationWidth = min(Metrics.navigationWidth, contentWidth)
        let overflowWidth = showsMoreButton ? min(Metrics.overflowWidth, contentWidth - navigationWidth) : 0
        let accessoryWidth =
            trailingAccessory?.isHidden == false
            ? min(trailingAccessoryWidth, max(0, contentWidth - navigationWidth - overflowWidth)) : 0
        let searchWidth = max(0, contentWidth - navigationWidth - overflowWidth - accessoryWidth)
        let controlHeight = max(Metrics.touchSize, searchHeight)

        func slot(leading: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: isRTL ? content.maxX - leading - width : content.minX + leading,
                y: bounds.midY - height / 2, width: width, height: height
            )
        }

        let actionHeight = AndroidToolbarLayout.minimumHeight(for: availableLayoutSize ?? .zero)
        func actionSlot(leading: CGFloat, width: CGFloat) -> CGRect {
            var frame = slot(leading: leading, width: width, height: actionHeight)
            frame.origin.y = 0
            return frame
        }
        backButton.frame = actionSlot(leading: 0, width: navigationWidth)
        moreButton.frame = actionSlot(leading: contentWidth - overflowWidth, width: overflowWidth)
        trailingAccessory?.frame = actionSlot(
            leading: contentWidth - overflowWidth - accessoryWidth, width: accessoryWidth)
        moreButton.contentEdgeInsets = UIEdgeInsets(
            top: 0,
            left: isRTL ? Metrics.overflowEndPadding : Metrics.overflowStartPadding,
            bottom: 0,
            right: isRTL ? Metrics.overflowStartPadding : Metrics.overflowEndPadding
        )
        searchBackground.frame = slot(
            leading: navigationWidth, width: searchWidth, height: searchHeight
        )
        searchBackground.layer.cornerRadius = min(Metrics.searchRadius, searchHeight / 2)
        searchFocusTarget.frame = slot(
            leading: navigationWidth, width: searchWidth, height: bounds.height
        )

        // abc_search_view: edit-frame margins surround text, close and submit together.
        let showsSubmit = !submitButton.isHidden
        let showsClear = !clearButton.isHidden
        let iconWidth = (showsSubmit ? Metrics.iconSize : 0) + (showsClear ? Metrics.iconSize : 0)
        let preferredPadding =
            2 * (Metrics.editFrameMargin + Metrics.textInset)
            + (showsSubmit ? Metrics.submitWidth - Metrics.iconSize : 0)
            + (showsClear ? Metrics.clearWidth - Metrics.iconSize : 0)
        // Preserve two full-size glyphs on narrow layouts by reducing padding only.
        let queryWidth = 2 * (searchField.font?.pointSize ?? Metrics.fontSize)
        let paddingScale = min(1, max(0, (searchWidth - iconWidth - queryWidth) / preferredPadding))
        let margin = min(Metrics.editFrameMargin * paddingScale, searchWidth / 2)
        let editWidth = max(0, searchWidth - 2 * margin)
        let submitWidth =
            showsSubmit
            ? min(Metrics.iconSize + 2 * Metrics.submitPadding * paddingScale, editWidth) : 0
        let clearWidth =
            showsClear
            ? min(Metrics.iconSize + 2 * Metrics.clearPadding * paddingScale, editWidth - submitWidth) : 0
        let textWidth = max(0, editWidth - clearWidth - submitWidth)
        let textInset = min(Metrics.textInset * paddingScale, textWidth / 2)
        let editLeading = navigationWidth + margin
        searchField.frame = slot(
            leading: editLeading + textInset,
            width: max(0, textWidth - 2 * textInset), height: controlHeight
        )
        clearButton.frame = slot(
            leading: editLeading + textWidth, width: clearWidth, height: controlHeight
        )
        submitButton.frame = slot(
            leading: editLeading + textWidth + clearWidth,
            width: submitWidth, height: controlHeight
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        applyPalette()
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

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func configureViews() {
        accessibilityIdentifier = "search.toolbar"
        isAccessibilityElement = false
        minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: toolbarHeight)
        minimumHeightConstraint?.isActive = true

        searchBackground.isUserInteractionEnabled = false
        searchBackground.isAccessibilityElement = false
        // Android clamps bg_searchview's 35dp radius to half its 30dp surface.
        searchBackground.layer.cornerRadius = min(Metrics.searchRadius, Metrics.searchHeight / 2)
        searchBackground.layer.borderWidth = 0.5
        addSubview(searchBackground)

        // Only exposed frame margins reach this target; text selection and buttons
        // keep their own touches. AppCompat similarly expands the editor's tap area.
        searchFocusTarget.isAccessibilityElement = false
        searchFocusTarget.addTarget(self, action: #selector(handleSearchFocus), for: .touchUpInside)
        addSubview(searchFocusTarget)

        configureButton(backButton, image: ReaderMenuAndroidIcon.back.image())
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.accessibilityLabel = NSLocalizedString(
            "search.toolbar.back", value: "返回", comment: "Search toolbar back button"
        )
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        // AppCompat 1.7.1 abc_ic_go_search_api_material; autoMirrored is absent.
        configureButton(submitButton, image: androidImage(named: "SearchToolbarAndroidGo", size: Metrics.iconSize))
        submitButton.accessibilityIdentifier = "search.submitButton"
        submitButton.accessibilityLabel = L10n.Search.title
        submitButton.addTarget(self, action: #selector(handleSubmit), for: .touchUpInside)

        configureButton(clearButton, image: ReaderMenuAndroidIcon.clear.image())
        clearButton.accessibilityIdentifier = "search.clearButton"
        clearButton.accessibilityLabel = L10n.Common.clear
        clearButton.addTarget(self, action: #selector(handleClear), for: .touchUpInside)

        configureButton(moreButton, image: ReaderMenuAndroidIcon.more.image())
        moreButton.accessibilityIdentifier = UIIdentifiers.Search.moreMenu
        moreButton.accessibilityLabel = NSLocalizedString(
            "search.toolbar.more", value: "更多", comment: "Search toolbar overflow button"
        )
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)

        searchField.accessibilityIdentifier = UIIdentifiers.Search.searchField
        searchField.accessibilityLabel = queryHint
        searchField.placeholder = queryHint
        searchField.adjustsFontForContentSizeCategory = false
        searchField.adjustsFontSizeToFitWidth = false
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.clearButtonMode = .never
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.returnKeyType = .search
        searchField.enablesReturnKeyAutomatically = true
        searchField.contentVerticalAlignment = .center
        // The controller owns the delegate, editingChanged business actions and Return.
        // This target only keeps the hint and query controls synchronized.
        searchField.addTarget(
            self, action: #selector(queryControlsDidChange),
            for: [.editingChanged, .editingDidBegin, .editingDidEnd]
        )
        addSubview(searchField)

        updateTypography()
        applyPalette()
        updateQueryControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
        presentation.refreshHierarchy()
    }

    private func configureButton(_ button: UIButton, image: UIImage?) {
        // Custom, unconfigured buttons avoid iOS 26's additional button backgrounds.
        button.configuration = nil
        button.backgroundColor = .clear
        button.adjustsImageWhenHighlighted = false
        button.adjustsImageWhenDisabled = false
        button.showsMenuAsPrimaryAction = false
        button.tintColor = .white
        button.imageView?.contentMode = .center
        button.setImage(image, for: .normal)
        button.setImage(image, for: .disabled)
        button.isAccessibilityElement = true
        addSubview(button)
    }

    @objc private func applyPalette() {
        let selection = searchField.selectedTextRange
        let primary = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        let lightOverlay = Self.isColorLight(primary)
        // Keep the provider when an owner copies this color to its status-bar backdrop.
        backgroundColor = nil
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        // values-night changes transparent10 to #10ffffff, not ten percent opacity.
        let isNight =
            traitCollection.userInterfaceStyle == .dark
            && UserDefaults.standard.string(forKey: "theme_mode") != "E_INK"
        let fill = UIColor(white: isNight ? 1 : 0, alpha: 16.0 / 255)
        searchBackground.backgroundColor = fill
        searchBackground.layer.borderColor = fill.cgColor
        // AppBarOverlay follows primary luminance, independently of day/night resources.
        let primaryText = UIColor(white: lightOverlay ? 0 : 1, alpha: lightOverlay ? 222.0 / 255 : 1)
        let toolbarIconColor = UIColor(
            white: lightOverlay ? 0 : 1, alpha: lightOverlay ? 138.0 / 255 : 179.0 / 255)
        backButton.tintColor = toolbarIconColor
        moreButton.tintColor = toolbarIconColor
        trailingAccessory?.tintColor = toolbarIconColor
        // MaterialValueHelper.primaryTextColor uses actual PRIMARY luminance, not
        // AppConfig.isNightTheme. Both default primaries therefore keep go/close white.
        submitButton.tintColor = primaryText
        clearButton.tintColor = primaryText
        searchField.textColor = primaryText
        // AppBarOverlay overrides colorAccent to md_grey_900 / md_grey_50.
        searchField.tintColor = UIColor(white: lightOverlay ? 33.0 / 255 : 250.0 / 255, alpha: 1)
        placeholderColor = UIColor(white: lightOverlay ? 0 : 1, alpha: lightOverlay ? 0.38 : 0.5)
        updatePlaceholder()
        // Refresh attributes in place; never replace text, reload input views, or
        // disturb an active IME marked range during a same-mode palette change.
        if let selection, searchField.markedTextRange == nil {
            searchField.selectedTextRange = selection
        }
    }

    private static func isColorLight(_ color: UIColor) -> Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return false }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        // ColorUtils.isColorLight -> AndroidX calculateLuminance >= 0.5.
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue) >= 0.5
    }

    private func updateTypography() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: Metrics.fontSize, textStyle: .subheadline, compatibleWith: traitCollection)
        let fontChanged = searchField.font != font
        if fontChanged { searchField.font = font }
        updateLayoutMetrics()
        if fontChanged { setNeedsLayout() }
    }

    private func updatePlaceholder() {
        let font = searchField.font ?? .systemFont(ofSize: Metrics.fontSize)
        let paragraph = NSMutableParagraphStyle()
        let direction = effectiveUserInterfaceLayoutDirection
        paragraph.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        paragraph.alignment = direction == .rightToLeft ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: placeholderColor,
            .paragraphStyle: paragraph,
        ]
        let hint = NSMutableAttributedString(string: "", attributes: attributes)
        // SearchView.kt: " [CenteredImageSpan] " + queryHint, sized to integer 14sp.
        let iconSize = floor(font.pointSize)
        if let image = androidImage(named: "SearchToolbarAndroidHint", size: iconSize) {
            let attachment = NSTextAttachment()
            attachment.image = image.withTintColor(
                UIColor(white: 192.0 / 255, alpha: 1), renderingMode: .alwaysOriginal
            )
            attachment.bounds = CGRect(
                x: 0, y: (font.ascender + font.descender - iconSize) / 2,
                width: iconSize, height: iconSize
            )
            hint.append(NSAttributedString(string: " ", attributes: attributes))
            hint.append(NSAttributedString(attachment: attachment))
            hint.append(NSAttributedString(string: " ", attributes: attributes))
        }
        hint.append(NSAttributedString(string: queryHint, attributes: attributes))
        hint.addAttributes(attributes, range: NSRange(location: 0, length: hint.length))
        searchField.attributedPlaceholder = hint
        placeholderLayoutDirection = direction
    }

    private func androidImage(named name: String, size: CGFloat) -> UIImage? {
        guard let source = UIImage(named: name) else { return nil }
        let targetSize = CGSize(width: size, height: size)
        let image: UIImage
        if source.size == targetSize {
            image = source
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            if traitCollection.displayScale > 0 {
                format.scale = traitCollection.displayScale
            }
            image = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
                source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(origin: .zero, size: targetSize))
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    @objc private func queryControlsDidChange() {
        updateQueryControls()
    }

    @objc private func handleBack() {
        guard presentation.isActive else { return }
        onBack?()
    }

    @objc private func handleSubmit() {
        guard interactionEnabled, isSubmitButtonEnabled, presentation.isActive,
            searchField.isFirstResponder, !submitButton.isHidden
        else { return }
        onSubmit?()
    }

    @objc private func handleSearchFocus() {
        guard interactionEnabled, presentation.isActive else { return }
        searchField.becomeFirstResponder()
    }

    @objc private func handleClear() {
        guard interactionEnabled, presentation.isActive, !(searchField.text ?? "").isEmpty else { return }
        searchField.text = ""
        updateQueryControls()
        searchField.becomeFirstResponder()
        searchField.sendActions(for: .editingChanged)
    }

    @objc private func handleMore() {
        guard interactionEnabled, presentation.isActive else { return }
        onMore?()
    }
}

private final class AndroidSearchToolbarTextField: UITextField {
    override func drawPlaceholder(in rect: CGRect) {
        guard let hint = attributedPlaceholder else {
            super.drawPlaceholder(in: rect)
            return
        }
        guard rect.width > 0 else { return }
        // Explicit drawing keeps the inline vector on the same font-metric center as
        // Android's CenteredImageSpan, without a persistent leftView/caret indent.
        let height = ceil(hint.size().height)
        hint.draw(
            with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil
        )
    }
}
