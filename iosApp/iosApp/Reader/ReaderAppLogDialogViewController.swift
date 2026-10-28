import UIKit
import shared

/// AppLogDialog.kt, dialog_recycler_view.xml, item_app_log.xml and app_log.xml
/// at Legado 5f5d31404af9957684703747ecee2b91e7161f1d.
@MainActor
final class ReaderAppLogDialogViewController: UIViewController, UITableViewDataSource {
    private enum Operation {
        case load
        case clear

        var failureTitle: String {
            switch self {
            case .load:
                return NSLocalizedString(
                    "reader.app_log.load_failed", value: "日志加载失败", comment: "App log read error")
            case .clear:
                return NSLocalizedString(
                    "reader.app_log.clear_failed", value: "日志清除失败", comment: "App log write error")
            }
        }
    }

    private struct Failure {
        let operation: Operation
        let message: String
    }

    private let dialogView = UIView()
    private let outsideControl = UIControl()
    private let toolbar = UIView()
    private let titleLabel = ReaderAppLogTextLabel()
    private let clearButton = UIButton(type: .system)
    private let tableView = ReaderAppLogTableView(frame: .zero, style: .plain)
    private var toolbarHeight: NSLayoutConstraint?
    private var palette: ReaderTocPalette { ReaderTocPalette(traits: traitCollection) }

