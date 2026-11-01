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
            cell.configure(title: AppPrivacyPolicy.title, detail: nil, showsChevron: true, isLastRow: isLastRow)
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
            showTextDetail(title: AppPrivacyPolicy.title, content: AppPrivacyPolicy.content)
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
        let text = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? L10n.Settings.aboutShareText
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

private enum AppPrivacyPolicy {
    private static var usesChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static var title: String { usesChinese ? "隐私政策" : "Privacy Policy" }

    static var content: String { usesChinese ? chinese : english }

    private static let chinese = """
    更新日期：2026 年 10 月 27 日

    本政策说明本 iOS 阅读应用在本机存储信息，以及在使用网络功能时传输信息的方式。书源、订阅、备份服务器和语音服务的运营方可能是不同的第三方；使用相关服务前，请阅读其隐私政策。

    1. 本机数据与用途

    为提供阅读、搜索、收藏和个性化设置，本应用在设备中保存您导入的书籍、书架、书签、阅读进度和记录、搜索历史、订阅与收藏、书源规则、缓存及应用设置。您配置的服务器地址、登录信息、请求头和 Cookie 也可能保存在本机，用于访问对应服务。书源规则中填写的令牌或账户信息属于该规则的一部分。

    2. 书源、订阅与网页访问

    搜索、获取目录和正文、刷新书架、加载封面、图片或音频、更新订阅，以及从 URL 导入规则时，本应用会访问相关网址。接收方可获得您的 IP 地址、访问时间、请求网址、搜索词，以及该请求携带的请求头、Cookie 或登录信息。使用网页登录或登录表单时，您输入的信息会发送给对应网站。书源和订阅规则可包含脚本，并按规则向指定地址发起请求；请只启用可信规则，并避免在不可信规则中填写凭据。

    3. 备份、同步与导出

    配置并使用 WebDAV 后，备份、远程书籍和阅读进度同步会连接您指定的服务器。备份可能包含书架、书签、阅读记录、搜索历史、规则、设置及服务器配置；进度同步会传输书名、作者、章节和阅读位置等信息。自动备份仅在您配置并启用后运行。导出或系统分享会将所选数据交给您选择的文件位置、应用或接收方。

    备份密码用于保护特定凭据，并不代表整份备份文件、书籍或全部元数据均已加密。若选择在本机记住自动备份密码，应用会将其加密后保存在本机 Keychain 中。请妥善保护导出文件和访问凭据，并核实备份服务的存储位置与保留规则。

    4. 朗读与媒体

    系统朗读使用 iOS 提供的语音合成能力。选择并使用 HTTP 朗读服务时，要朗读的文字、语速及所配置的请求信息会发送到该服务地址，以生成语音。播放网络音频、漫画或其他媒体时，相关资源服务器也会收到网络请求。

    5. 本地网络与权限

    手动开启前台 Web 服务后，持有访问地址和令牌的浏览器可以读取服务提供的书架、章节和设置等信息；开启写入权限后，还可执行服务允许的导入或修改操作。选择局域网访问会使该服务可从同一网络中的设备连接。请只向可信设备分享访问地址，并在使用完毕后关闭服务。文件导入、图片选择和系统分享仅处理您选择交给本应用或接收方的内容。需要系统权限的功能受 iOS 权限设置控制。

    6. 保留、删除与停止传输

    本机信息按相应功能需要保留，直到您删除相关条目、清理数据或移除应用。您可通过书架、书签、阅读记录和规则管理等入口删除相应内容，通过书源菜单清除 Cookie 或通过登录入口清除登录头。自动备份设置提供“清除当前目标密码”，可移除该目标已记住的密码。

    您可停用书源或订阅、关闭自动备份和进度同步、移除服务器配置、切换回系统朗读，以及关闭 Web 服务，来停止对应功能的后续传输。删除本机条目或卸载应用不会自动删除已导出的文件、第三方账户、服务器备份、系统备份或单独保留的 Keychain 凭据；请分别管理和删除。第三方已接收的数据须按其政策和请求渠道处理。

    7. 联系与政策更新

    本应用由随身阅读器开发者提供。如有隐私问题或需要协助处理数据，请发送邮件至 yangtianxiang0313@gmail.com 联系随身阅读器开发者。若您主动发送问题说明、日志或文件，接收方将获得您发送的内容；发送前请移除密码、令牌和无关个人信息。应用功能或信息处理方式发生变化时，本政策会相应更新。
    """

