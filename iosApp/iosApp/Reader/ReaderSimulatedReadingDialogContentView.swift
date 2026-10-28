import UIKit

struct ReaderSimulatedReadingDraft: Equatable {
    var enabled: Bool
    var startDate: String
    var startChapter: String
    var dailyChapters: String
}

/// BaseReadBookActivity.showSimulatedReading / dialog_simulated_reading.xml at 5f5d314.
@MainActor
final class ReaderSimulatedReadingDialogContentView: UIView, UITextFieldDelegate {
    var onConfirm: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPickDate: (() -> Void)?
    var onChange: (() -> Void)?

    let startField: UITextField
    let dailyField: UITextField
    let dateButton: UIControl

    var draft: ReaderSimulatedReadingDraft {
        ReaderSimulatedReadingDraft(
            enabled: enabledControl.isOn, startDate: dateControl.isoDate,
            startChapter: startField.text ?? "", dailyChapters: dailyField.text ?? "")
    }

    private struct AcceptedInput {
        var text: String
        var selection: NSRange
    }

    private let titleLabel = AndroidExploreTextLabel()
    private let enabledLabel = AndroidExploreTextLabel()
    private let dateLabel = AndroidExploreTextLabel()
    private let startLabel = AndroidExploreTextLabel()
    private let dailyLabel = AndroidExploreTextLabel()
    private let statusLabel = AndroidExploreTextLabel()
    private let enabledControl = ReaderAndroidSwitchControl()
    private let dateControl: ReaderSimulatedReadingDateControl
    private let startInput: ReaderDownloadChoiceField
    private let dailyInput: ReaderDownloadChoiceField
    private let cancelControl = BookshelfLayoutDialogAction(title: "取消")
    // AlertBuilder.okButton uses android.R.string.ok, not the app's "确认" resource.
    private let confirmControl = BookshelfLayoutDialogAction(title: "确定")
    private let scrollView = ReaderSimulatedReadingScrollView()
    private let formView = UIView()
    private let footerView = UIView()
    private var acceptedInputs: [ObjectIdentifier: AcceptedInput] = [:]
    private var pendingInputs: [ObjectIdentifier: String] = [:]
    private var composingInputs: Set<ObjectIdentifier> = []
    private var restoringInput = false
    private var needsCaretReveal = false
    private var needsStatusReveal = false
    private var lastViewportSize: CGSize = .zero

