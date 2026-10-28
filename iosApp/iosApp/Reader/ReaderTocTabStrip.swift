import UIKit

/// Legado 5f5d314: TocActivity + view_tab_layout, using Widget.Design.TabLayout (Material 1.13.0).
final class ReaderTocTabStrip: UIView {
    private enum Metrics {
        // Base.Widget.Design.TabLayout: 12dp at either side, 264dp maximum, no fixed-mode minimum.
        static let horizontalPadding: CGFloat = 12
        static let maximumTabWidth: CGFloat = 264
        // SlidingTabIndicator.onMeasure reserves 16dp at either edge before centering equal-width tabs.
        static let centeringGutter: CGFloat = 16
        static let defaultHeight: CGFloat = 48
        // TabLayout defaults tabPaddingTop/Bottom to 0; the legacy style only overrides start/end.
        static let verticalPadding: CGFloat = 0
        static let indicatorHeight: CGFloat = 2
        static let minimumIndicatorWidth: CGFloat = 24
        static let selectionDuration: TimeInterval = 0.3
    }

    private let chaptersButton = ReaderTocTabButton(
        title: L10n.Reader.chapterListTitle, identifier: "reader.chapterList.chapters")
    private let bookmarksButton = ReaderTocTabButton(
        title: L10n.Reader.menuBookmark, identifier: UIIdentifiers.ReaderChapterList.bookmarksButton)
    private let indicator = UIView()
    private var selectedTab: ReaderTocTabPagerViewController.Tab = .chapters
    private var indicatorProgress: CGFloat = 0
    private var lastLayoutBounds: CGRect?
    private var lastLayoutDirection: UIUserInterfaceLayoutDirection?

