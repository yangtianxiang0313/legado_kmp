import UIKit

/// BaseReadBookActivity.showDownloadDialog / dialog_download_choice.xml at Legado
/// 5f5d31404af9957684703747ecee2b91e7161f1d. The caller registers and presents this controller,
/// supplies overrideUserInterfaceStyle if needed, and downloads the confirmed zero-based closed range.
@MainActor
final class ReaderDownloadChoiceDialogViewController: UIViewController, UITextFieldDelegate {
    private enum Phase {
        case waiting
        case active
        case closing(UUID)
        case finished
    }

    private let policy: ReaderDownloadChoiceRangePolicy
    private var onConfirm: ((Int, Int) -> Void)?
    private var phase: Phase = .waiting
    private var isVisible = false
    private var keyboardFrame: CGRect?
    private var rejectedInputFields: Set<ReaderDownloadChoiceRangePolicy.Field> = []
    private weak var pendingRevealView: UIView?
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let scrollView = ReaderDownloadChoiceScrollView()
    private let contentView = UIView()
    private let titleLabel = ReaderDownloadChoiceLabel()
    private let rangeView = ReaderDownloadChoiceRangeView()
    private let errorLabel = ReaderDownloadChoiceLabel()
    private let cancelControl = ReaderDownloadChoiceActionControl(title: L10n.Common.cancel)
    private let confirmControl = ReaderDownloadChoiceActionControl(
        title: NSLocalizedString(
            "reader.download.choice.ok", value: "确认", comment: "Legado ok"))

