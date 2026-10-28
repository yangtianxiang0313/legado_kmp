import UIKit
import shared

/// Uses import-source chrome; confirmation replaces one draft and never imports into the database.
final class BookSourceEditorDraftPickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var canSelect: (() -> Bool)?
    var onSelect: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let preview: SourceEditorImportPreview
    private let dialog = SourceImportPreviewDialogContainer()
    private let toolbar = SourceImportPreviewToolbar(title: SourceImportPreviewText.title)
    private let footer = SourceImportPreviewFooterView(identifier: "sourceEdit.import")
    private let chrome = UIScrollView()
    private let content = UIView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let sizingCell = BookSourceEditorDraftCell(style: .default, reuseIdentifier: nil)
    private let summary = UILabel()
    private let summaryView = UIView()
    private var selectedIndex: Int?
    private var hasFinished = false
    private var isVisible = false
    private weak var sourceWindow: UIWindow?
    private var sourceScene: ObjectIdentifier?
    private var actionRevision = UUID()
    private var highlightedRow: (index: Int, revision: UUID, binding: UUID)?
    private var outsideTouchArmed = false

    init(preview: SourceEditorImportPreview) {
        self.preview = preview
        selectedIndex = preview.candidates.count == 1 ? 0 : nil
        super.init(nibName: nil, bundle: nil)
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }
    override func loadView() { view = dialog }
    override var canBecomeFirstResponder: Bool { true }
    override var preferredStatusBarStyle: UIStatusBarStyle {
        ReaderPaletteColor.isLight(ReaderTocPalette(traits: traitCollection).titleBackground) ? .darkContent : .lightContent
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "sourceEdit.import.preview"
        for item in [toolbar, table, footer] { content.addSubview(item) }
        chrome.contentInsetAdjustmentBehavior = .never
        chrome.showsHorizontalScrollIndicator = false
        chrome.delegate = self
        chrome.bounces = false
        dialog.panel.addSubview(chrome)
        chrome.addSubview(content)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 68
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.register(BookSourceEditorDraftCell.self, forCellReuseIdentifier: "candidate")
        table.accessibilityIdentifier = "sourceEdit.import.candidates"
        summary.font = SourceImportPreviewStyle.font(13, style: .footnote, compatibleWith: traitCollection)
        summary.adjustsFontForContentSizeCategory = true
        summary.numberOfLines = 0
        summary.text = SourceImportPreviewText.ignoredCounts(duplicates: 0, invalid: Int(preview.invalidCount))
        summaryView.addSubview(summary)
        footer.cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        footer.confirmButton.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        footer.cancelButton.canInteract = { [weak self] in self?.canCancel == true }
        footer.confirmButton.canInteract = { [weak self] in self?.canUse == true }
        dialog.outsideControl.addTarget(self, action: #selector(beginOutsideTouch), for: .touchDown)
        dialog.outsideControl.addTarget(self, action: #selector(cancelOutsideTouch), for: [.touchCancel, .touchUpOutside])
        dialog.outsideControl.addTarget(self, action: #selector(finishOutsideTouch), for: .touchUpInside)
        dialog.onLayout = { [weak self] available in self?.layoutContent(in: available) }
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
            .androidReplicaThemeDidChange,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(presentationChanged(_:)), name: name, object: nil)
        }
        applyPalette()
        updateSelection()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        if sourceScene == nil, let window = view.window, let scene = window.windowScene {
            sourceWindow = window
            sourceScene = ObjectIdentifier(scene)
        }
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        cancelPendingTracking()
    }

    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canCancel else { return false }
        cancel()
        return true
    }

    private var canCancel: Bool {
        guard isVisible, !hasFinished, !isBeingPresented,
            !SourceImportPreviewDialogContainer.isLeavingPresentation(self), presentedViewController == nil,
            navigationController?.topViewController === self, navigationController?.presentedViewController == nil,
            UIApplication.shared.applicationState == .active,
            let window = viewIfLoaded?.window, window === sourceWindow, window.isKeyWindow,
            !window.isHidden, window.alpha > 0, let scene = window.windowScene,
            ObjectIdentifier(scene) == sourceScene, scene.activationState == .foregroundActive
        else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 || !current.isUserInteractionEnabled { return false }
            ancestor = current.superview
        }
        return true
    }

    private var canUse: Bool {
        canCancel && canSelect?() == true && !table.isDragging && !table.isDecelerating
            && !chrome.isDragging && !chrome.isDecelerating
    }

    private func layoutContent(in available: CGRect) {
        let frame = available.insetBy(dx: min(16, max(0, (available.width - 1) / 2)), dy: 0)
        guard frame.width > 0, frame.height > 0 else { return }
        let width = frame.width
        let toolbarHeight = toolbar.sizeThatFits(CGSize(width: width, height: 0)).height
        let footerHeight = footer.sizeThatFits(CGSize(width: width, height: 0)).height
        let summaryHeight =
            preview.invalidCount > 0
            ? ceil(
                summary.sizeThatFits(
                    CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)
                ).height) + 16 : 0
        var listHeight = summaryHeight
        for candidate in preview.candidates {
            sizingCell.configure(source: candidate.source, selected: false)
            listHeight += sizingCell.height(fitting: width)
            if listHeight > frame.height { break }
        }
        let viewport = max(min(68, listHeight), min(listHeight, frame.height - toolbarHeight - footerHeight))
        let height = min(frame.height, toolbarHeight + footerHeight + viewport)
        dialog.panel.frame = CGRect(x: frame.minX, y: frame.midY - height / 2, width: width, height: height)
        chrome.frame = dialog.panel.bounds
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        table.frame = CGRect(x: 0, y: toolbarHeight, width: width, height: viewport)
        footer.frame = CGRect(x: 0, y: table.frame.maxY, width: width, height: footerHeight)
        content.frame = CGRect(x: 0, y: 0, width: width, height: footer.frame.maxY)
        chrome.contentSize = content.bounds.size
        chrome.isScrollEnabled = content.bounds.height > height
        if summaryHeight > 0 {
            summary.frame = CGRect(x: 12, y: 8, width: max(1, width - 24), height: summaryHeight - 16)
            summaryView.frame = CGRect(x: 0, y: 0, width: width, height: summaryHeight)
            if table.tableHeaderView !== summaryView { table.tableHeaderView = summaryView }
        }
    }

    private func updateSelection() {
        footer.confirmButton.isEnabled = selectedIndex != nil && !hasFinished
        for case let cell as BookSourceEditorDraftCell in table.visibleCells {
            if let index = table.indexPath(for: cell)?.row { cell.updateSelection(index == selectedIndex) }
        }
    }

    private func bindActions(_ cell: BookSourceEditorDraftCell, index: Int) {
        let revision = actionRevision
        let binding = cell.bindingID
        let url = preview.candidates[index].source.bookSourceUrl
        cell.canInteract = { [weak self, weak cell] in
            guard let self, let cell, self.canUse, self.actionRevision == revision,
                cell.bindingID == binding, self.table.indexPath(for: cell)?.row == index,
                self.preview.candidates[index].source.bookSourceUrl == url,
                cell.window === self.sourceWindow, cell.frame.intersects(self.table.bounds)
            else { return false }
            return true
        }
        cell.onSelect = { [weak self, weak cell] in
            guard let self, cell?.canInteract?() == true else { return }
            self.selectedIndex = index
            self.updateSelection()
        }
    }

    private func cancelPendingTracking() {
        actionRevision = UUID()
        highlightedRow = nil
        outsideTouchArmed = false
        dialog.outsideControl.cancelTracking(with: nil)
        for button in [footer.cancelButton, footer.confirmButton] { button.cancelTracking(with: nil) }
        for case let cell as BookSourceEditorDraftCell in table.visibleCells {
            cell.cancelPendingTracking()
            if let index = table.indexPath(for: cell)?.row { bindActions(cell, index: index) }
        }
    }

    @objc private func presentationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, ObjectIdentifier(scene) != sourceScene { return }
        if let window = notification.object as? UIWindow, window !== sourceWindow { return }
        cancelPendingTracking()
        applyPalette()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        cancelPendingTracking()
        summary.font = SourceImportPreviewStyle.font(13, style: .footnote, compatibleWith: traitCollection)
        table.reloadData()
        applyPalette()
    }

    private func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        dialog.panel.backgroundColor = palette.background
        table.backgroundColor = palette.background
        summary.textColor = palette.secondaryText
        toolbar.applyPalette()
        footer.applyPalette()
        for case let cell as BookSourceEditorDraftCell in table.visibleCells { cell.applyPalette() }
        setNeedsStatusBarAppearanceUpdate()
        navigationController?.setNeedsStatusBarAppearanceUpdate()
        view.setNeedsLayout()
    }

    @objc private func confirm() {
        guard canUse, let selectedIndex else { return }
        hasFinished = true
        cancelPendingTracking()
        onSelect?(preview.candidates[selectedIndex].payload)
    }

    @objc private func cancel() {
        guard canCancel else { return }
        hasFinished = true
        cancelPendingTracking()
        onCancel?()
    }

    @objc private func beginOutsideTouch() { outsideTouchArmed = canCancel }

    @objc private func cancelOutsideTouch() { outsideTouchArmed = false }

    @objc private func finishOutsideTouch() {
        let armed = outsideTouchArmed
        outsideTouchArmed = false
        guard armed else { return }
        cancel()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { preview.candidates.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let cell = tableView.dequeueReusableCell(withIdentifier: "candidate", for: indexPath) as? BookSourceEditorDraftCell
        else { return UITableViewCell() }
        cell.configure(source: preview.candidates[indexPath.row].source, selected: indexPath.row == selectedIndex)
        bindActions(cell, index: indexPath.row)
        return cell
    }

    func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard canUse, let cell = tableView.cellForRow(at: indexPath) as? BookSourceEditorDraftCell else { return false }
        highlightedRow = (indexPath.row, actionRevision, cell.bindingID)
        return true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        defer { highlightedRow = nil }
        guard canUse, let row = highlightedRow, row.index == indexPath.row, row.revision == actionRevision,
            let cell = tableView.cellForRow(at: indexPath) as? BookSourceEditorDraftCell,
            cell.bindingID == row.binding, cell.canInteract?() == true
        else { return }
        selectedIndex = indexPath.row
        updateSelection()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { cancelPendingTracking() }
}

