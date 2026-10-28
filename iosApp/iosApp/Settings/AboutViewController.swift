import shared
import SnapKit
import StoreKit
import UIKit

final class AboutViewController: UIViewController, NavigationCustomToolbarProviding, UITableViewDataSource,
    UITableViewDelegate
{
    private let topBar = NavigationToolbarView()
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let topDividerView = UIView()
    private let tableView = UITableView(frame: .zero, style: .plain)

    private enum AboutSection: Int, CaseIterable {
        case info
        case legal
        case actions
    }

    private enum AboutRow {
        case version
        case build
        case contributors
        case privacyPolicy
        case openSourceLicense
        case disclaimer
        case rateApp
        case shareApp
    }

    private let rowsBySection: [[AboutRow]] = [
        [.version, .build],
        [.contributors, .privacyPolicy, .openSourceLicense, .disclaimer],
        [.rateApp, .shareApp],
    ]

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        title = L10n.Settings.aboutTitle
        configureTopBar()
        configureTableView()
        layoutViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private func configureTopBar() {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        topBar.translatesAutoresizingMaskIntoConstraints = false

        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.accessibilityLabel = L10n.Reader.backAction

        titleLabel.text = L10n.Settings.aboutTitle
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        topDividerView.backgroundColor = AndroidReplicaTheme.divider
        topDividerView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topBar)
        topBar.addSubview(backButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(topDividerView)
    }

    private func configureTableView() {
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(AndroidReplicaAboutCell.self, forCellReuseIdentifier: AndroidReplicaAboutCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
    }

    private func layoutViews() {
        topBar.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide.snp.top)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(56)
        }
        backButton.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.width.height.equalTo(48)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(backButton.snp.trailing)
            make.trailing.lessThanOrEqualToSuperview().inset(16)
            make.centerY.equalToSuperview()
        }
        topDividerView.snp.makeConstraints { make in
            make.leading.trailing.bottom.equalToSuperview()
            make.height.equalTo(1 / UIScreen.main.scale)
        }
        tableView.dataSource = self
        tableView.delegate = self
        tableView.snp.makeConstraints { make in
            make.top.equalTo(topBar.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    func numberOfSections(in _: UITableView) -> Int {
        rowsBySection.count
    }

    func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        rowsBySection[section].count
    }

    func tableView(_: UITableView, heightForRowAt _: IndexPath) -> CGFloat {
        56
    }

    func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 ? 18 : 40
    }

    func tableView(_: UITableView, heightForFooterInSection _: Int) -> CGFloat {
        0.01
    }

    func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let container = UIView()
        container.backgroundColor = AndroidReplicaTheme.background
        guard let title = headerTitle(for: AboutSection(rawValue: section)) else {
            return container
        }
        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = AndroidReplicaTheme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: AndroidReplicaAboutCell.reuseIdentifier, for: indexPath) as! AndroidReplicaAboutCell
        let row = rowsBySection[indexPath.section][indexPath.row]
        let isLastRow = indexPath.row == rowsBySection[indexPath.section].count - 1
        switch row {
        case .version:
            cell.configure(title: L10n.Settings.aboutVersion, detail: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-", showsChevron: false, isLastRow: isLastRow)
        case .build:
            cell.configure(title: L10n.Settings.aboutBuild, detail: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-", showsChevron: false, isLastRow: isLastRow)
        case .privacyPolicy:
            cell.configure(title: L10n.Settings.aboutPrivacyPolicy, detail: nil, showsChevron: true, isLastRow: isLastRow)
        case .openSourceLicense:
            cell.configure(title: L10n.Settings.aboutOpenSourceLicense, detail: nil, showsChevron: true, isLastRow: isLastRow)
        case .contributors:
            cell.configure(title: L10n.Settings.aboutContributors, detail: nil, showsChevron: true, isLastRow: isLastRow)
        case .disclaimer:
            cell.configure(title: L10n.Settings.aboutDisclaimer, detail: nil, showsChevron: true, isLastRow: isLastRow)
        case .rateApp:
            cell.configure(title: L10n.Settings.aboutRateApp, detail: nil, showsChevron: false, isLastRow: isLastRow)
        case .shareApp:
            cell.configure(title: L10n.Settings.aboutShareApp, detail: nil, showsChevron: false, isLastRow: isLastRow)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let row = rowsBySection[indexPath.section][indexPath.row]
        switch row {
        case .version, .build:
            break
        case .contributors:
            if let url = URL(string: "https://github.com/gedoor/legado/graphs/contributors") {
                UIApplication.shared.open(url)
            }
        case .privacyPolicy:
            showTextDetail(title: L10n.Settings.aboutPrivacyPolicy, content: L10n.Settings.aboutPrivacyContent)
        case .openSourceLicense:
            showOpenSourceLicenses()
        case .disclaimer:
            showTextDetail(title: L10n.Settings.aboutDisclaimer, content: L10n.Settings.aboutDisclaimerContent)
        case .rateApp:
            requestAppReview()
        case .shareApp:
            shareApp()
        }
    }

    private func showTextDetail(title: String, content: String) {
        let vc = AndroidReplicaAboutTextViewController(title: title, content: content)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func showOpenSourceLicenses() {
        let licenses = [
            ("Kotlin Multiplatform", "Apache License 2.0"),
            ("Ksoup", "MIT License"),
            ("Kingfisher", "MIT License"),
            ("SnapKit", "MIT License"),
            ("Then", "MIT License"),
            ("Ktor", "Apache License 2.0"),
            ("SQLDelight", "Apache License 2.0"),
            ("Koin", "Apache License 2.0"),
        ]
        let content = licenses.map { "\($0.0)\n\($0.1)" }.joined(separator: "\n\n")
        showTextDetail(title: L10n.Settings.aboutOpenSourceLicense, content: content)
    }

    private func requestAppReview() {
        if #available(iOS 16.0, *) {
            guard let scene = view.window?.windowScene else { return }
            SKStoreReviewController.requestReview(in: scene)
        }
    }

    private func shareApp() {
        let text = L10n.Settings.aboutShareText
        let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        present(activityVC, animated: true)
    }

    @objc private func handleBack() {
        if let navigationController {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    private func headerTitle(for section: AboutSection?) -> String? {
        switch section {
        case .info:
            nil
        case .legal:
            L10n.Settings.aboutTitle
        case .actions:
            L10n.Settings.configTitle
        case nil:
            nil
        }
    }
}

private final class AndroidReplicaAboutCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaAboutCell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))
    private let dividerView = UIView()

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
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectedBackgroundView = {
            let view = UIView()
            view.backgroundColor = AndroidReplicaTheme.activeIndicator
            return view
        }()

        titleLabel.font = .systemFont(ofSize: 16)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.86

        detailLabel.font = .systemFont(ofSize: 14)
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.textAlignment = .right
        detailLabel.numberOfLines = 1
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevronView.tintColor = AndroidReplicaTheme.secondaryText
        dividerView.backgroundColor = AndroidReplicaTheme.divider

        for item in [titleLabel, detailLabel, chevronView, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -12),

            detailLabel.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: chevronView.leadingAnchor, constant: -12),

            chevronView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            chevronView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            chevronView.widthAnchor.constraint(equalToConstant: 9),
            chevronView.heightAnchor.constraint(equalToConstant: 15),

            dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    func configure(title: String, detail: String?, showsChevron: Bool, isLastRow: Bool) {
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        chevronView.isHidden = !showsChevron
        dividerView.isHidden = isLastRow
        selectionStyle = showsChevron || detail == nil ? .default : .none
    }
}

private final class AndroidReplicaAboutTextViewController: UIViewController, NavigationCustomToolbarProviding {
    private let titleText: String
    private let content: String
    private let topBar = NavigationToolbarView()
    private let backButton = UIButton(type: .system)
    private let titleLabel = UILabel()
    private let dividerView = UIView()
    private let textView = UITextView()

    init(title: String, content: String) {
        titleText = title
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        title = titleText
        configureViews()
        layoutViews()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    private func configureViews() {
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        backButton.tintColor = AndroidReplicaTheme.toolbarText
        backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        backButton.accessibilityLabel = L10n.Reader.backAction

        titleLabel.text = titleText
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.lineBreakMode = .byTruncatingTail

        dividerView.backgroundColor = AndroidReplicaTheme.divider

        textView.text = content
        textView.font = .systemFont(ofSize: 16)
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.isEditable = false
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 18, left: 16, bottom: 28, right: 16)

        for item in [topBar, textView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        for item in [backButton, titleLabel, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            topBar.addSubview(item)
        }
    }

    private func layoutViews() {
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),

            backButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 48),
            backButton.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),
            titleLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            dividerView.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            textView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }
}
