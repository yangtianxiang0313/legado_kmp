import UIKit
import shared

@MainActor
final class BookshelfManageSourcePickerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let toolbar = BookshelfManageToolbar()
    private let table = UITableView(frame: .zero, style: .plain)
    private lazy var fastScroller = ReaderListFastScroller(tableView: table)
    private let status = UILabel()
    private let retry = UIButton(type: .system)
    private let statusStack = UIStackView()
    private var subscription: FlowSubscription?
    private var sources: [BookSource] = []
    private var rows: [BookSource] = []
    private var delay: Int32
    private var completion: ((BookSource, Int32) -> Void)?
    private var generation = UUID()
    private var active = false
    private var closing = false
    private var loaded = false
    private var error: String?
    private var pendingSources: [BookSource]?
    private var menu: ReaderOverflowMenuView?

    init(delay: Int32, completion: @escaping (BookSource, Int32) -> Void) {
        self.delay = delay
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        title = "选择书源"
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { subscription?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        toolbar.groupButton.isHidden = true
        toolbar.queryHint = "搜索书源"
        toolbar.searchField.accessibilityLabel = "搜索书源"
        toolbar.searchField.accessibilityIdentifier = "bookshelf.manage.source.search"
        toolbar.backButton.accessibilityIdentifier = "bookshelf.manage.source.back"
        toolbar.moreButton.accessibilityIdentifier = "bookshelf.manage.source.more"
        toolbar.backButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        toolbar.moreButton.addTarget(self, action: #selector(showMore), for: .touchUpInside)
        toolbar.searchField.addTarget(self, action: #selector(filterChanged), for: .editingChanged)
        toolbar.searchField.addTarget(self, action: #selector(submitFilter), for: .editingDidEndOnExit)
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = AndroidReplicaTheme.background
        table.separatorStyle = .none
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 52
        table.contentInsetAdjustmentBehavior = .never
        table.showsVerticalScrollIndicator = false
        table.keyboardDismissMode = .onDrag
        table.accessibilityIdentifier = "bookshelf.manage.source.table"
        table.register(BookshelfManageSourcePickerCell.self, forCellReuseIdentifier: "source")
        status.adjustsFontForContentSizeCategory = false
        status.numberOfLines = 0
        status.textColor = AndroidReplicaTheme.secondaryText
        status.accessibilityIdentifier = "bookshelf.manage.source.status"
        statusStack.axis = .vertical
        statusStack.alignment = .center
        statusStack.spacing = 6
        statusStack.isLayoutMarginsRelativeArrangement = true
        statusStack.directionalLayoutMargins = .init(top: 16, leading: 16, bottom: 16, trailing: 16)
        retry.setTitle(L10n.Common.retry, for: .normal)
        retry.tintColor = AndroidReplicaTheme.accent
        retry.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        statusStack.addArrangedSubview(status)
        statusStack.addArrangedSubview(retry)
        status.widthAnchor.constraint(equalTo: statusStack.layoutMarginsGuide.widthAnchor).isActive = true
        let body = UIStackView(arrangedSubviews: [toolbar, statusStack, table])
        body.axis = .vertical
        body.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(body)
        view.addSubview(fastScroller)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            body.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            fastScroller.topAnchor.constraint(equalTo: table.topAnchor, constant: 8),
            fastScroller.bottomAnchor.constraint(equalTo: table.bottomAnchor, constant: -8),
            fastScroller.trailingAnchor.constraint(equalTo: table.trailingAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: 24),
        ])
        fastScroller.apply(accent: AndroidReplicaTheme.accent)
        fastScroller.onScrubbingChanged = { [weak self] scrubbing in
            guard let self else { return }
            self.table.allowsSelection = !scrubbing && !self.closing
            self.toolbar.setEnabled(!scrubbing && !self.closing)
            if !scrubbing, let pending = self.pendingSources {
                self.pendingSources = nil
                self.accept(pending)
            }
        }
        updateFonts()
        render()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { updateFonts() }
    }

    private func updateFonts() {
        status.font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traitCollection)
        retry.titleLabel?.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        retry.titleLabel?.adjustsFontForContentSizeCategory = false
        view.setNeedsLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        active = true
        start()
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || presentingViewController?.isBeingDismissed == true { invalidate() }
        menu?.dismiss()
    }

    override func accessibilityPerformEscape() -> Bool {
        guard presentedViewController == nil else { return false }
        cancel()
        return true
    }

    private func start() {
        guard subscription == nil, active, !closing else { return }
        let stamp = generation
        error = nil
        do {
            subscription = try SharedRuntime.sourceManagementFacade().get().watchSources { [weak self] sources in
                DispatchQueue.main.async {
                    guard let self, self.active, !self.closing, self.generation == stamp else { return }
                    self.loaded = true
                    self.accept(sources)
                }
            }
        } catch {
            self.error = error.userFacingMessage
            render()
        }
    }

    private func accept(_ sources: [BookSource]) {
        if fastScroller.isScrubbing {
            pendingSources = sources
            return
        }
        self.sources = sources.filter(\.enabled)
        render()
    }

    private func render() {
        guard isViewLoaded else { return }
        rows = SearchScopeSourceFilter.apply(sources, query: toolbar.searchField.text ?? "")
        statusStack.isHidden = error == nil && loaded && !rows.isEmpty
        status.text = error ?? (loaded ? "暂无可用书源" : L10n.Common.loadingTitle)
        retry.isHidden = error == nil
        table.reloadData()
        fastScroller.reload()
    }

    @objc private func filterChanged() { if active, !closing { render() } }
    @objc private func submitFilter() { toolbar.searchField.resignFirstResponder() }
    @objc private func retryLoad() {
        subscription?.cancel()
        subscription = nil
        start()
    }
    @objc private func cancel() {
        guard active, !closing, presentedViewController == nil else { return }
        invalidate()
        dismiss(animated: true)
    }
    private func invalidate() {
        closing = true
        active = false
        generation = UUID()
        subscription?.cancel()
        subscription = nil
        completion = nil
        pendingSources = nil
        fastScroller.cancelScrubbing()
    }

    @objc private func showMore() {
        guard active, !closing, presentedViewController == nil else { return }
        view.endEditing(true)
        let menu = ReaderOverflowMenuView(
            items: [
                .init(identifier: "bookshelf.manage.source.delay", title: "换源间隔") { [weak self] in self?.editDelay() }
            ], anchorView: toolbar.moreButton, interfaceStyle: traitCollection.userInterfaceStyle)
        self.menu = menu
        menu.present(in: view)
    }

    private func editDelay() {
        guard active, !closing, presentedViewController == nil else { return }
        let dialog = AndroidReaderNumberPickerDialogViewController(
            titleText: "换源间隔", value: Int(delay), range: 0...9999,
            valueTitle: { String($0) },
            completion: { [weak self] value in
                guard let self, self.active, !self.closing else { return }
                self.toolbar.setEnabled(false)
                self.table.allowsSelection = false
                Task { @MainActor [weak self] in
                    do {
                        try await SharedRuntime.settingsFacade().get().setBatchChangeSourceDelayAsync(
                            delay: Int32(value))
                        guard let self, self.active, !self.closing else { return }
                        self.delay = Int32(value)
                    } catch { self?.error = error.userFacingMessage }
                    guard let self, self.active, !self.closing else { return }
                    self.toolbar.setEnabled(true)
                    self.table.allowsSelection = true
                    self.render()
                }
            })
        present(dialog, animated: true)
    }

    func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { rows.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let source = rows[indexPath.row]
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "source", for: indexPath) as! BookshelfManageSourcePickerCell
        let group = source.bookSourceGroup ?? ""
        let title =
            group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? source.bookSourceName : "\(source.bookSourceName) (\(group))"
        cell.configure(title: title)
        cell.accessibilityIdentifier = "bookshelf.manage.source.\(source.bookSourceUrl)"
        cell.accessibilityTraits = .button
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard active, !closing, !fastScroller.isScrubbing, presentedViewController == nil,
            rows.indices.contains(indexPath.row)
        else { return }
        let source = rows[indexPath.row]
        let callback = completion
        let delay = delay
        invalidate()
        dismiss(animated: true) { callback?(source, delay) }
    }
}

/// SourcePickerDialog replaces item_1line_text's root padding with 16dp.
final class BookshelfManageSourcePickerCell: UITableViewCell {
    private let nameLabel = ReaderTocSingleLineLabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.adjustsFontForContentSizeCategory = false
        nameLabel.isAccessibilityElement = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)
        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        selectedBackgroundView = UIView()
        isAccessibilityElement = true
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(title: String) {
        nameLabel.text = title
        accessibilityLabel = title
        accessibilityTraits = .button
        updateAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        accessibilityLabel = nil
        accessibilityIdentifier = nil
        accessibilityTraits = .button
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    private func updateAppearance() {
        backgroundColor = AndroidReplicaTheme.background
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        nameLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
        selectedBackgroundView?.backgroundColor =
            ReaderPaletteColor.isNightResource(traits: traitCollection)
            ? UIColor.white.withAlphaComponent(51 / 255) : UIColor.black.withAlphaComponent(31 / 255)
    }
}