private final class BookSourceEditorDraftCell: UITableViewCell {
    var canInteract: (() -> Bool)?
    var onSelect: (() -> Void)?
    private(set) var bindingID = UUID()
    private let checkbox = SourceImportPreviewActionButton(type: .custom)
    private let nameLabel = UILabel()
    private let urlLabel = UILabel()
    private let labels = UIStackView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        isAccessibilityElement = false
        labels.axis = .vertical
        labels.spacing = 4
        for label in [nameLabel, urlLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            labels.addArrangedSubview(label)
        }
        checkbox.canInteract = { [weak self] in self?.canInteract?() == true }
        checkbox.addTarget(self, action: #selector(selectSource), for: .touchUpInside)
        for item in [checkbox, labels] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            checkbox.widthAnchor.constraint(equalToConstant: 40),
            checkbox.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            checkbox.heightAnchor.constraint(equalToConstant: 44),
            labels.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor),
            labels.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            labels.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            labels.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            labels.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        accessibilityElements = [checkbox]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelPendingTracking()
        bindingID = UUID()
        canInteract = nil
        onSelect = nil
    }

    func configure(source: BookSource, selected: Bool) {
        cancelPendingTracking()
        bindingID = UUID()
        nameLabel.text = source.bookSourceName
        urlLabel.text = source.bookSourceUrl
        nameLabel.lineBreakMode = .byWordWrapping
        urlLabel.lineBreakMode = .byCharWrapping
        nameLabel.font = SourceImportPreviewStyle.font(16, compatibleWith: traitCollection)
        urlLabel.font = SourceImportPreviewStyle.font(14, style: .subheadline, compatibleWith: traitCollection)
        checkbox.accessibilityLabel = source.bookSourceName + "，" + source.bookSourceUrl
        updateSelection(selected)
    }

    func updateSelection(_ selected: Bool) {
        checkbox.isSelected = selected
        checkbox.setImage(
            UIImage(named: selected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
                .withRenderingMode(.alwaysTemplate), for: .normal)
        checkbox.accessibilityValue = selected ? SourceImportPreviewText.selected : SourceImportPreviewText.unselected
        checkbox.accessibilityTraits = selected ? [.button, .selected] : .button
        applyPalette()
    }

    func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        nameLabel.textColor = palette.primaryText
        urlLabel.textColor = palette.secondaryText
        checkbox.tintColor = checkbox.isSelected ? palette.accent : palette.secondaryText
    }

    func height(fitting width: CGFloat) -> CGFloat {
        ceil(
            contentView.systemLayoutSizeFitting(
                CGSize(width: width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
            ).height)
    }

    func cancelPendingTracking() {
        checkbox.cancelTracking(with: nil)
        isHighlighted = false
    }
    @objc private func selectSource() { if canInteract?() == true { onSelect?() } }
}
