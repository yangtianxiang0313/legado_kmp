import UIKit
import shared

final class SourceImportPreviewDraftViewController: UIViewController, UIAdaptivePresentationControllerDelegate,
    UITextViewDelegate
{
    var onSave: ((SourceImportCandidate) -> Void)?

    private let facade: SourceManagementFacade
    private let initialPayload: String
    private let dialog = SourceImportPreviewDialogContainer()
    private let scrollView = SourceImportPreviewScrollView()
    private let contentView = UIView()
    private let toolbar = UIView()
    private let titleLabel = UILabel()
    private let cancelButton = SourceImportPreviewActionButton(type: .system)
    private let saveButton = SourceImportPreviewActionButton(type: .system)
    private let errorLabel = UILabel()
    private let textView = SourceImportDraftCodeView()
    private var parseTask: Task<Void, Never>?
    private var parseID: UUID?
    private var pendingCandidate: SourceImportCandidate?
    private var isParsing = false
    private var isClosing = false
    private var shouldRevealSelection = false
    private var lastViewportSize = CGSize.zero

    init(source: BookSource, facade: SourceManagementFacade) throws {
        self.facade = facade
        initialPayload = try facade.encodeImportSource(source: source)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { parseTask?.cancel() }

    override func loadView() { view = dialog }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "sourceImport.preview.draft.root"
        dialog.edgeInset = 0
        dialog.panel.layer.cornerRadius = 0
        configureContent()
        applyTypography()
        dialog.onAvailabilityChanged = { [weak self] active in
            guard let self else { return }
            for button in [self.cancelButton, self.saveButton] { button.cancelTracking(with: nil) }
            self.textView.setPresentationActive(active && !self.isClosing)
            if active { DispatchQueue.main.async { [weak self] in self?.deliverPreparedDraft() } }
        }
        dialog.onLayout = { [weak self] available in self?.layoutContent(in: available) }
        dialog.outsideControl.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        dialog.setPresentationActive(true)
        presentationController?.delegate = self
        if !isClosing, presentedViewController == nil {
            becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: titleLabel)
        }
        DispatchQueue.main.async { [weak self] in self?.deliverPreparedDraft() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dialog.setPresentationActive(false)
        if SourceImportPreviewDialogContainer.isLeavingPresentation(self) { invalidateParsing() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil { invalidateParsing() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyTypography()
        shouldRevealSelection = textView.isFirstResponder
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTapped))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        let save = UIKeyCommand(input: "s", modifierFlags: .command, action: #selector(saveTapped))
        save.discoverabilityTitle = L10n.Common.save
        return [escape, save]
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        cancelTapped()
        return true
    }

    private var canInteract: Bool {
        !isParsing && !isClosing && dialog.canInteract(with: self)
            && !scrollView.isDragging && !scrollView.isDecelerating
            && !textView.isDragging && !textView.isDecelerating
    }

    private func configureContent() {
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.text = "code edit"
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceImport.preview.draft.title"
        configureAction(cancelButton, symbol: "xmark", title: L10n.Common.cancel, identifier: "cancel")
        configureAction(saveButton, symbol: "square.and.arrow.down", title: L10n.Common.save, identifier: "confirm")
        saveButton.configuration?.image =
            UIImage(named: "EditorAndroidSave")?.withRenderingMode(.alwaysTemplate)
            ?? UIImage(systemName: "square.and.arrow.down")
        for button in [cancelButton, saveButton, dialog.outsideControl] {
            button.canInteract = { [weak self] in self?.canInteract == true }
        }
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        saveButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        for item in [titleLabel, cancelButton, saveButton] { toolbar.addSubview(item) }

        textView.text = initialPayload
        textView.delegate = self
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.textContainer.lineFragmentPadding = 0
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardDismissMode = .interactive
        textView.contentInsetAdjustmentBehavior = .never
        textView.accessibilityLabel = SourceImportPreviewText.draftPayload
        textView.accessibilityIdentifier = "sourceImport.preview.draft.json"
        errorLabel.numberOfLines = 0
        errorLabel.adjustsFontForContentSizeCategory = false
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "sourceImport.preview.draft.error"
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.keyboardDismissMode = .interactive
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        dialog.panel.addSubview(scrollView)
        scrollView.addSubview(contentView)
        for item in [toolbar, errorLabel, textView] { contentView.addSubview(item) }
    }

    private func configureAction(_ button: UIButton, symbol: String, title: String, identifier: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = AndroidReplicaTheme.toolbarText
        button.configuration = configuration
        button.accessibilityLabel = title
        button.accessibilityIdentifier = "sourceImport.preview.draft.\(identifier)"
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
        button.isExclusiveTouch = true
    }

    private func applyTypography() {
        titleLabel.font = SourceImportPreviewAndroidStyle.font(
            20, style: .headline, weight: .medium, compatibleWith: traitCollection)
        textView.refreshAppearance()
        errorLabel.font = SourceImportPreviewAndroidStyle.font(14, style: .subheadline, compatibleWith: traitCollection)
        for button in [cancelButton, saveButton] {
            button.setPreferredSymbolConfiguration(
                UIImage.SymbolConfiguration(pointSize: 22, weight: .regular, scale: .medium), forImageIn: .normal)
        }
        view.setNeedsLayout()
    }

    private func layoutContent(in available: CGRect) {
        guard available.width > 0, available.height > 0 else { return }
        dialog.panel.frame = available
        scrollView.frame = dialog.panel.bounds
        let width = available.width
        let titleWidth = max(1, width - 120)
        let toolbarHeight = max(
            56, ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height) + 24)
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        cancelButton.frame = CGRect(x: rtl ? width - 52 : 4, y: (toolbarHeight - 48) / 2, width: 48, height: 48)
        saveButton.frame = CGRect(x: rtl ? 4 : width - 52, y: (toolbarHeight - 48) / 2, width: 48, height: 48)
        titleLabel.frame = CGRect(x: 60, y: 12, width: titleWidth, height: toolbarHeight - 24)
        var y = toolbarHeight
        if !errorLabel.isHidden {
            let errorWidth = max(1, width - 24)
            let errorHeight = ceil(
                errorLabel.sizeThatFits(CGSize(width: errorWidth, height: .greatestFiniteMagnitude)).height)
            errorLabel.frame = CGRect(x: 12, y: y + 8, width: errorWidth, height: errorHeight)
            y = errorLabel.frame.maxY + 8
        }
        let editorHeight = max(120, available.height - y)
        textView.frame = CGRect(x: 0, y: y, width: width, height: editorHeight)
        let contentHeight = y + editorHeight
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > available.height
        scrollView.contentOffset.y = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - available.height))
        let viewportChanged = lastViewportSize != available.size
        lastViewportSize = available.size
        if textView.isFirstResponder, shouldRevealSelection || viewportChanged,
            let selectedRange = textView.selectedTextRange
        {
            shouldRevealSelection = false
            textView.scrollRangeToVisible(textView.selectedRange)
            let caret = textView.convert(textView.caretRect(for: selectedRange.end), to: contentView)
            scrollView.scrollRectToVisible(caret.insetBy(dx: 0, dy: -12), animated: false)
        }
    }

    @objc private func saveTapped() {
        guard canInteract else { return }
        let payload = textView.text ?? ""
        let requestID = UUID()
        parseID = requestID
        errorLabel.isHidden = true
        isParsing = true
        updateControls()
        parseTask = Task { @MainActor [self] in
            do {
                let preview: SourceImportPreview = try await SharedAsync.value { completion in
                    facade.previewSourceImport(payload: payload, completionHandler: completion)
                }
                guard acceptsParseResult(requestID) else { return }
                guard preview.candidates.count == 1, let candidate = preview.candidates.first,
                    preview.totalCount == 1, preview.invalidCount == 0, preview.duplicateCount == 0
                else {
                    throw NSError(
                        domain: "io.legado.kmp.sourceImport.preview", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: SourceImportPreviewText.singleSourceRequired]
                    )
                }
                parseTask = nil
                parseID = nil
                pendingCandidate = candidate
                deliverPreparedDraft()
            } catch {
                guard acceptsParseResult(requestID) else { return }
                parseTask = nil
                parseID = nil
                isParsing = false
                errorLabel.text = error.userFacingMessage
                errorLabel.isHidden = false
                updateControls()
                scrollView.setContentOffset(.zero, animated: false)
                view.setNeedsLayout()
                if canInteract { UIAccessibility.post(notification: .announcement, argument: errorLabel.text) }
            }
        }
    }

    private func deliverPreparedDraft() {
        guard let candidate = pendingCandidate, !isClosing, dialog.canInteract(with: self) else { return }
        pendingCandidate = nil
        isParsing = false
        isClosing = true
        dialog.setPresentationActive(false)
        updateControls()
        let completion = onSave
        onSave = nil
        view.endEditing(true)
        // Only this candidate returns to the same preview; persistence still requires the outer confirmation.
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { completion?(candidate) }
    }

    private func acceptsParseResult(_ requestID: UUID) -> Bool {
        parseID == requestID && !isClosing && !Task.isCancelled
            && !SourceImportPreviewDialogContainer.isLeavingPresentation(self)
            && presentingViewController != nil && viewIfLoaded?.window != nil
    }

    private func updateControls() {
        let enabled = !isParsing && !isClosing
        isModalInPresentation = true
        textView.isEditable = enabled
        textView.isSelectable = enabled
        textView.isUserInteractionEnabled = enabled
        cancelButton.isEnabled = enabled
        saveButton.isEnabled = enabled
        dialog.outsideControl.isEnabled = enabled
        saveButton.configuration?.showsActivityIndicator = isParsing
        saveButton.accessibilityValue = isParsing ? SourceImportPreviewText.parsing : nil
        view.setNeedsLayout()
    }

    @objc private func cancelTapped() {
        guard canInteract else { return }
        invalidateParsing()
        view.endEditing(true)
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    private func invalidateParsing() {
        isClosing = true
        dialog.setPresentationActive(false)
        parseID = nil
        pendingCandidate = nil
        parseTask?.cancel()
        parseTask = nil
        onSave = nil
        if isViewLoaded { updateControls() }
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        canInteract
    }

    func textViewDidBeginEditing(_ textView: UITextView) {
        shouldRevealSelection = true
        view.setNeedsLayout()
    }

    func textViewDidChange(_ textView: UITextView) {
        guard !isParsing, !isClosing, !self.textView.isApplyingTextAppearance else { return }
        if !errorLabel.isHidden {
            errorLabel.isHidden = true
            view.setNeedsLayout()
        }
        shouldRevealSelection = true
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        self.textView.compositionDidChange()
        guard textView.isFirstResponder, !self.textView.isApplyingTextAppearance else { return }
        shouldRevealSelection = true
        view.setNeedsLayout()
    }
}