    init(draft: ReaderSimulatedReadingDraft) {
        let startInput = ReaderDownloadChoiceField(field: .start)
        let dailyInput = ReaderDownloadChoiceField(field: .end)
        let dateControl = ReaderSimulatedReadingDateControl()
        self.startInput = startInput
        self.dailyInput = dailyInput
        self.dateControl = dateControl
        startField = startInput
        dailyField = dailyInput
        dateButton = dateControl
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        layer.cornerRadius = 3
        clipsToBounds = true
        accessibilityViewIsModal = true
        accessibilityIdentifier = "reader.simulatedReading"
        let labels = [titleLabel, enabledLabel, dateLabel, startLabel, dailyLabel]
        let titles = ["模拟追读", "开关", "开始日期", "起始章节", "日更章数"]
        for (label, text) in zip(labels, titles) {
            BookshelfLayoutDialogStyle.configure(label, text: text, color: AndroidReplicaTheme.primaryText)
            label.lineBreakMode = .byCharWrapping
        }
        titleLabel.accessibilityTraits = .header
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityIdentifier = "reader.simulatedReading.title"
        // Each input exposes its original identity rather than a second spoken label beside it.
        for label in [enabledLabel, dateLabel, startLabel, dailyLabel] { label.isAccessibilityElement = false }
        BookshelfLayoutDialogStyle.configure(statusLabel, text: "", color: .systemRed)
        statusLabel.lineBreakMode = .byCharWrapping
        statusLabel.isHidden = true
        statusLabel.accessibilityIdentifier = "reader.simulatedReading.status"

        enabledControl.setOn(draft.enabled, animated: false)
        enabledControl.accessibilityLabel = "开关"
        enabledControl.accessibilityIdentifier = "reader.simulatedReading.enabled"
        enabledControl.addTarget(self, action: #selector(changeEnabled), for: .valueChanged)
        dateControl.setDate(draft.startDate)
        dateControl.accessibilityIdentifier = "reader.simulatedReading.startDate"
        dateControl.addTarget(self, action: #selector(pickDate), for: .touchUpInside)
        startInput.placeholder = "开始"
        dailyInput.placeholder = "3"
        dailyInput.textAlignment = .center
        for (field, text, label, identifier) in [
            (startInput, draft.startChapter, "起始章节", "startChapter"),
            (dailyInput, draft.dailyChapters, "日更章数", "dailyChapters"),
        ] {
            // Imported defaults remain exact, including zero, leading zeroes and empty strings.
            field.text = text
            field.accessibilityLabel = label
            field.accessibilityIdentifier = "reader.simulatedReading.\(identifier)"
            field.delegate = self
            field.addTarget(self, action: #selector(inputChanged(_:)), for: .editingChanged)
            acceptedInputs[ObjectIdentifier(field)] = AcceptedInput(
                text: text, selection: NSRange(location: (text as NSString).length, length: 0))
        }
        startInput.returnKeyType = .next
        dailyInput.returnKeyType = .done
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "reader.simulatedReading.content"
        cancelControl.accessibilityIdentifier = "reader.simulatedReading.cancel"
        confirmControl.accessibilityIdentifier = "reader.simulatedReading.confirm"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        addSubview(scrollView)
        scrollView.addSubview(formView)
        for child in labels + [statusLabel] { formView.addSubview(child) }
        for child in [enabledControl, dateControl, startInput, dailyInput] { formView.addSubview(child) }
        for control in [cancelControl, confirmControl] { footerView.addSubview(control) }
        applyFonts(traits: traitCollection)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func setStartDate(_ iso: String) {
        guard dateControl.isoDate != iso else { return }
        dateControl.setDate(iso)
        setNeedsLayout()
        onChange?()
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traits)
        let labelFont = ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traits)
        for label in [enabledLabel, dateLabel, startLabel, dailyLabel] { label.font = labelFont }
        dateControl.apply(font: labelFont)
        for field in [startInput, dailyInput] { field.apply(traits: traits) }
        statusLabel.font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        let actionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traits)
        for control in [cancelControl, confirmControl] { control.apply(font: actionFont) }
        needsCaretReveal = true
        setNeedsLayout()
    }

    func setInteraction(editable: Bool, cancelEnabled: Bool, submitEnabled: Bool) {
        if !editable { endEditing(true) }
        for field in [startInput, dailyInput] { field.isEnabled = editable }
        enabledControl.isEnabled = editable
        dateControl.isEnabled = editable
        cancelControl.isEnabled = cancelEnabled
        confirmControl.isEnabled = submitEnabled
    }

    func showStatus(_ text: String?) {
        statusLabel.text = text
        statusLabel.isHidden = text == nil || text?.isEmpty == true
        needsStatusReveal = !statusLabel.isHidden
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            applyFonts(traits: traitCollection)
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(
            width: size.width,
            height: arrangeForm(width: size.width, applyFrames: false)
                + arrangeActions(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        guard width > 0, bounds.height > 0 else { return }
        let formHeight = arrangeForm(width: width, applyFrames: true)
        let footerHeight = arrangeActions(width: width, applyFrames: true)
        // Match the existing input dialogs: pin actions, or scroll all chrome in a tiny viewport.
        let pinsFooter = bounds.height >= footerHeight + min(48, startInput.bounds.height)
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
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        var elements: [Any] = [titleLabel, enabledControl, dateControl, startInput, dailyInput]
        if !statusLabel.isHidden { elements.append(statusLabel) }
        if !pinsFooter { elements.append(footerView) }
        formView.accessibilityElements = elements
        accessibilityElements = pinsFooter ? [scrollView, footerView] : [scrollView]
        if lastViewportSize != scrollView.bounds.size {
            lastViewportSize = scrollView.bounds.size
            needsCaretReveal = true
        }
        revealPendingContent()
    }

    private func arrangeForm(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let titleInset = min(24, max(0, (width - 1) / 2))
        let titleWidth = max(1, width - titleInset * 2)
        let titleHeight = measuredHeight(titleLabel, width: titleWidth)
        place(titleLabel, x: titleInset, y: 18, width: titleWidth, height: titleHeight, apply: applyFrames)
        // The custom root keeps 20dp padding; each of its three Android rows has 16dp padding.
        let rootInset = min(20, max(0, (width - 1) / 2))
        let rootWidth = max(1, width - rootInset * 2)
        let rowInset = min(16, max(0, (rootWidth - 1) / 2))
        let rowX = rootInset + rowInset
        let rowWidth = max(1, rootWidth - rowInset * 2)
        var y = 18 + titleHeight + 8 + 20
        y += arrangeEnabled(x: rowX, y: y, width: rowWidth, apply: applyFrames)
        y += arrangeDate(x: rowX, y: y, width: rowWidth, apply: applyFrames)
        y += arrangeNumbers(x: rowX, y: y, width: rowWidth, apply: applyFrames)
        if !statusLabel.isHidden {
            y += 8
            let height = measuredHeight(statusLabel, width: rootWidth)
            place(statusLabel, x: rootInset, y: y, width: rootWidth, height: height, apply: applyFrames)
            y += height
        }
        return rounded(y + 20)
    }

    private func arrangeEnabled(x: CGFloat, y: CGFloat, width: CGFloat, apply: Bool) -> CGFloat {
        let switchWidth: CGFloat = min(53, width)
        let switchHeight: CGFloat = 28
        let labelWidth = max(88, naturalWidth(enabledLabel))
        if labelWidth + 2 + switchWidth <= width {
            let labelHeight = measuredHeight(enabledLabel, width: labelWidth)
            let height = max(60, max(labelHeight, switchHeight) + 32)
            place(
                enabledLabel, x: x, y: y + (height - labelHeight) / 2,
                width: labelWidth, height: labelHeight, apply: apply)
            place(
                enabledControl, x: x + labelWidth + 2, y: y + (height - switchHeight) / 2,
                width: switchWidth, height: switchHeight, apply: apply)
            return rounded(height)
        }
        let labelHeight = measuredHeight(enabledLabel, width: width)
        place(enabledLabel, x: x, y: y + 16, width: width, height: labelHeight, apply: apply)
        place(
            enabledControl, x: x, y: y + 16 + labelHeight + 8,
            width: switchWidth, height: switchHeight, apply: apply)
        return rounded(32 + labelHeight + 8 + switchHeight)
    }

    private func arrangeDate(x: CGFloat, y: CGFloat, width: CGFloat, apply: Bool) -> CGFloat {
        let labelWidth = max(100, naturalWidth(dateLabel))
        if labelWidth + dateControl.preferredWidth <= width {
            // Preserve the XML's 68dp trailing space whenever the complete ISO date fits.
            let trailing = min(68, max(0, width - labelWidth - dateControl.preferredWidth))
            let inputWidth = max(1, width - labelWidth - trailing)
            let labelHeight = measuredHeight(dateLabel, width: labelWidth)
            let inputHeight = dateControl.sizeThatFits(CGSize(width: inputWidth, height: .greatestFiniteMagnitude))
                .height
            // The original 49dp date field is centered in a 65dp row, leaving 8dp per side.
            let height = rounded(max(65, max(labelHeight, inputHeight) + 16))
            place(
                dateLabel, x: x, y: y + (height - labelHeight) / 2,
                width: labelWidth, height: labelHeight, apply: apply)
            place(
                dateControl, x: x + labelWidth, y: y + (height - inputHeight) / 2,
                width: inputWidth, height: inputHeight, apply: apply)
            return height
        }
        let labelHeight = measuredHeight(dateLabel, width: width)
        let inputHeight = dateControl.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        place(dateLabel, x: x, y: y + 16, width: width, height: labelHeight, apply: apply)
        place(
            dateControl, x: x, y: y + 16 + labelHeight + 8,
            width: width, height: inputHeight, apply: apply)
        return rounded(32 + labelHeight + 8 + inputHeight)
    }

    private func arrangeNumbers(x: CGFloat, y: CGFloat, width: CGFloat, apply: Bool) -> CGFloat {
        let startWidth = max(100, naturalWidth(startLabel))
        let dailyWidth = naturalWidth(dailyLabel)
        let startInputWidth = numericWidth(startInput)
        let dailyInputWidth = numericWidth(dailyInput)
        let requiredWidth = startWidth + startInputWidth + 25 + dailyWidth + 5 + dailyInputWidth
        if requiredWidth <= width {
            let startHeight = measuredHeight(startLabel, width: startWidth)
            let dailyHeight = measuredHeight(dailyLabel, width: dailyWidth)
            let height = rounded(
                max(
                    63,
                    max(
                        max(startHeight, dailyHeight),
                        max(startInput.preferredHeight, dailyInput.preferredHeight)) + 32))
            place(
                startLabel, x: x, y: y + (height - startHeight) / 2,
                width: startWidth, height: startHeight, apply: apply)
            place(
                startInput, x: x + startWidth, y: y + (height - startInput.preferredHeight) / 2,
                width: startInputWidth, height: startInput.preferredHeight, apply: apply)
            let dailyX = x + width - dailyInputWidth
            place(
                dailyLabel, x: dailyX - 5 - dailyWidth, y: y + (height - dailyHeight) / 2,
                width: dailyWidth, height: dailyHeight, apply: apply)
            place(
                dailyInput, x: dailyX, y: y + (height - dailyInput.preferredHeight) / 2,
                width: dailyInputWidth, height: dailyInput.preferredHeight, apply: apply)
            return height
        }
        let firstHeight = arrangeNumberPair(startLabel, field: startInput, x: x, y: y, width: width, apply: apply)
        return firstHeight
            + arrangeNumberPair(
                dailyLabel, field: dailyInput, x: x, y: y + firstHeight, width: width, apply: apply)
    }

    private func arrangeNumberPair(
        _ label: UILabel, field: ReaderDownloadChoiceField, x: CGFloat, y: CGFloat, width: CGFloat, apply: Bool
    ) -> CGFloat {
        let labelWidth = max(100, naturalWidth(label))
        let inputWidth = min(width, numericWidth(field))
        let inputHeight = field.preferredHeight
        if labelWidth + inputWidth <= width {
            let labelHeight = measuredHeight(label, width: labelWidth)
            let height = rounded(max(63, max(labelHeight, inputHeight) + 32))
            place(
                label, x: x, y: y + (height - labelHeight) / 2,
                width: labelWidth, height: labelHeight, apply: apply)
            place(
                field, x: x + labelWidth, y: y + (height - inputHeight) / 2,
                width: inputWidth, height: inputHeight, apply: apply)
            return height
        }
        let labelHeight = measuredHeight(label, width: width)
        place(label, x: x, y: y + 16, width: width, height: labelHeight, apply: apply)
        place(field, x: x, y: y + 16 + labelHeight + 8, width: inputWidth, height: inputHeight, apply: apply)
        return rounded(32 + labelHeight + 8 + inputHeight)
    }

    private func arrangeActions(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(12, max(0, (width - 32) / 2))
        let availableWidth = max(1, width - inset * 2)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let cancelWidth = rounded(cancelControl.preferredWidth)
        let confirmWidth = rounded(confirmControl.preferredWidth)
        if cancelWidth + confirmWidth <= availableWidth {
            let height = rounded(
                max(
                    cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude)).height,
                    confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: .greatestFiniteMagnitude)).height))
            if applyFrames {
                let confirmX = isRTL ? inset : width - inset - confirmWidth
                let cancelX = isRTL ? confirmX + confirmWidth : confirmX - cancelWidth
                confirmControl.frame = CGRect(x: confirmX, y: 4, width: confirmWidth, height: height)
                cancelControl.frame = CGRect(x: cancelX, y: 4, width: cancelWidth, height: height)
                footerView.accessibilityElements = [cancelControl, confirmControl]
            }
            return height + 8
        }
        // AppCompat ButtonBarLayout reverses its children when stacked: positive first.
        var y: CGFloat = 4
        for control in [confirmControl, cancelControl] {
            let controlWidth = min(availableWidth, rounded(control.preferredWidth))
            let height = rounded(
                control.sizeThatFits(CGSize(width: controlWidth, height: .greatestFiniteMagnitude)).height)
            place(
                control, x: isRTL ? inset : width - inset - controlWidth, y: y,
                width: controlWidth, height: height, apply: applyFrames)
            y += height
        }
        if applyFrames { footerView.accessibilityElements = [confirmControl, cancelControl] }
        return y + 4
    }

    private func numericWidth(_ field: ReaderDownloadChoiceField) -> CGFloat {
        // Explicit XML widths win over minWidth; grow only with the user's font scale.
        let original: CGFloat = field === startInput ? 47 : 42
        return original * max(1, (field.font?.pointSize ?? 14) / 14)
    }

    private func naturalWidth(_ label: UILabel) -> CGFloat {
        rounded(
            label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                .width)
    }

    private func measuredHeight(_ label: UILabel, width: CGFloat) -> CGFloat {
        rounded(label.sizeThatFits(CGSize(width: max(1, width), height: .greatestFiniteMagnitude)).height)
    }

    private func rounded(_ value: CGFloat) -> CGFloat {
        let scale = max(1, traitCollection.displayScale)
        return ceil(value * scale) / scale
    }

    private func place(_ view: UIView, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, apply: Bool) {
        if apply { view.frame = CGRect(x: x, y: y, width: width, height: height) }
    }

    private func revealPendingContent() {
        if needsStatusReveal {
            needsStatusReveal = false
            needsCaretReveal = false
            reveal(statusLabel.frame)
        } else if needsCaretReveal {
            needsCaretReveal = false
            guard let field = [startInput, dailyInput].first(where: { $0.isFirstResponder }),
                let selection = field.selectedTextRange
            else { return }
            field.layoutIfNeeded()
            let caret = field.caretRect(for: selection.end)
            guard !caret.isNull, !caret.isInfinite else { return }
            reveal(field.convert(caret, to: formView))
        }
    }

    private func reveal(_ rect: CGRect) {
        var target = rect.insetBy(dx: 0, dy: -8)
        target.size.height = min(target.height, scrollView.bounds.height)
        scrollView.scrollRectToVisible(target, animated: false)
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        needsCaretReveal = true
        setNeedsLayout()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard textField.isEnabled else { return false }
        if textField === startInput { dailyInput.becomeFirstResponder() } else { confirm() }
        return false
    }

    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String
    ) -> Bool {
        guard textField.isEnabled else { return false }
        let key = ObjectIdentifier(textField)
        if textField.markedTextRange != nil {
            pendingInputs.removeValue(forKey: key)
            return true
        }
        let text = textField.text ?? ""
        guard let textRange = Range(range, in: text) else { return false }
        let candidate = text.replacingCharacters(in: textRange, with: string)
        // Deletion remains possible for an oversized imported default; never rewrite that default.
        guard string.isEmpty || acceptsNumber(candidate) else { return false }
        pendingInputs[key] = candidate
        return true
    }

    func textFieldDidChangeSelection(_ textField: UITextField) {
        guard !restoringInput else { return }
        let key = ObjectIdentifier(textField)
        let finishedComposition = textField.markedTextRange == nil && composingInputs.contains(key)
        reconcileInput(textField)
        needsCaretReveal = true
        setNeedsLayout()
        if finishedComposition { onChange?() }
    }

    @objc private func inputChanged(_ field: UITextField) {
        reconcileInput(field)
        needsCaretReveal = true
        setNeedsLayout()
        onChange?()
    }

    private func acceptsNumber(_ text: String) -> Bool {
        text.utf8.count <= 5 && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    private func reconcileInput(_ field: UITextField) {
        guard !restoringInput else { return }
        let key = ObjectIdentifier(field)
        guard field.markedTextRange == nil else {
            composingInputs.insert(key)
            pendingInputs.removeValue(forKey: key)
            return
        }
        composingInputs.remove(key)
        let text = field.text ?? ""
        let pending = pendingInputs[key]
        let accepted = acceptedInputs[key]
        if acceptsNumber(text) || text == pending || text == accepted?.text {
            if text == pending { pendingInputs.removeValue(forKey: key) }
            let selection: NSRange
            if let range = field.selectedTextRange {
                selection = NSRange(
                    location: field.offset(from: field.beginningOfDocument, to: range.start),
                    length: field.offset(from: range.start, to: range.end))
            } else {
                selection = NSRange(location: (text as NSString).length, length: 0)
            }
            acceptedInputs[key] = AcceptedInput(text: text, selection: selection)
        } else if let accepted {
            // Wait for IME commit, then reject the whole invalid edit instead of truncating marked text.
            pendingInputs.removeValue(forKey: key)
            restoringInput = true
            field.text = accepted.text
            if let start = field.position(from: field.beginningOfDocument, offset: accepted.selection.location),
                let end = field.position(from: start, offset: accepted.selection.length)
            {
                field.selectedTextRange = field.textRange(from: start, to: end)
            }
            restoringInput = false
        }
    }

    @objc private func changeEnabled() {
        // Acknowledge the local draft so disabling the switch cannot restore its initial value.
        enabledControl.setOn(enabledControl.isOn, animated: false)
        onChange?()
    }

    @objc private func pickDate() {
        guard dateControl.isEnabled else { return }
        endEditing(true)
        onPickDate?()
    }

    @objc private func cancel() {
        guard cancelControl.isEnabled else { return }
        onCancel?()
    }

    @objc private func confirm() {
        guard confirmControl.isEnabled else { return }
        onConfirm?()
    }
}

