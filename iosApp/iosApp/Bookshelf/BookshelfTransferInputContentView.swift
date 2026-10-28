import UIKit

@MainActor
final class BookshelfTransferInputContentView: UIView {
    let titleLabel = UILabel()
    let textView = UITextView()
    let cancelControl = BookshelfLayoutDialogAction(title: L10n.Common.cancel)
    let submitControl = BookshelfLayoutDialogAction(title: L10n.Common.confirm)
    let fileControl = BookshelfLayoutDialogAction(title: "选择文件")
    let showsFileAction: Bool

    private let scrollView = BookshelfTransferInputScrollView()
    private let formView = UIView()
    private let footerView = UIView()
    private let placeholderLabel = UILabel()
    private let underline = UIView()
    private let errorLabel = UILabel()
    private var needsRevealCaret = false
    private var needsRevealError = false

    init(mode: BookshelfTransferInputMode, initialText: String) {
        let titleText: String
        let hint: String
        switch mode {
        case .addURL:
            titleText = "添加书籍网址"
            hint = "url"
            showsFileAction = false
        case .importBookshelf:
            titleText = "导入书单"
            hint = "url/json"
            showsFileAction = true
        }
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        accessibilityIdentifier = "bookshelf.transfer.dialog"
        for label in [titleLabel, placeholderLabel, errorLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontForContentSizeCategory = true
            label.textAlignment = .natural
        }
        titleLabel.text = titleText
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookshelf.transfer.title"
        placeholderLabel.text = hint
        placeholderLabel.lineBreakMode = .byCharWrapping
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "bookshelf.transfer.error"
        underline.isUserInteractionEnabled = false
        underline.isAccessibilityElement = false
        textView.text = initialText
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContentType = nil
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.enablesReturnKeyAutomatically = false
        textView.allowsEditingTextAttributes = false
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = hint
        textView.accessibilityIdentifier = "bookshelf.transfer.input"
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "bookshelf.transfer.form"
        cancelControl.accessibilityIdentifier = "bookshelf.transfer.cancel"
        submitControl.accessibilityIdentifier = "bookshelf.transfer.submit"
        fileControl.accessibilityIdentifier = "bookshelf.transfer.file"
        fileControl.isHidden = !showsFileAction
        footerView.backgroundColor = AndroidReplicaTheme.background
        addSubview(scrollView)
        scrollView.addSubview(formView)
        for item in [titleLabel, textView, placeholderLabel, underline, errorLabel] { formView.addSubview(item) }
        for control in [fileControl, cancelControl, submitControl] { footerView.addSubview(control) }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyAppearance(traits: UITraitCollection) {
        titleLabel.font = BookshelfLayoutDialogStyle.font(
            size: 20, weight: .medium, style: .headline, traits: traits)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        let inputFont = BookshelfLayoutDialogStyle.font(size: 18, traits: traits)
        textView.font = inputFont
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        textView.keyboardAppearance = traits.userInterfaceStyle == .dark ? .dark : .light
        placeholderLabel.font = inputFont
        placeholderLabel.textColor = AndroidReplicaTheme.secondaryText
        errorLabel.font = BookshelfLayoutDialogStyle.font(size: 13, style: .footnote, traits: traits)
        errorLabel.textColor = AndroidReplicaTheme.accent
        let actionFont = BookshelfLayoutDialogStyle.font(
            size: 14, weight: .medium, style: .subheadline, traits: traits)
        for control in [fileControl, cancelControl, submitControl] { control.apply(font: actionFont) }
        refreshInput()
    }

    func refreshInput() {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
        underline.backgroundColor =
            textView.isFirstResponder || !errorLabel.isHidden
            ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        setNeedsLayout()
    }

    func clearError() {
        errorLabel.isHidden = true
        errorLabel.text = nil
        textView.accessibilityHint = nil
        needsRevealError = false
        refreshInput()
    }

    func showEmptyError() {
        errorLabel.text = "输入不能为空"
        errorLabel.isHidden = false
        textView.accessibilityHint = errorLabel.text
        needsRevealError = true
        refreshInput()
        UIAccessibility.post(notification: .announcement, argument: errorLabel.text)
    }

    func revealCaretOnNextLayout() {
        needsRevealCaret = textView.isFirstResponder
        setNeedsLayout()
    }

    func preferredHeight(width: CGFloat) -> CGFloat {
        layoutForm(width: width) + layoutActions(width: width)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let formHeight = layoutForm(width: width)
        let footerHeight = layoutActions(width: width)
        // Extremely short keyboard/AX windows scroll the actions too, rather than overlap the editor.
        let pinsFooter = bounds.height >= footerHeight + min(48, textView.bounds.height)
        let footerParent = pinsFooter ? self : formView
        if footerView.superview !== footerParent { footerParent.addSubview(footerView) }
        footerView.frame = CGRect(
            x: 0, y: pinsFooter ? bounds.height - footerHeight : formHeight,
            width: width, height: footerHeight)
        let viewportHeight = max(0, bounds.height - (pinsFooter ? footerHeight : 0))
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        let contentHeight = formHeight + (pinsFooter ? 0 : footerHeight)
        formView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = formView.bounds.size
        scrollView.isScrollEnabled = contentHeight > viewportHeight
        let offset = CGPoint(
            x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        formView.accessibilityElements =
            pinsFooter
            ? [titleLabel, textView, errorLabel] : [titleLabel, textView, errorLabel, footerView]
        accessibilityElements = pinsFooter ? [scrollView, footerView] : [scrollView]
        revealPendingContent()
    }

    private func layoutForm(width: CGFloat) -> CGFloat {
        let titleWidth = max(1, width - 48)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        titleLabel.frame = CGRect(x: 24, y: 18, width: titleWidth, height: titleHeight)
        let inputWidth = max(1, width - 32)
        let placeholderWidth = max(1, inputWidth - 8)
        let placeholderHeight = ceil(
            placeholderLabel.sizeThatFits(CGSize(width: placeholderWidth, height: .greatestFiniteMagnitude)).height)
        let measured = textView.sizeThatFits(CGSize(width: inputWidth, height: .greatestFiniteMagnitude))
        let minimumTextHeight = max(textView.font?.lineHeight ?? 22, placeholderLabel.isHidden ? 0 : placeholderHeight)
        let inputHeight = max(48, ceil(max(minimumTextHeight + 16, measured.height)))
        textView.frame = CGRect(x: 16, y: titleLabel.frame.maxY + 12, width: inputWidth, height: inputHeight)
        placeholderLabel.frame = CGRect(
            x: 20, y: textView.frame.minY + 8, width: placeholderWidth, height: placeholderHeight)
        underline.frame = CGRect(
            x: 16, y: textView.frame.maxY, width: inputWidth,
            height: textView.isFirstResponder || !errorLabel.isHidden ? 2 : 1)
        var bottom = underline.frame.maxY + 8
        if !errorLabel.isHidden {
            let errorWidth = max(1, width - 40)
            let errorHeight = ceil(
                errorLabel.sizeThatFits(CGSize(width: errorWidth, height: .greatestFiniteMagnitude)).height)
            errorLabel.frame = CGRect(x: 20, y: bottom, width: errorWidth, height: errorHeight)
            bottom = errorLabel.frame.maxY + 8
        }
        return bottom
    }

    private func layoutActions(width: CGFloat) -> CGFloat {
        let controls = showsFileAction ? [fileControl, cancelControl, submitControl] : [cancelControl, submitControl]
        let availableWidth = max(1, width - 24)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        if controls.reduce(CGFloat.zero, { $0 + $1.preferredWidth }) <= availableWidth {
            let height = controls.map { $0.sizeThatFits(CGSize(width: $0.preferredWidth, height: 0)).height }.max() ?? 48
            let submitWidth = submitControl.preferredWidth
            let cancelWidth = cancelControl.preferredWidth
            submitControl.frame = CGRect(
                x: isRTL ? 12 : width - 12 - submitWidth, y: 4, width: submitWidth, height: height)
            cancelControl.frame = CGRect(
                x: isRTL ? submitControl.frame.maxX : submitControl.frame.minX - cancelWidth,
                y: 4, width: cancelWidth, height: height)
            fileControl.frame = CGRect(
                x: isRTL ? width - 12 - fileControl.preferredWidth : 12,
                y: 4, width: fileControl.preferredWidth, height: height)
            footerView.accessibilityElements = controls
            return height + 8
        }
        // AppCompat ButtonBarLayout stacks positive, negative, then neutral actions.
        let stackedControls = showsFileAction ? [submitControl, cancelControl, fileControl] : [submitControl, cancelControl]
        var y: CGFloat = 4
        for control in stackedControls {
            let controlWidth = min(availableWidth, control.preferredWidth)
            let height = control.sizeThatFits(CGSize(width: controlWidth, height: 0)).height
            control.frame = CGRect(
                x: isRTL ? 12 : width - 12 - controlWidth, y: y, width: controlWidth, height: height)
            y += height
        }
        footerView.accessibilityElements = stackedControls
        return y + 4
    }

    private func revealPendingContent() {
        if needsRevealError, !errorLabel.isHidden {
            needsRevealError = false
            let rect = errorLabel.frame.insetBy(dx: 0, dy: -8)
            scrollView.scrollRectToVisible(
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, scrollView.bounds.height)),
                animated: false)
            return
        }
        guard needsRevealCaret else { return }
        needsRevealCaret = false
        guard textView.isFirstResponder, let selection = textView.selectedTextRange else { return }
        textView.layoutIfNeeded()
        let caret = textView.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        scrollView.scrollRectToVisible(textView.convert(caret, to: formView).insetBy(dx: 0, dy: -8), animated: false)
    }
}

private final class BookshelfTransferInputScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is BookshelfLayoutDialogAction { return true }
        return super.touchesShouldCancel(in: view)
    }
}
