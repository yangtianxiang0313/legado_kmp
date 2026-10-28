import UIKit
import shared

final class SearchInputHelpView: UIView {
    var onBookSelected: ((Book) -> Void)?
    var onHistorySelected: ((String) -> Void)?
    var onHistoryDeleted: ((String) -> Void)?
    var onClearHistory: (() -> Void)?
    var canActivate: (() -> Bool)?

    private var presentationActive = true
    private var historyRevision = UUID()
    private var booksRevision = UUID()

    private let viewportScrollView = SearchInputHelpScrollView()
    private let contentView = UIView()
    private let bookshelfSection = SearchInputHelpSection(title: L10n.Bookshelf.title)
    private let historySection = SearchInputHelpSection(title: L10n.Search.historyTitle, hasClearButton: true)

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        accessibilityIdentifier = UIIdentifiers.Search.inputHelp
        clipsToBounds = true

        addSubview(viewportScrollView)
        viewportScrollView.addSubview(contentView)
        contentView.addSubview(bookshelfSection)
        contentView.addSubview(historySection)
        bookshelfSection.isHidden = true

        historySection.clearButton?.addAction(
            UIAction { [weak self] _ in
                guard let self, self.canDeliverInput,
                    let clearButton = self.historySection.clearButton,
                    canActivateSearchInputHelpElement(clearButton)
                else { return }
                self.onClearHistory?()
            }, for: .touchUpInside)
        updateFonts()
        updateAccessibilityOrder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func update(history: [SearchKeyword]) {
        historyRevision = UUID()
        let revision = historyRevision
        historySection.update(
            items: history.map { keyword in
                let word = keyword.word
                return SearchInputHelpItem(
                    identifier: word,
                    text: word,
                    accessibilityIdentifier: UIIdentifiers.Search.historyCell,
                    accessibilityHint: nil,
                    onSelect: { [weak self] in
                        guard let self, self.canDeliverInput, self.historyRevision == revision else { return }
                        self.onHistorySelected?(word)
                    },
                    onDelete: { [weak self] in
                        guard let self, self.canDeliverInput, self.historyRevision == revision,
                            let onDelete = self.onHistoryDeleted
                        else { return false }
                        onDelete(word)
                        return true
                    }
                )
            })
        setNeedsLayout()
    }

    func update(books: [Book]) {
        booksRevision = UUID()
        let revision = booksRevision
        bookshelfSection.update(
            items: books.map { book in
                SearchInputHelpItem(
                    identifier: book.bookUrl,
                    text: book.name,
                    accessibilityIdentifier: nil,
                    accessibilityHint: L10n.Bookshelf.openDetail,
                    onSelect: { [weak self] in
                        guard let self, self.canDeliverInput, self.booksRevision == revision else { return }
                        self.onBookSelected?(book)
                    },
                    onDelete: nil
                )
            })
        bookshelfSection.isHidden = books.isEmpty
        updateAccessibilityOrder()
        setNeedsLayout()
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        isUserInteractionEnabled = active
        accessibilityElementsHidden = !active
        if !active {
            for control in inputControls(in: self) {
                control.cancelTracking(with: nil)
                control.isHighlighted = false
            }
        }
    }