    var onSelect: ((ReaderTocTabPagerViewController.Tab) -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        isAccessibilityElement = false
        chaptersButton.addTarget(self, action: #selector(showChapters), for: .touchUpInside)
        bookmarksButton.addTarget(self, action: #selector(showBookmarks), for: .touchUpInside)
        addSubview(chaptersButton)
        addSubview(bookmarksButton)
        indicator.isUserInteractionEnabled = false
        indicator.isAccessibilityElement = false
        addSubview(indicator)
        updateFonts()
        updateSelection()
        applyPalette(ReaderTocPalette(traits: traitCollection))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var bounds: CGRect {
        didSet {
            if oldValue.width != bounds.width { invalidateIntrinsicContentSize() }
        }
    }

    /// Width-dependent full line boxes, with a 48pt floor. Before assigning a width, use sizeThatFits.
    override var intrinsicContentSize: CGSize {
        CGSize(
            width: UIView.noIntrinsicMetric,
            height: preferredHeight(availableWidth: bounds.width > 0 ? bounds.width : nil))
    }

    /// The toolbar supplies its tab slot width and must allocate the returned height without capping it.
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite ? max(0, size.width) : 2 * largestTabWidth + 2 * Metrics.centeringGutter
        return CGSize(width: width, height: preferredHeight(availableWidth: width))
    }

    private var largestTabWidth: CGFloat {
        min(
            Metrics.maximumTabWidth,
            max(
                chaptersButton.measuredWidth(
                    maximumWidth: Metrics.maximumTabWidth, horizontalPadding: Metrics.horizontalPadding),
                bookmarksButton.measuredWidth(
                    maximumWidth: Metrics.maximumTabWidth, horizontalPadding: Metrics.horizontalPadding)))
    }

    private func tabWidth(availableWidth: CGFloat) -> CGFloat {
        let largestWidth = largestTabWidth
        let canCenter = 2 * largestWidth <= availableWidth - 2 * Metrics.centeringGutter
        return canCenter ? largestWidth : availableWidth / 2
    }

    private func preferredHeight(availableWidth: CGFloat?) -> CGFloat {
        let width = availableWidth.map { tabWidth(availableWidth: $0) } ?? largestTabWidth
        let titleHeight = max(
            chaptersButton.preferredTitleHeight(tabWidth: width, horizontalPadding: Metrics.horizontalPadding),
            bookmarksButton.preferredTitleHeight(tabWidth: width, horizontalPadding: Metrics.horizontalPadding))
        return max(Metrics.defaultHeight, titleHeight + 2 * Metrics.verticalPadding)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let direction = effectiveUserInterfaceLayoutDirection
        if lastLayoutBounds != bounds || lastLayoutDirection != direction {
            indicator.layer.removeAllAnimations()
            lastLayoutBounds = bounds
            lastLayoutDirection = direction
        }
        let availableWidth = max(0, bounds.width)
        let tabWidth = self.tabWidth(availableWidth: availableWidth)
        let startX = bounds.minX + (availableWidth - 2 * tabWidth) / 2
        let firstFrame = CGRect(x: startX, y: bounds.minY, width: tabWidth, height: max(0, bounds.height))
        let secondFrame = firstFrame.offsetBy(dx: tabWidth, dy: 0)
        UIView.performWithoutAnimation {
            self.chaptersButton.frame = direction == .rightToLeft ? secondFrame : firstFrame
            self.bookmarksButton.frame = direction == .rightToLeft ? firstFrame : secondFrame
            self.chaptersButton.fitTitle(horizontalPadding: Metrics.horizontalPadding)
            self.bookmarksButton.fitTitle(horizontalPadding: Metrics.horizontalPadding)
            self.indicator.frame = self.indicatorFrame(at: self.indicatorProgress)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            indicator.layer.removeAllAnimations()
            updateFonts()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { indicator.layer.removeAllAnimations() }
    }

    func select(_ tab: ReaderTocTabPagerViewController.Tab, animated: Bool) {
        selectedTab = tab
        updateSelection()
        animateTransition(to: tab == .chapters ? 0 : 1, duration: animated ? Metrics.selectionDuration : 0)
    }

    /// Material follows the nearest tab while dragging; the pager owns the committed selection.
    func setTransitionProgress(_ progress: CGFloat) {
        guard progress.isFinite else { return }
        selectedTab = progress >= 0.5 ? .bookmarks : .chapters
        updateSelection()
        animateTransition(to: progress, duration: 0)
    }

    /// Programmatic paging can animate the underline in parallel without announcing a selection early.
    func animateTransition(to progress: CGFloat, duration: TimeInterval) {
        guard progress.isFinite else { return }
        layoutIfNeeded()
        let startFrame = indicator.layer.presentation()?.frame ?? indicator.frame
        indicator.layer.removeAllAnimations()
        indicatorProgress = min(1, max(0, progress))
        let targetFrame = indicatorFrame(at: indicatorProgress)
        UIView.performWithoutAnimation { self.indicator.frame = targetFrame }
        guard duration.isFinite, duration > 0, window != nil, bounds.width > 0, bounds.height > 0,
            !UIAccessibility.isReduceMotionEnabled, startFrame != targetFrame
        else { return }

        let position = CABasicAnimation(keyPath: "position")
        position.fromValue = NSValue(cgPoint: CGPoint(x: startFrame.midX, y: startFrame.midY))
        position.toValue = NSValue(cgPoint: CGPoint(x: targetFrame.midX, y: targetFrame.midY))
        let size = CABasicAnimation(keyPath: "bounds")
        size.fromValue = NSValue(cgRect: CGRect(origin: .zero, size: startFrame.size))
        size.toValue = NSValue(cgRect: CGRect(origin: .zero, size: targetFrame.size))
        let animation = CAAnimationGroup()
        animation.animations = [position, size]
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        indicator.layer.add(animation, forKey: "reader.toc.indicator")
    }

    func setControlsEnabled(_ enabled: Bool) {
        chaptersButton.isEnabled = enabled
        bookmarksButton.isEnabled = enabled
        updateSelection()
    }

    func applyPalette(_ palette: ReaderTocPalette) {
        indicator.backgroundColor = palette.accent
        for button in [chaptersButton, bookmarksButton] {
            button.applyTitleColors(primary: palette.toolbarText, secondary: palette.toolbarSecondaryText)
        }
    }

    private func updateFonts() {
        // TextAppearance.Design.Tab -> AppCompat.Button -> sans-serif-medium, with no selected weight override.
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        let multilineFont = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        for button in [chaptersButton, bookmarksButton] {
            button.setFonts(singleLine: font, multiline: multilineFont)
        }
    }

    private func updateSelection() {
        chaptersButton.isSelected = selectedTab == .chapters
        bookmarksButton.isSelected = selectedTab == .bookmarks
        for button in [chaptersButton, bookmarksButton] {
            var traits: UIAccessibilityTraits = .button
            if button.isSelected { traits.insert(.selected) }
            if !button.isEnabled { traits.insert(.notEnabled) }
            button.accessibilityTraits = traits
        }
    }

    private func indicatorFrame(at progress: CGFloat) -> CGRect {
        let start = indicatorFrame(for: chaptersButton)
        let end = indicatorFrame(for: bookmarksButton)
        // Material's linear indicator interpolates the two content edges, not the entire tab background.
        let left = start.minX + (end.minX - start.minX) * progress
        let right = start.maxX + (end.maxX - start.maxX) * progress
        return CGRect(x: left, y: start.minY, width: max(0, right - left), height: start.height)
    }

    private func indicatorFrame(for button: ReaderTocTabButton) -> CGRect {
        let width = min(button.bounds.width, max(Metrics.minimumIndicatorWidth, button.renderedTitleWidth))
        let height = min(Metrics.indicatorHeight, max(0, bounds.height))
        return CGRect(x: button.frame.midX - width / 2, y: bounds.maxY - height, width: width, height: height)
    }

    @objc private func showChapters() { onSelect?(.chapters) }
    @objc private func showBookmarks() { onSelect?(.bookmarks) }
}

private final class ReaderTocTabButton: UIButton {
    private struct TitleLayout {
        let font: UIFont
        let size: CGSize
    }

    private let caption = AndroidExploreTextLabel()
    private let sizingCaption = UILabel()
    private let captionTitle: String
    private var singleLineFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private var multilineFont = UIFont.systemFont(ofSize: 12, weight: .medium)
    private var primaryTitleColor = UIColor.white
    private var secondaryTitleColor = UIColor.white.withAlphaComponent(179.0 / 255.0)
    private var captionFrame = CGRect.zero
    private(set) var renderedTitleWidth: CGFloat = 0

    override var isSelected: Bool {
        didSet { updateTitleColor() }
    }

    private var titleColor: UIColor {
        // mtrl_tabs_legacy_text_color_selector uses toolbar primary/secondary text, not the indicator accent.
        isSelected ? primaryTitleColor : secondaryTitleColor
    }

    init(title: String, identifier: String) {
        // The Android text appearance is all-caps; keep the original localized title for accessibility.
        captionTitle = title.uppercased(with: Locale.current)
        super.init(frame: .zero)
        backgroundColor = .clear
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        for label in [caption, sizingCaption] {
            label.isAccessibilityElement = false
            label.isUserInteractionEnabled = false
            label.textAlignment = .center
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 2
            label.adjustsFontSizeToFitWidth = false
            label.clipsToBounds = true
        }
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func layoutSubviews() {
        super.layoutSubviews()
        caption.frame = captionFrame
    }

    func setFonts(singleLine: UIFont, multiline: UIFont) {
        singleLineFont = singleLine
        multilineFont = multiline
    }

    func measuredWidth(maximumWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        let contentWidth = max(0, maximumWidth - 2 * horizontalPadding)
        let singleLineWidth = (captionTitle as NSString).size(withAttributes: attributes(font: singleLineFont)).width
        // TabView.onMeasure remeasures its wrap_content TextView at 12sp when the 14sp text wraps.
        let font = singleLineWidth > contentWidth ? multilineFont : singleLineFont
        let titleWidth = ceil((captionTitle as NSString).size(withAttributes: attributes(font: font)).width)
        return min(maximumWidth, titleWidth + 2 * horizontalPadding)
    }

    func applyTitleColors(primary: UIColor, secondary: UIColor) {
        primaryTitleColor = primary
        secondaryTitleColor = secondary
        updateTitleColor()
    }

    private func updateTitleColor() {
        if let text = caption.attributedText {
            let updated = NSMutableAttributedString(attributedString: text)
            updated.addAttribute(
                .foregroundColor, value: titleColor, range: NSRange(location: 0, length: updated.length))
            caption.attributedText = updated
        }
    }

    func fitTitle(horizontalPadding: CGFloat) {
        // Base.Widget.Design.TabLayout keeps its 12dp side padding, including at narrow widths.
        let availableWidth = max(0, bounds.width - 2 * horizontalPadding)
        guard availableWidth > 0, bounds.height > 0 else {
            captionFrame = .zero
            caption.frame = .zero
            renderedTitleWidth = 0
            return
        }
        let layout = titleLayout(contentWidth: availableWidth)
        caption.font = layout.font
        caption.attributedText = NSAttributedString(string: captionTitle, attributes: attributes(font: layout.font))
        renderedTitleWidth = layout.size.width
        // Never shrink accessibility text or trim its line box to the current toolbar height.
        let height = layout.size.height
        captionFrame = CGRect(
            x: bounds.midX - renderedTitleWidth / 2, y: bounds.midY - height / 2,
            width: renderedTitleWidth, height: height)
        caption.frame = captionFrame
    }

    func preferredTitleHeight(tabWidth: CGFloat, horizontalPadding: CGFloat) -> CGFloat {
        titleLayout(contentWidth: max(0, tabWidth - 2 * horizontalPadding)).size.height
    }

    private func attributes(font: UIFont) -> [NSAttributedString.Key: Any] {
        [.font: font, .kern: CGFloat(0), .foregroundColor: titleColor]
    }

    private func titleLayout(contentWidth: CGFloat) -> TitleLayout {
        guard contentWidth > 0 else { return TitleLayout(font: singleLineFont, size: .zero) }
        let singleLineWidth = (captionTitle as NSString).size(withAttributes: attributes(font: singleLineFont)).width
        // TabView.onMeasure only changes 14sp to 12sp when the title wraps, never because of height.
        let font = singleLineWidth > contentWidth ? multilineFont : singleLineFont
        let titleWidth = ceil((captionTitle as NSString).size(withAttributes: attributes(font: font)).width)
        // Like a wrap_content TextView, a wrapped caption occupies its constrained content width.
        let width = min(contentWidth, titleWidth)
        sizingCaption.font = font
        sizingCaption.attributedText = NSAttributedString(string: captionTitle, attributes: attributes(font: font))
        let textSize = sizingCaption.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        // TextView defaults includeFontPadding=true; StaticLayout applies top/bottom once, not per line.
        // AndroidExploreTextLabel draws with these same font-boundary insets around UIKit's two-line layout.
        let scale = max(1, traitCollection.displayScale)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
        let height = ceil((max(font.lineHeight, textSize.height) + padding.top + padding.bottom) * scale) / scale
        return TitleLayout(font: font, size: CGSize(width: width, height: height))
    }
}