    init(currentChapterIndex: Int, chapterCount: Int, onConfirm: @escaping (Int, Int) -> Void) {
        policy = ReaderDownloadChoiceRangePolicy(
            currentChapterIndex: currentChapterIndex, chapterCount: chapterCount)
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
        title = NSLocalizedString(
            "reader.download.choice.title", value: "离线缓存", comment: "Legado offline_cache")
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
        guard case .active = phase else { return nil }
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyFonts()
        if case .failure(let error) = policy.resolve(
            startText: policy.initialStartText, endText: policy.initialEndText)
        {
            show(error: error, announce: false)
        }
        updateInteraction()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard case .waiting = phase else { return }
        phase = .active
        isVisible = true
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if case .closing = phase { updateInteraction() } else { invalidate() }
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        invalidate()
        super.dismiss(animated: flag, completion: completion)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
        pendingRevealView = focusedField
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(range: nil)
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let available = availableFrame
        guard available.width > 0, available.height > 0 else { return }
        let width = min(available.width, view.bounds.width * dialogWidthFraction)
        let titleWidth = max(1, width - 48)
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: titleWidth, height: .greatestFiniteMagnitude)
        ).height
        titleLabel.frame = CGRect(x: 24, y: 18, width: titleWidth, height: titleHeight)
        let rangeHeight = rangeView.sizeThatFits(CGSize(width: width, height: 0)).height
        rangeView.frame = CGRect(x: 0, y: titleLabel.frame.maxY, width: width, height: rangeHeight)
        var nextY = rangeView.frame.maxY
        if !errorLabel.isHidden {
            let errorWidth = max(1, width - 32)
            let errorHeight = errorLabel.sizeThatFits(
                CGSize(width: errorWidth, height: .greatestFiniteMagnitude)
            ).height
            errorLabel.frame = CGRect(x: 16, y: nextY, width: errorWidth, height: errorHeight)
            nextY += errorHeight + 16
        }
        let contentHeight = layoutActions(width: width, top: nextY + 4) + 4
        let height = min(available.height, contentHeight)
        dialogView.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2,
            width: width, height: height)
        scrollView.frame = dialogView.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        let offset = CGPoint(x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }
        rangeView.layoutIfNeeded()
        if let target = pendingRevealView {
            pendingRevealView = nil
            reveal(target)
        }
    }

    private var availableFrame: CGRect {
        var frame = view.safeAreaLayoutGuide.layoutFrame
        if let keyboardFrame, let window = view.window {
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inView = view.convert(inWindow, from: window)
            let intersection = frame.intersection(inView)
            if !intersection.isNull, intersection.width > 0 {
                frame.size.height = max(1, intersection.minY - frame.minY)
            }
        }
        let verticalInset = min(16, max(0, (frame.height - 1) / 2))
        return frame.insetBy(dx: 0, dy: verticalInset)
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        // Same AppCompat minor/major width buckets as ReaderPreferenceChoiceDialog.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func layoutActions(width: CGFloat, top: CGFloat) -> CGFloat {
        let availableWidth = max(1, width - 24)
        let cancelWidth = cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        if cancelWidth + confirmWidth <= availableWidth {
            let height = max(
                cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: 0)).height,
                confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: 0)).height)
            let isRTL = dialogView.effectiveUserInterfaceLayoutDirection == .rightToLeft
            cancelControl.frame = CGRect(
                x: isRTL ? 12 + confirmWidth : width - 12 - confirmWidth - cancelWidth,
                y: top, width: cancelWidth, height: height)
            confirmControl.frame = CGRect(
                x: isRTL ? 12 : width - 12 - confirmWidth, y: top, width: confirmWidth, height: height)
            return top + height
        }
        let cancelHeight = cancelControl.sizeThatFits(CGSize(width: availableWidth, height: 0)).height
        let confirmHeight = confirmControl.sizeThatFits(CGSize(width: availableWidth, height: 0)).height
        cancelControl.frame = CGRect(x: 12, y: top, width: availableWidth, height: cancelHeight)
        confirmControl.frame = CGRect(x: 12, y: top + cancelHeight, width: availableWidth, height: confirmHeight)
        return top + cancelHeight + confirmHeight
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.download.choice"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true
        titleLabel.text = title
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.download.choice.title"
        errorLabel.numberOfLines = 0
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.textColor = .systemRed
        errorLabel.adjustsFontForContentSizeCategory = false
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "reader.download.choice.error"
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.accessibilityIdentifier = "reader.download.choice.form"
        rangeView.startField.text = policy.initialStartText
        rangeView.endField.text = policy.initialEndText
        rangeView.startField.returnKeyType = .next
        rangeView.endField.returnKeyType = .done
        for field in [rangeView.startField, rangeView.endField] { field.delegate = self }
        rangeView.startField.accessibilityIdentifier = "reader.download.choice.start"
        rangeView.endField.accessibilityIdentifier = "reader.download.choice.end"
        cancelControl.accessibilityIdentifier = "reader.download.choice.cancel"
        confirmControl.accessibilityIdentifier = "reader.download.choice.confirm"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        for item in [titleLabel, rangeView, errorLabel, cancelControl, confirmControl] {
            contentView.addSubview(item)
        }
        contentView.accessibilityElements = [titleLabel, rangeView, errorLabel, cancelControl, confirmControl]
    }

    private func applyFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        errorLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 13, textStyle: .footnote, compatibleWith: traitCollection)
        rangeView.apply(traits: traitCollection)
        for control in [cancelControl, confirmControl] { control.apply(traits: traitCollection) }
        view.setNeedsLayout()
    }

    private var focusedField: UITextField? {
        [rangeView.startField, rangeView.endField].first { $0.isFirstResponder }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        pendingRevealView = textField
        view.setNeedsLayout()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard canInteract else { return false }
        if textField === rangeView.startField {
            rangeView.endField.becomeFirstResponder()
        } else {
            confirm()
        }
        return false
    }

    func textField(
        _ textField: UITextField, shouldChangeCharactersIn range: NSRange,
        replacementString string: String
    ) -> Bool {
        guard canInteract, let oldText = textField.text, let textRange = Range(range, in: oldText) else {
            return false
        }
        let candidate = oldText.replacingCharacters(in: textRange, with: string)
        let field: ReaderDownloadChoiceRangePolicy.Field = textField === rangeView.startField ? .start : .end
        // Deletion must also work for an oversized programmatic default; never truncate or filter a paste.
        if string.isEmpty || ReaderDownloadChoiceRangePolicy.acceptsInput(candidate) {
            rejectedInputFields.remove(field)
            return true
        }
        rejectedInputFields.insert(field)
        show(error: .invalidNumber(field))
        return false
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard case .active = phase else { return }
        keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        pendingRevealView = focusedField
        view.setNeedsLayout()
        let duration =
            (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0
        let curve = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 0
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
            options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState, .allowUserInteraction]
        ) { self.view.layoutIfNeeded() }
    }

    @objc private func keyboardFrameDidChange() {
        guard case .active = phase else { return }
        pendingRevealView = focusedField
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }

    private func reveal(_ target: UIView) {
        let rect = target.convert(target.bounds, to: contentView).insetBy(dx: 0, dy: -8)
        // If one very large field is taller than the viewport, reveal its top instead of jumping past it.
        let visibleRect = CGRect(
            x: rect.minX, y: rect.minY, width: rect.width,
            height: min(rect.height, scrollView.bounds.height))
        scrollView.scrollRectToVisible(visibleRect, animated: false)
    }

    private func show(error: ReaderDownloadChoiceRangePolicy.ValidationError, announce: Bool = true) {
        errorLabel.text = error.message
        errorLabel.isHidden = false
        rangeView.startField.showsError = error.field == .start || error.field == nil
        rangeView.endField.showsError = error.field == .end || error.field == nil
        pendingRevealView = errorLabel
        view.setNeedsLayout()
        if announce { UIAccessibility.post(notification: .announcement, argument: error.message) }
    }

    private var canInteract: Bool {
        guard case .active = phase, isVisible, !isBeingDismissed, !isBeingPresented,
            presentedViewController == nil, let window = viewIfLoaded?.window,
            let presenter = presentingViewController
        else { return false }
        return isCurrentPresenter(presenter, in: window)
    }

    private func isCurrentPresenter(_ presenter: UIViewController, in window: UIWindow) -> Bool {
        guard !window.isHidden, window.windowScene?.activationState == .foregroundActive,
            presenter.viewIfLoaded?.window === window
        else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent else { return false }
            current = controller.parent
        }
        return true
    }

    private func updateInteraction() {
        let enabled: Bool
        if case .active = phase { enabled = isVisible } else { enabled = false }
        outsideControl.isEnabled = enabled
        scrollView.isUserInteractionEnabled = enabled
        for control in [cancelControl, confirmControl] { control.isEnabled = enabled }
        for field in [rangeView.startField, rangeView.endField] { field.isEnabled = enabled }
    }

    private func invalidate() {
        phase = .finished
        onConfirm = nil
        if isViewLoaded { updateInteraction() }
    }

    @objc private func cancel() { close(range: nil) }

    @objc private func confirm() {
        guard canInteract else { return }
        // An invalid paste leaves the old text untouched, but must not silently submit that old range.
        for field in [ReaderDownloadChoiceRangePolicy.Field.start, .end] where rejectedInputFields.contains(field) {
            show(error: .invalidNumber(field))
            return
        }
        switch policy.resolve(startText: rangeView.startField.text ?? "", endText: rangeView.endField.text ?? "") {
        case .success(let range): close(range: range)
        case .failure(let error): show(error: error)
        }
    }

    private func close(range: ClosedRange<Int>?) {
        guard canInteract, let presenter = presentingViewController, let window = viewIfLoaded?.window else { return }
        let dismissalID = UUID()
        phase = .closing(dismissalID)
        if range == nil { onConfirm = nil }
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        // Only this dismissal's completion may consume the callback, after the animation finishes.
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self, weak presenter, weak window] in
            guard case .closing(let currentID) = phase, currentID == dismissalID else { return }
            let callback = onConfirm
            invalidate()
            guard let range, presentingViewController == nil, viewIfLoaded?.window == nil,
                let presenter, let window, presenter.presentedViewController == nil,
                isCurrentPresenter(presenter, in: window)
            else { return }
            callback?(range.lowerBound, range.upperBound)
        }
    }
}
