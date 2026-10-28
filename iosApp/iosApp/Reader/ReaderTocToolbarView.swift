import UIKit

/// Legado 5f5d314: TocActivity/book_toc/activity_chapter_list and AppCompat 1.7.1.
/// The owner supplies search state and owns editing, query changes, and tab selection.
final class ReaderTocToolbarView: UIView {
    private enum Metrics {
        static let backWidth: CGFloat = 56
        static let moreWidth: CGFloat = 40
        static let searchWidth: CGFloat = 48
        static let searchHeight: CGFloat = 48
        static let inputHeight: CGFloat = 36
        static let editFrameMargin: CGFloat = 8
        static let closeWidth: CGFloat = 40
        static let inputFontSize: CGFloat = 18
    }

    let searchField: UITextField = ReaderTocToolbarSearchField()
    let moreButton: UIButton = ReaderTocToolbarIconButton(type: .system)

    var onBack: (() -> Void)?
    /// Both the collapsed search button and expanded X forward to this callback.
    var onSearch: (() -> Void)?
    var onMore: (() -> Void)?

    private let backButton = ReaderTocToolbarIconButton(type: .system)
    private let searchButton = ReaderTocToolbarIconButton(type: .system)
    private let tabsContainer = UIView()
    private let tabsView: UIView
    private let searchPlate = UIView()
    private let hintIcon = UIImageView()
    private let underline = UIView()
    private var isSearchExpanded = false
    private var searchHasQuery = false
    private var controlsEnabled = true
    private var palette: ReaderTocPalette?
    private var availableSize = CGSize.zero
    private var heightConstraint: NSLayoutConstraint?

