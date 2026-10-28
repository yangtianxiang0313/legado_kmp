import UIKit

@MainActor
final class BookInfoEditFormView: UIView {
    let nameField: UITextField = BookInfoEditTextField()
    let authorField: UITextField = BookInfoEditTextField()
    let typeButton = BookInfoEditTypeButton()
    let coverUrlTextView = BookInfoEditGrowingTextView()
    let introTextView = BookInfoEditGrowingTextView()
    let defaultCoverView = AndroidDefaultBookCoverView()
    let coverImageView = UIImageView()
    let coverSpinner = UIActivityIndicatorView(style: .medium)
    let localCoverButton: UIButton = BookInfoEditStrokeButton(title: "选择本地图片")
    let coverSourceButton: UIButton = BookInfoEditStrokeButton(title: "封面换源")
    let refreshCoverButton: UIButton = BookInfoEditStrokeButton(title: "刷新封面")
    let scrollView = UIScrollView()

    private let overflowScrollView = UIScrollView()
    private let header = UIView()
    private let body = UIView()
    private let typeRow = UIScrollView()
    private let typeLabel = AndroidExploreTextLabel()
    private let commandScrollView = UIScrollView()
    private var fields: [BookInfoEditField] = []
    private var usesOverflowScrolling = false
    private var isLayingOutForm = false
    private var lastLayoutSize = CGSize.zero
    private var lastHeaderHeight: CGFloat = 0
    private var lastBodyHeight: CGFloat = 0
    private var lastCommandDirection: UIUserInterfaceLayoutDirection?
    private var lastTypeDirection: UIUserInterfaceLayoutDirection?
    private var disabledControls: [(UIControl, Bool)] = []
    private var lockedTextViews: [(UITextView, Bool)] = []
    private var isBusy = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        configureEditors()
        configureHierarchy()
        refreshAppearanceAndFields()
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func setBusy(_ busy: Bool) {
        guard busy != isBusy else { return }
        isBusy = busy
        if busy {
            let controls: [UIControl] = [
                nameField, authorField, typeButton, localCoverButton, coverSourceButton, refreshCoverButton,
            ]
            disabledControls = controls.map { ($0, $0.isEnabled) }
            lockedTextViews = [coverUrlTextView, introTextView].map { ($0, $0.isEditable) }
            for (control, _) in disabledControls { control.isEnabled = false }
            for (textView, _) in lockedTextViews { textView.isEditable = false }
        } else {
            for (control, wasEnabled) in disabledControls { control.isEnabled = wasEnabled }
            for (textView, wasEditable) in lockedTextViews { textView.isEditable = wasEditable }
            disabledControls.removeAll()
            lockedTextViews.removeAll()
        }
        refreshAppearanceAndFields()
    }

    func setCoverSourceAvailable(_ available: Bool) {
        guard coverSourceButton.isHidden == available else { return }
        coverSourceButton.isHidden = !available
        setNeedsLayout()
    }

    func refreshAppearanceAndFields() {
        backgroundColor = AndroidReplicaTheme.background
        tintColor = AndroidReplicaTheme.accent
        coverImageView.backgroundColor = AndroidReplicaTheme.coverBackground
        coverImageView.tintColor = AndroidReplicaTheme.secondaryText
        coverSpinner.color = AndroidReplicaTheme.accent
        typeLabel.textColor = AndroidReplicaTheme.primaryText
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        typeLabel.font = font
        typeLabel.adjustsFontForContentSizeCategory = false
        typeButton.refreshAppearance()
        for field in fields { field.refreshAppearanceAndFields() }
        for button in [localCoverButton, coverSourceButton, refreshCoverButton] {
            (button as? BookInfoEditStrokeButton)?.refreshAppearance()
        }
        setNeedsLayout()
    }

