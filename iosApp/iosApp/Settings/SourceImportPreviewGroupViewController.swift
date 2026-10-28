import UIKit
import shared

final class SourceImportPreviewGroupViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource,
    UITableViewDelegate
{
    var onSave: ((String?, Bool) -> Void)?

    private let initialGroupName: String?
    private let initialAppendGroup: Bool
    private let titleText: String
    private let showsAppendGroup: Bool
    private let dialog = SourceImportPreviewDialogContainer()
    private let scrollView = SourceImportPreviewScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let appendLabel = UILabel()
    private let appendSummaryLabel = UILabel()
    private let appendSwitch = ReaderAndroidSwitchControl(frame: .zero)
    private let nameLabel = UILabel()
    private let groupField = UITextField()
    private let underline = UIView()
    private let suggestionsTable = UITableView(frame: .zero, style: .plain)
    private let errorLabel = UILabel()
    private let cancelButton = SourceImportPreviewActionButton(type: .system)
    private let confirmButton = SourceImportPreviewActionButton(type: .system)
    private var groupSubscription: FlowSubscription?
    private var groups: [String] = []
    private var suggestions: [String] = []
    private var suppressesSuggestions = false
    private var shouldRevealField = false
    private var lastViewportSize = CGSize.zero
    private var isClosing = false
    private var highlightedSuggestion: String?

    init(
        groupName: String?, appendGroup: Bool, titleText: String? = nil, showsAppendGroup: Bool = true
    ) {
        initialGroupName = groupName
        initialAppendGroup = appendGroup
        self.titleText = titleText ?? SourceImportPreviewText.groupPrompt
        self.showsAppendGroup = showsAppendGroup
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { groupSubscription?.cancel() }

    override func loadView() { view = dialog }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "sourceImport.preview.group.root"
        configureContent()
        applyTypography()
        dialog.onAvailabilityChanged = { [weak self] _ in self?.cancelPendingTracking() }
        dialog.onLayout = { [weak self] available in self?.layoutContent(in: available) }
        dialog.outsideControl.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        dialog.setPresentationActive(true)
        observeGroupsIfNeeded()
        if presentedViewController == nil {
            if !groupField.becomeFirstResponder() { becomeFirstResponder() }
            UIAccessibility.post(notification: .screenChanged, argument: groupField)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        dialog.setPresentationActive(false)
        if SourceImportPreviewDialogContainer.isLeavingPresentation(self) {
            isClosing = true
            stopObservingGroups()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if presentingViewController == nil || SourceImportPreviewDialogContainer.isLeavingPresentation(self) {
            isClosing = true
            stopObservingGroups()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyTypography()
        suggestionsTable.reloadData()
        shouldRevealField = groupField.isFirstResponder
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        cancelTapped()
        return true
    }

    override var keyCommands: [UIKeyCommand]? {
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancelTapped))
        escape.discoverabilityTitle = L10n.Common.cancel
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    private var canInteract: Bool {
        !isClosing && dialog.canInteract(with: self) && !scrollView.isDragging && !scrollView.isDecelerating
            && !suggestionsTable.isDragging && !suggestionsTable.isDecelerating
    }

    private func configureContent() {
        titleLabel.text = titleText
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "sourceImport.preview.group.title"
        appendLabel.text = SourceImportPreviewText.appendGroup
        appendSummaryLabel.text = Bundle.main.localizedString(
            forKey: "source_import.preview.group_summary", value: "关闭替换分组/开启添加分组", table: nil)
        appendLabel.isAccessibilityElement = false
        appendSummaryLabel.isAccessibilityElement = false
        appendSwitch.setOn(initialAppendGroup, animated: false)
        appendSwitch.onTintColor = AndroidReplicaTheme.accent
        appendSwitch.canInteract = { [weak self] in self?.canInteract == true }
        appendSwitch.addTarget(self, action: #selector(appendChanged), for: .valueChanged)
        appendSwitch.accessibilityLabel = SourceImportPreviewText.appendGroup
        appendSwitch.accessibilityHint = appendSummaryLabel.text
        appendSwitch.accessibilityIdentifier = "sourceImport.preview.group.append"
        for item in [appendLabel, appendSummaryLabel, appendSwitch] { item.isHidden = !showsAppendGroup }

        nameLabel.text = SourceImportPreviewText.groupName
        nameLabel.isAccessibilityElement = false
        groupField.text = initialGroupName
        groupField.borderStyle = .none
        groupField.textColor = AndroidReplicaTheme.primaryText
        groupField.tintColor = AndroidReplicaTheme.accent
        groupField.adjustsFontForContentSizeCategory = false
        groupField.autocorrectionType = .no
        groupField.autocapitalizationType = .none
        groupField.spellCheckingType = .no
        groupField.smartQuotesType = .no
        groupField.smartDashesType = .no
        groupField.smartInsertDeleteType = .no
        groupField.clearButtonMode = .whileEditing
        groupField.returnKeyType = .done
        groupField.delegate = self
        groupField.accessibilityLabel = SourceImportPreviewText.groupName
        groupField.accessibilityIdentifier = "sourceImport.preview.group.name"
        groupField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)
        groupField.addTarget(self, action: #selector(focusChanged), for: [.editingDidBegin, .editingDidEnd])
        let tap = UITapGestureRecognizer(target: self, action: #selector(fieldTapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesEnded = false
        groupField.addGestureRecognizer(tap)
        underline.backgroundColor = AndroidReplicaTheme.secondaryText

        suggestionsTable.backgroundColor = AndroidReplicaTheme.background
        suggestionsTable.separatorColor = AndroidReplicaTheme.divider
        suggestionsTable.separatorInset = .zero
        suggestionsTable.tableFooterView = UIView()
        suggestionsTable.dataSource = self
        suggestionsTable.delegate = self
        suggestionsTable.estimatedRowHeight = 32
        suggestionsTable.keyboardDismissMode = .none
        suggestionsTable.contentInsetAdjustmentBehavior = .never
        suggestionsTable.accessibilityIdentifier = "sourceImport.preview.group.suggestions"
        suggestionsTable.isHidden = true
        errorLabel.isHidden = true
        errorLabel.accessibilityIdentifier = "sourceImport.preview.group.error"

        for label in [titleLabel, appendLabel, appendSummaryLabel, nameLabel, errorLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = false
        }
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        appendLabel.textColor = AndroidReplicaTheme.primaryText
        appendSummaryLabel.textColor = AndroidReplicaTheme.secondaryText
        nameLabel.textColor = AndroidReplicaTheme.secondaryText
        errorLabel.textColor = .systemRed
        cancelButton.setTitle(L10n.Common.cancel, for: .normal)
        confirmButton.setTitle(L10n.Common.ok, for: .normal)
        for button in [cancelButton, confirmButton] {
            button.canInteract = { [weak self] in self?.canInteract == true }
            button.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.isExclusiveTouch = true
        }
        cancelButton.accessibilityIdentifier = "sourceImport.preview.group.cancel"
        confirmButton.accessibilityIdentifier = "sourceImport.preview.group.confirm"
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        confirmButton.addTarget(self, action: #selector(saveTapped), for: .touchUpInside)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.delegate = self
        dialog.outsideControl.canInteract = { [weak self] in self?.canInteract == true }
        dialog.panel.addSubview(scrollView)
        scrollView.addSubview(contentView)
        for item in [
            titleLabel, appendLabel, appendSummaryLabel, appendSwitch, nameLabel, groupField, underline,
            suggestionsTable, errorLabel, cancelButton, confirmButton,
        ] { contentView.addSubview(item) }
    }

    private func applyTypography() {
        titleLabel.font = SourceImportPreviewAndroidStyle.font(
            20, style: .headline, weight: .medium, compatibleWith: traitCollection)
        let bodyFont = SourceImportPreviewAndroidStyle.font(14, style: .subheadline, compatibleWith: traitCollection)
        appendLabel.font = bodyFont
        appendSummaryLabel.font = bodyFont
        nameLabel.font = SourceImportPreviewAndroidStyle.font(12, style: .caption1, compatibleWith: traitCollection)
        groupField.font = SourceImportPreviewAndroidStyle.font(18, compatibleWith: traitCollection)
        errorLabel.font = bodyFont
        suggestionsTable.rowHeight = max(32, ceil(bodyFont.lineHeight) + 12)
        for button in [cancelButton, confirmButton] {
            button.titleLabel?.font = SourceImportPreviewAndroidStyle.font(
                14, style: .subheadline, weight: .medium, compatibleWith: traitCollection)
        }
        view.setNeedsLayout()
    }

    private func observeGroupsIfNeeded() {
        guard groupSubscription == nil else { return }
        switch SharedRuntime.sourceManagementFacade() {
        case .success(let facade):
            // Suggestions are read-only. Saving this dialog only returns the requested import options.
            groupSubscription = facade.watchGroups { [weak self] groups in
                DispatchQueue.main.async {
                    guard let self, !self.isClosing else { return }
                    self.groups = groups
                    self.updateSuggestions()
                }
            }
        case .failure(let error):
            errorLabel.text = error.userFacingMessage
            errorLabel.isHidden = false
            view.setNeedsLayout()
        }
    }

    private func stopObservingGroups() {
        groupSubscription?.cancel()
        groupSubscription = nil
    }

    private func updateSuggestions() {
        cancelPendingTracking()
        let query = groupField.text ?? ""
        if groupField.isFirstResponder && !suppressesSuggestions && groupField.markedTextRange == nil {
            suggestions = query.isEmpty ? groups : groups.filter { $0.localizedStandardContains(query) }
        } else {
            suggestions = []
        }
        suggestionsTable.isHidden = suggestions.isEmpty
        suggestionsTable.reloadData()
        shouldRevealField = groupField.isFirstResponder
        view.setNeedsLayout()
    }

    private func layoutContent(in available: CGRect) {
        guard available.width > 0, available.height > 0 else { return }
        let width = min(560, available.width * 0.95)
        let bodyWidth = max(1, width - 40)
        let titleWidth = max(1, width - 48)
        let titleHeight = titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height
        titleLabel.frame = CGRect(x: 24, y: 20, width: titleWidth, height: ceil(titleHeight))
        var y = titleLabel.frame.maxY + 12
        if showsAppendGroup {
            let switchSize = appendSwitch.sizeThatFits(.zero)
            let labelWidth = max(1, bodyWidth - switchSize.width - 16)
            let labelHeight = ceil(
                appendLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
            let summaryHeight = ceil(
                appendSummaryLabel.sizeThatFits(CGSize(width: labelWidth, height: .greatestFiniteMagnitude)).height)
            let rowHeight = max(switchSize.height, labelHeight + summaryHeight + 4)
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            let textX: CGFloat = rtl ? 20 + switchSize.width + 16 : 20
            appendLabel.frame = CGRect(x: textX, y: y + 6, width: labelWidth, height: labelHeight)
            appendSummaryLabel.frame = CGRect(
                x: textX, y: appendLabel.frame.maxY + 4, width: labelWidth, height: summaryHeight)
            appendSwitch.frame = CGRect(
                x: rtl ? 20 : width - 20 - switchSize.width, y: y + 6 + (rowHeight - switchSize.height) / 2,
                width: switchSize.width, height: switchSize.height)
            y += rowHeight + 18
        }
        let hintHeight = ceil(
            nameLabel.sizeThatFits(CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)).height)
        nameLabel.frame = CGRect(x: 20, y: y + 6, width: bodyWidth, height: hintHeight)
        groupField.frame = CGRect(
            x: 20, y: nameLabel.frame.maxY, width: bodyWidth,
            height: max(44, ceil(groupField.font?.lineHeight ?? 20) + 16))
        underline.frame = CGRect(
            x: 20, y: groupField.frame.maxY - 1, width: bodyWidth, height: groupField.isFirstResponder ? 2 : 1)
        y = groupField.frame.maxY + 8
        if !suggestionsTable.isHidden {
            let height = min(180, CGFloat(suggestions.count) * suggestionsTable.rowHeight)
            suggestionsTable.frame = CGRect(x: 20, y: y, width: bodyWidth, height: height)
            y += height + 8
        }
        if !errorLabel.isHidden {
            let height = ceil(
                errorLabel.sizeThatFits(CGSize(width: bodyWidth, height: .greatestFiniteMagnitude)).height)
            errorLabel.frame = CGRect(x: 20, y: y, width: bodyWidth, height: height)
            y += height + 8
        }
        let contentHeight = layoutActions(width: width, y: y + 4) + 8
        let height = min(available.height, contentHeight)
        dialog.panel.frame = CGRect(
            x: available.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        scrollView.frame = dialog.panel.bounds
        contentView.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scrollView.contentSize = contentView.bounds.size
        scrollView.isScrollEnabled = contentHeight > height
        scrollView.contentOffset.y = min(max(0, scrollView.contentOffset.y), max(0, contentHeight - height))
        let viewportChanged = lastViewportSize != dialog.panel.bounds.size
        lastViewportSize = dialog.panel.bounds.size
        if groupField.isFirstResponder && (shouldRevealField || viewportChanged) {
            shouldRevealField = false
            scrollView.scrollRectToVisible(groupField.frame.insetBy(dx: 0, dy: -8), animated: false)
        }
    }

    private func layoutActions(width: CGFloat, y: CGFloat) -> CGFloat {
        let cancelWidth = max(64, ceil(cancelButton.sizeThatFits(.zero).width) + 24)
        let confirmWidth = max(64, ceil(confirmButton.sizeThatFits(.zero).width) + 24)
        let height = max(48, ceil(cancelButton.titleLabel?.font.lineHeight ?? 17) + 24)
        let available = max(1, width - 16)
        if cancelWidth + confirmWidth <= available {
            let rtl = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
            cancelButton.frame = CGRect(
                x: rtl ? 8 + confirmWidth : width - 8 - confirmWidth - cancelWidth,
                y: y, width: cancelWidth, height: height)
            confirmButton.frame = CGRect(
                x: rtl ? 8 : width - 8 - confirmWidth, y: y, width: confirmWidth, height: height)
            return y + height
        }
        let cancelHeight = max(
            height, ceil(cancelButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height) + 16)
        let confirmHeight = max(
            height, ceil(confirmButton.sizeThatFits(CGSize(width: available, height: .greatestFiniteMagnitude)).height) + 16)
        cancelButton.frame = CGRect(x: 8, y: y, width: available, height: cancelHeight)
        confirmButton.frame = CGRect(x: 8, y: y + cancelHeight, width: available, height: confirmHeight)
        return y + cancelHeight + confirmHeight
    }

    @objc private func nameChanged() {
        suppressesSuggestions = false
        updateSuggestions()
    }

    @objc private func appendChanged() {
        guard canInteract else {
            appendSwitch.cancelPendingTracking()
            return
        }
        appendSwitch.setOn(appendSwitch.isOn, animated: false)
    }

    @objc private func fieldTapped() {
        guard canInteract else { return }
        suppressesSuggestions = false
        updateSuggestions()
    }

    @objc private func focusChanged() {
        underline.backgroundColor =
            groupField.isFirstResponder ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        nameLabel.textColor = underline.backgroundColor
        suppressesSuggestions = false
        updateSuggestions()
    }

    @objc private func cancelTapped() {
        guard canInteract else { return }
        beginClosing()
        view.endEditing(true)
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func saveTapped() {
        guard canInteract else { return }
        let rawGroup = groupField.text ?? ""
        let trimmedGroup = rawGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        // ImportBookSourceDialog keeps the entered title; SourceImportOptions trims only when importing.
        let groupName = trimmedGroup.isEmpty ? nil : (showsAppendGroup ? rawGroup : trimmedGroup)
        let append = showsAppendGroup ? appendSwitch.isOn : initialAppendGroup
        let completion = onSave
        beginClosing()
        view.endEditing(true)
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { completion?(groupName, append) }
    }

    private func beginClosing() {
        isClosing = true
        dialog.setPresentationActive(false)
        stopObservingGroups()
        onSave = nil
        groupField.isEnabled = false
        appendSwitch.isEnabled = false
        suggestionsTable.isUserInteractionEnabled = false
        cancelButton.isEnabled = false
        confirmButton.isEnabled = false
        dialog.outsideControl.isEnabled = false
    }

    func textFieldShouldReturn(_: UITextField) -> Bool {
        saveTapped()
        return false
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { suggestions.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "groupSuggestion") as? SourceImportGroupSuggestionCell
            ?? SourceImportGroupSuggestionCell(style: .default, reuseIdentifier: "groupSuggestion")
        let name = suggestions[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = SourceImportPreviewAndroidStyle.singleLine(name)
        configuration.textProperties.color = AndroidReplicaTheme.primaryText
        configuration.textProperties.font = SourceImportPreviewAndroidStyle.font(
            14, style: .subheadline, compatibleWith: traitCollection)
        configuration.textProperties.adjustsFontForContentSizeCategory = false
        configuration.textProperties.numberOfLines = 1
        configuration.textProperties.lineBreakMode = .byTruncatingTail
        configuration.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 6, trailing: 6)
        cell.contentConfiguration = configuration
        cell.backgroundColor = AndroidReplicaTheme.background
        cell.accessibilityTraits = .button
        cell.accessibilityIdentifier = "sourceImport.preview.group.suggestion.\(indexPath.row)"
        cell.onActivate = { [weak self, weak cell] in
            guard let self, let cell, self.canInteract, self.suggestionsTable.indexPath(for: cell) == indexPath,
                self.suggestions.indices.contains(indexPath.row), self.suggestions[indexPath.row] == name
            else { return false }
            self.selectSuggestion(at: indexPath.row)
            return true
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let highlighted = highlightedSuggestion
        highlightedSuggestion = nil
        tableView.deselectRow(at: indexPath, animated: false)
        guard canInteract, suggestions.indices.contains(indexPath.row), highlighted == suggestions[indexPath.row] else { return }
        selectSuggestion(at: indexPath.row)
    }

    private func selectSuggestion(at index: Int) {
        guard canInteract, suggestions.indices.contains(index) else { return }
        groupField.text = suggestions[index]
        suppressesSuggestions = true
        updateSuggestions()
        UIAccessibility.post(notification: .layoutChanged, argument: groupField)
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard canInteract, suggestions.indices.contains(indexPath.row) else { return false }
        highlightedSuggestion = suggestions[indexPath.row]
        return true
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelPendingTracking() }

    private func cancelPendingTracking() {
        highlightedSuggestion = nil
        for button in [cancelButton, confirmButton, dialog.outsideControl] { button.cancelTracking(with: nil) }
        appendSwitch.cancelPendingTracking()
        if let selected = suggestionsTable.indexPathForSelectedRow { suggestionsTable.deselectRow(at: selected, animated: false) }
    }
}

private final class SourceImportGroupSuggestionCell: UITableViewCell {
    var onActivate: (() -> Bool)?

    override func accessibilityActivate() -> Bool { onActivate?() == true }

    override func prepareForReuse() {
        super.prepareForReuse()
        onActivate = nil
    }
}

// Kept in an existing project source so both dialogs can share keyboard-safe chrome without PBX changes.
final class SourceImportPreviewDialogContainer: UIView {
    let outsideControl = SourceImportPreviewActionButton(type: .custom)
    let panel = UIView()
    var onLayout: ((CGRect) -> Void)?
    var onAvailabilityChanged: ((Bool) -> Void)?
    var edgeInset: CGFloat = 16
    private var keyboardFrame: CGRect?
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.presentationAvailabilityChanged()
    }

    private func presentationAvailabilityChanged() {
        outsideControl.cancelTracking(with: nil)
        onAvailabilityChanged?(presentation.isActive)
    }

    init() {
        super.init(frame: .zero)
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        accessibilityViewIsModal = true
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 2
        panel.clipsToBounds = true
        addSubview(outsideControl)
        addSubview(panel)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillChange(_:)), name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardDidChange), name: UIResponder.keyboardDidChangeFrameNotification,
            object: nil)
        for name in [UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(windowChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentation.refreshHierarchy()
        outsideControl.frame = bounds
        var available = safeAreaLayoutGuide.layoutFrame
        if let keyboardFrame, let window {
            let inWindow = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let intersection = available.intersection(convert(inWindow, from: window))
            if !intersection.isNull, intersection.width > 0, intersection.height > 0 {
                available.size.height = max(1, intersection.minY - available.minY)
            }
        }
        let inset = min(edgeInset, max(0, (available.height - 1) / 2))
        onLayout?(available.insetBy(dx: 0, dy: inset))
    }

    func font(_ size: CGFloat, style: UIFont.TextStyle = .body, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: style).scaledFont(
            for: .systemFont(ofSize: size, weight: weight), compatibleWith: traitCollection)
    }

    func setPresentationActive(_ active: Bool) {
        presentation.refreshHierarchy()
        presentation.setPresentationActive(active)
    }

    func canInteract(with controller: UIViewController) -> Bool {
        guard presentation.isActive, !controller.isBeingPresented,
            !Self.isLeavingPresentation(controller), controller.presentedViewController == nil,
            controller.presentingViewController?.presentedViewController === controller,
            controller.transitionCoordinator == nil, let window, window.isKeyWindow
        else { return false }
        let center = panel.convert(CGPoint(x: panel.bounds.midX, y: panel.bounds.midY), to: window)
        guard let hit = window.hitTest(center, with: nil) else { return false }
        return hit === panel || hit.isDescendant(of: panel)
    }

    @objc private func windowChanged(_ notification: Notification) {
        guard let changedWindow = notification.object as? UIWindow, changedWindow === window else { return }
        outsideControl.cancelTracking(with: nil)
        onAvailabilityChanged?(notification.name == UIWindow.didBecomeKeyNotification && presentation.isActive)
    }

    static func isLeavingPresentation(_ controller: UIViewController) -> Bool {
        var current: UIViewController? = controller
        while let item = current {
            if item.isBeingDismissed || item.isMovingFromParent { return true }
            current = item.parent ?? item.presentingViewController
        }
        return false
    }

    @objc private func keyboardWillChange(_ notification: Notification) {
        guard window != nil else { return }
        keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        setNeedsLayout()
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
        let curve = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 0
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : duration, delay: 0,
            options: [.beginFromCurrentState, UIView.AnimationOptions(rawValue: curve << 16)]
        ) { [weak self] in self?.layoutIfNeeded() }
    }

    @objc private func keyboardDidChange() { setNeedsLayout() }
}