    init(tabsView: UIView) {
        self.tabsView = tabsView
        super.init(frame: .zero)
        clipsToBounds = true
        isAccessibilityElement = false
        for item in [backButton, tabsContainer, searchPlate, searchButton, moreButton] {
            addSubview(item)
        }
        tabsContainer.clipsToBounds = true
        tabsView.translatesAutoresizingMaskIntoConstraints = true
        tabsContainer.addSubview(tabsView)
        searchPlate.clipsToBounds = true
        searchPlate.addSubview(searchField)
        searchPlate.addSubview(underline)
        searchField.addSubview(hintIcon)
        for item in [hintIcon, underline] {
            item.isUserInteractionEnabled = false
            item.isAccessibilityElement = false
        }
        hintIcon.contentMode = .scaleAspectFit
        hintIcon.clipsToBounds = true

        configureButton(
            backButton, icon: .back, label: L10n.Reader.backAction,
            identifier: "reader.chapterList.back", action: #selector(handleBack))
        configureButton(
            searchButton, icon: .search, label: L10n.Search.title,
            identifier: "reader.chapterList.search", action: #selector(handleSearch))
        configureButton(
            moreButton, icon: .more, label: L10n.Reader.menuMore,
            identifier: "reader.chapterList.more", action: #selector(handleMore))
        // Widget.Material.ActionButton.Overflow: 6dp start / 10dp end padding around 24dp art.
        (moreButton as? ReaderTocToolbarIconButton)?.imageStartOffset = -2

        searchField.borderStyle = .none
        searchField.backgroundColor = .clear
        searchField.clipsToBounds = true
        searchField.returnKeyType = .search
        searchField.autocorrectionType = .no
        searchField.autocapitalizationType = .none
        searchField.spellCheckingType = .no
        searchField.clearButtonMode = .never
        searchField.textAlignment = .natural
        searchField.contentVerticalAlignment = .center
        searchField.adjustsFontForContentSizeCategory = true
        searchField.adjustsFontSizeToFitWidth = false
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .natural
        paragraph.lineBreakMode = .byTruncatingTail
        searchField.defaultTextAttributes[.paragraphStyle] = paragraph
        searchField.accessibilityLabel = L10n.Search.title
        searchField.accessibilityIdentifier = UIIdentifiers.ReaderChapterList.searchField
        searchField.addTarget(self, action: #selector(searchFocusChanged), for: .editingDidBegin)
        searchField.addTarget(self, action: #selector(searchFocusChanged), for: .editingDidEnd)
        updateFont()
        applyPalette(ReaderTocPalette(traits: traitCollection))
        updateSearchPresentation()
        let height = heightAnchor.constraint(equalToConstant: intrinsicContentSize.height)
        heightConstraint = height
        height.isActive = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : availableSize.width
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
        let tabsWidth = max(0, width - 2 * padding - Metrics.backWidth - Metrics.searchWidth - Metrics.moreWidth)
        let tabsHeight = tabsView.sizeThatFits(CGSize(width: tabsWidth, height: .greatestFiniteMagnitude)).height
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: max(resourceHeight, isSearchExpanded ? searchSurfaceHeight : tabsHeight))
    }

    override var bounds: CGRect {
        didSet {
            if oldValue.width != bounds.width {
                invalidateIntrinsicContentSize()
                updateHeightConstraint()
            }
        }
    }

    private var resourceHeight: CGFloat { AndroidToolbarLayout.minimumHeight(for: availableSize) }

    private var inputHeight: CGFloat {
        let font = searchField.font ?? .systemFont(ofSize: Metrics.inputFontSize)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        return max(Metrics.inputHeight, ceil(font.lineHeight + padding.top + padding.bottom))
    }

    private var searchSurfaceHeight: CGFloat {
        max(Metrics.searchHeight, inputHeight + Metrics.searchHeight - Metrics.inputHeight)
    }

    func updateLayout(availableSize: CGSize) {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0, self.availableSize != availableSize
        else { return }
        let oldHeight = resourceHeight
        let oldPadding = AndroidToolbarLayout.horizontalPadding(for: self.availableSize)
        self.availableSize = availableSize
        guard oldHeight != resourceHeight || oldPadding != AndroidToolbarLayout.horizontalPadding(for: availableSize)
        else { return }
        invalidateIntrinsicContentSize()
        updateHeightConstraint()
        setNeedsLayout()
    }

    private func updateHeightConstraint() {
        let height = intrinsicContentSize.height
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateHeightConstraint()
        let outerPadding = min(AndroidToolbarLayout.horizontalPadding(for: availableSize), max(0, bounds.width) / 2)
        let width = max(0, bounds.width - 2 * outerPadding)
        let height = max(0, bounds.height)
        let actionHeight = min(resourceHeight, height)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(start: CGFloat, width itemWidth: CGFloat, height itemHeight: CGFloat, action: Bool = false) -> CGRect {
            CGRect(
                x: bounds.minX + outerPadding + (isRTL ? width - start - itemWidth : start),
                y: action ? bounds.minY : bounds.midY - itemHeight / 2, width: itemWidth, height: itemHeight)
        }

        let backWidth = min(Metrics.backWidth, width)
        backButton.frame = frame(start: 0, width: backWidth, height: actionHeight, action: true)
        let remainingWidth = max(0, width - backWidth)
        if isSearchExpanded {
            // abc_search_view: 8dp edit-frame margins; keep the X reachable before reserving margins.
            let margin = min(
                Metrics.editFrameMargin, max(0, remainingWidth - Metrics.closeWidth) / 2)
            let plateWidth = max(0, remainingWidth - 2 * margin)
            // SearchView.onMeasure uses its 48dp preferred height; only search_src_text is 36dp.
            let plateHeight = min(searchSurfaceHeight, height)
            let closeWidth = min(Metrics.closeWidth, plateWidth)
            let inputWidth = max(0, plateWidth - closeWidth)
            searchPlate.frame = frame(
                start: backWidth + margin, width: plateWidth, height: plateHeight)
            searchButton.frame = frame(
                start: backWidth + margin + inputWidth, width: closeWidth, height: plateHeight)
            let inputHeight = min(self.inputHeight, plateHeight)
            searchField.frame = CGRect(
                x: isRTL ? closeWidth : 0, y: (plateHeight - inputHeight) / 2,
                width: inputWidth, height: inputHeight)
            let lineHeight = min(plateHeight, searchField.isEnabled && searchField.isFirstResponder ? 2 : 1)
            underline.frame = CGRect(
                x: 0, y: plateHeight - lineHeight, width: plateWidth, height: lineHeight)
            tabsContainer.frame = .zero
            moreButton.frame = .zero
            layoutHintIcon()
        } else {
            // Only degenerate widths compress action slots; tabs never extend beneath an action.
            let scale = min(1, remainingWidth / (Metrics.searchWidth + Metrics.moreWidth))
            let searchWidth = Metrics.searchWidth * scale
            let moreWidth = min(Metrics.moreWidth * scale, max(0, remainingWidth - searchWidth))
            let tabsWidth = max(0, remainingWidth - searchWidth - moreWidth)
            tabsContainer.frame = frame(start: backWidth, width: tabsWidth, height: height)
            searchButton.frame = frame(start: backWidth + tabsWidth, width: searchWidth, height: actionHeight, action: true)
            moreButton.frame = frame(start: width - moreWidth, width: moreWidth, height: actionHeight, action: true)
            searchPlate.frame = .zero
        }
        tabsView.frame = tabsContainer.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFont()
        }
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            applyPalette(ReaderTocPalette(traits: traitCollection))
        }
        invalidateIntrinsicContentSize()
        updateHeightConstraint()
        setNeedsLayout()
    }

    func setSearchExpanded(_ expanded: Bool) {
        isSearchExpanded = expanded
        invalidateIntrinsicContentSize()
        updateHeightConstraint()
        updateSearchPresentation()
    }

    /// Call after every owner-driven or user-driven query change; this view never reads or writes the query.
    func setSearchHasQuery(_ hasQuery: Bool) {
        searchHasQuery = hasQuery
        updateSearchPresentation()
    }

    func setControlsEnabled(_ enabled: Bool, searchEnabled: Bool) {
        controlsEnabled = enabled
        for button in [backButton, searchButton, moreButton] {
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.38
        }
        // A ViewPager swipe does not replace or blur the toolbar's SearchView.
        searchField.isEnabled = searchEnabled
        searchPlate.alpha = searchEnabled ? 1 : 0.38
        tabsContainer.isUserInteractionEnabled = enabled
        updateUnderlineColor()
        setNeedsLayout()
    }

    func applyPalette(_ palette: ReaderTocPalette) {
        self.palette = palette
        backgroundColor = palette.titleBackground
        backButton.tintColor = palette.toolbarText
        moreButton.tintColor = palette.toolbarText
        // TocActivity.applyTint(primaryTextColor) tints SearchView action icons, not its input text.
        searchButton.tintColor = palette.toolbarText
        // searchHintIcon retains colorControlNormal; TintHelper only filters the action ImageViews.
        hintIcon.tintColor = palette.toolbarSecondaryText
        searchField.textColor = palette.toolbarText
        searchField.tintColor = palette.toolbarAccent
        var attributes = searchField.defaultTextAttributes
        attributes[.foregroundColor] = palette.toolbarText
        attributes[.kern] = CGFloat(0)
        searchField.defaultTextAttributes = attributes
        updateUnderlineColor()
    }

    private func configureButton(
        _ button: UIButton, icon: ReaderMenuAndroidIcon, label: String,
        identifier: String, action: Selector
    ) {
        button.setImage(icon == .search ? ReaderTocSearchIcon.image() : icon.image(), for: .normal)
        button.backgroundColor = .clear
        button.clipsToBounds = true
        button.adjustsImageWhenDisabled = false
        button.adjustsImageWhenHighlighted = false
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func updateSearchPresentation() {
        tabsContainer.isHidden = isSearchExpanded
        tabsView.isHidden = isSearchExpanded
        moreButton.isHidden = isSearchExpanded
        searchPlate.isHidden = !isSearchExpanded
        searchField.isHidden = !isSearchExpanded
        hintIcon.isHidden = searchHasQuery
        searchButton.setImage(
            isSearchExpanded ? ReaderMenuAndroidIcon.clear.image() : ReaderTocSearchIcon.image(), for: .normal)
        searchButton.accessibilityLabel =
            isSearchExpanded ? (searchHasQuery ? L10n.Common.clear : L10n.Common.cancel) : L10n.Search.title
        accessibilityElements =
            isSearchExpanded
            ? [backButton, searchField, searchButton]
            : [backButton, tabsContainer, searchButton, moreButton]
        updateUnderlineColor()
        setNeedsLayout()
    }

    private func updateFont() {
        // abc_search_view's SearchAutoComplete inherits the regular sans-serif EditText appearance.
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: Metrics.inputFontSize, textStyle: .body, compatibleWith: traitCollection)
        searchField.font = font
        var attributes = searchField.defaultTextAttributes
        attributes[.font] = font
        attributes[.kern] = CGFloat(0)
        searchField.defaultTextAttributes = attributes
        // The hint is an image only, never a placeholder string or an editable attachment.
        hintIcon.image = ReaderTocSearchIcon.image(size: floor(font.pointSize * 1.25))
        invalidateIntrinsicContentSize()
        updateHeightConstraint()
        setNeedsLayout()
    }

    private func layoutHintIcon() {
        let content = searchField.textRect(forBounds: searchField.bounds)
        let font = searchField.font ?? .systemFont(ofSize: Metrics.inputFontSize, weight: .regular)
        // SearchView.getDecoratedHint puts one space before its 1.25em image span.
        let space = min(content.width, (" " as NSString).size(withAttributes: [.font: font, .kern: CGFloat(0)]).width)
        let size = max(0, min(floor(font.pointSize * 1.25), content.height, content.width - space))
        let isRTL = searchField.effectiveUserInterfaceLayoutDirection == .rightToLeft
        hintIcon.frame = CGRect(
            x: isRTL ? content.maxX - space - size : content.minX + space,
            y: content.midY - size / 2, width: size, height: size)
    }

    private func updateUnderlineColor() {
        guard let palette else { return }
        underline.backgroundColor =
            searchField.isEnabled && searchField.isFirstResponder
            ? palette.toolbarAccent : palette.toolbarText.withAlphaComponent(0.3)
    }

    @objc private func searchFocusChanged() {
        updateUnderlineColor()
        setNeedsLayout()
    }

    @objc private func handleBack() {
        guard controlsEnabled else { return }
        onBack?()
    }

    @objc private func handleSearch() {
        guard controlsEnabled else { return }
        onSearch?()
    }

    @objc private func handleMore() {
        guard controlsEnabled, !isSearchExpanded else { return }
        onMore?()
    }
}

private final class ReaderTocToolbarSearchField: UITextField {
    override func textRect(forBounds bounds: CGRect) -> CGRect { inputRect(in: bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect { inputRect(in: bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { inputRect(in: bounds) }

    private func inputRect(in bounds: CGRect) -> CGRect {
        // abc_dropdownitem_text_padding_left/right are 8dp, separate from edit-frame margins.
        let padding = min(8, max(0, bounds.width) / 2)
        let fontPadding = AndroidExploreTextMetrics.padding(
            font: font ?? .systemFont(ofSize: 18), scale: traitCollection.displayScale)
        return CGRect(
            x: bounds.minX + padding, y: bounds.minY + fontPadding.top,
            width: max(0, bounds.width - 2 * padding),
            height: max(0, bounds.height - fontPadding.top - fontPadding.bottom))
    }
}

private final class ReaderTocToolbarIconButton: UIButton {
    var imageStartOffset: CGFloat = 0

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        let size = max(0, min(24, contentRect.width, contentRect.height))
        let offset = effectiveUserInterfaceLayoutDirection == .rightToLeft ? -imageStartOffset : imageStartOffset
        return CGRect(
            x: contentRect.midX - size / 2 + offset, y: contentRect.midY - size / 2,
            width: size, height: size)
    }
}

private enum ReaderTocSearchIcon {
    /// AppCompat 1.7.1 abc_ic_search_api_material.xml, viewport 24, with no autoMirrored flag.
    static func image(size: CGFloat = 24) -> UIImage? {
        guard size.isFinite, size > 0 else { return nil }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { context in
            context.cgContext.scaleBy(x: size / 24, y: size / 24)
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 15.5, y: 14))
            path.addLine(to: CGPoint(x: 14.7, y: 14))
            path.addLine(to: CGPoint(x: 14.4, y: 13.7))
            path.addCurve(
                to: CGPoint(x: 16, y: 9.5), controlPoint1: CGPoint(x: 15.4, y: 12.6),
                controlPoint2: CGPoint(x: 16, y: 11.1))
            path.addCurve(
                to: CGPoint(x: 9.5, y: 3), controlPoint1: CGPoint(x: 16, y: 5.9),
                controlPoint2: CGPoint(x: 13.1, y: 3))
            path.addCurve(
                to: CGPoint(x: 3, y: 9.5), controlPoint1: CGPoint(x: 5.9, y: 3),
                controlPoint2: CGPoint(x: 3, y: 5.9))
            path.addCurve(
                to: CGPoint(x: 9.5, y: 16), controlPoint1: CGPoint(x: 3, y: 13.1),
                controlPoint2: CGPoint(x: 5.9, y: 16))
            path.addCurve(
                to: CGPoint(x: 13.7, y: 14.4), controlPoint1: CGPoint(x: 11.1, y: 16),
                controlPoint2: CGPoint(x: 12.6, y: 15.4))
            path.addLine(to: CGPoint(x: 14, y: 14.7))
            path.addLine(to: CGPoint(x: 14, y: 15.5))
            path.addLine(to: CGPoint(x: 19, y: 20.5))
            path.addLine(to: CGPoint(x: 20.5, y: 19))
            path.addLine(to: CGPoint(x: 15.5, y: 14))
            path.close()
            path.move(to: CGPoint(x: 9.5, y: 14))
            path.addCurve(
                to: CGPoint(x: 5, y: 9.5), controlPoint1: CGPoint(x: 7, y: 14),
                controlPoint2: CGPoint(x: 5, y: 12))
            path.addCurve(
                to: CGPoint(x: 9.5, y: 5), controlPoint1: CGPoint(x: 5, y: 7),
                controlPoint2: CGPoint(x: 7, y: 5))
            path.addCurve(
                to: CGPoint(x: 14, y: 9.5), controlPoint1: CGPoint(x: 12, y: 5),
                controlPoint2: CGPoint(x: 14, y: 7))
            path.addCurve(
                to: CGPoint(x: 9.5, y: 14), controlPoint1: CGPoint(x: 14, y: 12),
                controlPoint2: CGPoint(x: 12, y: 14))
            path.close()
            UIColor.black.setFill()
            path.fill()
        }.withRenderingMode(.alwaysTemplate)
    }
}