/// Reuses the source editor's renderer; newline indentation follows Android CodeView.autoIndent.
private final class SourceImportDraftCodeView: UITextView {
    private static let indentCharacters = Set("{+-*/=".utf16)
    private var syntaxHighlighter: BookSourceEditorSyntaxHighlighter?
    private var mutationDepth = 0

    var isApplyingTextAppearance: Bool { syntaxHighlighter?.isApplyingAttributes == true }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        let inputFont = BookSourceEditorTypography.inputFont(compatibleWith: traitCollection)
        font = inputFont
        syntaxHighlighter = BookSourceEditorSyntaxHighlighter(textView: self, font: inputFont)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func refreshAppearance() {
        syntaxHighlighter?.updateFont(BookSourceEditorTypography.inputFont(compatibleWith: traitCollection))
    }

    func setPresentationActive(_ active: Bool) { syntaxHighlighter?.setPresentationActive(active) }

    func compositionDidChange() {
        if mutationDepth == 0 { syntaxHighlighter?.compositionDidChange() }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        mutationDepth += 1
        defer { finishMutation() }
        super.setMarkedText(markedText, selectedRange: selectedRange)
    }

    override func unmarkText() {
        mutationDepth += 1
        defer { finishMutation() }
        super.unmarkText()
    }

    override func insertText(_ text: String) {
        mutationDepth += 1
        defer { finishMutation() }
        super.insertText(text == "\n" && markedTextRange == nil ? indentedNewline() : text)
    }

