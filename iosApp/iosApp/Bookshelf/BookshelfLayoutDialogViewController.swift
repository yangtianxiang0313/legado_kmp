import UIKit

struct BookshelfLayoutDraft: Equatable {
    var layoutIndex: Int
    var sortIndex: Int
    var showUnread: Bool
    var showLastUpdateTime: Bool
    var groupStyleIndex: Int = 0
    var showWaitUpCount: Bool = false
    var showBookshelfFastScroller: Bool = false
}

/// BaseBookshelfFragment.configBookshelf / dialog_bookshelf_config.xml.
/// The caller owns persistence and may supply an explicit day/night trait override.
final class BookshelfLayoutDialogViewController: UIViewController {
    private var draft: BookshelfLayoutDraft
    private let onSave: (BookshelfLayoutDraft) async throws -> Void
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let titleLabel = UILabel()
    private let scrollView = BookshelfLayoutDialogScrollView()
    private let contentView = UIView()
    private let errorLabel = UILabel()
    private lazy var bodyView = BookshelfLayoutDialogBodyView(draft: draft)
    private let cancelControl = BookshelfLayoutDialogAction(title: L10n.Common.cancel)
    private let confirmControl = BookshelfLayoutDialogAction(title: L10n.Common.ok)
    private var saveTask: Task<Void, Never>?
    private var activeSaveID: UUID?
    private var isVisible = false
    private var isClosing = false

