import UIKit

/// GroupManageDialog addGroup/editGroup + dialog_edit_text.xml, not a new settings page.
@MainActor
final class BookSourceGroupManagementEditorViewController: UIViewController, UITextFieldDelegate {
    var onSubmit: ((String) -> Void)?

    private let initialGroup: String?
    private var isActive = false
    private var isClosing = false
    private var isSaving = false
    private var keyboardFrame: CGRect?
    private var shouldRevealField = false
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let scrollView = BookSourceGroupManagementScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let nameField = UITextField()
    private let underline = UIView()
    private let errorLabel = UILabel()
    private let cancelButton = UIButton(type: .system)
    private let confirmButton = UIButton(type: .system)

    init(group: String?) {
        initialGroup = group
        super.init(nibName: nil, bundle: nil)
        title = group == nil ? BookSourceGroupManagementText.add : BookSourceGroupManagementText.edit
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    var canSubmit: Bool {
        isActive && !isClosing && !isSaving && !isBeingPresented && !isLeavingPresentation
            && viewIfLoaded?.window != nil && presentingViewController != nil
            && view.window?.windowScene?.activationState == .foregroundActive
    }

    var acceptsSaveResult: Bool {
        isActive && !isClosing && !isLeavingPresentation && presentingViewController != nil
            && viewIfLoaded?.window != nil
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard !isSaving else { return nil }
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyTypography()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidChange), name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isActive = true
        updateInteraction()
        nameField.becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: nameField)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isLeavingPresentation { invalidate() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isLeavingPresentation || presentingViewController == nil { invalidate() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        invalidate()
        super.dismiss(animated: flag, completion: completion)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canSubmit else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyTypography()
        shouldRevealField = nameField.isFirstResponder
    }

    func setSaving(_ saving: Bool) {
        guard !isClosing else { return }
        isSaving = saving
        if saving { view.endEditing(true) }
        updateInteraction()
    }

    func showFailure(_ message: String) {
        guard acceptsSaveResult else { return }
        isSaving = false
        errorLabel.text = message
        errorLabel.isHidden = false
        updateInteraction()
        view.setNeedsLayout()
        UIAccessibility.post(notification: .announcement, argument: message)
    }

    func finishSaving() {
        guard acceptsSaveResult else { return }
        invalidate()
        view.endEditing(true)
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "sourceManagement.groupManage.editor"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceManagement.groupManage.editor.title"
        nameField.text = initialGroup
        nameField.placeholder = BookSourceGroupManagementText.name
        nameField.borderStyle = .none
        nameField.textColor = AndroidReplicaTheme.primaryText
        nameField.tintColor = AndroidReplicaTheme.accent
        nameField.autocorrectionType = .no
        nameField.autocapitalizationType = .none
        nameField.spellCheckingType = .no
        nameField.smartQuotesType = .no
        nameField.smartDashesType = .no
        nameField.smartInsertDeleteType = .no
        nameField.adjustsFontForContentSizeCategory = true
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.accessibilityLabel = BookSourceGroupManagementText.name
        nameField.accessibilityIdentifier = "sourceManagement.groupManage.editor.name"
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        nameField.addTarget(self, action: #selector(focusChanged), for: [.editingDidBegin, .editingDidEnd])
        underline.backgroundColor = AndroidReplicaTheme.secondaryText
        errorLabel.numberOfLines = 0
        errorLabel.textColor = .systemRed
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "sourceManagement.groupManage.editor.error"
        cancelButton.setTitle(L10n.Common.cancel, for: .normal)
        confirmButton.setTitle(BookSourceGroupManagementText.confirm, for: .normal)
        for button in [cancelButton, confirmButton] {
            button.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.isExclusiveTouch = true
        }
        cancelButton.accessibilityIdentifier = "sourceManagement.groupManage.editor.cancel"
        confirmButton.accessibilityIdentifier = "sourceManagement.groupManage.editor.confirm"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmButton.addTarget(self, action: #selector(submit), for: .touchUpInside)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .interactive
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        for item in [titleLabel, nameField, underline, errorLabel, cancelButton, confirmButton] {
            contentView.addSubview(item)
        }
        updateInteraction()
    }

    private func applyTypography() {
        titleLabel.font = BookSourceGroupManagementTypography.font(20, style: .headline, traits: traitCollection)
        nameField.font = BookSourceGroupManagementTypography.font(18, traits: traitCollection)
        errorLabel.font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        for button in [cancelButton, confirmButton] {
            button.titleLabel?.font = BookSourceGroupManagementTypography.font(14, traits: traitCollection)
        }
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableFrame
        guard available.width > 0, available.height > 0 else { return }
        let width = min(available.width, view.bounds.width * widthFraction)
        let titleWidth = max(1, width - 48)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        titleLabel.frame = CGRect(x: 24, y: 20, width: titleWidth, height: titleHeight)
        let fieldHeight = max(48, ceil(nameField.font?.lineHeight ?? 22) + 16)
        nameField.frame = CGRect(x: 16, y: titleLabel.frame.maxY + 8, width: max(1, width - 32), height: fieldHeight)
        underline.frame = CGRect(
            x: 16, y: nameField.frame.maxY - 2, width: max(1, width - 32), height: nameField.isFirstResponder ? 2 : 1)
        var y = nameField.frame.maxY + 8
        if !errorLabel.isHidden {
            let errorHeight = ceil(
                errorLabel.sizeThatFits(CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)).height)
            errorLabel.frame = CGRect(x: 16, y: y, width: max(1, width - 32), height: errorHeight)
            y += errorHeight + 8
        }
        let contentHeight = layoutActions(width: width, y: y + 4) + 4
        let height = min(available.height, contentHeight)
        dialogView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        scrollView.frame = dialogView.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        let maxOffset = max(0, contentHeight - height)
        scrollView.contentOffset.y = min(max(0, scrollView.contentOffset.y), maxOffset)
        if shouldRevealField, nameField.isFirstResponder {
            shouldRevealField = false
            scrollView.scrollRectToVisible(nameField.frame.insetBy(dx: 0, dy: -8), animated: false)
        }
    }

    private func layoutActions(width: CGFloat, y: CGFloat) -> CGFloat {
        let cancelWidth = max(64, ceil(cancelButton.sizeThatFits(.zero).width) + 16)
        let confirmWidth = max(64, ceil(confirmButton.sizeThatFits(.zero).width) + 16)
        let lineHeight = max(
            cancelButton.titleLabel?.font.lineHeight ?? 20, confirmButton.titleLabel?.font.lineHeight ?? 20)
        let height = max(48, ceil(lineHeight) + 16)
        let available = max(1, width - 24)
        if cancelWidth + confirmWidth + 8 <= available {
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            cancelButton.frame = CGRect(
                x: rtl ? 12 + confirmWidth + 8 : width - 12 - confirmWidth - 8 - cancelWidth, y: y, width: cancelWidth,
                height: height)
            confirmButton.frame = CGRect(
                x: rtl ? 12 : width - 12 - confirmWidth, y: y, width: confirmWidth, height: height)
            return y + height
        }
        let cancelHeight = max(
            height,
            ceil(cancelButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height) + 16)
        let confirmHeight = max(
            height,
            ceil(confirmButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height) + 16)
        cancelButton.frame = CGRect(x: 12, y: y, width: available, height: cancelHeight)
        confirmButton.frame = CGRect(x: 12, y: y + cancelHeight, width: available, height: confirmHeight)
        return y + cancelHeight + confirmHeight
    }

    private var availableFrame: CGRect {
        var frame = view.safeAreaLayoutGuide.layoutFrame
        if let keyboardFrame, let window = view.window {
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let intersection = frame.intersection(view.convert(inWindow, from: window))
            if !intersection.isNull, intersection.width > 0 {
                frame.size.height = max(1, intersection.minY - frame.minY)
            }
        }
        return frame.insetBy(dx: 0, dy: min(16, max(0, (frame.height - 1) / 2)))
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

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = isActive && !isClosing && !isSaving
        nameField.isEnabled = enabled
        cancelButton.isEnabled = enabled
        confirmButton.isEnabled = enabled
        outsideControl.isEnabled = enabled
    }

    @objc private func submit() {
        guard canSubmit else { return }
        let name = nameField.text ?? ""
        if initialGroup == nil, BookSourceGroupManagementGroups.split(name).isEmpty {
            showFailure(BookSourceGroupManagementText.emptyName)
            return
        }
        onSubmit?(name)
    }

    @objc private func cancel() {
        guard canSubmit else { return }
        invalidate()
        view.endEditing(true)
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func nameChanged() {
        guard !isSaving, !isClosing else { return }
        errorLabel.isHidden = true
        view.setNeedsLayout()
    }

    @objc private func focusChanged() {
        underline.backgroundColor =
            nameField.isFirstResponder ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        shouldRevealField = nameField.isFirstResponder
        view.setNeedsLayout()
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        shouldRevealField = nameField.isFirstResponder
        view.setNeedsLayout()
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
            options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curve << 16)]
        ) { [weak self] in
            self?.view.layoutIfNeeded()
        }
    }

    @objc private func keyboardDidChange() {
        shouldRevealField = nameField.isFirstResponder
        view.setNeedsLayout()
    }

    private func invalidate() {
        isClosing = true
        isActive = false
        onSubmit = nil
        updateInteraction()
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        submit()
        return false
    }
}
