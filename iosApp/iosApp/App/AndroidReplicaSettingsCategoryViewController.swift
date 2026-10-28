import Kingfisher
import UIKit
import shared

final class AndroidReplicaSettingsCategoryViewController: UIViewController, NavigationCustomToolbarProviding,
    UITableViewDataSource, UITableViewDelegate
{
    private let category: Category
    private let screen = SettingsScreenAdapter()
    private lazy var themeCoordinator = ThemeSettingsCoordinator(
        owner: self, screen: screen,
        generation: { [weak self] in self?.bootstrapGeneration ?? 0 },
        isSessionCurrent: { [weak self] in self?.settingsSessionIsCurrent($0) == true },
        onChange: { [weak self] in self?.requestContentRefresh() },
        onBusy: { [weak self] busy in
            self?.isSettingTaskRunning = busy
            self?.invalidateRowInteractions()
            self?.updateThemeModeButton()
        })
    private lazy var backupCoordinator = SettingsBackupCoordinator(
        owner: self, screen: screen,
        onError: { [weak self] in self?.presentError($0) },
        onRestored: { [weak self] in self?.requestContentRefresh() }
    )
    private lazy var preferenceDialogs = SettingsPreferenceDialogCoordinator(
        owner: self, screen: screen,
        generation: { [weak self] in self?.bootstrapGeneration ?? 0 },
        isSessionCurrent: { [weak self] in self?.settingsSessionIsCurrent($0) == true },
        canInteract: { [weak self] in self?.allowsRowInteraction == true },
        onBusy: { [weak self] busy in
            self?.isSettingTaskRunning = busy
            self?.invalidateRowInteractions()
            self?.updateThemeModeButton()
        },
        onChange: { [weak self] in self?.requestContentRefresh() })
    private let topBar = NavigationToolbarView()
    private let backButton = UIButton(type: .custom)
    private let titleLabel = AndroidExploreTextLabel()
    private var toolbarHeight: NSLayoutConstraint?
    private let themeModeButton = ThemeSettingsModeButton()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let loadingView = UIView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = AndroidExploreTextLabel()
    private let retryButton = UIButton(type: .system)
    private var preferences: AppUiPreferences?
    private var runtimeConfig: AppRuntimeConfig?
    private var headers: [Int: AndroidReplicaSettingsSectionHeader] = [:]
    private var bindingGeneration: UInt64 = 0
    private var bootstrapGeneration: UInt64 = 0
    private var bootstrapTask: Task<Void, Never>?
    private var defaultsReady = false
    private var interactionActive = false
    private var isSettingTaskRunning = false
    private var pendingToggle: (row: Row, value: Bool)?
    private var contentRefreshPending = false
    private var contentRefreshScheduled = false
    private var selectionGeneration: UInt64?
    private var lastListWidth: CGFloat = 0

    private var rowPresentation: AndroidReplicaSettingsRowPresentation {
        .init(preferences: preferences, runtimeConfig: runtimeConfig)
    }

    init(category: Category) {
        self.category = category
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themePaletteChanged), name: .androidReplicaThemeDidChange, object: nil)
        if category == .other {
            NotificationCenter.default.addObserver(
                self, selector: #selector(localPreferencesChanged), name: UserDefaults.didChangeNotification,
                object: nil)
        }
        bootstrapDependencies()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        interactionActive = true
        requestContentRefresh()
        updateThemeModeButton()
    }

    override func viewWillDisappear(_ animated: Bool) {
        interactionActive = false
        themeModeButton.isEnabled = false
        invalidateRowInteractions(advanceGeneration: true)
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if tableView.bounds.width != lastListWidth {
            refreshTypography()
            lastListWidth = tableView.bounds.width
            invalidateRowInteractions()
            requestContentRefresh()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            requestContentRefresh()
        }
        updateThemeModeButton()
        refreshTypography()
    }

    deinit {
        bootstrapTask?.cancel()
        screen.unbind()
        NotificationCenter.default.removeObserver(self)
    }

    private func configureThemeModeButton() {
        guard category == .theme else { return }
        themeModeButton.translatesAutoresizingMaskIntoConstraints = false
        themeModeButton.onToggle = { [weak self] in
            guard let self, self.allowsRowInteraction else { return }
            self.themeCoordinator.toggleMode()
        }
        themeModeButton.onChoose = { [weak self] in
            guard let self, self.allowsRowInteraction else { return }
            self.themeCoordinator.showModePicker(current: self.preferences?.themeMode)
        }
        topBar.addSubview(themeModeButton)
        NSLayoutConstraint.activate([
            themeModeButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            themeModeButton.topAnchor.constraint(equalTo: topBar.topAnchor),
            themeModeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            themeModeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        updateThemeModeButton()
    }

    private func updateThemeModeButton() {
        guard category == .theme else { return }
        themeModeButton.apply(
            modeText: rowPresentation.themeModeText(preferences?.themeMode), enabled: allowsRowInteraction)
    }

    private func themePreview(for row: Row) -> UIColor? {
        guard case .themeColor(let field, let isNight) = row,
            let palette = try? screen.themePalette(isNight: isNight)
        else { return nil }
        return field.color(in: palette)
    }

    @objc private func themePaletteChanged() {
        for header in headers.values { header.applyPalette() }
        requestContentRefresh()
        updateThemeModeButton()
    }

    @objc private func localPreferencesChanged() {
        DispatchQueue.main.async { [weak self] in self?.requestContentRefresh() }
    }

    private func configureViews() {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        backButton.setImage(ReaderMenuAndroidIcon.back.image(), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.imageView?.contentMode = .center
        backButton.accessibilityLabel = L10n.Reader.backAction
        backButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Reader.backAction))
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        titleLabel.text = category.title
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureThemeModeButton()

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.estimatedSectionHeaderHeight = 50
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInset = .zero
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = UIIdentifiers.Settings.table
        tableView.register(
            AndroidReplicaSettingsRowCell.self, forCellReuseIdentifier: AndroidReplicaSettingsRowCell.reuseIdentifier)

        configureLoadingView()

        for item in [topBar, tableView, loadingView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [backButton, titleLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }

        toolbarHeight = topBar.heightAnchor.constraint(equalToConstant: 56)
        toolbarHeight?.isActive = true
        refreshTypography()
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 56),
            backButton.heightAnchor.constraint(equalToConstant: 56),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: category == .theme ? themeModeButton.leadingAnchor : topBar.trailingAnchor,
                constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),

            tableView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            loadingView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            loadingView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            loadingView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            loadingView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureLoadingView() {
        loadingView.backgroundColor = AndroidReplicaTheme.background
        loadingIndicator.color = AndroidReplicaTheme.secondaryText
        loadingLabel.textColor = AndroidReplicaTheme.secondaryText
        loadingLabel.textAlignment = .center
        loadingLabel.numberOfLines = 0
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        retryButton.backgroundColor = AndroidReplicaTheme.menuBackground
        retryButton.layer.cornerRadius = 8
        retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [loadingIndicator, loadingLabel, retryButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        loadingView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: loadingView.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: loadingView.centerYAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: loadingView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: loadingView.trailingAnchor, constant: -24),
            retryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),
        ])
    }

    private func refreshTypography() {
        let titleHeight = AndroidReplicaSettingsTypography.apply(
            title: titleLabel, status: loadingLabel, retry: retryButton, traits: traitCollection)
        let actionHeight =
            category == .theme
            ? themeModeButton.sizeThatFits(
                CGSize(width: max(48, (viewIfLoaded?.bounds.width ?? 0) - 92), height: CGFloat.greatestFiniteMagnitude)
            ).height : 0
        toolbarHeight?.constant = max(titleHeight, actionHeight)
    }

    private func bootstrapDependencies() {
        bootstrapGeneration &+= 1
        let generation = bootstrapGeneration
        bootstrapTask?.cancel()
        preferences = nil
        runtimeConfig = nil
        defaultsReady = false
        pendingToggle = nil
        invalidateRowInteractions(advanceGeneration: true)
        showLoading(L10n.Settings.loading)
        screen.onPreferencesChange = { [weak self] preferences in
            guard let self, self.bootstrapGeneration == generation else { return }
            self.preferences = preferences
            self.receivedSnapshot()
        }
        screen.onRuntimeConfigChange = { [weak self] runtimeConfig in
            guard let self, self.bootstrapGeneration == generation else { return }
            self.runtimeConfig = runtimeConfig
            self.receivedSnapshot()
        }

        switch screen.bootstrap() {
        case .success:
            bootstrapTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.screen.bootstrapDefaultsIfNeeded()
                    guard !Task.isCancelled, self.bootstrapGeneration == generation else { return }
                    self.defaultsReady = true
                    self.receivedSnapshot()
                } catch {
                    guard !Task.isCancelled, self.bootstrapGeneration == generation else { return }
                    self.showLoadingError(error.userFacingMessage)
                }
            }
        case .failure(let error):
            showLoadingError(error.message)
        }
    }

    private func receivedSnapshot() {
        reconcilePendingToggle()
        if defaultsReady, preferences != nil, runtimeConfig != nil { hideLoading() }
        requestContentRefresh()
        updateThemeModeButton()
    }

    private func showLoading(_ message: String) {
        loadingLabel.text = message
        loadingView.isHidden = false
        tableView.isHidden = true
        retryButton.isHidden = true
        loadingIndicator.startAnimating()
    }

    private func hideLoading() {
        loadingView.isHidden = true
        tableView.isHidden = false
        loadingIndicator.stopAnimating()
    }

    private func showLoadingError(_ message: String) {
        loadingLabel.text = message
        loadingView.isHidden = false
        tableView.isHidden = true
        retryButton.isHidden = false
        loadingIndicator.stopAnimating()
    }

    func numberOfSections(in _: UITableView) -> Int {
        category.sections.count
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        category.sections[section].rows.count
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = category.sections[section].title else { return nil }
        if let header = headers[section] { return header }
        let header = AndroidReplicaSettingsSectionHeader(title: title, allowsDividerAbove: section > 0)
        headers[section] = header
        return header
    }

    func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        category.sections[section].title == nil ? .leastNormalMagnitude : UITableView.automaticDimension
    }

    func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat {
        .leastNormalMagnitude
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: AndroidReplicaSettingsRowCell.reuseIdentifier, for: indexPath)
            as! AndroidReplicaSettingsRowCell
        configure(cell, at: indexPath)
        return cell
    }

    private func configure(_ cell: AndroidReplicaSettingsRowCell, at indexPath: IndexPath) {
        let row = category.sections[indexPath.section].rows[indexPath.row]
        let presentation = rowPresentation
        let value = pendingToggle.flatMap { $0.row == row ? $0.value : nil }
        cell.configure(
            title: presentation.title(for: row),
            detail: value.map(presentation.boolText) ?? presentation.detail(for: row),
            iconName: "", isToggle: presentation.isToggle(row), isOn: value ?? presentation.toggleValue(for: row),
            previewColor: themePreview(for: row))
        let generation = bindingGeneration
        cell.bindingGeneration = generation
        cell.canInteract = { [weak self, weak cell] in
            guard let self, let cell else { return false }
            return self.allowsRowInteraction && self.bindingGeneration == generation
                && self.tableView.indexPath(for: cell) == indexPath
        }
        cell.onToggle = { [weak self, weak cell] target in
            guard let self, let cell, self.allowsRowInteraction,
                self.bindingGeneration == generation, self.tableView.indexPath(for: cell) == indexPath
            else { return }
            self.handleToggle(row: row, value: target)
        }
        cell.onActivate = { [weak self, weak cell] in
            guard let self, let cell, self.allowsRowInteraction,
                self.bindingGeneration == generation, self.tableView.indexPath(for: cell) == indexPath
            else { return }
            self.handle(row: row)
        }
    }

    func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool {
        guard allowsRowInteraction else { return false }
        selectionGeneration = bindingGeneration
        return true
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if selectionGeneration == nil, tableView.cellForRow(at: indexPath)?.isFocused == true {
            selectionGeneration = bindingGeneration
        }
        return allowsRowInteraction && selectionGeneration == bindingGeneration ? indexPath : nil
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard allowsRowInteraction, selectionGeneration == bindingGeneration else { return }
        selectionGeneration = nil
        let row = category.sections[indexPath.section].rows[indexPath.row]
        if rowPresentation.isToggle(row) {
            _ = (tableView.cellForRow(at: indexPath) as? AndroidReplicaSettingsRowCell)?.activateToggle()
        } else {
            handle(row: row)
        }
    }

    func tableView(_: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt _: IndexPath) {
        (cell as? AndroidReplicaSettingsRowCell)?.cancelPendingTracking()
    }

    func scrollViewWillBeginDragging(_: UIScrollView) { invalidateRowInteractions() }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { requestContentRefresh() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { requestContentRefresh() }

    private var allowsRowInteraction: Bool {
        interactionActive && !isSettingTaskRunning && pendingToggle == nil
            && preferences != nil && runtimeConfig != nil && !tableView.isHidden
            && !tableView.isDragging && !tableView.isDecelerating
            && presentedViewController == nil && viewIfLoaded?.window != nil
            && (navigationController == nil || navigationController?.topViewController === self)
            && view.window?.windowScene?.activationState != .background
            && view.window?.windowScene?.activationState != .foregroundInactive
    }

    private func invalidateRowInteractions(advanceGeneration: Bool = false) {
        if advanceGeneration { bindingGeneration &+= 1 }
        selectionGeneration = nil
        for case let cell as AndroidReplicaSettingsRowCell in tableView.visibleCells { cell.cancelPendingTracking() }
    }

    private func requestContentRefresh() {
        contentRefreshPending = true
        guard !contentRefreshScheduled, interactionActive else { return }
        contentRefreshScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.contentRefreshScheduled = false
            self.flushContentRefresh()
        }
    }

    private func flushContentRefresh() {
        guard contentRefreshPending, interactionActive, !isSettingTaskRunning,
            !tableView.isHidden, viewIfLoaded?.window != nil
        else { return }
        guard !tableView.isDragging, !tableView.isDecelerating else { return }
        guard !tableView.isTracking,
            !tableView.visibleCells.contains(where: {
                ($0 as? AndroidReplicaSettingsRowCell)?.isTrackingInteraction == true
            })
        else {
            requestContentRefresh()
            return
        }
        contentRefreshPending = false
        AndroidReplicaSettingsListRefresh.preservingScrollAnchor(in: tableView) {
            invalidateRowInteractions()
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                if let cell = tableView.cellForRow(at: indexPath) as? AndroidReplicaSettingsRowCell {
                    configure(cell, at: indexPath)
                }
            }
        }
    }

    private func handle(row: Row) {
        guard allowsRowInteraction else { return }
        invalidateRowInteractions()
        switch row {
        case .readerAppearance:
            navigationController?.pushViewController(
                AndroidReaderStyleSheetViewController().configuredForDrillDownPresentation(), animated: true)
        case .themePreset:
            themeCoordinator.showPresets()
        case .themeBackground(let night):
            themeCoordinator.showBackground(isNight: night)
        case .coverConfiguration:
            navigationController?.pushViewController(
                CoverConfigurationViewController().configuredForDrillDownPresentation(), animated: true)
        case .appLock:
            navigationController?.pushViewController(
                AppLockSettingsViewController().configuredForDrillDownPresentation(), animated: true)
        case .automaticBackup:
            navigationController?.pushViewController(
                AutomaticBackupSettingsViewController().configuredForDrillDownPresentation(), animated: true)
        case .themeMode:
            themeCoordinator.showModePicker(current: preferences?.themeMode)
        case .themeColor(let field, let isNight):
            themeCoordinator.showColor(field, isNight: isNight)
        case .saveTheme(let isNight):
            themeCoordinator.showSave(isNight: isNight)
        case .bookshelfLayout:
            showBookshelfLayoutPicker()
        case .threadCount:
            showThreadCountPicker()
        case .sourceCheck:
            let generation = bootstrapGeneration
            showSourceCheckConfiguration(
                isCurrent: { [weak self] in self?.settingsSessionIsCurrent(generation) == true },
                onChange: { [weak self] in self?.requestContentRefresh() })
        case .defaultHome:
            showDefaultHomePicker()
        case .clearCache:
            clearCache()
        case .backupPath:
            showTextEditor(
                title: L10n.Settings.backupPathTitle, value: runtimeConfig?.backupPath,
                placeholder: "content://backup/Legado"
            ) { [weak self] value in
                try await self?.screen.setBackupPath(path: value)
            }
        case .backupCapabilities:
            navigationController?.pushViewController(
                BackupCapabilitiesViewController(style: .insetGrouped).configuredForDrillDownPresentation(),
                animated: true)
        case .backupNow:
            backupCoordinator.executeBackup()
        case .restoreNow:
            backupCoordinator.showRestoreFilePicker()
        case .webDavUrl:
            showTextEditor(
                title: L10n.Settings.webDavUrlTitle, value: runtimeConfig?.webDavUrl,
                placeholder: L10n.Settings.webDavUrlPlaceholder
            ) { [weak self] value in
                try await self?.screen.setWebDavUrl(url: value)
            }
        case .webDavAccount:
            showTextEditor(
                title: L10n.Settings.webDavAccountTitle, value: runtimeConfig?.webDavAccount,
                placeholder: L10n.Settings.webDavAccountPlaceholder
            ) { [weak self] value in
                try await self?.screen.setWebDavAccount(account: value)
            }
        case .webDavPassword:
            showTextEditor(
                title: L10n.Settings.webDavPasswordTitle, value: runtimeConfig?.webDavPassword,
                placeholder: L10n.Settings.webDavPasswordPlaceholder, isSecure: true
            ) { [weak self] value in
                try await self?.screen.setWebDavPassword(password: value)
            }
        case .webDavDir:
            showTextEditor(title: L10n.Settings.webDavDirTitle, value: runtimeConfig?.webDavDir, placeholder: "legado")
            { [weak self] value in
                try await self?.screen.setWebDavDir(dir: value ?? "legado")
            }
        case .webDavDeviceName:
            showTextEditor(
                title: L10n.Settings.webDavDeviceNameTitle, value: runtimeConfig?.webDavDeviceName,
                placeholder: UIDevice.current.name
            ) { [weak self] value in
                try await self?.screen.setWebDavDeviceName(name: value)
            }
        case .restoreIgnore:
            showBackupIgnorePicker()
        case .userAgent:
            showTextEditor(
                title: L10n.Settings.userAgentTitle, value: runtimeConfig?.userAgent,
                placeholder: L10n.Settings.userAgentPlaceholder, usesUserAgentLayout: true
            ) { [weak self] value in
                try await self?.screen.setUserAgent(ua: value ?? "")
            }
        default:
            break  // Toggle rows use the control's target Bool, never a second row-level inversion.
        }
        requestContentRefresh()
    }

    private func handleToggle(row: Row, value: Bool) {
        guard allowsRowInteraction, rowPresentation.isToggle(row), value != rowPresentation.toggleValue(for: row) else {
            return
        }
        if row == .showAddToShelfAlert {
            let preferences = ReaderExitPreferences()
            preferences.showsAddToShelfPrompt = value
            requestContentRefresh()
            return
        }
        pendingToggle = (row, value)
        runSettingTask {
            switch row {
            case .precisionSearch: try await self.screen.setPrecisionSearch(enabled: value)
            case .replaceRuleEnabledByDefault: try await self.screen.setReplaceRuleEnabledByDefault(enabled: value)
            case .keepScreenOn: RestoredAppPreferences.setKeepScreenOn(value)
            case .showDiscovery: RestoredAppPreferences.set(value, forKey: "showDiscovery")
            case .showRss: RestoredAppPreferences.set(value, forKey: "showRss")
            case .syncBookProgress: try await self.screen.setSyncBookProgress(enabled: value)
            case .syncBookProgressPlus: try await self.screen.setSyncBookProgressPlus(enabled: value)
            case .onlyLatestBackup: try await self.screen.setOnlyLatestBackup(enabled: value)
            case .autoCheckNewBackup: try await self.screen.setAutoCheckNewBackup(enabled: value)
            case .hideStatusBar: try await self.screen.setHideStatusBar(enabled: value)
            case .hideNavigationBar: try await self.screen.setHideNavigationBar(enabled: value)
            case .textFullJustify: try await self.screen.setTextFullJustify(enabled: value)
            case .textBottomJustify: try await self.screen.setTextBottomJustify(enabled: value)
            case .autoRefreshOnStart: RestoredAppPreferences.set(value, forKey: "autoRefreshOnStart")
            case .defaultToRead: StartupReadingPreferences.isEnabled = value
            case .autoChangeSource: ReaderAutoChangeSourcePreference.setEnabled(value)
            default: break
            }
        }
    }

    private func reconcilePendingToggle() {
        if let pendingToggle, rowPresentation.toggleValue(for: pendingToggle.row) == pendingToggle.value {
            self.pendingToggle = nil
        }
    }

    private func settingsSessionIsCurrent(_ generation: UInt64) -> Bool {
        generation == bootstrapGeneration && viewIfLoaded?.window != nil
            && (navigationController == nil || navigationController?.topViewController === self)
            && !isMovingFromParent && !isBeingDismissed
    }

    private func showBookshelfLayoutPicker() {
        preferenceDialogs.showBookshelfLayout(current: preferences?.bookshelfLayoutMode)
    }

    private func showThreadCountPicker() {
        preferenceDialogs.showThreadCount(current: Int(runtimeConfig?.threadCount ?? 16))
    }

    private func showDefaultHomePicker() {
        preferenceDialogs.showDefaultHome(current: UserDefaults.standard.integer(forKey: "defaultHomePage"))
    }

    private func showBackupIgnorePicker() {
        preferenceDialogs.showBackupIgnore(
            selected: rowPresentation.backupIgnoreKeySet(), options: rowPresentation.backupIgnoreOptions)
    }

    private func showTextEditor(
        title: String,
        value: String?,
        placeholder: String,
        isSecure: Bool = false,
        usesUserAgentLayout: Bool = false,
        save: @escaping (String?) async throws -> Void
    ) {
        preferenceDialogs.showTextEditor(
            title: title, value: value, placeholder: placeholder, isSecure: isSecure,
            usesUserAgentLayout: usesUserAgentLayout, save: save)
    }

    private func clearCache() {
        KingfisherManager.shared.cache.clearMemoryCache()
        KingfisherManager.shared.cache.clearDiskCache { [weak self] in
            URLCache.shared.removeAllCachedResponses()
            DispatchQueue.main.async {
                self?.showTransientMessage(L10n.Settings.clearCacheSuccess)
            }
        }
    }

    private func runSettingTask(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isSettingTaskRunning, settingsSessionIsCurrent(bootstrapGeneration) else { return }
        isSettingTaskRunning = true
        invalidateRowInteractions()
        let generation = bootstrapGeneration
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isSettingTaskRunning = false
                self.reconcilePendingToggle()
                self.requestContentRefresh()
            }
            do {
                guard self.settingsSessionIsCurrent(generation) else {
                    self.pendingToggle = nil
                    return
                }
                try await operation()
            } catch {
                self.pendingToggle = nil
                if self.settingsSessionIsCurrent(generation), !(error is CancellationError) {
                    self.presentError(error)
                }
            }
        }
    }

    @objc private func handleRetry() {
        bootstrapDependencies()
    }

    @objc private func handleBack() {
        invalidateRowInteractions(advanceGeneration: true)
        navigationController?.popViewController(animated: true)
    }
}