    private static let english = """
    Last updated: October 27, 2026

    This policy describes how this iOS reading app stores information on your device and transmits information when network features are used. Book sources, feeds, backup servers and speech services may have different third-party operators. Review their privacy policies before using those services.

    1. On-device information and purposes

    To support reading, search, bookmarks and preferences, the app stores imported books, your bookshelf, bookmarks, reading progress and history, search history, feeds and favorites, source rules, caches and settings on your device. Server addresses, login information, request headers and cookies you configure may also be stored locally to access the corresponding services. Tokens or account information entered in a source rule form part of that rule.

    2. Sources, feeds and websites

    Searching, retrieving chapters, refreshing books, loading covers, images or audio, updating feeds and importing rules from a URL contact the relevant websites. Recipients can receive your IP address, request time, requested URL, search terms and any request headers, cookies or login information sent with the request. Information entered in a website or source login form is sent to the corresponding site. Source and feed rules can contain scripts and make requests to addresses specified by those rules. Enable only trusted rules and avoid entering credentials in untrusted rules.

    3. Backups, synchronization and exports

    After you configure and use WebDAV, backups, remote books and reading-progress synchronization connect to the server you specify. A backup may include your bookshelf, bookmarks, reading records, search history, rules, settings and server configurations. Progress synchronization transmits information such as book name, author, chapter and reading position. Automatic backup operates after you configure and enable it. Exporting or using system sharing passes the selected information to the file location, app or recipient you choose.

    A backup password protects certain credentials; it does not mean the entire archive, books or all metadata are encrypted. If you choose to remember an automatic-backup password on this device, the app encrypts it and stores it in this device's Keychain. Protect exported files and credentials, and check your backup provider's storage location and retention practices.

    4. Read-aloud and media

    System read-aloud uses the speech synthesis provided by iOS. When you select and use an HTTP speech service, the text to be read, speech rate and configured request information are sent to that service to generate audio. Playing online audio, comics or other media also sends requests to the corresponding resource servers.

    5. Local network and permissions

    When you manually start the foreground web service, a browser with the access address and token can read information exposed by that service, including bookshelves, chapters and settings. Enabling write access also allows supported imports or changes. Selecting local-network access makes the service reachable by devices on the same network. Share the address only with trusted devices and stop the service when finished. File import, image selection and system sharing process the content you choose to provide to the app or recipient. Features that require system permission are controlled through iOS settings.

    6. Retention, deletion and stopping transfers

    Local information is retained as needed for the corresponding features until you delete the relevant items, clear data or remove the app. Use bookshelf, bookmark, reading-history and rule management to delete corresponding items. Source menus can clear cookies, and the login screen can clear login headers. Automatic-backup settings provide an option to clear the password remembered for the current destination.

    To stop future transfers for a feature, disable its source or feed, turn off automatic backup and progress synchronization, remove the server configuration, switch back to system speech, or stop the web service. Deleting local items or uninstalling the app does not automatically delete exported files, third-party accounts, server backups, system backups or separately retained Keychain credentials. Manage and delete these separately. Requests concerning information already received by third parties must follow their policies and contact channels.

    7. Contact and policy updates

    This app is provided by the developer of 随身阅读器. For privacy questions or help with your information, contact the developer of 随身阅读器 at yangtianxiang0313@gmail.com. If you choose to send a description, log or file, the recipient receives its contents. Remove passwords, tokens and unrelated personal information before sending it. This policy will be updated when the app's features or information practices change.
    """
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
