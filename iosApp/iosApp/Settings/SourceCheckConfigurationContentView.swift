import UIKit

@MainActor
final class SourceCheckConfigurationContentView: UIView {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?
    var onLayoutChange: (() -> Void)?
    var canInteract: (() -> Bool)?

    let editor = BookInfoEditGrowingTextView()
    var rawTimeout: String { editor.text ?? "" }
    var accessibilityHeading: UIView { titleLabel }
    private(set) var draft: SourceCheckSettings

    private let scrollView = SourceCheckConfigurationScrollView()
    private let formView = UIView()
    private let toolbar = UIView()
    private let titleLabel = UILabel()
    private let timeoutLabel = UILabel()
    private let underline = UIView()
    private let errorLabel = UILabel()
    private let itemsLabel = UILabel()
    private let footer = UIView()
    private let cancelButton = SourceImportPreviewStyle.actionButton(
        title: "取消", identifier: "sourceCheck.configuration.cancel")
    private let confirmButton = SourceImportPreviewStyle.actionButton(
        title: "确定", identifier: "sourceCheck.configuration.confirm")
    private let options = ["搜索", "发现", "详情", "目录", "正文"].map { SourceCheckConfigurationOptionView(title: $0) }
    private var interactionEnabled = false
    private var needsCaretReveal = false
    private var lastViewportSize: CGSize = .zero

