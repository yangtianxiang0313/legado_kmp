import UIKit

// Legado 5f5d314: fragment_explore.xml, main_explore.xml, view_search.xml,
// SearchView.kt and TitleBar; search internals follow AppCompat 1.7.1.
final class ExploreToolbarView: UIView {
    let searchField: UITextField = ExploreToolbarTextField(frame: .zero)
    let groupButton = ExploreAndroidSelectableButton(frame: .zero)

    var onQueryChange: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onGroup: (() -> Void)?

    private enum Metrics {
        static let searchHeight: CGFloat = 30
        static let verticalMargin: CGFloat = 10
        static let groupWidth: CGFloat = 48
        static let touchHeight: CGFloat = 44
        static let iconSize: CGFloat = 24
        static let editFrameMargin: CGFloat = 8
        static let textInset: CGFloat = 8
        static let clearPadding: CGFloat = 8
        static let submitPadding: CGFloat = 16
        static let fontSize: CGFloat = 14
    }

    private let searchBackground = UIView()
    private let searchFocusTarget = UIControl()
    private let clearButton = ExploreAndroidSelectableButton(frame: .zero)
    private let submitButton = ExploreAndroidSelectableButton(frame: .zero)
    private let queryHint = NSLocalizedString(
        "discovery.toolbar.query", value: "筛选发现源", comment: "ExploreFragment screen_find hint"
    )
    private var interactionEnabled = true
    private var lastNotifiedQuery = ""
    private var availableLayoutSize: CGSize?
    private var horizontalPadding: CGFloat = 0
    private var contentInsetStart = AndroidToolbarLayout.contentInsetStart(for: .zero)
    private var searchHeight = Metrics.searchHeight
    private var toolbarHeight = AndroidToolbarLayout.minimumHeight(for: .zero)
    private var minimumHeightConstraint: NSLayoutConstraint?
    private var placeholderLayoutDirection: UIUserInterfaceLayoutDirection?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
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
        // Keep the last valid page context across temporary zero-size layout callbacks.
        let availableSize = availableLayoutSize ?? .zero
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
        let insetStart = AndroidToolbarLayout.contentInsetStart(for: availableSize)
        let surfaceHeight = AndroidToolbarLayout.searchSurfaceHeight(
            font: searchField.font ?? .systemFont(ofSize: Metrics.fontSize),
            displayScale: traitCollection.displayScale)
        let height = max(
            AndroidToolbarLayout.minimumHeight(for: availableSize),
            surfaceHeight + 2 * Metrics.verticalMargin)
        let heightChanged = toolbarHeight != height
        let layoutChanged =
            heightChanged || horizontalPadding != padding || contentInsetStart != insetStart
            || searchHeight != surfaceHeight
        horizontalPadding = padding
        contentInsetStart = insetStart
        searchHeight = surfaceHeight
        toolbarHeight = height
        if heightChanged {
            minimumHeightConstraint?.constant = height
            invalidateIntrinsicContentSize()
        }
        if layoutChanged { setNeedsLayout() }
    }

    // ExploreFragment submits group queries; ordinary filter updates do not request focus.
    func setQuery(_ query: String, submit: Bool = false) {
        if searchField.text != query {
            searchField.text = query
            searchField.sendActions(for: .editingChanged)
        } else {
            updateQueryControls()
        }
        if submit { submitQuery() }
    }

    func hideKeyboardKeepingFocus() {
        (searchField as? ExploreToolbarTextField)?.hideKeyboardKeepingFocus()
    }

    func updateQueryControls() {
        let hasQuery = !(searchField.text ?? "").isEmpty
        clearButton.isHidden = !hasQuery
        clearButton.isEnabled = interactionEnabled && hasQuery
        // AppCompat updateSubmitButton: focused, even when empty (voice is absent).
        let showsSubmit = searchField.isFirstResponder
        submitButton.isHidden = !showsSubmit
        submitButton.isEnabled = interactionEnabled && showsSubmit

        var elements: [UIView] = [searchField]
        if hasQuery { elements.append(clearButton) }
        if showsSubmit { elements.append(submitButton) }
        elements.append(groupButton)
        accessibilityElements = elements
        setNeedsLayout()
    }

    func setInteractionEnabled(_ enabled: Bool, preservingSearchFocus: Bool = false) {
        interactionEnabled = enabled
        if !enabled {
            if !preservingSearchFocus { searchField.resignFirstResponder() }
            searchFocusTarget.cancelTracking(with: nil)
            for button in [clearButton, submitButton, groupButton] { button.cancelPendingActivation() }
        }
        // A PopupMenu does not pause ExploreFragment or clear its editor's focus/IME.
        // Keep the responder while covered; the delegate also rejects hardware-keyboard edits.
        searchField.isEnabled = enabled || preservingSearchFocus
        // Disabling UITextField hit testing also resigns its responder on UIKit.
        // Gate touches at the toolbar instead when the Android editor keeps focus.
        searchField.isUserInteractionEnabled = enabled || preservingSearchFocus
        searchFocusTarget.isEnabled = enabled
        groupButton.isEnabled = enabled
        updateQueryControls()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return interactionEnabled ? hit : self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let direction = effectiveUserInterfaceLayoutDirection
        let isRTL = direction == .rightToLeft
        if placeholderLayoutDirection != direction { updatePlaceholder() }
        let content = bounds.inset(
            by: UIEdgeInsets(
                top: 0, left: safeAreaInsets.left + horizontalPadding, bottom: 0,
                right: safeAreaInsets.right + horizontalPadding)
        )
        let contentWidth = max(0, content.width)
        let groupWidth = min(Metrics.groupWidth, contentWidth)
        let searchLeading = min(contentInsetStart, contentWidth - groupWidth)
        let searchWidth = max(0, contentWidth - searchLeading - groupWidth)
        let controlHeight = max(Metrics.touchHeight, searchHeight)

        func slot(leading: CGFloat, width: CGFloat, height: CGFloat) -> CGRect {
            CGRect(
                x: isRTL ? content.maxX - leading - width : content.minX + leading,
                y: bounds.midY - height / 2, width: width, height: height
            )
        }

        let actionHeight = AndroidToolbarLayout.minimumHeight(for: availableLayoutSize ?? .zero)
        var groupFrame = slot(leading: contentWidth - groupWidth, width: groupWidth, height: actionHeight)
        groupFrame.origin.y = 0
        groupButton.frame = groupFrame
        searchBackground.frame = slot(
            leading: searchLeading, width: searchWidth, height: searchHeight
        )
        searchBackground.layer.cornerRadius = searchHeight / 2
        searchFocusTarget.frame = slot(
            leading: searchLeading, width: searchWidth, height: bounds.height
        )

        let showsClear = !clearButton.isHidden
        let showsSubmit = !submitButton.isHidden
        let iconWidth = (showsClear ? Metrics.iconSize : 0) + (showsSubmit ? Metrics.iconSize : 0)
        let preferredPadding =
            2 * (Metrics.editFrameMargin + Metrics.textInset)
            + (showsClear ? 2 * Metrics.clearPadding : 0)
            + (showsSubmit ? 2 * Metrics.submitPadding : 0)
        // Keep the font and original glyphs; spend padding only after reserving query space.
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
        let editLeading = searchLeading + margin
        searchField.frame = slot(
            leading: editLeading + textInset,
            width: max(0, textWidth - 2 * textInset), height: controlHeight
        )
        clearButton.frame = slot(
            leading: editLeading + textWidth, width: clearWidth, height: controlHeight
        )
        submitButton.frame = slot(
            leading: editLeading + textWidth + clearWidth, width: submitWidth, height: controlHeight
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        applyPalette()
    }

    private func configureViews() {
        accessibilityIdentifier = "discovery.toolbar"
        isAccessibilityElement = false
        minimumHeightConstraint = heightAnchor.constraint(greaterThanOrEqualToConstant: toolbarHeight)
        minimumHeightConstraint?.isActive = true

        searchBackground.isUserInteractionEnabled = false
        searchBackground.isAccessibilityElement = false
        searchBackground.layer.borderWidth = 0.5
        addSubview(searchBackground)

        // The exposed vertical margins focus the editor without stealing selection/button taps.
        searchFocusTarget.isAccessibilityElement = false
        searchFocusTarget.addTarget(self, action: #selector(focusSearch), for: .touchUpInside)
        addSubview(searchFocusTarget)

        configureButton(clearButton, image: ReaderMenuAndroidIcon.clear.image(), label: L10n.Common.clear)
        clearButton.accessibilityIdentifier = "discovery.clear"
        clearButton.addTarget(self, action: #selector(clearQuery), for: .touchUpInside)

        configureButton(
            submitButton, image: androidImage(named: "SearchToolbarAndroidGo", size: Metrics.iconSize),
            label: L10n.Search.title
        )
        submitButton.accessibilityIdentifier = "discovery.submit"
        submitButton.addTarget(self, action: #selector(submitFromButton), for: .touchUpInside)

        configureButton(
            groupButton, image: androidImage(named: "BookDetailAndroidGroups", size: Metrics.iconSize),
            label: L10n.Discovery.groupFallback
        )
        groupButton.accessibilityIdentifier = UIIdentifiers.Discovery.groupButton
        groupButton.addTarget(self, action: #selector(showGroups), for: .touchUpInside)

        searchField.delegate = self
        searchField.accessibilityIdentifier = UIIdentifiers.Discovery.searchField
        searchField.accessibilityLabel = queryHint
        searchField.placeholder = queryHint
        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.clipsToBounds = true
        searchField.adjustsFontForContentSizeCategory = false
        searchField.adjustsFontSizeToFitWidth = false
        searchField.clearButtonMode = .never
        searchField.autocapitalizationType = .none
        searchField.autocorrectionType = .no
        searchField.spellCheckingType = .no
        searchField.smartQuotesType = .no
        searchField.smartDashesType = .no
        searchField.returnKeyType = .search
        searchField.contentVerticalAlignment = .center
        searchField.addTarget(self, action: #selector(queryDidChange), for: .editingChanged)
        searchField.addTarget(
            self, action: #selector(focusDidChange), for: [.editingDidBegin, .editingDidEnd]
        )
        addSubview(searchField)

        updateTypography()
        applyPalette()
        updateQueryControls()
    }

    private func configureButton(_ button: ExploreAndroidSelectableButton, image: UIImage?, label: String) {
        button.configuration = nil
        button.backgroundColor = .clear
        // Covering the page pauses input, not the Android toolbar's appearance.
        button.dimsWhenDisabled = false
        button.adjustsImageWhenHighlighted = false
        button.adjustsImageWhenDisabled = false
        button.imageView?.contentMode = .center
        // AppCompat's search/action buttons use a borderless selectable background.
        button.clipsToBounds = false
        button.setImage(image, for: .normal)
        button.setImage(image, for: .disabled)
        button.isAccessibilityElement = true
        button.accessibilityLabel = label
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        addSubview(button)
    }

    private func updateTypography() {
        let font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        let fontChanged = searchField.font != font
        if fontChanged { searchField.font = font }
        updateLayoutMetrics()
        if fontChanged { setNeedsLayout() }
    }

    private func applyPalette() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        let textColor = AndroidReplicaTheme.toolbarText
        searchField.textColor = textColor
        searchField.tintColor = textColor
        clearButton.tintColor = textColor
        submitButton.tintColor = textColor
        groupButton.tintColor = textColor.withAlphaComponent(179.0 / 255)
        // bg_searchview's transparent10 is #10000000 / #10ffffff, not 10% opacity.
        let fill = UIColor { traits in
            UIColor(white: traits.userInterfaceStyle == .dark ? 1 : 0, alpha: 16.0 / 255)
        }
        searchBackground.backgroundColor = fill
        searchBackground.layer.borderColor = fill.resolvedColor(with: traitCollection).cgColor
        updatePlaceholder()
    }

    private func updatePlaceholder() {
        let font = searchField.font ?? .systemFont(ofSize: Metrics.fontSize)
        let direction = effectiveUserInterfaceLayoutDirection
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
        paragraph.alignment = direction == .rightToLeft ? .right : .left
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: AndroidReplicaTheme.toolbarText.withAlphaComponent(0.5),
            .paragraphStyle: paragraph,
        ]
        let hint = NSMutableAttributedString(string: "", attributes: attributes)
        // SearchView.kt's CenteredImageSpan uses the integer text size, with a space each side.
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
        if source.size == targetSize { return source.withRenderingMode(.alwaysTemplate) }
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        if traitCollection.displayScale > 0 { format.scale = traitCollection.displayScale }
        return UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(origin: .zero, size: targetSize))
        }.withRenderingMode(.alwaysTemplate)
    }

    @objc private func queryDidChange() {
        updateQueryControls()
        let query = searchField.text ?? ""
        guard query != lastNotifiedQuery else { return }
        lastNotifiedQuery = query
        onQueryChange?()
    }

    @objc private func focusDidChange() {
        updateQueryControls()
    }

    @objc private func focusSearch() {
        guard interactionEnabled, ExploreAndroidGraphics.isAvailableForInteraction(searchFocusTarget) else { return }
        searchField.becomeFirstResponder()
    }

    @objc private func clearQuery() {
        guard interactionEnabled, clearButton.canReceiveActivation, !(searchField.text ?? "").isEmpty else { return }
        searchField.text = ""
        searchField.becomeFirstResponder()
        searchField.sendActions(for: .editingChanged)
    }

    @objc private func submitFromButton() {
        guard submitButton.canReceiveActivation else { return }
        submitQuery()
    }

    private func submitQuery() {
        guard interactionEnabled, ExploreAndroidGraphics.isAvailableForInteraction(searchField),
            searchField.markedTextRange == nil,
            !(searchField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        onSubmit?()
    }

    @objc private func showGroups() {
        guard interactionEnabled, groupButton.canReceiveActivation else { return }
        onGroup?()
    }
}

extension ExploreToolbarView: UITextFieldDelegate {
    func textFieldShouldBeginEditing(_ textField: UITextField) -> Bool {
        interactionEnabled
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String)
        -> Bool
    {
        interactionEnabled
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submitQuery()
        // The callback owns dismissal; Return must not implicitly end marked-text input.
        return false
    }
}

private final class ExploreToolbarTextField: UITextField {
    private var keyboardHidden = false
    private let hiddenKeyboardView = UIView(frame: .zero)

    func hideKeyboardKeepingFocus() {
        guard isFirstResponder, !keyboardHidden else { return }
        // AppCompat onSubmitQuery hides the IME without clearFocus. A zero-height input
        // view preserves UIKit's responder, caret, selection and hardware-keyboard input.
        keyboardHidden = true
        inputView = hiddenKeyboardView
        reloadInputViews()
    }

    override func becomeFirstResponder() -> Bool {
        showKeyboardIfNeeded()
        return super.becomeFirstResponder()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        showKeyboardIfNeeded()
        super.touchesBegan(touches, with: event)
    }

    override func accessibilityActivate() -> Bool {
        showKeyboardIfNeeded()
        return super.accessibilityActivate()
    }

    private func showKeyboardIfNeeded() {
        guard keyboardHidden else { return }
        keyboardHidden = false
        inputView = nil
        if isFirstResponder { reloadInputViews() }
    }

    override func drawPlaceholder(in rect: CGRect) {
        guard let hint = attributedPlaceholder else {
            super.drawPlaceholder(in: rect)
            return
        }
        guard rect.width > 0 else { return }
        let height = ceil(hint.size().height)
        hint.draw(
            with: CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil
        )
    }
}
