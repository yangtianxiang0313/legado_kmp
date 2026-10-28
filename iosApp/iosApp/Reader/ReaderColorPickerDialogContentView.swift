import UIKit

/// cpv_dialog_color_picker / cpv_dialog_presets and AppCompat's un-tinted AlertDialog chrome.
@MainActor
final class ReaderColorPickerDialogContentView: UIView {
    var onConfirm: (() -> Void)?
    var onStateChange: (() -> Void)?
    var canBeginEditing: (() -> Bool)?

    let hexInput: ReaderColorHexInput
    private(set) var color: UIColor
    var accessibilityHeading: UIView { titleLabel }
    var isValidForSubmission: Bool { isCustom ? hexInput.isValidForSubmission : true }

    private let initialColor: UIColor
    private let titleLabel = AndroidExploreTextLabel()
    private let scrollView = ReaderColorDialogScrollView()
    private let formView = UIView()
    private let customBody = UIView()
    private let customPicker: ReaderColorCustomPickerView
    private var presetsPicker: ReaderColorPresetsView?
    private let oldPreview = UIView()
    private let newPreview = UIButton(type: .custom)
    private let arrowView = UIImageView(image: UIImage(systemName: "arrow.right"))
    private let footerView = UIView()
    private var modeControl: BookshelfLayoutDialogAction
    private let confirmControl = BookshelfLayoutDialogAction(title: "确认")
    private var isCustom: Bool
    private var isSynchronizingColor = false
    private var isEditable = false
    private var isSubmitEnabled = false
    private var needsHexReveal = false
    private var lastViewportSize: CGSize = .zero