    init(settings: SourceCheckSettings) {
        draft = settings.normalized
        super.init(frame: .zero)
        layer.cornerRadius = 2
        clipsToBounds = true
        BookshelfLayoutDialogStyle.configure(titleLabel, text: "校验设置", color: AndroidReplicaTheme.toolbarText)
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceCheck.configuration.title"
        BookshelfLayoutDialogStyle.configure(
            timeoutLabel, text: "单个书源校验超时（秒）", color: AndroidReplicaTheme.secondaryText)
        timeoutLabel.lineBreakMode = .byCharWrapping
        timeoutLabel.isAccessibilityElement = false
        BookshelfLayoutDialogStyle.configure(itemsLabel, text: "校验项目", color: AndroidReplicaTheme.accent)
        BookshelfLayoutDialogStyle.configure(errorLabel, text: "", color: .systemRed)
        errorLabel.lineBreakMode = .byCharWrapping
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "sourceCheck.configuration.error"
        editor.text = String(draft.timeoutSeconds)
        editor.backgroundColor = .clear
        editor.contentInsetAdjustmentBehavior = .never
        editor.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        editor.textContainer.lineFragmentPadding = 0
        editor.textContainer.lineBreakMode = .byCharWrapping
        editor.textContainer.maximumNumberOfLines = 0
        editor.keyboardType = .numberPad
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.spellCheckingType = .no
        editor.smartDashesType = .no
        editor.smartQuotesType = .no
        editor.smartInsertDeleteType = .no
        editor.textContentType = nil
        editor.scrollsToTop = false
        editor.allowsEditingTextAttributes = false
        editor.adjustsFontForContentSizeCategory = true
        editor.accessibilityLabel = timeoutLabel.text
        editor.accessibilityIdentifier = "sourceCheck.configuration.timeout"
        editor.onContentChange = { [weak self] in self?.requestLayout() }
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.keyboardDismissMode = .interactive
        addSubview(scrollView)
        scrollView.addSubview(formView)
        formView.addSubview(toolbar)
        toolbar.addSubview(titleLabel)
        for item in [timeoutLabel, editor, underline, errorLabel, itemsLabel] { formView.addSubview(item) }
        for (index, option) in options.enumerated() {
            option.button.tag = index
            option.button.accessibilityIdentifier = "sourceCheck.configuration.option.\(index)"
            option.button.canInteract = { [weak self] in self?.canInteract?() == true }
            option.button.addTarget(self, action: #selector(toggle(_:)), for: .touchUpInside)
            formView.addSubview(option)
        }
        for button in [cancelButton, confirmButton] {
            button.canInteract = { [weak self] in self?.canInteract?() == true }
            footer.addSubview(button)
        }
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        footer.accessibilityElements = [cancelButton, confirmButton]
        refreshOptions()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func apply(traits: UITraitCollection) {
        let palette = ReaderTocPalette(traits: traits)
        backgroundColor = palette.background
        toolbar.backgroundColor = palette.titleBackground
        titleLabel.textColor = palette.toolbarText
        titleLabel.font = BookshelfLayoutDialogStyle.font(size: 20, style: .headline, traits: traits)
        timeoutLabel.font = BookshelfLayoutDialogStyle.font(size: 12, style: .caption1, traits: traits)
        editor.tintColor = palette.accent
        editor.keyboardAppearance = traits.userInterfaceStyle == .dark ? .dark : .light
        itemsLabel.font = BookshelfLayoutDialogStyle.font(size: 14, traits: traits)
        itemsLabel.textColor = palette.accent
        errorLabel.font = BookshelfLayoutDialogStyle.font(size: 12, style: .caption1, traits: traits)
        for option in options { option.apply(traits: traits, palette: palette) }
        for button in [cancelButton, confirmButton] {
            var configuration = button.configuration
            configuration?.baseForegroundColor = palette.accent
            button.configuration = configuration
            button.setNeedsUpdateConfiguration()
        }
        scrollView.indicatorStyle = traits.userInterfaceStyle == .dark ? .white : .black
        updateInputAppearance()
        revealCaretOnNextLayout()
    }

    func setInteraction(editable: Bool, confirmEnabled: Bool) {
        interactionEnabled = editable
        if editor.isEditable != editable { editor.isEditable = editable }
        cancelButton.isEnabled = editable
        confirmButton.isEnabled = confirmEnabled
        refreshOptions()
    }

    func showError(_ message: String?) {
        errorLabel.text = message
        errorLabel.isHidden = message == nil
        updateInputAppearance()
        requestLayout()
    }

    func updateInputAppearance() {
        let palette = ReaderTocPalette(traits: traitCollection)
        if editor.markedTextRange == nil {
            let font = BookshelfLayoutDialogStyle.font(size: 18, traits: traitCollection)
            if editor.font != font { editor.font = font }
            editor.textColor = palette.primaryText
        }
        let focused = editor.isFirstResponder
        timeoutLabel.textColor = errorLabel.isHidden ? (focused ? palette.accent : palette.secondaryText) : .systemRed
        underline.backgroundColor = errorLabel.isHidden ? (focused ? palette.accent : palette.secondaryText) : .systemRed
        setNeedsLayout()
    }

    func revealCaretOnNextLayout() {
        needsCaretReveal = true
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrangeForm(width: size.width, apply: false) + arrangeFooter(width: size.width, apply: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let formHeight = arrangeForm(width: width, apply: true)
        let footerHeight = arrangeFooter(width: width, apply: true)
        // Short keyboard/AX viewports scroll the chrome too; otherwise keep both actions visible.
        let pinsFooter = bounds.height >= footerHeight + 48
        let footerParent = pinsFooter ? self : formView
        if footer.superview !== footerParent { footerParent.addSubview(footer) }
        footer.frame = CGRect(x: 0, y: pinsFooter ? bounds.height - footerHeight : formHeight, width: width, height: footerHeight)
        let viewportHeight = max(0, bounds.height - (pinsFooter ? footerHeight : 0))
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        let contentHeight = formHeight + (pinsFooter ? 0 : footerHeight)
        formView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = formView.bounds.size
        scrollView.isScrollEnabled = contentHeight > viewportHeight
        let offset = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight))
        if scrollView.contentOffset.y != offset { scrollView.contentOffset = CGPoint(x: 0, y: offset) }
        var elements: [UIView] = [titleLabel, editor]
        if !errorLabel.isHidden { elements.append(errorLabel) }
        elements += [itemsLabel] + options.map { $0.button }
        formView.accessibilityElements = pinsFooter ? elements : elements + [footer]
        accessibilityElements = pinsFooter ? [scrollView, footer] : [scrollView]
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsCaretReveal = true
        }
        if needsCaretReveal {
            needsCaretReveal = false
            if editor.isFirstResponder, let selection = editor.selectedTextRange {
                editor.layoutIfNeeded()
                let caret = editor.caretRect(for: selection.end)
                if !caret.isNull, !caret.isInfinite {
                    var target = editor.convert(caret, to: formView).insetBy(dx: 0, dy: -8)
                    target.size.height = min(target.height, viewportHeight)
                    scrollView.scrollRectToVisible(target, animated: false)
                }
            }
        }
    }

