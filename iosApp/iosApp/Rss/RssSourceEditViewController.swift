import shared
import UIKit

final class RssSourceEditViewController: UIViewController, NavigationCustomToolbarProviding, UITableViewDataSource,
    UITableViewDelegate
{
    enum Mode {
        case create
        case edit(String) // sourceUrl
    }

    private let mode: Mode
    private let screen: RssSourceManagementScreenAdapter
    private let topBar = NavigationToolbarView()
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let saveButton = UIButton(type: .system)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let loadingView = UIView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let loadingLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    // Editable fields
    private var sourceName = ""
    private var sourceUrl = ""
    private var sourceGroup: String?
    private var sourceIcon = ""
    private var sourceComment: String?
    private var enabled = true
    private var sortUrl: String?
    private var singleUrl = false
    private var articleStyle: Int32 = 0
    private var ruleArticles: String?
    private var ruleNextPage: String?
    private var ruleTitle: String?
    private var rulePubDate: String?
    private var ruleDescription: String?
    private var ruleImage: String?
    private var ruleLink: String?
    private var ruleContent: String?
    private var header: String?
    private var loginUrl: String?
    private var concurrentRate: String?
    private var style: String?
    private var jsLib: String?
    private var enableJs = true
    private var loadWithBaseUrl = true
    private var variableComment: String?
    private var contentWhitelist: String?
    private var contentBlacklist: String?

    private var isDirty = false
    private var originalSource: RssSource?

    private enum Section: Int, CaseIterable {
        case base = 0
        case rules
        case advanced
    }

    private struct Row {
        let title: String
        let keyPath: WritableKeyPath<RssSourceEditViewController, String>?
        let optionalKeyPath: WritableKeyPath<RssSourceEditViewController, String?>?
        let boolKeyPath: WritableKeyPath<RssSourceEditViewController, Bool>?
        let int32KeyPath: WritableKeyPath<RssSourceEditViewController, Int32>?

        init(title: String, keyPath: WritableKeyPath<RssSourceEditViewController, String>) {
            self.title = title
            self.keyPath = keyPath
            optionalKeyPath = nil
            boolKeyPath = nil
            int32KeyPath = nil
        }

        init(title: String, optionalKeyPath: WritableKeyPath<RssSourceEditViewController, String?>) {
            self.title = title
            keyPath = nil
            self.optionalKeyPath = optionalKeyPath
            boolKeyPath = nil
            int32KeyPath = nil
        }

        init(title: String, boolKeyPath: WritableKeyPath<RssSourceEditViewController, Bool>) {
            self.title = title
            keyPath = nil
            optionalKeyPath = nil
            self.boolKeyPath = boolKeyPath
            int32KeyPath = nil
        }

        init(title: String, int32KeyPath: WritableKeyPath<RssSourceEditViewController, Int32>) {
            self.title = title
            keyPath = nil
            optionalKeyPath = nil
            boolKeyPath = nil
            self.int32KeyPath = int32KeyPath
        }
    }

    private let baseRows: [Row] = [
        Row(title: L10n.RSS.sourceEditNameTitle, keyPath: \.sourceName),
        Row(title: L10n.RSS.sourceEditUrlTitle, keyPath: \.sourceUrl),
        Row(title: L10n.RSS.sourceEditGroupTitle, optionalKeyPath: \.sourceGroup),
        Row(title: L10n.RSS.sourceEditIconTitle, keyPath: \.sourceIcon),
        Row(title: L10n.RSS.sourceEditCommentTitle, optionalKeyPath: \.sourceComment),
        Row(title: L10n.RSS.sourceEditEnabledTitle, boolKeyPath: \.enabled),
    ]

    private let ruleRows: [Row] = [
        Row(title: L10n.RSS.sourceEditSortUrlTitle, optionalKeyPath: \.sortUrl),
        Row(title: L10n.RSS.sourceEditSingleUrlTitle, boolKeyPath: \.singleUrl),
        Row(title: L10n.RSS.sourceEditArticleStyleTitle, int32KeyPath: \.articleStyle),
        Row(title: L10n.RSS.sourceEditRuleArticlesTitle, optionalKeyPath: \.ruleArticles),
        Row(title: L10n.RSS.sourceEditRuleNextPageTitle, optionalKeyPath: \.ruleNextPage),
        Row(title: L10n.RSS.sourceEditRuleTitleTitle, optionalKeyPath: \.ruleTitle),
        Row(title: L10n.RSS.sourceEditRulePubDateTitle, optionalKeyPath: \.rulePubDate),
        Row(title: L10n.RSS.sourceEditRuleDescriptionTitle, optionalKeyPath: \.ruleDescription),
        Row(title: L10n.RSS.sourceEditRuleImageTitle, optionalKeyPath: \.ruleImage),
        Row(title: L10n.RSS.sourceEditRuleLinkTitle, optionalKeyPath: \.ruleLink),
        Row(title: L10n.RSS.sourceEditRuleContentTitle, optionalKeyPath: \.ruleContent),
    ]

    private let advancedRows: [Row] = [
        Row(title: L10n.RSS.sourceEditHeaderTitle, optionalKeyPath: \.header),
        Row(title: L10n.RSS.sourceEditLoginUrlTitle, optionalKeyPath: \.loginUrl),
        Row(title: L10n.RSS.sourceEditConcurrentRateTitle, optionalKeyPath: \.concurrentRate),
        Row(title: L10n.RSS.sourceEditStyleTitle, optionalKeyPath: \.style),
        Row(title: L10n.RSS.sourceEditJsLibTitle, optionalKeyPath: \.jsLib),
        Row(title: L10n.RSS.sourceEditEnableJsTitle, boolKeyPath: \.enableJs),
        Row(title: L10n.RSS.sourceEditLoadWithBaseUrlTitle, boolKeyPath: \.loadWithBaseUrl),
        Row(title: L10n.RSS.sourceEditVariableCommentTitle, optionalKeyPath: \.variableComment),
        Row(title: L10n.RSS.sourceEditContentWhitelistTitle, optionalKeyPath: \.contentWhitelist),
        Row(title: L10n.RSS.sourceEditContentBlacklistTitle, optionalKeyPath: \.contentBlacklist),
    ]

    init(sourceUrl: String?, screen: RssSourceManagementScreenAdapter) {
        if let sourceUrl {
            mode = .edit(sourceUrl)
        } else {
            mode = .create
        }
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background

        let titleText: String
        switch mode {
        case .create:
            titleText = L10n.RSS.sourceEditCreateTitle
        case .edit:
            titleText = L10n.RSS.sourceEditEditTitle
        }
        configureViews(title: titleText)

        switch mode {
        case .create:
            setLoading(false)
        case let .edit(sourceUrl):
            loadSource(sourceUrl: sourceUrl)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private func configureViews(title: String) {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.lineBreakMode = .byTruncatingTail

        saveButton.setTitle(L10n.RSS.sourceEditSaveAction, for: .normal)
        saveButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
        saveButton.tintColor = AndroidReplicaTheme.toolbarText
        saveButton.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        saveButton.semanticContentAttribute = .forceLeftToRight
        saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)

        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 60
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 28, right: 0)
        tableView.register(AndroidReplicaRssEditFieldCell.self, forCellReuseIdentifier: AndroidReplicaRssEditFieldCell.reuseIdentifier)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.sourceEditTable
        tableView.keyboardDismissMode = .onDrag

        configureLoadingView()

        for item in [topBar, tableView, loadingView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [backButton, titleLabel, saveButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 48),
            backButton.heightAnchor.constraint(equalToConstant: 48),

            saveButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -10),
            saveButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            saveButton.heightAnchor.constraint(equalToConstant: 40),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 2),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: saveButton.leadingAnchor, constant: -12),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

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
        loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.textAlignment = .center
        loadingLabel.numberOfLines = 0
        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.backgroundColor = AndroidReplicaTheme.menuBackground
        retryButton.layer.cornerRadius = 8

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

    // MARK: - UITableViewDataSource

    func numberOfSections(in _: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section) {
        case .base: return baseRows.count
        case .rules: return ruleRows.count
        case .advanced: return advancedRows.count
        case .none: return 0
        }
    }

    private func titleForSection(_ section: Int) -> String? {
        switch Section(rawValue: section) {
        case .base: return L10n.RSS.sourceEditBaseSection
        case .rules: return L10n.RSS.sourceEditRuleSection
        case .advanced: return L10n.RSS.sourceEditAdvancedSection
        case .none: return nil
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: AndroidReplicaRssEditFieldCell.reuseIdentifier,
            for: indexPath
        ) as! AndroidReplicaRssEditFieldCell
        let row = rowForIndexPath(indexPath)

        if let boolKP = row.boolKeyPath {
            let toggle = UISwitch()
            toggle.isOn = self[keyPath: boolKP]
            toggle.onTintColor = AndroidReplicaTheme.accent
            toggle.tag = indexPath.section * 100 + indexPath.row
            toggle.addTarget(self, action: #selector(boolFieldChanged(_:)), for: .valueChanged)
            cell.configure(title: row.title, value: nil, trailingView: toggle, showChevron: false)
        } else if let int32KP = row.int32KeyPath {
            cell.configure(title: row.title, value: "\(self[keyPath: int32KP])", trailingView: nil, showChevron: true)
        } else {
            let value: String?
            if let kp = row.keyPath {
                value = self[keyPath: kp].isEmpty ? nil : self[keyPath: kp]
            } else if let optKP = row.optionalKeyPath {
                value = self[keyPath: optKP]
            } else {
                value = nil
            }
            cell.configure(title: row.title, value: value, trailingView: nil, showChevron: true)
        }

        return cell
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let title = titleForSection(section) else { return nil }
        return AndroidReplicaRssEditSectionHeader(title: title)
    }

    func tableView(_: UITableView, heightForHeaderInSection _: Int) -> CGFloat {
        44
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rowForIndexPath(indexPath)

        if row.boolKeyPath != nil {
            return // handled by switch
        }

        if let int32KP = row.int32KeyPath {
            presentIntEditor(title: row.title, current: self[keyPath: int32KP]) { [weak self] newValue in
                self?[keyPath: int32KP] = newValue
                self?.isDirty = true
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            }
            return
        }

        if let kp = row.keyPath {
            presentTextEditor(title: row.title, current: self[keyPath: kp]) { [weak self] newValue in
                self?[keyPath: kp] = newValue
                self?.isDirty = true
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            }
        } else if let optKP = row.optionalKeyPath {
            presentTextEditor(title: row.title, current: self[keyPath: optKP] ?? "") { [weak self] newValue in
                self?[keyPath: optKP] = newValue.isEmpty ? nil : newValue
                self?.isDirty = true
                self?.tableView.reloadRows(at: [indexPath], with: .none)
            }
        }
    }

    // MARK: - Actions

    @objc private func handleBack() {
        guard isDirty else {
            navigationController?.popViewController(animated: true)
            return
        }
        let controller = AndroidReplicaOptionSheetViewController(
            titleText: L10n.RSS.sourceEditUnsavedTitle,
            options: [
                .init(title: L10n.RSS.sourceEditDiscardAction, systemImage: "trash", isSelected: false, isDestructive: true) { [weak self] in
                    self?.navigationController?.popViewController(animated: true)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
        present(
            controller.wrappedInReaderBottomSheet(fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: 2)),
            animated: true
        )
    }

    @objc private func handleSave() {
        let source = buildSource()
        guard source.isValid else {
            showTransientMessage(L10n.Errors.sourceUrlEmpty)
            return
        }
        Task { [weak self] in
            do {
                _ = try await self?.screen.saveSource(source: source)
                await MainActor.run {
                    self?.isDirty = false
                    self?.navigationController?.popViewController(animated: true)
                }
            } catch {
                await MainActor.run {
                    self?.presentError(error)
                }
            }
        }
    }

    @objc private func boolFieldChanged(_ sender: UISwitch) {
        let section = sender.tag / 100
        let row = sender.tag % 100
        let indexPath = IndexPath(row: row, section: section)
        let rowDef = rowForIndexPath(indexPath)
        if let boolKP = rowDef.boolKeyPath {
            setBoolProperty(boolKP, value: sender.isOn)
            isDirty = true
        }
    }

    private func setBoolProperty(_ keyPath: WritableKeyPath<RssSourceEditViewController, Bool>, value: Bool) {
        switch keyPath {
        case \.enabled: enabled = value
        case \.singleUrl: singleUrl = value
        case \.enableJs: enableJs = value
        case \.loadWithBaseUrl: loadWithBaseUrl = value
        default: break
        }
    }

    // MARK: - Data

    private func loadSource(sourceUrl: String) {
        setLoading(true, message: L10n.RSS.sourceEditLoading)
        Task { [weak self] in
            do {
                guard let source = try await self?.screen.getSource(sourceUrl: sourceUrl) else {
                    await MainActor.run {
                        self?.showLoadingError(L10n.RSS.sourceEditLoadFailed, retrySourceUrl: sourceUrl)
                    }
                    return
                }
                await MainActor.run {
                    self?.populateFields(from: source)
                    self?.originalSource = source
                    self?.setLoading(false)
                    self?.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self?.showLoadingError(error.userFacingMessage, retrySourceUrl: sourceUrl)
                }
            }
        }
    }

    private func populateFields(from source: RssSource) {
        sourceName = source.sourceName
        sourceUrl = source.sourceUrl
        sourceGroup = source.sourceGroup
        sourceIcon = source.sourceIcon
        sourceComment = source.sourceComment
        enabled = source.enabled
        sortUrl = source.sortUrl
        singleUrl = source.singleUrl
        articleStyle = source.articleStyle
        ruleArticles = source.ruleArticles
        ruleNextPage = source.ruleNextPage
        ruleTitle = source.ruleTitle
        rulePubDate = source.rulePubDate
        ruleDescription = source.ruleDescription
        ruleImage = source.ruleImage
        ruleLink = source.ruleLink
        ruleContent = source.ruleContent
        header = source.header
        loginUrl = source.loginUrl
        concurrentRate = source.concurrentRate
        style = source.style
        jsLib = source.jsLib
        enableJs = source.enableJs
        loadWithBaseUrl = source.loadWithBaseUrl
        variableComment = source.variableComment
        contentWhitelist = source.contentWhitelist
        contentBlacklist = source.contentBlacklist
    }

    private func buildSource() -> RssSource {
        return RssSource(
            sourceUrl: sourceUrl,
            sourceName: sourceName,
            sourceIcon: sourceIcon,
            sourceGroup: sourceGroup,
            sourceComment: sourceComment,
            enabled: enabled,
            variableComment: variableComment,
            jsLib: jsLib,
            enabledCookieJar: originalSource?.enabledCookieJar ?? true,
            concurrentRate: concurrentRate,
            header: header,
            loginUrl: loginUrl,
            loginUi: originalSource?.loginUi,
            loginCheckJs: originalSource?.loginCheckJs,
            coverDecodeJs: originalSource?.coverDecodeJs,
            sortUrl: sortUrl,
            singleUrl: singleUrl,
            articleStyle: articleStyle,
            ruleArticles: ruleArticles,
            ruleNextPage: ruleNextPage,
            ruleTitle: ruleTitle,
            rulePubDate: rulePubDate,
            ruleDescription: ruleDescription,
            ruleImage: ruleImage,
            ruleLink: ruleLink,
            ruleContent: ruleContent,
            contentWhitelist: contentWhitelist,
            contentBlacklist: contentBlacklist,
            shouldOverrideUrlLoading: originalSource?.shouldOverrideUrlLoading,
            style: style,
            enableJs: enableJs,
            loadWithBaseUrl: loadWithBaseUrl,
            injectJs: originalSource?.injectJs,
            lastUpdateTime: originalSource?.lastUpdateTime ?? 0,
            customOrder: originalSource?.customOrder ?? 0
        )
    }

    // MARK: - Helpers

    private func rowForIndexPath(_ indexPath: IndexPath) -> Row {
        switch Section(rawValue: indexPath.section) {
        case .base: return baseRows[indexPath.row]
        case .rules: return ruleRows[indexPath.row]
        case .advanced: return advancedRows[indexPath.row]
        case .none: return baseRows[0]
        }
    }

    private func presentTextEditor(title: String, current: String, onSave: @escaping (String) -> Void) {
        let controller = AndroidReplicaRssFieldEditSheet(titleText: title, value: current, keyboardType: .default) { [weak self] value in
            onSave(value)
            self?.dismiss(animated: true)
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 318), animated: true)
    }

    private func presentIntEditor(title: String, current: Int32, onSave: @escaping (Int32) -> Void) {
        let controller = AndroidReplicaRssFieldEditSheet(titleText: title, value: "\(current)", keyboardType: .numberPad) { [weak self] value in
            onSave(Int32(value) ?? current)
            self?.dismiss(animated: true)
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 318), animated: true)
    }

    private func setLoading(_ loading: Bool, message: String = "") {
        loadingLabel.text = message
        loadingView.isHidden = loading == false
        retryButton.isHidden = true
        loading ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating()
        saveButton.isEnabled = loading == false
        tableView.isHidden = loading
    }

    private func showLoadingError(_ message: String, retrySourceUrl: String) {
        loadingLabel.text = message
        loadingView.isHidden = false
        tableView.isHidden = true
        loadingIndicator.stopAnimating()
        retryButton.isHidden = false
        retryButton.removeTarget(nil, action: nil, for: .touchUpInside)
        retryButton.addAction(UIAction { [weak self] _ in
            self?.loadSource(sourceUrl: retrySourceUrl)
        }, for: .touchUpInside)
    }
}