@MainActor
private final class ReaderSimulatedReadingDateControl: UIControl {
    private let label = AndroidExploreTextLabel()
    private let underline = UIView()
    private(set) var isoDate = ""

    var preferredWidth: CGFloat {
        ceil(
            label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
                .width + 11)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        BookshelfLayoutDialogStyle.configure(label, text: "Select date", color: AndroidReplicaTheme.secondaryText)
        label.lineBreakMode = .byCharWrapping
        label.isAccessibilityElement = false
        underline.isUserInteractionEnabled = false
        underline.isAccessibilityElement = false
        addSubview(label)
        addSubview(underline)
        isAccessibilityElement = true
        accessibilityLabel = "开始日期"
        accessibilityTraits = .button
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
            if !isEnabled { isHighlighted = false }
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    func setDate(_ iso: String) {
        isoDate = iso
        label.text = iso.isEmpty ? "Select date" : iso
        label.textColor = iso.isEmpty ? AndroidReplicaTheme.secondaryText : AndroidReplicaTheme.primaryText
        accessibilityValue = iso.isEmpty ? "Select date" : iso
        setNeedsLayout()
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textHeight = label.sizeThatFits(
            CGSize(width: max(1, size.width - 11), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: max(49, ceil(textHeight + 21)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // abc_edit_text_material adds 4/10/7dp plus 4dp nine-patch bottom content padding.
        label.frame = CGRect(x: 4, y: 10, width: max(0, bounds.width - 11), height: max(0, bounds.height - 21))
        underline.frame = CGRect(x: 4, y: bounds.height - 9, width: max(0, bounds.width - 8), height: 1)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func updateAppearance() {
        let disabledAlpha: CGFloat = ReaderPaletteColor.isNightResource(traits: traitCollection) ? 0.30 : 0.26
        underline.backgroundColor = AndroidReplicaTheme.accent
        underline.alpha = (222 / 255) * (isEnabled ? 1 : disabledAlpha)
    }
}

private final class ReaderSimulatedReadingScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