    private var canDeliverInput: Bool {
        guard presentationActive, canActivate?() != false,
            let window, !window.isHidden, window.windowScene?.activationState == .foregroundActive
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            if let scroll = view as? UIScrollView, scroll.isDragging || scroll.isDecelerating {
                return false
            }
            ancestor = view.superview
        }
        return true
    }

    private func inputControls(in view: UIView) -> [UIControl] {
        (view as? UIControl).map { [$0] } ?? view.subviews.flatMap { inputControls(in: $0) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let viewport = bounds.inset(by: safeAreaInsets)
        viewportScrollView.frame = CGRect(
            x: viewport.minX, y: viewport.minY,
            width: max(0, viewport.width), height: max(0, viewport.height)
        )
        let width = viewportScrollView.bounds.width
        guard width > 0 else { return }
        let height = viewportScrollView.bounds.height
        let hasBooks = !bookshelfSection.isHidden
        let bookHeaderHeight = hasBooks ? bookshelfSection.headerHeight(for: width) : 0
        let headerHeight = bookHeaderHeight + historySection.headerHeight(for: width)
        let minimumBookHeight = hasBooks ? bookshelfSection.minimumContentHeight : 0
        let minimumHeight = headerHeight + minimumBookHeight + historySection.minimumContentHeight

        // Keep two independent recycler-like panes. Only scroll their headers as a
        // whole when even one row per nonempty pane cannot fit above the keyboard.
        let contentHeight = max(height, minimumHeight)
        let bodyHeight = max(0, contentHeight - headerHeight)
        var bookHeight: CGFloat = 0
        if hasBooks {
            let bookLimit =
                historySection.isEmpty
                ? bodyHeight
                : max(0, bodyHeight - historySection.minimumContentHeight)
            bookHeight = bookHeaderHeight + min(bookshelfSection.contentHeight(for: width), bookLimit)
        }
        bookshelfSection.frame = CGRect(x: 0, y: 0, width: width, height: bookHeight)
        historySection.frame = CGRect(
            x: 0, y: bookHeight, width: width, height: max(0, contentHeight - bookHeight)
        )

        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        let size = contentView.bounds.size
        if viewportScrollView.contentSize != size {
            viewportScrollView.contentSize = size
        }
        let needsOuterScroll = contentHeight > height
        if viewportScrollView.isScrollEnabled != needsOuterScroll {
            viewportScrollView.isScrollEnabled = needsOuterScroll
        }
        if !viewportScrollView.isTracking, !viewportScrollView.isDecelerating {
            viewportScrollView.clampContentOffset()
        }
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
                || previousTraitCollection?.displayScale != traitCollection.displayScale
        else { return }
        updateFonts()
        setNeedsLayout()
    }

    private var inputFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
    }

    private func updateFonts() {
        bookshelfSection.updateFont(inputFont)
        historySection.updateFont(inputFont)
    }

    private func updateAccessibilityOrder() {
        contentView.accessibilityElements =
            bookshelfSection.isHidden
            ? [historySection]
            : [bookshelfSection, historySection]
    }
}

private struct SearchInputHelpItem {
    let identifier: String
    let text: String
    let accessibilityIdentifier: String?
    let accessibilityHint: String?
    let onSelect: () -> Void
    let onDelete: (() -> Bool)?
}

private final class SearchInputHelpSection: UIView {
    let clearButton: SearchInputHelpClearButton?

    private let titleLabel = SearchInputHelpTitleLabel()
    private let scrollView = SearchInputHelpScrollView()
    private let chipContainer = UIView()
    private var chips: [SearchInputHelpChip] = []
    private var font = UIFont.systemFont(ofSize: 14)
    private var pendingAnchor: ScrollAnchor?
    private var needsChipLayout = true
    private var layoutWidth: CGFloat = -1
    private var layoutDirection: UIUserInterfaceLayoutDirection?

    private struct ScrollAnchor {
        struct Candidate {
            let chip: SearchInputHelpChip
            let offsetWithinRow: CGFloat
        }

        let candidates: [Candidate]
        let fallbackOffset: CGFloat
    }

    var isEmpty: Bool { chips.isEmpty }
    private var textHeight: CGFloat {
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        return ceil(font.lineHeight) + padding.top + padding.bottom
    }
    var minimumContentHeight: CGFloat { isEmpty ? 0 : textHeight + 14 }

    func headerHeight(for width: CGFloat) -> CGFloat {
        headerLayout(width: width).height
    }