private final class AndroidReplicaRssEditSectionHeader: UIView {
    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AndroidReplicaTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }
}

private final class AndroidReplicaRssEditFieldCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaRssEditFieldCell"
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let trailingContainer = UIView()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let dividerView = UIView()
    private var embeddedTrailingView: UIView?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .none
        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        valueLabel.font = .systemFont(ofSize: 13)
        valueLabel.textColor = AndroidReplicaTheme.secondaryText
        valueLabel.numberOfLines = 2
        chevronView.tintColor = AndroidReplicaTheme.secondaryText.withAlphaComponent(0.72)
        chevronView.contentMode = .scaleAspectFit
        dividerView.backgroundColor = AndroidReplicaTheme.divider

        for item in [titleLabel, valueLabel, trailingContainer, chevronView, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 58),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            titleLabel.widthAnchor.constraint(equalToConstant: 116),

            valueLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -10),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            trailingContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            trailingContainer.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            chevronView.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 12),
            chevronView.heightAnchor.constraint(equalToConstant: 18),

            dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        embeddedTrailingView?.removeFromSuperview()
        embeddedTrailingView = nil
    }

    func configure(title: String, value: String?, trailingView: UIView?, showChevron: Bool) {
        titleLabel.text = title
        valueLabel.text = value?.nilIfEmpty ?? "未设置"
        valueLabel.textColor = value?.nilIfEmpty == nil ? AndroidReplicaTheme.secondaryText.withAlphaComponent(0.64) : AndroidReplicaTheme.secondaryText
        chevronView.isHidden = showChevron == false
        trailingContainer.isHidden = trailingView == nil
        valueLabel.isHidden = trailingView != nil
        if let trailingView {
            embeddedTrailingView = trailingView
            trailingView.translatesAutoresizingMaskIntoConstraints = false
            trailingContainer.addSubview(trailingView)
            NSLayoutConstraint.activate([
                trailingView.topAnchor.constraint(equalTo: trailingContainer.topAnchor),
                trailingView.bottomAnchor.constraint(equalTo: trailingContainer.bottomAnchor),
                trailingView.leadingAnchor.constraint(equalTo: trailingContainer.leadingAnchor),
                trailingView.trailingAnchor.constraint(equalTo: trailingContainer.trailingAnchor),
            ])
        }
    }
}