    private var facade: LogFacade?
    private var entries: [AppLogEntry] = []
    private var failure: Failure?
    private var hasLoadedEntries = false
    private var sessionID: UUID?
    private var loadRequestID: UUID?
    private var clearRequestID: UUID?
    private var loadTask: Task<Void, Never>?
    private var clearTask: Task<Void, Never>?
    private var logSubscription: FlowSubscription?
    private var isClosing = false

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        loadTask?.cancel()
        clearTask?.cancel()
        logSubscription?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(
            input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeDialog))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return [command]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Bookshelf.logTitle
        configureViews()
        applyPaletteAndFonts()
        updateControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isClosing = false
        becomeFirstResponder()
        if sessionID == nil {
            sessionID = UUID()
            loadEntries()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyPaletteAndFonts()
        tableView.reloadData()
    }

    override func accessibilityPerformEscape() -> Bool {
        closeDialog()
        return true
    }

    private func configureViews() {
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "reader.appLog.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.addTarget(self, action: #selector(closeDialog), for: .touchUpInside)
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true

        titleLabel.text = L10n.Bookshelf.logTitle
        titleLabel.accessibilityTraits = .header
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // app_log.xml has a text-only action; values-zh/strings.xml calls it "清除".
        clearButton.setTitle(
            NSLocalizedString("reader.app_log.clear", value: "清除", comment: "Legado menu_clear"),
            for: .normal)
        clearButton.titleLabel?.adjustsFontForContentSizeCategory = false
        clearButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        clearButton.accessibilityIdentifier = "reader.appLog.clear"
        clearButton.addTarget(self, action: #selector(clearLogs), for: .touchUpInside)

        tableView.dataSource = self
        tableView.register(ReaderAppLogCell.self, forCellReuseIdentifier: ReaderAppLogCell.reuseIdentifier)
        tableView.register(ReaderAppLogFailureCell.self, forCellReuseIdentifier: ReaderAppLogFailureCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 64
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorStyle = .none
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.showsVerticalScrollIndicator = false
        tableView.alwaysBounceVertical = false
        tableView.allowsSelection = false
        tableView.accessibilityIdentifier = "reader.appLog.list"
        tableView.setContentHuggingPriority(.defaultHigh, for: .vertical)
        tableView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        view.addSubview(outsideControl)
        view.addSubview(dialogView)
        dialogView.addSubview(toolbar)
        dialogView.addSubview(tableView)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(clearButton)
        for item in [outsideControl, dialogView, toolbar, titleLabel, clearButton, tableView] {
            item.translatesAutoresizingMaskIntoConstraints = false
        }

        let safeArea = view.safeAreaLayoutGuide
        let toolbarHeight = toolbar.heightAnchor.constraint(equalToConstant: 56)
        self.toolbarHeight = toolbarHeight
        NSLayoutConstraint.activate([
            outsideControl.topAnchor.constraint(equalTo: view.topAnchor),
            outsideControl.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            outsideControl.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            outsideControl.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dialogView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
            dialogView.centerYAnchor.constraint(equalTo: safeArea.centerYAnchor),
            // The Android window is 90% wide; its background adds horizontal insets.
            // 16pt per edge approximates the observed ~82% visible panel on a phone.
            dialogView.widthAnchor.constraint(equalTo: safeArea.widthAnchor, multiplier: 0.9, constant: -32),
            dialogView.topAnchor.constraint(greaterThanOrEqualTo: safeArea.topAnchor, constant: 16),
            dialogView.bottomAnchor.constraint(lessThanOrEqualTo: safeArea.bottomAnchor, constant: -16),
            toolbar.topAnchor.constraint(equalTo: dialogView.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: dialogView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: dialogView.trailingAnchor),
            toolbarHeight,
            titleLabel.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: clearButton.leadingAnchor, constant: -8),
            clearButton.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            clearButton.topAnchor.constraint(equalTo: toolbar.topAnchor),
            clearButton.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            clearButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
            tableView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: dialogView.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: dialogView.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: dialogView.bottomAnchor),
        ])
    }

    private func applyPaletteAndFonts() {
        let colors = palette
        dialogView.backgroundColor = colors.background
        tableView.backgroundColor = colors.background
        toolbar.backgroundColor = colors.titleBackground
        titleLabel.textColor = colors.toolbarText
        clearButton.setTitleColor(colors.toolbarText, for: .normal)
        clearButton.setTitleColor(colors.toolbarText.withAlphaComponent(0.38), for: .disabled)
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let actionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        clearButton.titleLabel?.font = actionFont
        toolbarHeight?.constant = max(56, max(titleLabel.intrinsicContentSize.height, actionFont.lineHeight) + 16)
    }

    private func canUpdate(session: UUID) -> Bool {
        sessionID == session && !isClosing && !isBeingDismissed
            && presentingViewController?.isBeingDismissed != true && viewIfLoaded?.window != nil
    }

    private func loadEntries() {
        guard let session = sessionID, canUpdate(session: session), loadTask == nil else { return }
        logSubscription?.cancel()
        logSubscription = nil
        hasLoadedEntries = false
        failure = nil
        tableView.reloadData()
        let request = UUID()
        loadRequestID = request
        loadTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.loadRequestID == request {
                    self.loadTask = nil
                    self.loadRequestID = nil
                    self.updateControls()
                }
            }
            do {
                try Task.checkCancellation()
                let facade = try SharedRuntime.logFacade().get()
                let loaded = try await facade.loadEntriesAsync()
                try Task.checkCancellation()
                guard let self, self.canUpdate(session: session), self.loadRequestID == request else { return }
                self.facade = facade
                self.hasLoadedEntries = true
                self.applyEntries(loaded)
                // Subscribe after the snapshot so a late load cannot overwrite live updates.
                // StateFlow immediately emits its current value, including intervening writes.
                self.logSubscription = facade.watchLogs { [weak self] updated in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.canUpdate(session: session) else { return }
                        self.applyEntries(updated)
                    }
                }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                    let self, self.canUpdate(session: session), self.loadRequestID == request
                else { return }
                self.showFailure(.load, error: error)
            }
        }
        updateControls()
    }

    @objc private func clearLogs() {
        guard let session = sessionID, canUpdate(session: session), hasLoadedEntries,
            loadTask == nil, clearTask == nil, let facade
        else { return }
        failure = nil
        tableView.reloadData()
        let request = UUID()
        clearRequestID = request
        clearTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.clearRequestID == request {
                    self.clearTask = nil
                    self.clearRequestID = nil
                    self.updateControls()
                }
            }
            do {
                try Task.checkCancellation()
                try await facade.clearAsync()
                try Task.checkCancellation()
                // watchLogs supplies the committed state. Do not optimistically erase
                // rows or overwrite messages appended concurrently with the clear.
            } catch {
                guard !Task.isCancelled, !(error is CancellationError),
                    let self, self.canUpdate(session: session), self.clearRequestID == request
                else { return }
                self.showFailure(.clear, error: error)
            }
        }
        updateControls()
    }

    private func applyEntries(_ updated: [AppLogEntry]) {
        // AppLogStore appends; Android AppLog inserts at index zero (newest first).
        entries = Array(updated.reversed())
        tableView.reloadData()
    }

    private func showFailure(_ operation: Operation, error: Error) {
        failure = Failure(operation: operation, message: error.userFacingMessage)
        tableView.reloadData()
        tableView.layoutIfNeeded()
        tableView.scrollToRow(at: IndexPath(row: 0, section: 0), at: .top, animated: false)
        UIAccessibility.post(
            notification: .announcement, argument: "\(operation.failureTitle): \(error.userFacingMessage)")
    }

    private func updateControls() {
        clearButton.isEnabled =
            sessionID != nil && !isClosing && hasLoadedEntries
            && loadTask == nil && clearTask == nil
        if let cell = tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? ReaderAppLogFailureCell {
            cell.setRetryEnabled(canRetryFailure)
        }
    }

    private var canRetryFailure: Bool {
        sessionID != nil && !isClosing && loadTask == nil && clearTask == nil
    }

    private func retryFailure() {
        guard let session = sessionID, canUpdate(session: session), let failure else { return }
        switch failure.operation {
        case .load: loadEntries()
        case .clear: clearLogs()
        }
    }

    private func stopSession() {
        isClosing = true
        sessionID = nil
        loadRequestID = nil
        clearRequestID = nil
        loadTask?.cancel()
        clearTask?.cancel()
        logSubscription?.cancel()
        loadTask = nil
        clearTask = nil
        logSubscription = nil
        facade = nil
        hasLoadedEntries = false
        updateControls()
    }

    @objc private func closeDialog() {
        guard !isClosing else { return }
        stopSession()
        view.endEditing(true)
        dismiss(animated: true)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        entries.count + (failure == nil ? 0 : 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.row == 0, let failure {
            let cell =
                tableView.dequeueReusableCell(
                    withIdentifier: ReaderAppLogFailureCell.reuseIdentifier, for: indexPath) as! ReaderAppLogFailureCell
            cell.configure(
                message: "\(failure.operation.failureTitle)\n\(failure.message)",
                palette: palette, isRetryEnabled: canRetryFailure
            ) { [weak self] in self?.retryFailure() }
            return cell
        }
        let entry = entries[indexPath.row - (failure == nil ? 0 : 1)]
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: ReaderAppLogCell.reuseIdentifier, for: indexPath) as! ReaderAppLogCell
        cell.configure(
            time: timeFormatter.string(from: Date(timeIntervalSince1970: Double(entry.timestamp) / 1000)),
            message: entry.message, palette: palette)
        return cell
    }
}