    init(title: String, hasClearButton: Bool = false) {
        clearButton = hasClearButton ? SearchInputHelpClearButton() : nil
        super.init(frame: .zero)
        clipsToBounds = true
        shouldGroupAccessibilityChildren = true
        accessibilityContainerType = .semanticGroup

        titleLabel.text = title
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        addSubview(titleLabel)
        if let clearButton {
            clearButton.isHidden = true
            addSubview(clearButton)
        }
        addSubview(scrollView)
        scrollView.addSubview(chipContainer)
        updateFont(font)
        updateAccessibilityOrder()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func update(items: [SearchInputHelpItem]) {
        let anchor = pendingAnchor ?? scrollAnchor()
        // Preserve views (and VoiceOver focus) across repeated flow emissions.
        var reusable = Dictionary(grouping: chips.reversed(), by: \.itemIdentifier)
        var textChanged = false
        let updated = items.map { item -> SearchInputHelpChip in
            let chip: SearchInputHelpChip
            if let existing = reusable[item.identifier]?.popLast() {
                chip = existing
                textChanged = chip.currentTitle != item.text || textChanged
                chip.update(item: item)
            } else {
                chip = SearchInputHelpChip(item: item, font: font)
                chipContainer.addSubview(chip)
            }
            return chip
        }
        let orderChanged = chips.count != updated.count || zip(chips, updated).contains { $0.0 !== $0.1 }
        for chip in reusable.values.flatMap({ $0 }) {
            chip.removeFromSuperview()
        }
        chips = updated
        clearButton?.isHidden = items.isEmpty
        if orderChanged || textChanged {
            pendingAnchor = anchor
            needsChipLayout = true
            setNeedsLayout()
        }
        updateAccessibilityOrder()
    }

    func updateFont(_ font: UIFont) {
        pendingAnchor = pendingAnchor ?? scrollAnchor()
        self.font = font
        titleLabel.font = font
        clearButton?.updateFont(font)
        for chip in chips {
            chip.updateFont(font)
        }
        needsChipLayout = true
        setNeedsLayout()
    }

    func contentHeight(for width: CGFloat) -> CGFloat {
        layoutChips(width: width, applyFrames: false)
    }

    private func headerLayout(width: CGFloat) -> (
        clearWidth: CGFloat, titleHeight: CGFloat, clearHeight: CGFloat, height: CGFloat
    ) {
        // INVISIBLE retains the clear TextView's wrap-content width; the weighted title gets the rest.
        let clearWidth =
            clearButton.map {
                min(width, ceil($0.titleLabel?.intrinsicContentSize.width ?? 0) + 12)
            } ?? 0
        let titleWidth = max(0, width - clearWidth - 12)
        let titleHeight =
            titleWidth > 0
            ? ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
            : 0
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        let clearHeight =
            clearButton.map { button in
                let size =
                    button.titleLabel?.sizeThatFits(
                        CGSize(width: max(1, clearWidth - 12), height: .greatestFiniteMagnitude)) ?? .zero
                return ceil(max(font.lineHeight, size.height)) + padding.top + padding.bottom
            } ?? 0
        return (clearWidth, titleHeight, clearHeight, max(titleHeight, clearHeight) + 12)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0 else { return }
        let anchor = pendingAnchor ?? scrollAnchor()
        let oldViewportSize = scrollView.bounds.size
        let oldContentSize = scrollView.contentSize
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let header = headerLayout(width: width)
        let clearWidth = header.clearWidth
        titleLabel.frame = CGRect(
            x: isRTL ? clearWidth + 6 : 6, y: 6,
            width: max(0, width - clearWidth - 12), height: header.titleHeight
        )
        clearButton?.frame = CGRect(
            x: isRTL ? 0 : width - clearWidth, y: 0, width: clearWidth, height: header.clearHeight + 12
        )
        scrollView.frame = CGRect(x: 0, y: header.height, width: width, height: max(0, bounds.height - header.height))

        let reflow = needsChipLayout || layoutWidth != width || layoutDirection != effectiveUserInterfaceLayoutDirection
        if reflow {
            let height = layoutChips(width: width, applyFrames: true)
            chipContainer.frame = CGRect(x: 0, y: 0, width: width, height: height)
            if scrollView.contentSize != chipContainer.bounds.size {
                scrollView.contentSize = chipContainer.bounds.size
            }
            layoutWidth = width
            layoutDirection = effectiveUserInterfaceLayoutDirection
            needsChipLayout = false
        }
        let canScroll = scrollView.contentSize.height > scrollView.bounds.height && scrollView.bounds.height > 0
        if scrollView.isScrollEnabled != canScroll {
            scrollView.isScrollEnabled = canScroll
        }
        if reflow || oldViewportSize != scrollView.bounds.size || oldContentSize != scrollView.contentSize {
            let offset: CGFloat
            if let candidate = anchor?.candidates.first(where: { candidate in
                chips.contains(where: { $0 === candidate.chip })
            }) {
                offset = candidate.chip.frame.minY + candidate.offsetWithinRow
            } else {
                offset = anchor?.fallbackOffset ?? scrollView.contentOffset.y
            }
            scrollView.clampContentOffset(proposedY: offset)
        }
        pendingAnchor = nil
    }

    private func layoutChips(width: CGFloat, applyFrames: Bool) -> CGFloat {
        guard !chips.isEmpty else { return 0 }
        // item_fillet_text.xml: each item owns 3dp on all sides, including at wraps.
        let margin: CGFloat = 3
        let availableWidth = max(0, width - margin * 2)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var x = margin
        var y = margin
        var rowHeight: CGFloat = 0
        for chip in chips {
            let size = chip.sizeThatFits(CGSize(width: availableWidth, height: .greatestFiniteMagnitude))
            if x > margin, x + size.width + margin > width {
                x = margin
                y += rowHeight + margin * 2
                rowHeight = 0
            }
            if applyFrames {
                chip.frame = CGRect(
                    x: isRTL ? width - x - size.width : x, y: y, width: size.width, height: size.height
                )
            }
            x += size.width + margin * 2
            rowHeight = max(rowHeight, size.height)
        }
        return y + rowHeight + margin
    }

    private func scrollAnchor() -> ScrollAnchor? {
        guard scrollView.bounds.height > 0 else { return nil }
        let visible = chips.filter { $0.frame.intersects(scrollView.bounds) }
        guard !visible.isEmpty else { return nil }
        return ScrollAnchor(
            candidates: visible.map {
                ScrollAnchor.Candidate(chip: $0, offsetWithinRow: scrollView.contentOffset.y - $0.frame.minY)
            },
            fallbackOffset: scrollView.contentOffset.y
        )
    }

    private func updateAccessibilityOrder() {
        var elements: [Any] = [titleLabel]
        if let clearButton, !clearButton.isHidden {
            elements.append(clearButton)
        }
        elements.append(scrollView)
        accessibilityElements = elements
        chipContainer.accessibilityElements = chips
    }
}

private final class SearchInputHelpChip: UIButton {
    let itemIdentifier: String
    private var onSelect: () -> Void
    private var onDelete: (() -> Bool)?
    private var deleteGesture: UILongPressGestureRecognizer?