    init(draft: BookshelfLayoutDraft, onSave: @escaping (BookshelfLayoutDraft) async throws -> Void) {
        var normalizedDraft = draft
        if !BookshelfLayoutDialogBodyView.layoutTitles.indices.contains(draft.layoutIndex) {
            normalizedDraft.layoutIndex = 0
        }
        if !BookshelfLayoutDialogBodyView.sortTitles.indices.contains(draft.sortIndex) {
            normalizedDraft.sortIndex = 0
        }
        if !BookshelfLayoutDialogBodyView.groupStyleTitles.indices.contains(draft.groupStyleIndex) {
            normalizedDraft.groupStyleIndex = 0
        }
        self.draft = normalizedDraft
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        saveTask?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard activeSaveID == nil, !isClosing else { return nil }
        let escape = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyFonts()
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isVisible = true
        updateInteraction()
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        invalidateSave()
        updateInteraction()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
        view.setNeedsLayout()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract, activeSaveID == nil else { return false }
        cancel()
        return true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        guard safeFrame.width > 0, safeFrame.height > 0 else { return }

        // AppCompat AlertDialog min-width fractions; applyTint removes background insets.
        let width = min(safeFrame.width, view.bounds.width * dialogWidthFraction)
        let innerWidth = max(1, width - 32)
        let titleHeight = measuredHeight(of: titleLabel, width: innerWidth)
        let headerHeight = 16 + titleHeight + 8
        let actionGap: CGFloat = 8
        let cancelWidth = cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        let compactActions = cancelWidth + confirmWidth + actionGap <= innerWidth
        let actionWidth = max(1, (innerWidth - actionGap) / 2)
        let widths = compactActions ? [cancelWidth, confirmWidth] : [actionWidth, actionWidth]
        let actionHeight = max(
            cancelControl.sizeThatFits(CGSize(width: widths[0], height: .greatestFiniteMagnitude)).height,
            confirmControl.sizeThatFits(CGSize(width: widths[1], height: .greatestFiniteMagnitude)).height
        )
        let footerHeight = actionHeight + 16

        let errorHeight =
            errorLabel.isHidden ? 0 : measuredHeight(of: errorLabel, width: innerWidth) + 12
        let bodyHeight = bodyView.sizeThatFits(
            CGSize(width: innerWidth, height: .greatestFiniteMagnitude)
        ).height
        let contentHeight = errorHeight + bodyHeight + 16
        let preferredHeight = headerHeight + contentHeight + footerHeight
        let maximumHeight = min(
            safeFrame.height, max(safeFrame.height * 0.9, headerHeight + footerHeight + 48))
        let height = min(maximumHeight, preferredHeight)
        let viewportHeight = max(0, height - headerHeight - footerHeight)
        dialogView.frame = CGRect(
            x: safeFrame.midX - width / 2, y: safeFrame.midY - height / 2,
            width: width, height: height)
        titleLabel.frame = CGRect(x: 16, y: 16, width: innerWidth, height: titleHeight)
        scrollView.frame = CGRect(x: 0, y: headerHeight, width: width, height: viewportHeight)
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        errorLabel.frame = CGRect(x: 16, y: 0, width: innerWidth, height: max(0, errorHeight - 12))
        bodyView.frame = CGRect(x: 16, y: errorHeight, width: innerWidth, height: bodyHeight)
        scrollView.contentSize = contentView.bounds.size
        let canScroll = contentHeight > viewportHeight
        if scrollView.isScrollEnabled != canScroll { scrollView.isScrollEnabled = canScroll }
        let offset = CGPoint(
            x: 0, y: min(max(0, scrollView.contentOffset.y), max(0, contentHeight - viewportHeight)))
        if scrollView.contentOffset != offset { scrollView.contentOffset = offset }

        let isRTL = dialogView.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let confirmX = isRTL ? 16 : width - 16 - widths[1]
        let cancelX = isRTL ? confirmX + widths[1] + actionGap : confirmX - actionGap - widths[0]
        let actionY = headerHeight + viewportHeight + 8
        cancelControl.frame = CGRect(x: cancelX, y: actionY, width: widths[0], height: actionHeight)
        confirmControl.frame = CGRect(x: confirmX, y: actionY, width: widths[1], height: actionHeight)
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        let landscape = size.width > size.height
        // AppCompat values[-large/-xlarge]-v4 abc_dialog_min_width_minor/major.
        if shortSide >= 720 && longSide >= 960 { return landscape ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return landscape ? 0.55 : 0.80 }
        return landscape ? 0.65 : 0.95
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "bookshelf.layoutDialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.backgroundColor = AndroidReplicaTheme.background
        dialogView.layer.cornerRadius = 3
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true

        BookshelfLayoutDialogStyle.configure(
            titleLabel, text: "书架布局", color: AndroidReplicaTheme.primaryText)
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookshelf.layoutDialog.title"
        BookshelfLayoutDialogStyle.configure(errorLabel, text: "", color: .systemRed)
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "bookshelf.layoutDialog.error"

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.accessibilityIdentifier = "bookshelf.layoutDialog.content"
        cancelControl.accessibilityIdentifier = "bookshelf.layoutDialog.cancel"
        confirmControl.accessibilityIdentifier = "bookshelf.layoutDialog.confirm"
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(save), for: .touchUpInside)
        bodyView.onChange = { [weak self] draft in
            guard let self, self.canInteract, self.activeSaveID == nil else { return }
            self.draft = draft
        }

        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(titleLabel)
        dialogView.addSubview(scrollView)
        scrollView.addSubview(contentView)
        contentView.addSubview(errorLabel)
        contentView.addSubview(bodyView)
        dialogView.addSubview(cancelControl)
        dialogView.addSubview(confirmControl)
        dialogView.accessibilityElements = [titleLabel, scrollView, cancelControl, confirmControl]
    }

    private func applyFonts() {
        titleLabel.font = BookshelfLayoutDialogStyle.font(
            size: 20, weight: .medium, style: .headline, traits: traitCollection)
        errorLabel.font = BookshelfLayoutDialogStyle.font(size: 14, traits: traitCollection)
        let actionFont = BookshelfLayoutDialogStyle.font(
            size: 14, weight: .medium, traits: traitCollection)
        cancelControl.apply(font: actionFont)
        confirmControl.apply(font: actionFont)
        bodyView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    private func measuredHeight(of label: UILabel, width: CGFloat) -> CGFloat {
        ceil(label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
    }

    private var canInteract: Bool {
        guard isVisible, !isClosing, !isBeingDismissed, !isBeingPresented,
            viewIfLoaded?.window != nil, presentedViewController == nil,
            let presenter = presentingViewController
        else { return false }
        var current: UIViewController? = presenter
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent else { return false }
            current = controller.parent
        }
        return true
    }

    private func updateInteraction() {
        let enabled = isVisible && !isClosing && activeSaveID == nil
        outsideControl.isEnabled = enabled
        cancelControl.isEnabled = enabled
        confirmControl.isEnabled = enabled
        bodyView.isEditingEnabled = enabled
    }

    @objc private func cancel() {
        guard canInteract, activeSaveID == nil else { return }
        if bodyView.dismissGroupStyleMenu() { return }
        close()
    }

    @objc private func save() {
        guard canInteract, activeSaveID == nil else { return }
        let requestID = UUID()
        activeSaveID = requestID
        errorLabel.text = nil
        errorLabel.isHidden = true
        updateInteraction()
        view.setNeedsLayout()

        // Do not unwrap self before the await: the operation must not own this dialog.
        saveTask = Task { @MainActor [weak self, onSave = onSave, snapshot = draft] in
            do {
                try Task.checkCancellation()
                try await onSave(snapshot)
                try Task.checkCancellation()
                self?.finishSave(requestID: requestID, error: nil)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishSave(requestID: requestID, error: error)
            }
        }
    }

    private func finishSave(requestID: UUID, error: Error?) {
        guard activeSaveID == requestID, canInteract else { return }
        activeSaveID = nil
        saveTask = nil
        if let error {
            errorLabel.text = error.localizedDescription
            errorLabel.isHidden = false
            updateInteraction()
            view.setNeedsLayout()
            view.layoutIfNeeded()
            scrollView.setContentOffset(.zero, animated: false)
            UIAccessibility.post(notification: .layoutChanged, argument: errorLabel)
        } else {
            close()
        }
    }

    private func invalidateSave() {
        activeSaveID = nil
        saveTask?.cancel()
        saveTask = nil
    }

    private func close() {
        isClosing = true
        invalidateSave()
        updateInteraction()
        resignFirstResponder()
        dismiss(animated: true)
    }
}

private final class BookshelfLayoutDialogScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UISwitch { return false }
        return view is UIControl || super.touchesShouldCancel(in: view)
    }
}
