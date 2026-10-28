import UIKit

struct ReaderHardwarePageKeyBinding: Equatable {
    var previous: String
    var next: String

    static let `default` = ReaderHardwarePageKeyBinding(
        previous: "",
        next: ""
    )

    var summaryText: String {
        let previousText = previous.nilIfEmpty ?? L10n.Reader.customKeyPageUnset
        let nextText = next.nilIfEmpty ?? L10n.Reader.customKeyPageUnset
        return
            "\(L10n.Reader.customKeyPagePreviousTitle): \(previousText) / \(L10n.Reader.customKeyPageNextTitle): \(nextText)"
    }

    var previousTokens: [String] {
        Self.tokens(from: previous)
    }

    var nextTokens: [String] {
        Self.tokens(from: next)
    }

    func normalized() -> ReaderHardwarePageKeyBinding {
        ReaderHardwarePageKeyBinding(
            previous: Self.clean(previous),
            next: Self.clean(next)
        )
    }

    private static func tokens(from value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }

    private static func clean(_ value: String) -> String {
        let tokens = tokens(from: value)
        return tokens.joined(separator: ", ")
    }
}

extension ReaderHardwarePagingPreference {
    static func customPageKeyBinding() -> ReaderHardwarePageKeyBinding {
        let previousTokens = previousCustomKeyTokens()
        let nextTokens = nextCustomKeyTokens()
        return ReaderHardwarePageKeyBinding(
            previous: previousTokens.joined(separator: ", "),
            next: nextTokens.joined(separator: ", ")
        ).normalized()
    }

    static func setCustomPageKeyBinding(_ binding: ReaderHardwarePageKeyBinding) {
        let normalized = binding.normalized()
        setPreviousCustomKeyTokens(normalized.previousTokens)
        setNextCustomKeyTokens(normalized.nextTokens)
    }

    static func resetCustomPageKeyBinding() {
        setPreviousCustomKeyTokens([])
        setNextCustomKeyTokens([])
    }
}

/// PageKeyDialog.kt / dialog_page_key.xml at Legado 5f5d31404.
final class AndroidReaderHardwareKeyConfigSheetViewController: UIViewController, UITextFieldDelegate {
    private let onSave: (ReaderHardwarePageKeyBinding) -> Void
    private let binding: ReaderHardwarePageKeyBinding
    private var isClosing = false
    private var lastViewportSize = CGSize.zero
    private var needsFocusedFieldReveal = false

    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let scrollView = ReaderHardwareKeyDialogScrollView()
    private let stackView = UIStackView()
    private let helpLabel = AndroidExploreTextLabel()
    private let previousInput = ReaderHardwareKeyDialogField(title: L10n.Reader.customKeyPagePreviousTitle)
    private let nextInput = ReaderHardwareKeyDialogField(title: L10n.Reader.customKeyPageNextTitle)
    private let resetButton = ReaderHardwareKeyDialogActionButton(title: L10n.Reader.customKeyPageReset)
    private let saveButton = ReaderHardwareKeyDialogActionButton(title: L10n.Common.ok)

    init(binding: ReaderHardwarePageKeyBinding, onSave: @escaping (ReaderHardwarePageKeyBinding) -> Void) {
        self.binding = binding.normalized()
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("Use init(binding:onSave:)")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyFonts()
        previousInput.textField.text = binding.previous
        nextInput.textField.text = binding.next
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isClosing = true
        view.endEditing(true)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
        needsFocusedFieldReveal = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        for label in [titleLabel, helpLabel] where label.bounds.width > 0 {
            if label.preferredMaxLayoutWidth != label.bounds.width {
                label.preferredMaxLayoutWidth = label.bounds.width
                label.invalidateIntrinsicContentSize()
            }
        }
        let viewportSize = scrollView.bounds.size
        let shouldReveal =
            needsFocusedFieldReveal || viewportSize.width != lastViewportSize.width
            || viewportSize.height < lastViewportSize.height
        lastViewportSize = viewportSize
        needsFocusedFieldReveal = false
        guard shouldReveal else { return }
        revealFocusedField(animated: false)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard !isClosing else { return false }
        cancel()
        return true
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = UIIdentifiers.ReaderHardwareKeyConfig.root
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true

        titleLabel.text = L10n.Reader.customKeyPageTitle
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        helpLabel.text = L10n.Reader.customKeyPageHelp
        helpLabel.textColor = AndroidReplicaTheme.secondaryText
        helpLabel.numberOfLines = 0
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.adjustsFontForContentSizeCategory = false
        helpLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.isLayoutMarginsRelativeArrangement = true
        // Android: 16dp root padding plus each child's 5dp margin.
        stackView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 21, leading: 21, bottom: 21, trailing: 21)

        configureField(previousInput.textField, identifier: UIIdentifiers.ReaderHardwareKeyConfig.previousField)
        configureField(nextInput.textField, identifier: UIIdentifiers.ReaderHardwareKeyConfig.nextField)