    init(item: SearchInputHelpItem, font: UIFont) {
        itemIdentifier = item.identifier
        onSelect = item.onSelect
        onDelete = item.onDelete
        super.init(frame: .zero)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .highlighted)
        titleLabel?.numberOfLines = 1
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.textAlignment = .center
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.adjustsFontForContentSizeCategory = false
        updateFont(font)
        layer.cornerRadius = 16
        clipsToBounds = true
        isAccessibilityElement = true
        accessibilityTraits = .button
        addAction(
            UIAction { [weak self] _ in
                guard let self, canActivateSearchInputHelpElement(self) else { return }
                self.onSelect()
            }, for: .touchUpInside)
        update(item: item)
        updateAppearance()
    }

    func update(item: SearchInputHelpItem) {
        if currentTitle != item.text {
            setTitle(item.text, for: .normal)
        }
        onSelect = item.onSelect
        onDelete = item.onDelete
        accessibilityLabel = item.text
        accessibilityHint = item.accessibilityHint
        accessibilityIdentifier = item.accessibilityIdentifier
        if onDelete != nil {
            if deleteGesture == nil {
                let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
                gesture.cancelsTouchesInView = true
                addGestureRecognizer(gesture)
                deleteGesture = gesture
            }
            deleteGesture?.isEnabled = true
            if accessibilityCustomActions == nil {
                accessibilityCustomActions = [
                    UIAccessibilityCustomAction(name: L10n.Common.delete) { [weak self] _ in
                        guard let self, canActivateSearchInputHelpElement(self) else { return false }
                        return self.onDelete?() ?? false
                    }
                ]
            }
        } else {
            deleteGesture?.isEnabled = false
            accessibilityCustomActions = nil
        }
    }

    func updateFont(_ font: UIFont) {
        titleLabel?.font = font
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        contentEdgeInsets = UIEdgeInsets(top: 4 + padding.top, left: 12, bottom: 4 + padding.bottom, right: 12)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateAppearance()
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        // UIButton's natural title width must not escape the single-line chip.
        CGRect(
            x: contentRect.minX, y: contentRect.minY,
            width: max(0, contentRect.width), height: max(0, contentRect.height)
        )
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        // Use only this item's margins, so adjacent chips never share a hit area.
        bounds.insetBy(dx: -3, dy: -3).contains(point)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let titleSize = titleLabel?.intrinsicContentSize ?? .zero
        return CGSize(
            width: min(max(0, size.width), ceil(max(0, titleSize.width)) + 24),
            height: ceil(max(titleLabel?.font.lineHeight ?? 0, titleSize.height))
                + contentEdgeInsets.top + contentEdgeInsets.bottom
        )
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        revealSearchInputHelpElement(self)
    }

