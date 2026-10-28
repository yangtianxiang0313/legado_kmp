import UIKit
import shared

/// dialog_bookmark.xml and BookmarkDialog.kt at Legado 5f5d314.
@MainActor
final class ReaderTocBookmarkEditorViewController: UIViewController, UITextViewDelegate {
    /// Side-effect-free host/book identity guard. Nil preserves existing callers.
    /// Replacing it revokes pending UI delivery, not an already accepted write.
    var canSubmit: (() -> Bool)? {
        didSet {
            guard isViewLoaded else { return }
            presentationSession.revokeDelivery()
            updateControls()
        }
    }

    private let bookmark: Bookmark
    private let onSave: (String, String) async throws -> Void
    private let onDelete: (() async throws -> Void)?
    private let outsideControl = UIControl()
    private let cardView = UIView()
    private let toolbar = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let chapterLabel = AndroidExploreTextLabel()
    private lazy var chapterRow = paddedChapter()
    private let scrollView = UIScrollView()
    private let formStack = UIStackView()
    private let errorLabel = AndroidExploreTextLabel()
    private let bookTextField = ReaderTocBookmarkEditorField(
        hint: NSLocalizedString("reader.toc.bookmark.content", value: "内容", comment: "Legado content"))
    private let noteField = ReaderTocBookmarkEditorField(
        hint: NSLocalizedString("reader.toc.bookmark.note_content", value: "备注内容", comment: "Legado note_content"))
    private let footer = ReaderTocBookmarkEditorFooter()
    private var toolbarHeightConstraint: NSLayoutConstraint?
    private var pinnedChromeConstraints: [NSLayoutConstraint] = []
    private var scrollingChromeConstraints: [NSLayoutConstraint] = []
    private var scrollsChrome = false
    private var keyboardFrame: CGRect?
    private lazy var presentationSession = ReaderBookmarkEditorPresentation(editor: self)
    private var isPerformingOperation = false
    private var hasCompletedOperation = false
    private var isClosing = false
    private var isCheckingSubmission = false
    private var isUpdatingControls = false