    private func arrangeForm(width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(12, max(0, (width - 1) / 2))
        let contentWidth = max(1, width - inset * 2)
        let titleInset = min(16, max(0, (width - 1) / 2))
        let titleWidth = max(1, width - titleInset * 2)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let toolbarHeight = max(56, titleHeight + 16)
        if apply {
            toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
            titleLabel.frame = CGRect(x: titleInset, y: (toolbarHeight - titleHeight) / 2, width: titleWidth, height: titleHeight)
        }
        var y = toolbarHeight + 3
        func place(_ item: UIView, height: CGFloat) {
            if apply { item.frame = CGRect(x: inset, y: y, width: contentWidth, height: height) }
            y += height
        }
        place(timeoutLabel, height: ceil(timeoutLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height))
        place(editor, height: max(48, editor.height(fitting: contentWidth)))
        place(underline, height: editor.isFirstResponder || !errorLabel.isHidden ? 2 : 1)
        if !errorLabel.isHidden {
            y += 4
            place(errorLabel, height: ceil(errorLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height))
        }
        y += 8
        place(itemsLabel, height: ceil(itemsLabel.sizeThatFits(CGSize(width: contentWidth, height: .greatestFiniteMagnitude)).height))
        y += arrangeOptions(width: contentWidth, origin: CGPoint(x: inset, y: y), apply: apply)
        return y + 4
    }

    private func arrangeOptions(width: CGFloat, origin: CGPoint, apply: Bool) -> CGFloat {
        var rows: [[(SourceCheckConfigurationOptionView, CGSize)]] = []
        var row: [(SourceCheckConfigurationOptionView, CGSize)] = []
        var used: CGFloat = 0
        for option in options {
            let itemWidth = min(width, option.preferredWidth)
            let size = option.sizeThatFits(CGSize(width: itemWidth, height: .greatestFiniteMagnitude))
            if !row.isEmpty, used + itemWidth > width {
                rows.append(row)
                row = []
                used = 0
            }
            row.append((option, size))
            used += itemWidth
        }
        if !row.isEmpty { rows.append(row) }
        var y: CGFloat = 0
        for row in rows {
            let height = row.map { $0.1.height }.max() ?? 0
            let used = row.reduce(CGFloat.zero) { $0 + $1.1.width }
            let gap = row.count > 1 ? max(0, width - used) / CGFloat(row.count - 1) : 0
            var x: CGFloat = 0
            for (option, size) in row {
                if apply {
                    let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                    option.frame = CGRect(x: origin.x + (rtl ? width - x - size.width : x), y: origin.y + y, width: size.width, height: height)
                }
                x += size.width + gap
            }
            y += height
        }
        return y
    }

    private func arrangeFooter(width: CGFloat, apply: Bool) -> CGFloat {
        let inset = min(12, max(0, (width - 1) / 2))
        let available = max(1, width - inset * 2)
        let sizes = [cancelButton, confirmButton].map { SourceImportPreviewStyle.actionSize($0, constrainedTo: available) }
        let inline = sizes[0].width + sizes[1].width <= available
        let rowHeight = max(sizes[0].height, sizes[1].height)
        var y: CGFloat = 0
        for (index, button) in [cancelButton, confirmButton].enumerated() {
            let size = sizes[index]
            if apply {
                let x = inline && index == 0 ? width - inset - sizes[1].width - size.width : width - inset - size.width
                button.frame = CGRect(x: x, y: y, width: size.width, height: inline ? rowHeight : size.height)
            }
            if !inline { y += size.height }
        }
        return inline ? rowHeight : y
    }