    override func accessibilityActivate() -> Bool {
        guard canActivateSearchInputHelpElement(self) else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func updateAppearance() {
        backgroundColor =
            isHighlighted || isFocused
            ? SearchInputHelpColors.chipPressed
            : SearchInputHelpColors.chipNormal
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, canActivateSearchInputHelpElement(self) else { return }
        cancelTracking(with: nil)
        isHighlighted = false
        _ = onDelete?()
    }
}

private final class SearchInputHelpClearButton: UIButton {
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        setTitle(L10n.Search.clearHistory, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .highlighted)
        titleLabel?.numberOfLines = 0
        titleLabel?.lineBreakMode = .byWordWrapping
        titleLabel?.adjustsFontForContentSizeCategory = false
        contentEdgeInsets = UIEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        accessibilityLabel = L10n.Search.clearHistory
        accessibilityIdentifier = UIIdentifiers.Search.clearHistoryButton
        accessibilityTraits = .button
        updateAppearance()
    }

    func updateFont(_ font: UIFont) {
        titleLabel?.font = font
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        contentEdgeInsets = UIEdgeInsets(top: 6 + padding.top, left: 6, bottom: 6 + padding.bottom, right: 6)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        updateAppearance()
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        CGRect(
            x: contentRect.minX, y: contentRect.minY,
            width: max(0, contentRect.width), height: max(0, contentRect.height)
        )
    }

    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        revealSearchInputHelpElement(self)
    }

    private func updateAppearance() {
        backgroundColor = isHighlighted || isFocused ? AndroidReplicaTheme.activeIndicator : .clear
    }
}

private final class SearchInputHelpTitleLabel: AndroidExploreTextLabel {
    override func accessibilityElementDidBecomeFocused() {
        super.accessibilityElementDidBecomeFocused()
        revealSearchInputHelpElement(self)
    }
}

private enum SearchInputHelpColors {
    // selector_fillet_btn_bg -> shape_fillet_btn[_press], values[-night]/colors.xml.
    static let chipNormal = UIColor { traits in
        UIColor(white: CGFloat(traits.userInterfaceStyle == .dark ? 0x4D : 0xAC) / 255, alpha: CGFloat(0x63) / 255)
    }
    static let chipPressed = UIColor { traits in
        UIColor(white: CGFloat(traits.userInterfaceStyle == .dark ? 0x68 : 0x85) / 255, alpha: CGFloat(0x63) / 255)
    }
}

private final class SearchInputHelpScrollView: UIScrollView {
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        // activity_book_search.xml leaves both input-help RecyclerView scrollbars off.
        showsVerticalScrollIndicator = false
        alwaysBounceVertical = false
        delaysContentTouches = false
        canCancelContentTouches = true
        isDirectionalLockEnabled = true
        keyboardDismissMode = .none
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func clampContentOffset(proposedY: CGFloat? = nil) {
        let maximumOffset = max(0, contentSize.height - bounds.height)
        let y = min(maximumOffset, max(0, proposedY ?? contentOffset.y))
        if contentOffset.x != 0 || abs(contentOffset.y - y) > 0.5 {
            setContentOffset(CGPoint(x: 0, y: y), animated: false)
        }
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIButton || super.touchesShouldCancel(in: view)
    }
}

private func revealSearchInputHelpElement(_ view: UIView) {
    var ancestor = view.superview
    while let container = ancestor {
        if container is SearchInputHelpView { break }
        if let scrollView = container as? UIScrollView, scrollView.bounds.height > 0 {
            // Reveal in the inner pane first, then in the emergency outer viewport.
            scrollView.scrollRectToVisible(view.convert(view.bounds, to: scrollView), animated: false)
        }
        ancestor = container.superview
    }
}

private func canActivateSearchInputHelpElement(_ view: UIView) -> Bool {
    guard let window = view.window, !window.isHidden,
        window.windowScene?.activationState == .foregroundActive
    else { return false }
    var visible = view.convert(view.bounds, to: window).intersection(window.bounds)
    var ancestor: UIView? = view
    while let current = ancestor {
        guard !current.isHidden, current.alpha > 0.01, current.isUserInteractionEnabled else { return false }
        if let control = current as? UIControl, !control.isEnabled { return false }
        if let scroll = current as? UIScrollView, scroll.isDragging || scroll.isDecelerating {
            return false
        }
        if current.clipsToBounds {
            visible = visible.intersection(current.convert(current.bounds, to: window))
        }
        ancestor = current.superview
    }
    return !visible.isNull && !visible.isEmpty
}

final class SearchScreenPresentationObserver: UIView {
    var onDetach: (() -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            DispatchQueue.main.async { [self] in onDetach?() }
        }
    }
}
