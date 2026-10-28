import UIKit

/// MoreConfigDialog's NumberPickerDialog uses AppCompat alert chrome and a 180dp number wheel.
/// Keep the native iOS wheel and editable center value, without changing the stored threshold.
@MainActor
final class AndroidReaderNumberPickerDialogViewController: UIViewController, UIPickerViewDataSource,
    UIPickerViewDelegate, UITextFieldDelegate
{
    private enum Phase {
        case waiting
        case active
        case closing(UUID)
        case finished
    }

    private let titleText: String
    private let range: ClosedRange<Int>
    private let valueTitle: (Int) -> String
    private var completion: ((Int) -> Void)?
    private var selectedValue: Int
    private var phase: Phase = .waiting
    private var isInputValid = true

    private let availableGuide = UILayoutGuide()
    private let outsideControl = UIControl()
    private let containerView = UIView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let pickerView = UIPickerView()
    private let inputField = UITextField()
    private let inputErrorLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    init(
        titleText: String, value: Int, range: ClosedRange<Int>,
        valueTitle: @escaping (Int) -> String, completion: @escaping (Int) -> Void
    ) {
        self.titleText = titleText
        self.range = range
        self.valueTitle = valueTitle
        self.completion = completion
        selectedValue = min(max(value, range.lowerBound), range.upperBound)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTapped))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyFonts()
        pickerView.selectRow(selectedValue - range.lowerBound, inComponent: 0, animated: false)
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard case .waiting = phase else { return }
        phase = .active
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if case .closing = phase {} else { invalidate() }
        view.endEditing(true)
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        invalidate()
        super.dismiss(animated: flag, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(value: nil)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableGuide.layoutFrame
        guard available.width > 0, available.height > 0 else { return }
        let width = min(available.width, view.bounds.width * widthFraction)
        let textWidth = max(1, width - 48)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: textWidth, height: .greatestFiniteMagnitude)
            ).height)
        let wheelHeight = max(180, pickerView(pickerView, rowHeightForComponent: 0) * 3)
        let cancelWidth = min(actionWidth(cancelButton), max(1, (width - 32) / 2))
        let confirmWidth = min(actionWidth(confirmButton), max(1, (width - 32) / 2))
        let actionHeight = max(
            actionHeight(cancelButton, width: cancelWidth),
            actionHeight(confirmButton, width: confirmWidth))
        let errorHeight =
            isInputValid
            ? 0
            : ceil(
                inputErrorLabel.sizeThatFits(
                    CGSize(width: textWidth, height: .greatestFiniteMagnitude)
                ).height) + 8
        let wheelY = 18 + titleHeight + 8
        let actionsY = wheelY + wheelHeight + errorHeight + 4
        let contentHeight = actionsY + actionHeight + 8
        let height = min(available.height, contentHeight)
        containerView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2,
            width: width, height: height)
        scrollView.frame = containerView.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        titleLabel.frame = CGRect(x: 24, y: 18, width: textWidth, height: titleHeight)
        pickerView.frame = CGRect(x: 24, y: wheelY, width: textWidth, height: wheelHeight)
        let fieldHeight = pickerView(pickerView, rowHeightForComponent: 0)
        inputField.frame = CGRect(
            x: 24, y: pickerView.frame.midY - fieldHeight / 2,
            width: textWidth, height: fieldHeight)
        inputErrorLabel.frame = CGRect(
            x: 24, y: wheelY + wheelHeight, width: textWidth,
            height: max(0, errorHeight - 8))
        let isRTL = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        confirmButton.frame = CGRect(
            x: isRTL ? 12 : width - 12 - confirmWidth, y: actionsY,
            width: confirmWidth, height: actionHeight)
        cancelButton.frame = CGRect(
            x: isRTL ? 20 + confirmWidth : width - 20 - confirmWidth - cancelWidth,
            y: actionsY, width: cancelWidth, height: actionHeight)
        let maximum = max(0, contentHeight - height)
        if scrollView.contentOffset.y > maximum {
            scrollView.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
        }
        if inputField.isFirstResponder {
            scrollView.scrollRectToVisible(inputField.frame.insetBy(dx: 0, dy: -8), animated: false)
        }
    }

    private var widthFraction: CGFloat {
        let size = view.bounds.size
        let short = min(size.width, size.height)
        let long = max(size.width, size.height)
        let landscape = size.width > size.height
        if short >= 720 && long >= 960 { return landscape ? 0.45 : 0.72 }
        if short >= 480 && long >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "readerNumberPicker.root"
        view.addLayoutGuide(availableGuide)
        NSLayoutConstraint.activate([
            availableGuide.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            availableGuide.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            availableGuide.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            availableGuide.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
        ])
        outsideControl.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        outsideControl.isAccessibilityElement = false
        containerView.backgroundColor = AndroidReplicaTheme.background
        containerView.layer.cornerRadius = 3
        containerView.clipsToBounds = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false

        titleLabel.text = titleText
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "readerNumberPicker.title"
        pickerView.dataSource = self
        pickerView.delegate = self
        pickerView.accessibilityIdentifier = "readerNumberPicker.wheel"
        pickerView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.Common.edit) { [weak self] _ in
                self?.beginValueEntry() ?? false
            }
        ]
        let editTap = UITapGestureRecognizer(target: self, action: #selector(editCenterValue(_:)))
        editTap.cancelsTouchesInView = false
        pickerView.addGestureRecognizer(editTap)

        inputField.delegate = self
        inputField.isHidden = true
        inputField.backgroundColor = AndroidReplicaTheme.background
        inputField.textColor = AndroidReplicaTheme.primaryText
        inputField.tintColor = AndroidReplicaTheme.accent
        inputField.textAlignment = .center
        inputField.keyboardType = range.lowerBound < 0 ? .numbersAndPunctuation : .numberPad
        inputField.returnKeyType = .done
        inputField.autocorrectionType = .no
        inputField.autocapitalizationType = .none
        inputField.adjustsFontForContentSizeCategory = false
        inputField.accessibilityLabel = titleText
        inputField.accessibilityIdentifier = "readerNumberPicker.value"
        inputField.addTarget(self, action: #selector(inputChanged), for: .editingChanged)
        inputErrorLabel.text = L10n.Reader.pageTouchSlopInvalidRange
        inputErrorLabel.textColor = AndroidReplicaTheme.accent
        inputErrorLabel.numberOfLines = 0
        inputErrorLabel.isHidden = true
        inputErrorLabel.adjustsFontForContentSizeCategory = false
        configureActionButton(
            cancelButton, title: L10n.Common.cancel, identifier: "readerNumberPicker.cancel",
            action: #selector(cancelTapped))
        configureActionButton(
            confirmButton, title: L10n.Common.confirm, identifier: "readerNumberPicker.confirm",
            action: #selector(confirmTapped))
        view.addSubview(outsideControl)
        view.addSubview(containerView)
        containerView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        for item in [titleLabel, pickerView, inputField, inputErrorLabel, cancelButton, confirmButton] {
            contentView.addSubview(item)
        }
    }

    private func configureActionButton(_ button: UIButton, title: String, identifier: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        button.setTitleColor(AndroidReplicaTheme.secondaryText, for: .disabled)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byWordWrapping
        button.titleLabel?.textAlignment = .center
        button.titleLabel?.adjustsFontForContentSizeCategory = false
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    private func applyFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        // NumberPicker.Material inherits Body1 (14sp) for both the input and wheel paint.
        inputField.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
        inputErrorLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .footnote, compatibleWith: traitCollection)
        for button in [cancelButton, confirmButton] {
            button.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        }
        pickerView.reloadAllComponents()
        view.setNeedsLayout()
    }

    private func actionWidth(_ button: UIButton) -> CGFloat {
        max(
            64,
            ceil(
                button.titleLabel?.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                ).width ?? 0) + 16)
    }

    private func actionHeight(_ button: UIButton, width: CGFloat) -> CGFloat {
        max(
            48,
            ceil(
                button.titleLabel?.sizeThatFits(
                    CGSize(width: max(1, width - 16), height: .greatestFiniteMagnitude)
                ).height ?? 0) + 16)
    }

    func numberOfComponents(in _: UIPickerView) -> Int { 1 }

    func pickerView(_: UIPickerView, numberOfRowsInComponent _: Int) -> Int {
        range.upperBound - range.lowerBound + 1
    }

    func pickerView(_: UIPickerView, titleForRow row: Int, forComponent _: Int) -> String? {
        guard (0...range.upperBound - range.lowerBound).contains(row) else { return nil }
        return valueTitle(range.lowerBound + row)
    }

    func pickerView(_: UIPickerView, rowHeightForComponent _: Int) -> CGFloat {
        max(44, ceil(inputField.font?.lineHeight ?? 26) + 16)
    }

    func pickerView(_: UIPickerView, viewForRow row: Int, forComponent _: Int, reusing view: UIView?) -> UIView {
        let label = view as? UILabel ?? UILabel()
        label.text = valueTitle(range.lowerBound + row)
        label.font = inputField.font
        label.textColor = AndroidReplicaTheme.primaryText
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        return label
    }

    func pickerView(_: UIPickerView, didSelectRow row: Int, inComponent _: Int) {
        guard canInteract, (0...range.upperBound - range.lowerBound).contains(row) else { return }
        selectedValue = range.lowerBound + row
        inputField.text = String(selectedValue)
        setInputValidity(true)
        inputField.resignFirstResponder()
    }

    @objc private func editCenterValue(_ gesture: UITapGestureRecognizer) {
        guard canInteract,
            abs(gesture.location(in: pickerView).y - pickerView.bounds.midY)
                <= pickerView(pickerView, rowHeightForComponent: 0) / 2
        else { return }
        _ = beginValueEntry()
    }

    private func beginValueEntry() -> Bool {
        guard canInteract else { return false }
        inputField.text = String(selectedValue)
        inputField.isHidden = false
        guard inputField.becomeFirstResponder() else {
            inputField.isHidden = true
            return false
        }
        inputField.selectAll(nil)
        return true
    }

    @objc private func inputChanged() {
        guard let value = Int((inputField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
            range.contains(value)
        else {
            setInputValidity(false)
            return
        }
        selectedValue = value
        pickerView.selectRow(value - range.lowerBound, inComponent: 0, animated: false)
        setInputValidity(true)
    }

    private func setInputValidity(_ valid: Bool) {
        isInputValid = valid
        inputErrorLabel.isHidden = valid
        updateInteraction()
        view.setNeedsLayout()
    }

    func textFieldDidEndEditing(_: UITextField) {
        inputField.isHidden = isInputValid
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private var canInteract: Bool {
        guard case .active = phase, !isBeingDismissed, !isBeingPresented,
            viewIfLoaded?.window != nil, presentingViewController != nil
        else { return false }
        return true
    }

    private func updateInteraction() {
        let active: Bool
        if case .active = phase { active = true } else { active = false }
        pickerView.isUserInteractionEnabled = active
        inputField.isEnabled = active
        cancelButton.isEnabled = active
        confirmButton.isEnabled = active && isInputValid
        outsideControl.isEnabled = active
    }

    private func invalidate() {
        phase = .finished
        completion = nil
        if isViewLoaded { updateInteraction() }
    }

    @objc private func cancelTapped() { close(value: nil) }

    @objc private func confirmTapped() {
        guard isInputValid else { return }
        close(value: selectedValue)
    }

    private func close(value: Int?) {
        guard canInteract, let presenter = presentingViewController,
            let window = viewIfLoaded?.window
        else { return }
        let id = UUID()
        phase = .closing(id)
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self, weak presenter, weak window] in
            guard case .closing(let activeID) = phase, activeID == id else { return }
            let callback = completion
            invalidate()
            guard let value, range.contains(value), presentingViewController == nil,
                viewIfLoaded?.window == nil, let presenter, let window,
                presenter.presentedViewController == nil, presenter.viewIfLoaded?.window === window,
                !presenter.isBeingDismissed, presenter.parent?.isBeingDismissed != true,
                window.windowScene?.activationState == .foregroundActive
            else { return }
            callback?(value)
        }
    }
}