    func revealActiveEditor() {
        guard !isBusy, !isLayingOutForm else { return }
        layoutIfNeeded()
        revealEditorInCurrentLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isLayingOutForm, bounds.width > 0, bounds.height > 0 else { return }
        isLayingOutForm = true
        defer { isLayingOutForm = false }
        let anchor = captureScrollAnchor()
        let viewport = CGRect(
            x: safeAreaInsets.left, y: 0,
            width: max(1, bounds.width - safeAreaInsets.left - safeAreaInsets.right), height: bounds.height)
        let fieldWidth = max(1, viewport.width - 110)
        let nameHeight = fields[0].sizeThatFits(CGSize(width: fieldWidth, height: 0)).height
        let authorHeight = fields[1].sizeThatFits(CGSize(width: fieldWidth, height: 0)).height
        let headerHeight = max(140, nameHeight + authorHeight + 20)
        let bodyHeight = layoutBody(width: viewport.width)
        let minimumBodyViewport = max(typeRow.bounds.height, fields[2].minimumContentHeight)
        let overflow = viewport.height - headerHeight < minimumBodyViewport
        let geometryChanged =
            lastLayoutSize != viewport.size || lastHeaderHeight != headerHeight
            || lastBodyHeight != bodyHeight || usesOverflowScrolling != overflow

        // Both scroll containers and every editor keep their parent for the form's entire lifetime.
        overflowScrollView.frame = viewport
        header.frame = CGRect(x: 0, y: 0, width: viewport.width, height: headerHeight)
        layoutHeader(width: viewport.width, nameHeight: nameHeight, authorHeight: authorHeight)
        scrollView.frame = CGRect(
            x: 0, y: headerHeight, width: viewport.width,
            height: overflow ? bodyHeight : max(0, viewport.height - headerHeight))
        body.frame = CGRect(x: 0, y: 0, width: viewport.width, height: bodyHeight)
        scrollView.contentSize = body.bounds.size
        scrollView.isScrollEnabled = !overflow
        scrollView.alwaysBounceVertical = !overflow
        overflowScrollView.contentSize = CGSize(
            width: viewport.width, height: overflow ? headerHeight + bodyHeight : viewport.height)
        overflowScrollView.isScrollEnabled = overflow
        overflowScrollView.alwaysBounceVertical = overflow
        usesOverflowScrolling = overflow

        if overflow {
            scrollView.setContentOffset(.zero, animated: false)
        } else {
            overflowScrollView.setContentOffset(.zero, animated: false)
        }
        for field in fields { field.layoutIfNeeded() }
        if geometryChanged {
            if let anchor { restoreScrollAnchor(anchor) }
            revealEditorInCurrentLayout()
        }
        lastLayoutSize = viewport.size
        lastHeaderHeight = headerHeight
        lastBodyHeight = bodyHeight
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearanceAndFields()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    private func configureEditors() {
        for (field, title, identifier) in [
            (nameField, "书名", "name"), (authorField, "作者", "author"),
        ] {
            field.accessibilityLabel = title
            field.accessibilityIdentifier = "bookInfoEdit.\(identifier)"
            field.clearButtonMode = .never
            field.autocorrectionType = .no
            field.returnKeyType = .next
        }
        for (textView, title, identifier) in [
            (coverUrlTextView, "封面地址", "coverUrl"), (introTextView, "内容简介", "intro"),
        ] {
            textView.accessibilityLabel = title
            textView.accessibilityIdentifier = "bookInfoEdit.\(identifier)"
        }
        coverUrlTextView.autocapitalizationType = .none
        coverUrlTextView.autocorrectionType = .no
        coverUrlTextView.spellCheckingType = .no
        coverUrlTextView.smartQuotesType = .no
        coverUrlTextView.smartDashesType = .no
        coverUrlTextView.smartInsertDeleteType = .no
        coverUrlTextView.textContentType = .URL
        coverUrlTextView.textContainer.lineBreakMode = .byCharWrapping
        typeButton.accessibilityLabel = "类型"
        typeButton.accessibilityIdentifier = "bookInfoEdit.type"
        for (button, identifier) in [
            (localCoverButton, "localCover"), (coverSourceButton, "coverSource"),
            (refreshCoverButton, "refreshCover"),
        ] {
            button.accessibilityIdentifier = "bookInfoEdit.\(identifier)"
        }
        coverImageView.accessibilityLabel = "封面"
        coverImageView.accessibilityIdentifier = "bookInfoEdit.coverPreview"
        coverImageView.isAccessibilityElement = true
        coverImageView.clipsToBounds = true
        coverImageView.contentMode = .scaleAspectFill
        defaultCoverView.accessibilityLabel = "封面"
        defaultCoverView.accessibilityIdentifier = "bookInfoEdit.coverPreview"
        defaultCoverView.isAccessibilityElement = true
        defaultCoverView.accessibilityElementsHidden = false
        defaultCoverView.isUserInteractionEnabled = false
        defaultCoverView.isHidden = true
        coverSpinner.hidesWhenStopped = true
    }

    private func configureHierarchy() {
        fields = [
            BookInfoEditField(title: "书名", editor: nameField),
            BookInfoEditField(title: "作者", editor: authorField),
            BookInfoEditField(title: "封面地址", editor: coverUrlTextView),
            BookInfoEditField(title: "内容简介", editor: introTextView),
        ]
        for field in fields { field.onMetricsChange = { [weak self] in self?.setNeedsLayout() } }
        for scroller in [overflowScrollView, scrollView, typeRow, commandScrollView] {
            scroller.contentInsetAdjustmentBehavior = .never
            scroller.isDirectionalLockEnabled = true
            scroller.scrollsToTop = false
        }
        for scroller in [overflowScrollView, scrollView] {
            scroller.keyboardDismissMode = .interactive
        }
        typeRow.showsHorizontalScrollIndicator = false
        scrollView.accessibilityIdentifier = "bookInfoEdit.form"
        addSubview(overflowScrollView)
        overflowScrollView.addSubview(header)
        overflowScrollView.addSubview(scrollView)
        header.addSubview(defaultCoverView)
        header.addSubview(coverImageView)
        header.addSubview(coverSpinner)
        header.addSubview(fields[0])
        header.addSubview(fields[1])
        scrollView.addSubview(body)
        typeLabel.text = "类型："
        typeLabel.isAccessibilityElement = false
        typeRow.addSubview(typeLabel)
        typeRow.addSubview(typeButton)
        for child in [typeRow, fields[2], commandScrollView, fields[3]] { body.addSubview(child) }
        for button in [localCoverButton, coverSourceButton, refreshCoverButton] {
            commandScrollView.addSubview(button)
        }
    }

    private var isRTL: Bool { effectiveUserInterfaceLayoutDirection == .rightToLeft }

    private func directionalFrame(leading: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, in total: CGFloat)
        -> CGRect
    {
        CGRect(x: isRTL ? total - leading - width : leading, y: y, width: width, height: height)
    }

    private func layoutHeader(width: CGFloat, nameHeight: CGFloat, authorHeight: CGFloat) {
        coverImageView.frame = directionalFrame(leading: 5, y: 5, width: 90, height: 130, in: width)
        defaultCoverView.frame = coverImageView.frame
        coverSpinner.sizeToFit()
        coverSpinner.center = coverImageView.center
        let fieldWidth = max(1, width - 110)
        fields[0].frame = directionalFrame(leading: 100, y: 10, width: fieldWidth, height: nameHeight, in: width)
        fields[1].frame = directionalFrame(
            leading: 100, y: 10 + nameHeight, width: fieldWidth, height: authorHeight, in: width)
    }

    private func layoutBody(width: CGFloat) -> CGFloat {
        let labelSize = typeLabel.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let buttonSize = typeButton.intrinsicContentSize
        let rowHeight = max(ceil(labelSize.height), max(0, buttonSize.height))
        let labelWidth = ceil(labelSize.width)
        let buttonWidth = max(0, buttonSize.width)
        let contentWidth = max(width, 15 + labelWidth + buttonWidth)
        let oldRange = max(0, typeRow.contentSize.width - typeRow.bounds.width)
        let oldLeadingOffset = isRTL ? oldRange - typeRow.contentOffset.x : typeRow.contentOffset.x
        typeRow.frame = CGRect(x: 0, y: 0, width: width, height: rowHeight)
        typeLabel.frame = directionalFrame(leading: 12, y: 0, width: labelWidth, height: rowHeight, in: contentWidth)
        typeButton.frame = directionalFrame(
            leading: 15 + labelWidth, y: 0, width: buttonWidth, height: rowHeight, in: contentWidth)
        typeRow.contentSize = CGSize(width: contentWidth, height: rowHeight)
        let range = max(0, contentWidth - width)
        let direction = effectiveUserInterfaceLayoutDirection
        let leadingOffset = lastTypeDirection == direction ? min(range, max(0, oldLeadingOffset)) : 0
        let offset = CGPoint(x: isRTL ? range - leadingOffset : leadingOffset, y: 0)
        if typeRow.contentOffset != offset { typeRow.setContentOffset(offset, animated: false) }
        lastTypeDirection = direction
        let coverHeight = fields[2].sizeThatFits(CGSize(width: width, height: 0)).height
        fields[2].frame = CGRect(x: 0, y: rowHeight + 5, width: width, height: coverHeight)
        commandScrollView.frame.origin = CGPoint(x: 5, y: fields[2].frame.maxY)
        _ = layoutCommands(width: max(1, width - 10))
        let introHeight = fields[3].sizeThatFits(CGSize(width: width, height: 0)).height
        fields[3].frame = CGRect(x: 0, y: commandScrollView.frame.maxY + 10, width: width, height: introHeight)
        return fields[3].frame.maxY
    }

    private func layoutCommands(width: CGFloat) -> CGFloat {
        let buttons = [localCoverButton, coverSourceButton, refreshCoverButton].filter { !$0.isHidden }
        let sizes = buttons.map { $0.intrinsicContentSize }
        let height = sizes.map(\.height).max() ?? 0
        let total = sizes.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 10
        let oldRange = max(0, commandScrollView.contentSize.width - commandScrollView.bounds.width)
        let oldLeadingOffset = isRTL ? oldRange - commandScrollView.contentOffset.x : commandScrollView.contentOffset.x
        commandScrollView.frame.size = CGSize(width: width, height: height)
        let contentWidth = max(width, total)
        var leading: CGFloat = 0
        for (button, size) in zip(buttons, sizes) {
            button.frame = directionalFrame(
                leading: leading, y: (height - size.height) / 2, width: size.width, height: size.height,
                in: contentWidth)
            leading += size.width + 10
        }
        commandScrollView.contentSize = CGSize(width: contentWidth, height: height)
        let range = max(0, contentWidth - width)
        let direction = effectiveUserInterfaceLayoutDirection
        let offset = lastCommandDirection == direction ? min(range, max(0, oldLeadingOffset)) : 0
        let contentOffset = CGPoint(x: isRTL ? range - offset : offset, y: 0)
        if commandScrollView.contentOffset != contentOffset {
            commandScrollView.setContentOffset(contentOffset, animated: false)
        }
        lastCommandDirection = direction
        return height
    }

    private var activeScrollView: UIScrollView { usesOverflowScrolling ? overflowScrollView : scrollView }

    private struct ScrollAnchor {
        let view: UIView
        let localY: CGFloat
        let viewportY: CGFloat
        var textView: UITextView?
        var textOffset: Int?
        var caretViewportY: CGFloat?
    }

    private func captureScrollAnchor() -> ScrollAnchor? {
        guard lastLayoutSize != .zero else { return nil }
        let scroller = activeScrollView
        let top = scroller.contentOffset.y
        let candidates =
            usesOverflowScrolling
            ? [header, typeRow, fields[2], commandScrollView, fields[3]]
            : [typeRow, fields[2], commandScrollView, fields[3]]
        for candidate in candidates {
            let rect = candidate.convert(candidate.bounds, to: scroller)
            if rect.maxY > top {
                var anchor = ScrollAnchor(
                    view: candidate, localY: max(0, top - rect.minY), viewportY: max(0, rect.minY - top))
                if let textView = (candidate as? BookInfoEditField)?.editor as? UITextView {
                    let editorRect = textView.convert(textView.bounds, to: scroller)
                    if top >= editorRect.minY, top < editorRect.maxY {
                        let point = CGPoint(
                            x: isRTL
                                ? textView.bounds.maxX - textView.textContainerInset.right
                                : textView.textContainerInset.left,
                            y: textView.convert(CGPoint(x: 0, y: top), from: scroller).y)
                        if let position = textView.closestPosition(to: point) {
                            anchor.textView = textView
                            anchor.textOffset = textView.offset(from: textView.beginningOfDocument, to: position)
                            anchor.caretViewportY =
                                textView.convert(textView.caretRect(for: position), to: scroller).minY - top
                        }
                    }
                }
                return anchor
            }
        }
        return nil
    }

    private func restoreScrollAnchor(_ anchor: ScrollAnchor) {
        let scroller = activeScrollView
        if !usesOverflowScrolling, anchor.view === header { return }
        if let textView = anchor.textView, let offset = anchor.textOffset, let viewportY = anchor.caretViewportY,
            let position = textView.position(from: textView.beginningOfDocument, offset: offset)
        {
            let y = textView.convert(textView.caretRect(for: position), to: scroller).minY
            if y.isFinite {
                setVerticalOffset(y - viewportY, in: scroller)
                return
            }
        }
        let y = anchor.view.convert(CGPoint(x: 0, y: min(anchor.localY, anchor.view.bounds.height)), to: scroller).y
        setVerticalOffset(y - anchor.viewportY, in: scroller)
    }

    private func revealEditorInCurrentLayout() {
        guard !isBusy else { return }
        let editors: [UIView] = [nameField, authorField, coverUrlTextView, introTextView]
        guard let editor = editors.first(where: \.isFirstResponder) else { return }
        if !usesOverflowScrolling, editor === nameField || editor === authorField { return }
        let scroller = activeScrollView
        guard scroller.bounds.height > 0 else { return }
        let editorRect: CGRect
        if let textView = editor as? UITextView, let selection = textView.selectedTextRange {
            editorRect = textView.caretRect(for: selection.end)
        } else if let textField = editor as? UITextField, let selection = textField.selectedTextRange {
            editorRect = textField.caretRect(for: selection.end)
        } else {
            editorRect = editor.bounds
        }
        let rect = editor.convert(editorRect, to: scroller)
        guard rect.minY.isFinite, rect.maxY.isFinite else { return }
        let padding = min(16, max(0, (scroller.bounds.height - rect.height) / 2))
        let top = scroller.contentOffset.y
        if rect.minY - padding < top {
            setVerticalOffset(rect.minY - padding, in: scroller)
        } else if rect.maxY + padding > top + scroller.bounds.height {
            setVerticalOffset(rect.maxY + padding - scroller.bounds.height, in: scroller)
        }
    }

    private func setVerticalOffset(_ y: CGFloat, in scroller: UIScrollView) {
        let limit = max(0, scroller.contentSize.height - scroller.bounds.height)
        let offset = CGPoint(x: 0, y: min(limit, max(0, y)))
        if scroller.contentOffset != offset { scroller.setContentOffset(offset, animated: false) }
    }
}

@MainActor
private final class BookInfoEditStrokeButton: UIButton {
    private var titleInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)