    override func deleteBackward() {
        mutationDepth += 1
        defer { finishMutation() }
        super.deleteBackward()
    }

    override func replace(_ range: UITextRange, withText text: String) {
        mutationDepth += 1
        defer { finishMutation() }
        super.replace(range, withText: text)
    }

    private func finishMutation() {
        mutationDepth -= 1
        compositionDidChange()
    }

    private func indentedNewline() -> String {
        let source = textStorage.string as NSString
        let range = selectedRange
        guard range.location != NSNotFound, range.location < source.length,
            range.length <= source.length - range.location
        else { return "\n" }
        var start = range.location - 1
        var hasData = false
        var balance = 0
        while start >= 0 {
            let character = source.character(at: start)
            if character == 10 { break }
            if character != 32 && character != 9 {
                if !hasData {
                    if Self.indentCharacters.contains(character) { balance -= 1 }
                    hasData = true
                }
                if character == 40 { balance -= 1 }
                if character == 41 { balance += 1 }
            }
            start -= 1
        }
        var indentation = ""
        if start >= 0 {
            start += 1
            var end = start
            while end < NSMaxRange(range) {
                let character = source.character(at: end)
                if source.character(at: range.location) != 10, character == 47, end + 1 < NSMaxRange(range) {
                    end += 2
                    break
                }
                if character != 32 && character != 9 { break }
                end += 1
            }
            indentation = source.substring(with: NSRange(location: start, length: end - start))
        }
        return "\n" + indentation + (balance < 0 ? "\t" : "")
    }
}