private final class AndroidReplicaRssFieldEditSheet: UIViewController, UITextViewDelegate {
    private let titleText: String
    private let initialValue: String
    private let keyboardType: UIKeyboardType
    private let onSave: (String) -> Void
    private let textView = UITextView()

    init(titleText: String, value: String, keyboardType: UIKeyboardType, onSave: @escaping (String) -> Void) {
        self.titleText = titleText
        initialValue = value
        self.keyboardType = keyboardType
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        title = titleText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    private func configureViews() {
        let label = UILabel()
        label.text = titleText
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AndroidReplicaTheme.secondaryText

        textView.text = initialValue
        textView.delegate = self
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.tintColor = AndroidReplicaTheme.accent
        textView.keyboardType = keyboardType
        textView.backgroundColor = AndroidReplicaTheme.menuBackground
        textView.layer.cornerRadius = 8
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)

        let saveButton = UIButton(type: .system)
        saveButton.setTitle(L10n.Common.ok, for: .normal)
        saveButton.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        saveButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        saveButton.backgroundColor = AndroidReplicaTheme.menuBackground
        saveButton.layer.cornerRadius = 8
        saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)

        for item in [label, textView, saveButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),

            textView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 10),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.heightAnchor.constraint(equalToConstant: 132),

            saveButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 14),
            saveButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            saveButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            saveButton.heightAnchor.constraint(equalToConstant: 48),
        ])
    }

    @objc private func handleSave() {
        onSave(textView.text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