private final class ReaderAppLogTableView: UITableView {
    override var contentSize: CGSize {
        didSet {
            if oldValue.height != contentSize.height { invalidateIntrinsicContentSize() }
        }
    }

    override var intrinsicContentSize: CGSize {
        // XML has no explicit empty minHeight. The 56pt empty body follows the
        // observed Android dialog (112dp overall), not an invented empty message.
        CGSize(width: UIView.noIntrinsicMetric, height: max(56, ceil(contentSize.height)))
    }
}

private final class ReaderAppLogTextLabel: AndroidExploreTextLabel {
    override var intrinsicContentSize: CGSize { roundedSize(super.intrinsicContentSize) }

    override func sizeThatFits(_ size: CGSize) -> CGSize { roundedSize(super.sizeThatFits(size)) }

    private func roundedSize(_ size: CGSize) -> CGSize {
        let scale = max(1, traitCollection.displayScale)
        return CGSize(width: size.width, height: ceil(size.height * scale) / scale)
    }
}

private final class ReaderAppLogMessageView: UITextView {
    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        let scale = max(1, traitCollection.displayScale)
        return CGSize(width: size.width, height: size.height > 0 ? ceil(size.height * scale) / scale : size.height)
    }
}

private final class ReaderAppLogCell: UITableViewCell {
    static let reuseIdentifier = "ReaderAppLogCell"
    private let timeLabel = ReaderAppLogTextLabel()
    private let messageView = ReaderAppLogMessageView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    func configure(time: String, message: String, palette: ReaderTocPalette) {
        backgroundColor = palette.background
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        timeLabel.font = font
        messageView.font = font
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        messageView.textContainerInset = UIEdgeInsets(top: padding.top, left: 0, bottom: padding.bottom, right: 0)
        timeLabel.text = time
        timeLabel.textColor = palette.primaryText
        messageView.text = message
        messageView.textColor = palette.primaryText
        messageView.tintColor = palette.accent
        messageView.linkTextAttributes = [
            .foregroundColor: palette.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        messageView.selectedRange = NSRange(location: 0, length: 0)
    }

    private func configureViews() {
        selectionStyle = .none
        isAccessibilityElement = false
        contentView.directionalLayoutMargins = .zero
        timeLabel.numberOfLines = 0
        timeLabel.adjustsFontForContentSizeCategory = false
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.isScrollEnabled = false
        messageView.dataDetectorTypes = .link
        messageView.backgroundColor = .clear
        messageView.textContainerInset = .zero
        messageView.textContainer.lineFragmentPadding = 0
        messageView.adjustsFontForContentSizeCategory = false
        messageView.setContentCompressionResistancePriority(.required, for: .vertical)
        messageView.accessibilityLabel = L10n.Bookshelf.logTitle
        accessibilityIdentifier = "reader.appLog.entry"

        let stack = UIStackView(arrangedSubviews: [timeLabel, messageView])
        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }
}

/// Only shown for a real facade failure; a successful empty list stays blank.
private final class ReaderAppLogFailureCell: UITableViewCell {
    static let reuseIdentifier = "ReaderAppLogFailureCell"
    private let messageLabel = ReaderAppLogTextLabel()
    private let retryButton = UIButton(type: .system)
    private var onRetry: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    func configure(message: String, palette: ReaderTocPalette, isRetryEnabled: Bool, onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        backgroundColor = palette.background
        messageLabel.text = message
        messageLabel.textColor = palette.primaryText
        retryButton.setTitleColor(palette.accent, for: .normal)
        messageLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        retryButton.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        setRetryEnabled(isRetryEnabled)
    }

    func setRetryEnabled(_ enabled: Bool) {
        retryButton.isEnabled = enabled
    }

    private func configureViews() {
        selectionStyle = .none
        isAccessibilityElement = false
        accessibilityIdentifier = "reader.appLog.error"
        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = false
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = false
        retryButton.contentHorizontalAlignment = .leading
        retryButton.accessibilityIdentifier = "reader.appLog.retry"
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [messageLabel, retryButton])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @objc private func retry() {
        onRetry?()
    }
}