        resetButton.accessibilityIdentifier = UIIdentifiers.ReaderHardwareKeyConfig.resetButton
        saveButton.accessibilityIdentifier = UIIdentifiers.ReaderHardwareKeyConfig.saveButton
        resetButton.addTarget(self, action: #selector(resetDraft), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(saveChanges), for: .touchUpInside)

        let actionStack = UIStackView(arrangedSubviews: [resetButton, saveButton])
        actionStack.axis = .horizontal
        actionStack.spacing = 3
        actionStack.distribution = .fillEqually

        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(stackView)
        for item in [outsideControl, dialogView, scrollView, stackView] {
            item.translatesAutoresizingMaskIntoConstraints = false
        }

        [titleLabel, previousInput, nextInput, helpLabel, actionStack].forEach(stackView.addArrangedSubview)

        let availableArea = UILayoutGuide()
        view.addLayoutGuide(availableArea)
        let safeArea = view.safeAreaLayoutGuide
        let width = dialogView.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: 0.9)
        width.priority = .defaultHigh
        // Keep the intrinsic content intact; only its viewport gives way to the keyboard or large text.
        let wrapHeight = scrollView.heightAnchor.constraint(equalTo: scrollView.contentLayoutGuide.heightAnchor)
        wrapHeight.priority = .defaultLow
        let keyboardBottom = availableArea.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        // An undocked keyboard can be dragged above the safe area's top edge.
        keyboardBottom.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            outsideControl.topAnchor.constraint(equalTo: view.topAnchor),
            outsideControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outsideControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            outsideControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            availableArea.topAnchor.constraint(equalTo: safeArea.topAnchor),
            availableArea.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
            availableArea.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            availableArea.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor),
            availableArea.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            keyboardBottom,
            dialogView.centerXAnchor.constraint(equalTo: availableArea.centerXAnchor),
            dialogView.centerYAnchor.constraint(equalTo: availableArea.centerYAnchor),
            dialogView.leadingAnchor.constraint(greaterThanOrEqualTo: availableArea.leadingAnchor, constant: 8),
            dialogView.trailingAnchor.constraint(lessThanOrEqualTo: availableArea.trailingAnchor, constant: -8),
            dialogView.topAnchor.constraint(greaterThanOrEqualTo: availableArea.topAnchor),
            dialogView.bottomAnchor.constraint(lessThanOrEqualTo: availableArea.bottomAnchor),
            width,

            scrollView.topAnchor.constraint(equalTo: dialogView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: dialogView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dialogView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: dialogView.bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            wrapHeight,

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    private func configureField(_ field: ReaderHardwareKeyDialogCaptureTextField, identifier: String) {
        field.delegate = self
        field.accessibilityIdentifier = identifier
        field.onCancel = { [weak self] in self?.cancel() }
        field.onCaptureToken = { [weak self, weak field] token in
            guard let self, !self.isClosing, let field else { return }
            field.text = Self.appendingToken(token, to: field.text ?? "")
            let end = field.endOfDocument
            field.selectedTextRange = field.textRange(from: end, to: end)
        }
    }

    private func applyFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 18, textStyle: .headline, weight: 700, compatibleWith: traitCollection)
        helpLabel.font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        helpLabel.textColor = AndroidReplicaTheme.secondaryText
        titleLabel.invalidateIntrinsicContentSize()
        helpLabel.invalidateIntrinsicContentSize()
        resetButton.applyFont()
        saveButton.applyFont()
        view.setNeedsLayout()
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        needsFocusedFieldReveal = true
        view.setNeedsLayout()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        // Software Return ends editing. Hardware Enter remains a capturable token.
        textField.resignFirstResponder()
        return true
    }

    @objc private func keyboardFrameDidChange() {
        guard !isClosing else { return }
        view.layoutIfNeeded()
    }

    private func revealFocusedField(animated: Bool) {
        guard !isClosing, scrollView.bounds.height > 0,
            let field = [previousInput.textField, nextInput.textField].first(where: { $0.isFirstResponder })
        else { return }
        scrollView.scrollRectToVisible(
            field.convert(field.bounds, to: scrollView).insetBy(dx: 0, dy: -8), animated: animated)
    }

    private func currentBinding() -> ReaderHardwarePageKeyBinding {
        ReaderHardwarePageKeyBinding(
            previous: previousInput.textField.text ?? "",
            next: nextInput.textField.text ?? ""
        ).normalized()
    }

    @objc private func resetDraft() {
        guard !isClosing else { return }
        previousInput.textField.text = ""
        nextInput.textField.text = ""
    }

    @objc private func saveChanges() {
        finish(saving: currentBinding())
    }

    @objc private func cancel() {
        finish(saving: nil)
    }

    private func finish(saving updated: ReaderHardwarePageKeyBinding?) {
        guard !isClosing else { return }
        isClosing = true
        view.isUserInteractionEnabled = false
        view.endEditing(true)
        resignFirstResponder()
        if let updated {
            onSave(updated)
        }
        dismiss(animated: true)
    }

    private static func appendingToken(_ token: String, to text: String) -> String {
        var tokens =
            text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        if tokens.contains(token) == false {
            tokens.append(token)
        }
        return tokens.joined(separator: ", ")
    }
}