    init(title: String) {
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        accessibilityLabel = title
        titleLabel?.numberOfLines = 1
        titleLabel?.adjustsFontSizeToFitWidth = false
        layer.borderWidth = 1
        layer.cornerRadius = 1
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet { updateColors() }
    }

    override var isSelected: Bool {
        didSet { updateColors() }
    }

    override var isEnabled: Bool {
        didSet { updateColors() }
    }

    override var intrinsicContentSize: CGSize {
        let font = titleLabel?.font ?? .systemFont(ofSize: 14)
        let size = ((title(for: .normal) ?? "") as NSString).size(withAttributes: [.font: font])
        let insets = titleInsets
        return CGSize(
            width: ceil(size.width) + insets.left + insets.right,
            height: ceil(font.lineHeight) + insets.top + insets.bottom)
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        contentRect.inset(by: titleInsets)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearance()
    }

    func refreshAppearance() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        // titleRect can run while UIKit is creating titleLabel; never read it from that callback.
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        titleInsets = UIEdgeInsets(top: 5 + padding.top, left: 5, bottom: 5 + padding.bottom, right: 5)
        titleLabel?.font = font
        titleLabel?.adjustsFontForContentSizeCategory = false
        invalidateIntrinsicContentSize()
        updateColors()
    }

    private func updateColors() {
        let disabled = UIColor(white: 158 / 255, alpha: 1)
        let color =
            !isEnabled ? disabled : (isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText)
        setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
        setTitleColor(AndroidReplicaTheme.accent, for: .selected)
        setTitleColor(AndroidReplicaTheme.accent, for: [.selected, .highlighted])
        setTitleColor(disabled, for: .disabled)
        setTitleColor(disabled, for: [.selected, .disabled])
        layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
        let pressed = traitCollection.userInterfaceStyle == .dark ? UIColor.white : UIColor.black
        backgroundColor = isHighlighted && isEnabled ? pressed.withAlphaComponent(48 / 255) : .clear
    }
}
