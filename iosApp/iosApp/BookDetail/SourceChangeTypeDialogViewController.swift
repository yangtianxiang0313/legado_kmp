import UIKit

/// ChangeBookSourceDialog.changeTo at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
/// The caller decides whether types differ and owns the source-change workflow.
@MainActor
final class SourceChangeTypeDialogViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private let contentView = SourceChangeTypeDialogContentView()
    private lazy var dialogView = SourceChangeDialogView(
        content: contentView, wrapsContent: false, identifier: "sourceChange.typeDialog")
    private lazy var lifecycle = SourceChangeDialogLifecycle(
        controller: self,
        dismiss: { [weak self] animated, completion in
            self?.dismissDialog(animated: animated, completion: completion)
        },
        interactionChanged: { [weak self] in self?.updateInteraction() },
        detached: { [weak self] outcome in self?.didDetach(outcome) })

    init(onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onConfirm = onConfirm
        self.onCancel = onCancel
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
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = "取消"
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func loadView() {
        view = dialogView
        dialogView.onWindowChange = { [weak self] in self?.lifecycle.scheduleDetachmentCheck() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        contentView.cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        dialogView.outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        contentView.applyFonts(traits: traitCollection)
        updateInteraction()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationController?.delegate = self
        lifecycle.willAppear()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        lifecycle.didAppear()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lifecycle.canInteract else { return }
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.contentView.titleLabel)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        lifecycle.willDisappear()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        lifecycle.scheduleDetachmentCheck()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard presentedViewController == nil else {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        lifecycle.close(.external, animated: flag, completion: completion)
    }

    func presentationControllerDidDismiss(_: UIPresentationController) {
        lifecycle.externallyDismissed()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard lifecycle.canInteract else { return false }
        cancel()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    /// Programmatic close never confirms; onCancel releases the pending decision before completion.
    func finish(animated: Bool, completion: @escaping () -> Void) {
        lifecycle.close(.finished, animated: animated, completion: completion)
    }

    @objc private func cancel() {
        guard lifecycle.canInteract else { return }
        lifecycle.close(.cancelled, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func confirm() {
        guard lifecycle.canInteract else { return }
        lifecycle.close(.confirmed, animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func updateInteraction() {
        let enabled = lifecycle.canInteract
        contentView.cancelControl.isEnabled = enabled
        contentView.confirmControl.isEnabled = enabled
        dialogView.outsideControl.isEnabled = enabled
    }

    private func dismissDialog(animated: Bool, completion: @escaping () -> Void) {
        resignFirstResponder()
        super.dismiss(animated: animated, completion: completion)
    }

    private func didDetach(_ outcome: SourceChangeDialogLifecycle.Outcome) {
        let confirmCallback = onConfirm
        let cancelCallback = onCancel
        onConfirm = nil
        onCancel = nil
        switch outcome {
        case .confirmed: confirmCallback?()
        case .cancelled, .external, .finished: cancelCallback?()
        }
    }
}

@MainActor
private final class SourceChangeTypeDialogContentView: UIView {
    let titleLabel = UILabel()
    let cancelControl = BookshelfLayoutDialogAction(title: "取消")
    let confirmControl = BookshelfLayoutDialogAction(title: "确定")
    private let messageLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        BookshelfLayoutDialogStyle.configure(titleLabel, text: "书籍类型不一样", color: AndroidReplicaTheme.primaryText)
        BookshelfLayoutDialogStyle.configure(messageLabel, text: "是否确认换源", color: AndroidReplicaTheme.primaryText)
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceChange.typeDialog.title"
        messageLabel.accessibilityIdentifier = "sourceChange.typeDialog.message"
        cancelControl.accessibilityIdentifier = "sourceChange.typeDialog.cancel"
        confirmControl.accessibilityIdentifier = "sourceChange.typeDialog.confirm"
        for child in [titleLabel, messageLabel, cancelControl, confirmControl] { addSubview(child) }
        accessibilityElements = [titleLabel, messageLabel, cancelControl, confirmControl]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = BookshelfLayoutDialogStyle.font(size: 20, weight: .medium, style: .headline, traits: traits)
        messageLabel.font = BookshelfLayoutDialogStyle.font(size: 16, traits: traits)
        let actionFont = BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits)
        cancelControl.apply(font: actionFont)
        confirmControl.apply(font: actionFont)
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, applyFrames: true)
    }

    private func arrange(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(24, max(0, (width - 1) / 2))
        let textWidth = max(1, width - inset * 2)
        var y: CGFloat = 20
        for label in [titleLabel, messageLabel] {
            let height = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames { label.frame = CGRect(x: inset, y: y, width: textWidth, height: height) }
            y += height + 16
        }
        let actionInset = min(8, max(0, (width - 1) / 2))
        let available = max(1, width - actionInset * 2)
        let cancelWidth = cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        if cancelWidth + confirmWidth + 8 <= available {
            let height = max(
                cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude)).height,
                confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames {
                let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
                let confirmX = rtl ? actionInset : width - actionInset - confirmWidth
                let cancelX = rtl ? confirmX + confirmWidth + 8 : confirmX - 8 - cancelWidth
                cancelControl.frame = CGRect(x: cancelX, y: y, width: cancelWidth, height: height)
                confirmControl.frame = CGRect(x: confirmX, y: y, width: confirmWidth, height: height)
            }
            return y + height + 8
        }
        let cancelHeight = cancelControl.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
        let confirmHeight = confirmControl.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height
        if applyFrames {
            cancelControl.frame = CGRect(x: actionInset, y: y, width: available, height: cancelHeight)
            confirmControl.frame = CGRect(x: actionInset, y: y + cancelHeight + 8, width: available, height: confirmHeight)
        }
        return y + cancelHeight + 8 + confirmHeight + 8
    }
}