    private func refreshOptions() {
        let values = [draft.checkSearch, draft.checkDiscovery, draft.checkInfo, draft.checkCategory, draft.checkContent]
        for (index, option) in options.enumerated() {
            option.update(
                selected: values[index],
                enabled: interactionEnabled && (index != 3 || draft.checkInfo)
                    && (index != 4 || (draft.checkInfo && draft.checkCategory)))
        }
    }

    private func requestLayout() {
        setNeedsLayout()
        onLayoutChange?()
    }

    @objc private func toggle(_ button: UIButton) {
        guard interactionEnabled, button.isEnabled, canInteract?() == true else { return }
        switch button.tag {
        case 0:
            draft.checkSearch.toggle()
            if !draft.checkSearch && !draft.checkDiscovery { draft.checkDiscovery = true }
        case 1:
            draft.checkDiscovery.toggle()
            if !draft.checkSearch && !draft.checkDiscovery { draft.checkSearch = true }
        case 2: draft.checkInfo.toggle()
        case 3: draft.checkCategory.toggle()
        case 4: draft.checkContent.toggle()
        default: return
        }
        draft = draft.normalized
        refreshOptions()
    }

    @objc private func cancel() { onCancel?() }
    @objc private func confirm() { onConfirm?() }
}

/// Same AppCompat checkbox assets and 32dp label placement as the existing source editor.
private final class SourceCheckConfigurationOptionView: UIView {
    let button = SourceImportPreviewActionButton(type: .custom)
    private let mark = UIImageView()
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        BookshelfLayoutDialogStyle.configure(label, text: title, color: AndroidReplicaTheme.primaryText)
        label.lineBreakMode = .byCharWrapping
        label.isAccessibilityElement = false
        mark.contentMode = .scaleAspectFit
        mark.isUserInteractionEnabled = false
        mark.isAccessibilityElement = false
        button.accessibilityLabel = title
        button.isAccessibilityElement = true
        addSubview(button)
        button.addSubview(mark)
        button.addSubview(label)
        accessibilityElements = [button]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    var preferredWidth: CGFloat {
        max(44, 32 + ceil(label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width))
    }

    func apply(traits: UITraitCollection, palette: ReaderTocPalette) {
        label.font = BookshelfLayoutDialogStyle.font(size: 14, traits: traits)
        label.textColor = palette.primaryText
        mark.tintColor = button.isSelected ? palette.accent : palette.secondaryText
        setNeedsLayout()
    }

    func update(selected: Bool, enabled: Bool) {
        button.isSelected = selected
        button.isEnabled = enabled
        button.alpha = enabled ? 1 : 0.38
        mark.image = UIImage(named: selected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
            .withRenderingMode(.alwaysTemplate)
        let palette = ReaderTocPalette(traits: traitCollection)
        mark.tintColor = selected ? palette.accent : palette.secondaryText
        var traits: UIAccessibilityTraits = .button
        if selected { traits.insert(.selected) }
        if !enabled { traits.insert(.notEnabled) }
        button.accessibilityTraits = traits
        button.accessibilityValue = selected ? "已选中" : "未选中"
        if !enabled { button.cancelTracking(with: nil) }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let stacked = size.width < 32 + ceil(label.font?.pointSize ?? 14)
        let textWidth = max(1, size.width - (stacked ? 0 : 32))
        let height = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: size.width, height: max(48, height + (stacked ? 44 : 8)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        button.frame = bounds
        let stacked = bounds.width < 32 + ceil(label.font?.pointSize ?? 14)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let markWidth = min(32, bounds.width)
        mark.frame = CGRect(x: rtl ? bounds.width - markWidth : 0, y: stacked ? 4 : (bounds.height - 32) / 2, width: markWidth, height: 32)
        let textWidth = max(1, bounds.width - (stacked ? 0 : 32))
        let height = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        label.frame = CGRect(x: stacked || rtl ? 0 : 32, y: stacked ? 40 : (bounds.height - height) / 2, width: textWidth, height: height)
    }
}

private final class SourceCheckConfigurationScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