    init(color: UIColor, startsWithPresets: Bool = false) {
        initialColor = color
        self.color = color
        hexInput = ReaderColorHexInput(color: color)
        customPicker = ReaderColorCustomPickerView(color: color)
        isCustom = !startsWithPresets
        modeControl = BookshelfLayoutDialogAction(title: startsWithPresets ? "自定义颜色" : "预置颜色")
        super.init(frame: .zero)
        // ColorPreferenceCompat.applyTint replaces AppCompat's surface with filletBackground;
        // the reader's plain ColorPickerDialog keeps its original floating surface.
        backgroundColor =
            startsWithPresets
            ? AndroidReplicaTheme.background
            : UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 66.0 / 255, alpha: 1) : .white }
        layer.cornerRadius = startsWithPresets ? 3 : 2
        clipsToBounds = true
        accessibilityViewIsModal = true
        BookshelfLayoutDialogStyle.configure(titleLabel, text: "选择颜色", color: AndroidReplicaTheme.primaryText)
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.colorPicker.title"
        oldPreview.backgroundColor = initialColor
        oldPreview.isUserInteractionEnabled = false
        oldPreview.isAccessibilityElement = true
        oldPreview.accessibilityLabel = "原颜色"
        oldPreview.accessibilityIdentifier = "reader.colorPicker.old"
        newPreview.backgroundColor = color
        newPreview.accessibilityLabel = "确认颜色"
        newPreview.accessibilityIdentifier = "reader.colorPicker.new"
        newPreview.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        for preview in [oldPreview, newPreview] {
            preview.layer.borderWidth = 1
            preview.layer.borderColor = UIColor(white: 110.0 / 255, alpha: 1).cgColor
            preview.layer.cornerRadius = 0
        }
        arrowView.tintColor = AndroidReplicaTheme.primaryText
        arrowView.contentMode = .scaleAspectFit
        arrowView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        arrowView.isAccessibilityElement = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        confirmControl.accessibilityIdentifier = "reader.colorPicker.confirm"
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        configureModeControl()
        addSubview(scrollView)
        scrollView.addSubview(formView)
        formView.addSubview(titleLabel)
        formView.addSubview(customBody)
        for child in [customPicker, oldPreview, arrowView, newPreview, hexInput] { customBody.addSubview(child) }
        for child in [modeControl, confirmControl] { footerView.addSubview(child) }
        customBody.accessibilityElements = [customPicker, oldPreview, newPreview, hexInput]
        customPicker.onColorChange = { [weak self] color in self?.receive(color, from: .custom) }
        hexInput.canBeginEditing = { [weak self] in self?.canBeginEditing?() ?? false }
        hexInput.onColorChange = { [weak self] color in self?.receive(color, from: .hex) }
        hexInput.onSubmit = { [weak self] in self?.confirm() }
        hexInput.onEditingStateChange = { [weak self] in
            guard let self else { return }
            self.revealHexOnNextLayout()
            self.updateInteraction()
            self.onStateChange?()
        }
        if startsWithPresets { updatePickerBody() }
        applyFonts(traits: traitCollection)
        updatePreviewAccessibility()
        updateInteraction()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = BookshelfLayoutDialogStyle.font(size: 20, weight: .medium, style: .headline, traits: traits)
        let actionFont = BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits)
        modeControl.apply(font: actionFont)
        confirmControl.apply(font: actionFont)
        hexInput.applyFonts(traits: traits)
        presetsPicker?.updateFonts(compatibleWith: traits)
        updatePreviewAccessibility()
        revealHexOnNextLayout()
    }

    func setInteraction(editable: Bool, submitEnabled: Bool) {
        isEditable = editable
        isSubmitEnabled = submitEnabled
        updateInteraction()
    }

    func revealHexOnNextLayout() {
        needsHexReveal = true
        setNeedsLayout()
    }

    func prepareForSubmission() -> Bool {
        !isCustom || hexInput.prepareForSubmission()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: arrangeForm(width: formWidth(for: size.width), applyFrames: false)
                + arrangeActions(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        let contentWidth = formWidth(for: width)
        let formHeight = arrangeForm(width: contentWidth, applyFrames: true)
        let footerHeight = arrangeActions(width: width, applyFrames: true)
        let pinsFooter = bounds.height >= footerHeight + 48
        let footerParent = pinsFooter ? self : formView
        if footerView.superview !== footerParent { footerParent.addSubview(footerView) }
        footerView.frame = CGRect(
            x: 0, y: pinsFooter ? bounds.height - footerHeight : formHeight, width: width, height: footerHeight)
        let viewportHeight = max(0, bounds.height - (pinsFooter ? footerHeight : 0))
        scrollView.frame = CGRect(x: 0, y: 0, width: width, height: viewportHeight)
        let contentHeight = formHeight + (pinsFooter ? 0 : footerHeight)
        formView.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        scrollView.contentSize = formView.bounds.size
        scrollView.isScrollEnabled = contentHeight > viewportHeight || contentWidth > width
        scrollView.showsHorizontalScrollIndicator = contentWidth > width
        let offset = CGPoint(
            x: min(max(0, scrollView.contentOffset.x), max(0, contentWidth - width)),
            y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        let body: UIView = isCustom ? customBody : (presetsPicker ?? customBody)
        formView.accessibilityElements = pinsFooter ? [titleLabel, body] : [titleLabel, body, footerView]
        accessibilityElements = pinsFooter ? [scrollView, footerView] : [scrollView]
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsHexReveal = true
        }
        revealPendingHex()
    }

    private enum ColorOrigin { case custom, presets, hex }

    private func receive(_ newColor: UIColor, from origin: ColorOrigin) {
        guard isEditable, !isSynchronizingColor else { return }
        isSynchronizingColor = true
        color = newColor
        // An HSV touch must not echo RGB back into the picker: gray/black assignments reset hue/saturation.
        if origin != .custom { customPicker.setColor(newColor) }
        if origin != .presets { presetsPicker?.setColor(newColor) }
        hexInput.setColor(newColor)
        newPreview.backgroundColor = newColor
        updatePreviewAccessibility()
        isSynchronizingColor = false
        updateInteraction()
        onStateChange?()
    }

    private func updateInteraction() {
        customPicker.isUserInteractionEnabled = isEditable
        presetsPicker?.isUserInteractionEnabled = isEditable
        hexInput.setInteraction(enabled: isEditable)
        modeControl.isEnabled = isEditable && !hexInput.hasMarkedText
        let canConfirm = isEditable && isSubmitEnabled && isValidForSubmission
        newPreview.isEnabled = canConfirm
        confirmControl.isEnabled = canConfirm
    }

    private func configureModeControl() {
        modeControl.accessibilityIdentifier = "reader.colorPicker.mode"
        modeControl.addTarget(self, action: #selector(toggleMode), for: .touchUpInside)
    }

    @objc private func toggleMode() {
        guard modeControl.isEnabled, !hexInput.hasMarkedText else { return }
        hexInput.endEditing(true)
        isCustom.toggle()
        updatePickerBody()
        modeControl.removeFromSuperview()
        modeControl = BookshelfLayoutDialogAction(title: isCustom ? "预置颜色" : "自定义颜色")
        configureModeControl()
        footerView.addSubview(modeControl)
        applyFonts(traits: traitCollection)
        updateInteraction()
        scrollView.setContentOffset(.zero, animated: false)
        setNeedsLayout()
        onStateChange?()
    }

    private func updatePickerBody() {
        if !isCustom {
            // Android recreates createPresetsView on entry, deriving shades from the current color.
            presetsPicker?.removeFromSuperview()
            let picker = ReaderColorPresetsView(initialColor: initialColor, color: color)
            picker.onColorChange = { [weak self] color in self?.receive(color, from: .presets) }
            picker.onConfirm = { [weak self] color in
                self?.receive(color, from: .presets)
                self?.confirm()
            }
            presetsPicker = picker
            formView.addSubview(picker)
        } else {
            presetsPicker?.removeFromSuperview()
            presetsPicker = nil
            isSynchronizingColor = true
            customPicker.setColor(color)
            hexInput.setColor(color)
            isSynchronizingColor = false
        }
        customBody.isHidden = !isCustom
        presetsPicker?.isHidden = isCustom
    }

    @objc private func confirm() {
        guard isEditable, isSubmitEnabled, prepareForSubmission() else { return }
        onConfirm?()
    }

    private func updatePreviewAccessibility() {
        oldPreview.accessibilityValue = "#" + ReaderColorHex.hexString(color: initialColor, traits: traitCollection)
        newPreview.accessibilityValue = "#" + ReaderColorHex.hexString(color: color, traits: traitCollection)
    }

    private func formWidth(for width: CGFloat) -> CGFloat {
        isCustom ? width : max(width, ReaderColorPresetsView.minimumContentWidth)
    }

    private func arrangeForm(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let titleInset = min(24, max(0, (width - 1) / 2))
        let titleWidth = max(1, width - titleInset * 2)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let bodyY = 18 + titleHeight + 8
        let bodyHeight: CGFloat
        if isCustom {
            bodyHeight = arrangeCustom(width: width, applyFrames: applyFrames)
        } else {
            bodyHeight = presetsPicker?.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 0
        }
        if applyFrames {
            titleLabel.frame = CGRect(x: titleInset, y: 18, width: titleWidth, height: titleHeight)
            let body: UIView = isCustom ? customBody : (presetsPicker ?? customBody)
            body.frame = CGRect(x: 0, y: bodyY, width: width, height: bodyHeight)
        }
        return bodyY + bodyHeight
    }

    private func arrangeCustom(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let pickerHeight = customPicker.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let inset = min(16, max(0, (width - 1) / 2))
        let innerWidth = max(1, width - inset * 2)
        let arrowWidth = min(32, innerWidth / 3)
        let previewWidth = min(66, max(0, (innerWidth - arrowWidth) / 2))
        let previewsWidth = previewWidth * 2 + arrowWidth
        let hexWidth = min(innerWidth, hexInput.preferredWidth)
        let inputHeight = hexInput.sizeThatFits(CGSize(width: hexWidth, height: .greatestFiniteMagnitude)).height
        let oneRow = previewsWidth + 16 + hexWidth <= innerWidth
        let previewRowHeight = oneRow ? max(34, inputHeight) : 34
        let rowY = pickerHeight + 16
        let inputY = oneRow ? rowY : rowY + previewRowHeight + 8
        if applyFrames {
            customPicker.frame = CGRect(x: 0, y: 0, width: width, height: pickerHeight)
            oldPreview.frame = CGRect(x: inset, y: rowY + (previewRowHeight - 34) / 2, width: previewWidth, height: 34)
            arrowView.frame = CGRect(
                x: oldPreview.frame.maxX + 4, y: rowY, width: max(0, arrowWidth - 8), height: previewRowHeight)
            newPreview.frame = CGRect(
                x: inset + previewWidth + arrowWidth, y: oldPreview.frame.minY, width: previewWidth, height: 34)
            hexInput.frame = CGRect(x: width - inset - hexWidth, y: inputY, width: hexWidth, height: inputHeight)
        }
        return max(rowY + previewRowHeight, inputY + inputHeight) + 16
    }

    private func arrangeActions(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(12, max(0, (width - 1) / 2))
        let innerWidth = max(1, width - inset * 2)
        let modeWidth = min(innerWidth, modeControl.preferredWidth)
        let confirmWidth = min(innerWidth, confirmControl.preferredWidth)
        let modeHeight = modeControl.sizeThatFits(CGSize(width: modeWidth, height: .greatestFiniteMagnitude)).height
        let confirmHeight = confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: .greatestFiniteMagnitude))
            .height
        let oneRow = modeWidth + confirmWidth <= innerWidth
        let rowHeight = max(modeHeight, confirmHeight)
        if applyFrames {
            modeControl.frame = CGRect(
                x: inset, y: oneRow ? 4 : confirmHeight + 4, width: modeWidth, height: oneRow ? rowHeight : modeHeight)
            confirmControl.frame = CGRect(
                x: width - inset - confirmWidth, y: 4, width: confirmWidth, height: oneRow ? rowHeight : confirmHeight)
            footerView.accessibilityElements = oneRow ? [modeControl, confirmControl] : [confirmControl, modeControl]
        }
        return (oneRow ? rowHeight : modeHeight + confirmHeight) + 8
    }

    private func revealPendingHex() {
        guard needsHexReveal else { return }
        needsHexReveal = false
        let editor = hexInput.editor
        guard isCustom, editor.isFirstResponder, let selection = editor.selectedTextRange, scrollView.bounds.height > 0
        else { return }
        editor.layoutIfNeeded()
        let caret = editor.caretRect(for: selection.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        var target = editor.convert(caret, to: formView).insetBy(dx: 0, dy: -8)
        target.size.height = min(target.height, scrollView.bounds.height)
        scrollView.scrollRectToVisible(target, animated: false)
    }
}

private final class ReaderColorDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        var current: UIView? = view
        while let child = current, child !== self {
            if child is ReaderColorCustomPickerView { return false }
            current = child.superview
        }
        return view is UIControl || super.touchesShouldCancel(in: view)
    }
}