    init(
        bookmark: Bookmark,
        onSave: @escaping (String, String) async throws -> Void,
        onDelete: (() async throws -> Void)? = nil
    ) {
        self.bookmark = bookmark
        self.onSave = onSave
        self.onDelete = onDelete
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(bookmark:onSave:onDelete:)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard canCancelEditing else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelEditing))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        applyFonts()
        refreshPalette()
        presentationSession.onChange = { [weak self] in self?.updateControls() }
        updateControls()
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameDidChange),
            name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateChromePlacement()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        presentationSession.bindSourceIfNeeded()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !presentationSession.isRetired else { return }
        // A cancelled external transition keeps this draft, but never restores an old attempt's delivery.
        isClosing = false
        presentationSession.didAppear()
        if !hasMarkedText, !bookTextField.textView.isFirstResponder, !noteField.textView.isFirstResponder {
            becomeFirstResponder()
        }
        UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        presentationSession.willDisappear()
        resignFirstResponder()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        presentationSession.didDisappear()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        if presentedViewController == nil {
            // Never forward a stale instance's dismissal to a replacement presentation.
            guard !presentationSession.isRetired,
                let presenter = presentingViewController, presenter.presentedViewController === self
            else {
                presentationSession.retire()
                completion?()
                return
            }
            isClosing = true
            presentationSession.revokeDelivery()
            if isViewLoaded { updateControls() }
            resignFirstResponder()
        }
        super.dismiss(animated: flag) { [weak self] in
            self?.presentationSession.refresh()
            completion?()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true {
            refreshPalette()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            applyFonts()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        dismissEditor()
    }

    private func configureViews() {
        // The scrim covers the full window, including both unsafe areas.
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.toc.bookmark.editor"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        cardView.layer.cornerRadius = 3  // shape_card_view.xml
        cardView.clipsToBounds = true
        titleLabel.text = L10n.Settings.bookmarkTitle
        titleLabel.accessibilityTraits = .header
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        chapterLabel.text = bookmark.chapterName
        chapterLabel.numberOfLines = 0
        chapterLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        bookTextField.setText(bookmark.bookText)
        noteField.setText(bookmark.content)
        for field in [bookTextField, noteField] {
            field.textView.delegate = self
        }
        bookTextField.textView.accessibilityIdentifier = "reader.toc.bookmark.bookText"
        noteField.textView.accessibilityIdentifier = "reader.toc.bookmark.note"
        errorLabel.numberOfLines = 0
        // Preserve the line box above wrapHeight, but allow UIStackView's required hidden height.
        errorLabel.setContentCompressionResistancePriority(UILayoutPriority(999), for: .vertical)
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "reader.toc.bookmark.error"

        footer.deleteButton.addTarget(self, action: #selector(deleteBookmark), for: .touchUpInside)
        footer.setDeletionAvailable(onDelete != nil)
        footer.cancelButton.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        footer.confirmButton.addTarget(self, action: #selector(saveBookmark), for: .touchUpInside)

        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.accessibilityIdentifier = "reader.toc.bookmark.form"
        formStack.axis = .vertical
        formStack.spacing = 0
        let fieldsStack = UIStackView(arrangedSubviews: [bookTextField, noteField, errorLabel])
        fieldsStack.axis = .vertical
        fieldsStack.spacing = 0
        fieldsStack.isLayoutMarginsRelativeArrangement = true
        fieldsStack.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 16, leading: 16, bottom: 16, trailing: 16)
        formStack.addArrangedSubview(fieldsStack)

        view.addSubview(outsideControl)
        view.addSubview(cardView)
        cardView.addSubview(toolbar)
        cardView.addSubview(chapterRow)
        cardView.addSubview(scrollView)
        cardView.addSubview(footer)
        toolbar.addSubview(titleLabel)
        scrollView.addSubview(formStack)
        for item in [outsideControl, cardView, toolbar, titleLabel, chapterRow, scrollView, formStack, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
        }

        let availableArea = UILayoutGuide()
        view.addLayoutGuide(availableArea)
        let safeArea = view.safeAreaLayoutGuide
        // Prefer wrap_content. Only the viewport shrinks when the content or
        // keyboard exceeds the available height; the input text never clips.
        let wrapHeight = scrollView.heightAnchor.constraint(equalTo: scrollView.contentLayoutGuide.heightAnchor)
        wrapHeight.priority = .defaultHigh
        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 56)
        toolbarHeightConstraint = toolbarHeight
        pinnedChromeConstraints = [
            toolbar.topAnchor.constraint(equalTo: cardView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            chapterRow.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            chapterRow.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            chapterRow.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: chapterRow.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ]
        scrollingChromeConstraints = [
            scrollView.topAnchor.constraint(equalTo: cardView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),
        ]
        NSLayoutConstraint.activate([
            outsideControl.topAnchor.constraint(equalTo: view.topAnchor),
            outsideControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outsideControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outsideControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            availableArea.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 16),
            availableArea.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16),
            availableArea.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
            availableArea.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
            cardView.leadingAnchor.constraint(equalTo: availableArea.leadingAnchor),
            cardView.trailingAnchor.constraint(equalTo: availableArea.trailingAnchor),
            cardView.centerYAnchor.constraint(equalTo: availableArea.centerYAnchor),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: availableArea.topAnchor),
            cardView.bottomAnchor.constraint(lessThanOrEqualTo: availableArea.bottomAnchor),
            toolbarHeight,
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: toolbar.topAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: toolbar.bottomAnchor, constant: -4),
            scrollView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            wrapHeight,
            formStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            formStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            formStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            formStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            formStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
        NSLayoutConstraint.activate(pinnedChromeConstraints)
    }

    private func updateChromePlacement() {
        guard !pinnedChromeConstraints.isEmpty, view.bounds.width > 0 else { return }
        let width = max(1, view.bounds.width - view.safeAreaInsets.left - view.safeAreaInsets.right - 32)
        let titleHeight = titleLabel.sizeThatFits(
            CGSize(width: max(1, width - 32), height: .greatestFiniteMagnitude)
        ).height
        // Dialog Toolbar is wrap_content: its padded single line plus 4dp title margins.
        // Keep the normal 56dp minimum; the Activity's landscape resource is not this dialog's height.
        let toolbarHeight = max(56, ceil(titleHeight) + 8)
        toolbarHeightConstraint?.constant = toolbarHeight
        footer.updateAxis(for: width)
        let footerHeight = footer.systemLayoutSizeFitting(
            CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        let chapterHeight = chapterRow.systemLayoutSizeFitting(
            CGSize(width: width, height: 0), withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        var bottom = view.bounds.maxY - view.safeAreaInsets.bottom
        if let keyboardFrame, let window = view.window {
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let inView = view.convert(inWindow, from: window)
            let intersection = view.bounds.intersection(inView)
            if !intersection.isNull, intersection.maxY >= view.bounds.maxY - view.safeAreaInsets.bottom {
                bottom = min(bottom, intersection.minY)
            }
        }
        let availableHeight = bottom - view.safeAreaInsets.top - 32
        let shouldScrollChrome = availableHeight < toolbarHeight + chapterHeight + footerHeight + 44
        guard shouldScrollChrome != scrollsChrome else { return }
        scrollsChrome = shouldScrollChrome
        // Android keeps the chapter outside NestedScrollView with the toolbar.
        // Only a very short viewport scrolls all chrome, including the chapter.
        if shouldScrollChrome {
            NSLayoutConstraint.deactivate(pinnedChromeConstraints)
            toolbar.removeFromSuperview()
            chapterRow.removeFromSuperview()
            footer.removeFromSuperview()
            formStack.insertArrangedSubview(toolbar, at: 0)
            formStack.insertArrangedSubview(chapterRow, at: 1)
            formStack.addArrangedSubview(footer)
            NSLayoutConstraint.activate(scrollingChromeConstraints)
        } else {
            NSLayoutConstraint.deactivate(scrollingChromeConstraints)
            for item in [toolbar, chapterRow, footer] {
                formStack.removeArrangedSubview(item)
                item.removeFromSuperview()
                cardView.addSubview(item)
            }
            NSLayoutConstraint.activate(pinnedChromeConstraints)
        }
    }

    private func paddedChapter() -> UIView {
        let row = UIView()
        chapterLabel.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(chapterLabel)
        NSLayoutConstraint.activate([
            chapterLabel.topAnchor.constraint(equalTo: row.topAnchor),
            chapterLabel.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            chapterLabel.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            chapterLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
        ])
        return row
    }

    @objc private func refreshPalette() {
        guard isViewLoaded else { return }
        let palette = ReaderTocPalette(traits: traitCollection)
        // background_card is grey_100 / grey_850, not the TOC background.
        cardView.backgroundColor =
            ReaderPaletteColor.isNightResource(traits: traitCollection)
            ? UIColor(white: 48 / 255, alpha: 1)
            : UIColor(white: 245 / 255, alpha: 1)
        toolbar.backgroundColor = palette.titleBackground
        titleLabel.textColor = palette.toolbarText
        chapterLabel.textColor = palette.primaryText
        errorLabel.textColor = palette.accent
        for field in [bookTextField, noteField] { field.apply(palette: palette) }
        footer.apply(palette: palette)
    }

    private func applyFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        chapterLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        errorLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .footnote, compatibleWith: traitCollection)
        for field in [bookTextField, noteField] {
            field.applyFonts(traits: traitCollection)
        }
        footer.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        updateFieldAppearance()
        updateControls()
        revealCaret(in: textView)
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        updateFieldAppearance()
        updateControls()
    }

    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        updateFieldAppearance()
        updateControls()
        view.layoutIfNeeded()
        revealCaret(in: textView)
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        updateControls()
        guard textView.isFirstResponder else { return }
        revealCaret(in: textView)
    }

    private func updateFieldAppearance() {
        bookTextField.updateHint()
        noteField.updateHint()
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        keyboardFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        updateChromePlacement()
        view.setNeedsLayout()
    }

    @objc private func keyboardFrameDidChange() {
        guard !isClosing else { return }
        view.layoutIfNeeded()
        for field in [bookTextField, noteField] where field.textView.isFirstResponder {
            revealCaret(in: field.textView)
        }
    }

    private func revealCaret(in textView: UITextView) {
        guard let selection = textView.selectedTextRange else { return }
        let caret = textView.caretRect(for: selection.end).insetBy(dx: -4, dy: -12)
        scrollView.scrollRectToVisible(textView.convert(caret, to: scrollView), animated: false)
    }

    @objc private func saveBookmark() {
        guard let generation = prepareOperation() else { return }
        let bookText = bookTextField.textView.text ?? ""
        let note = noteField.textView.text ?? ""
        runOperation(generation: generation) { [onSave] in try await onSave(bookText, note) }
    }

    @objc private func deleteBookmark() {
        guard let onDelete, let generation = prepareOperation() else { return }
        runOperation(generation: generation) { [onDelete] in try await onDelete() }
    }

    private var hasMarkedText: Bool {
        bookTextField.textView.markedTextRange != nil || noteField.textView.markedTextRange != nil
    }

    private var canCancelEditing: Bool {
        !isPerformingOperation && !isClosing && !isCheckingSubmission && !hasMarkedText
            && presentationSession.isCurrent
    }

    private func permitsSubmission() -> Bool {
        guard !isCheckingSubmission, presentationSession.isCurrent else { return false }
        isCheckingSubmission = true
        defer { isCheckingSubmission = false }
        let generation = presentationSession.generation
        let permitted = canSubmit?() ?? true
        return permitted && generation == presentationSession.generation && presentationSession.isCurrent
    }

    private func prepareOperation() -> UUID? {
        guard !isPerformingOperation, !hasCompletedOperation, !isClosing,
            !isCheckingSubmission, !hasMarkedText, presentationSession.isCurrent
        else { return nil }
        // Acquire single-flight before caller code; never end editing while the IME still owns a draft.
        isPerformingOperation = true
        let generation = presentationSession.generation
        guard operationIsCurrent(generation), !hasMarkedText else {
            abandonPreparation()
            return nil
        }
        view.endEditing(true)
        guard operationIsCurrent(generation), !hasMarkedText else {
            abandonPreparation()
            return nil
        }
        updateControls()
        guard operationIsCurrent(generation), !hasMarkedText else {
            abandonPreparation()
            return nil
        }
        errorLabel.text = nil
        errorLabel.isHidden = true
        return generation
    }

    private func abandonPreparation() {
        isPerformingOperation = false
        updateControls()
    }

    private func operationIsCurrent(_ generation: UUID) -> Bool {
        !isClosing && generation == presentationSession.generation && permitsSubmission()
            && generation == presentationSession.generation
    }

    private func runOperation(generation: UUID, _ operation: @escaping () async throws -> Void) {
        // The write owns its snapshot, not this controller's lifetime. Dismissal only revokes UI delivery.
        Task { @MainActor [weak self] in
            do {
                try await operation()
                guard let self else { return }
                self.hasCompletedOperation = true
                let deliver = self.operationIsCurrent(generation)
                self.isPerformingOperation = false
                guard deliver, self.operationIsCurrent(generation) else { return }
                self.dismissEditor(delivering: generation)
            } catch {
                guard let self else { return }
                let deliver = self.operationIsCurrent(generation)
                self.isPerformingOperation = false
                guard deliver else { return }
                self.updateControls()
                guard self.operationIsCurrent(generation) else { return }
                let message =
                    error.userFacingMessage.isEmpty
                    ? NSLocalizedString(
                        "reader.toc.bookmark.operation_failed", value: "操作失败，请重试",
                        comment: "Bookmark persistence failure")
                    : error.userFacingMessage
                self.errorLabel.text = message
                self.errorLabel.isHidden = false
                self.view.layoutIfNeeded()
                self.scrollView.scrollRectToVisible(
                    self.errorLabel.convert(self.errorLabel.bounds, to: self.scrollView), animated: true)
                UIAccessibility.post(notification: .announcement, argument: message)
            }
        }
    }

    private func updateControls() {
        guard isViewLoaded, !isUpdatingControls else { return }
        isUpdatingControls = true
        defer { isUpdatingControls = false }
        let allowed = !isClosing && permitsSubmission()
        if isPerformingOperation, !allowed { presentationSession.revokeDelivery() }
        let enabled = !isPerformingOperation && !isClosing && presentationSession.isCurrent
        outsideControl.isEnabled = enabled && !hasMarkedText
        isModalInPresentation = !enabled
        footer.cancelButton.isEnabled = enabled && !hasMarkedText
        footer.confirmButton.isEnabled = enabled && allowed && !hasCompletedOperation && !hasMarkedText
        footer.deleteButton.isEnabled = footer.confirmButton.isEnabled && onDelete != nil
        for field in [bookTextField, noteField] {
            // Changing these flags can end IME composition, including on background/key-window changes.
            guard field.textView.markedTextRange == nil else { continue }
            let editable = enabled && !hasCompletedOperation
            if field.textView.isEditable != editable { field.textView.isEditable = editable }
            if field.textView.isSelectable != editable { field.textView.isSelectable = editable }
        }
        updateFieldAppearance()
    }

    @objc private func cancelEditing() {
        dismissEditor()
    }

    @discardableResult
    private func dismissEditor(delivering generation: UUID? = nil) -> Bool {
        guard canCancelEditing, generation.map({ operationIsCurrent($0) }) ?? true else { return false }
        view.endEditing(true)
        guard canCancelEditing, generation.map({ operationIsCurrent($0) }) ?? true else { return false }
        isClosing = true
        presentationSession.retire()
        updateControls()
        resignFirstResponder()
        super.dismiss(animated: true)
        return true
    }
}
