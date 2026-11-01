import UIKit

enum OpenSourceLicensesText {
    private static var chinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }
    private static func choose(_ zh: String, _ en: String) -> String { chinese ? zh : en }

    static var title: String { choose("\u{5F00}\u{6E90}\u{8BB8}\u{53EF}", "Open Source Licenses") }
    static var back: String { choose("\u{8FD4}\u{56DE}", "Back") }
    static var search: String { choose("\u{540D}\u{79F0}\u{6216}\u{8BB8}\u{53EF}\u{8BC1}", "Name or license") }
    static var filter: String { choose("\u{7B5B}\u{9009}", "Filter") }
    static var allFields: String { choose("\u{540D}\u{79F0}\u{4E0E}\u{8BB8}\u{53EF}\u{8BC1}", "Name and license") }
    static var name: String { choose("\u{540D}\u{79F0}", "Name") }
    static var license: String { choose("\u{8BB8}\u{53EF}\u{8BC1}", "License") }
    static var loading: String { choose("\u{6B63}\u{5728}\u{8BFB}\u{53D6}\u{2026}", "Loading...") }
    static var retry: String { choose("\u{91CD}\u{8BD5}", "Retry") }
    static var close: String { choose("\u{5173}\u{95ED}", "Close") }
    static var find: String { choose("\u{67E5}\u{627E}", "Find") }
    static var share: String { choose("\u{5206}\u{4EAB}", "Share") }
    static var source: String { choose("\u{67E5}\u{770B}\u{6E90}\u{7801}", "View source") }
    static var noMatches: String { choose("\u{6CA1}\u{6709}\u{5339}\u{914D}\u{9879}", "No matches") }
    static var catalogFailure: String {
        choose(
            "\u{65E0}\u{6CD5}\u{8BFB}\u{53D6}\u{5B8C}\u{6574}\u{8BB8}\u{53EF}\u{76EE}\u{5F55}",
            "Unable to load the complete license catalog")
    }
    static var documentFailure: String {
        choose(
            "\u{65E0}\u{6CD5}\u{8BFB}\u{53D6}\u{5B8C}\u{6574}\u{8BB8}\u{53EF}\u{53CA} NOTICE \u{6587}\u{672C}",
            "Unable to load the complete license and NOTICE text")
    }
    static var emptyCatalog: String {
        choose(
            "\u{5E94}\u{7528}\u{5305}\u{4E2D}\u{7684}\u{8BB8}\u{53EF}\u{76EE}\u{5F55}\u{4E3A}\u{7A7A}\u{3002}",
            "The bundled license catalog is empty.")
    }
    static var emptyDocument: String {
        choose(
            "\u{7EC4}\u{4EF6}\u{7684}\u{672C}\u{5730}\u{8BB8}\u{53EF}\u{6587}\u{672C}\u{7F3A}\u{5931}\u{6216}\u{4E3A}\u{7A7A}\u{3002}",
            "The component's bundled license documents are missing or empty.")
    }
    static var linkFailure: String {
        choose("\u{65E0}\u{6CD5}\u{6253}\u{5F00}\u{6E90}\u{7801}\u{94FE}\u{63A5}", "Unable to open the source link")
    }

    static func category(_ category: OpenSourceLicenseCategory) -> String {
        switch category {
        case .project: return choose("\u{9879}\u{76EE}", "Project")
        case .library: return choose("\u{4F9D}\u{8D56}", "Libraries")
        case .resource: return choose("\u{8D44}\u{6E90}", "Resources")
        }
    }
}

enum OpenSourceLicensesContentError: LocalizedError {
    case emptyCatalog
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .emptyCatalog: return OpenSourceLicensesText.emptyCatalog
        case .emptyDocument: return OpenSourceLicensesText.emptyDocument
        }
    }
}

@MainActor
enum OpenSourceLicensesUI {
    static func icon(_ symbol: String, label: String, identifier: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 20), forImageIn: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
        return button
    }

    static func close(_ controller: UIViewController) {
        controller.view.endEditing(true)
        if let navigation = controller.navigationController, navigation.viewControllers.first !== controller {
            navigation.popViewController(animated: true)
        } else {
            controller.dismiss(animated: true)
        }
    }
}

final class OpenSourceLicensesToolbar: NavigationToolbarView {
    let backButton = OpenSourceLicensesUI.icon(
        "chevron.backward", label: OpenSourceLicensesText.back, identifier: "licenses.back")
    private let titleLabel = UILabel()
    private let actions: [UIButton]
    private let divider = UIView()

    init(title: String, actions: [UIButton] = []) {
        self.actions = actions
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.accessibilityLabel = title
        titleLabel.accessibilityTraits = .header
        titleLabel.numberOfLines = 1
        titleLabel.textAlignment = .natural
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.clipsToBounds = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: actions)
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isUserInteractionEnabled = false
        for item in [backButton, titleLabel, stack, divider] { addSubview(item) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 2),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: CGFloat(actions.count) * 44),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: stack.leadingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / max(UIScreen.main.scale, 1)),
        ])
        refreshPalette()
        refreshTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshTypography()
        refreshPalette()
    }

    func refreshPalette() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        divider.backgroundColor = AndroidReplicaTheme.divider
        for button in [backButton] + actions { button.tintColor = AndroidReplicaTheme.toolbarText }
    }

    private func refreshTypography() {
        // A navigation title stays within the fixed 56pt chrome; document/list text scales without this cap.
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 20, weight: .semibold), maximumPointSize: 28, compatibleWith: traitCollection)
    }
}

final class OpenSourceLicensesStatusView: UIView {
    let retryButton = UIButton(type: .system)
    private let messageLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "licenses.state"
        let scroll = UIScrollView()
        let container = UIView()
        let stack = UIStackView(arrangedSubviews: [spinner, messageLabel, retryButton])
        scroll.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.accessibilityIdentifier = "licenses.message"
        spinner.hidesWhenStopped = true
        spinner.accessibilityIdentifier = "licenses.loading"
        var configuration = UIButton.Configuration.plain()
        configuration.title = OpenSourceLicensesText.retry
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 8
        configuration.titleLineBreakMode = .byWordWrapping
        retryButton.configuration = configuration
        retryButton.titleLabel?.numberOfLines = 0
        retryButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        retryButton.titleLabel?.adjustsFontForContentSizeCategory = true
        retryButton.accessibilityIdentifier = "licenses.retry"
        let retryHeight = retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        retryHeight.priority = UILayoutPriority(999)
        retryHeight.isActive = true
        addSubview(scroll)
        scroll.addSubview(container)
        container.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: container.widthAnchor, constant: -32)
        preferredWidth.priority = .defaultHigh
        let preferredHeight = container.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        preferredHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            container.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            container.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.heightAnchor),
            preferredHeight,
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 640),
            preferredWidth,
        ])
        refreshPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func showLoading() {
        show(message: OpenSourceLicensesText.loading, retry: false)
        spinner.startAnimating()
    }

    func show(message: String, retry: Bool) {
        isHidden = false
        accessibilityElementsHidden = false
        spinner.stopAnimating()
        messageLabel.text = message
        retryButton.isHidden = !retry
    }

    func hide() {
        spinner.stopAnimating()
        isHidden = true
        accessibilityElementsHidden = true
    }

    func refreshPalette() {
        backgroundColor = AndroidReplicaTheme.background
        messageLabel.textColor = AndroidReplicaTheme.primaryText
        retryButton.tintColor = AndroidReplicaTheme.accent
        spinner.color = AndroidReplicaTheme.secondaryText
    }
}

final class OpenSourceLicensesComponentCell: UITableViewCell {
    static let reuseIdentifier = "OpenSourceLicensesComponentCell"
    private let nameLabel = UILabel()
    private let licenseLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let stack = UIStackView(arrangedSubviews: [nameLabel, licenseLabel])
        stack.axis = .vertical
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .preferredFont(forTextStyle: .body)
        licenseLabel.font = .preferredFont(forTextStyle: .subheadline)
        for label in [nameLabel, licenseLabel] {
            label.numberOfLines = 0
            label.textAlignment = .natural
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontSizeToFitWidth = false
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        accessoryType = .disclosureIndicator
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        selectedBackgroundView = UIView()
        refreshPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        licenseLabel.text = nil
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    func configure(_ component: OpenSourceLicenseComponent) {
        nameLabel.text = component.title
        licenseLabel.text = component.license
        accessibilityIdentifier = "licenses.component." + component.id
        accessibilityLabel = component.title
        accessibilityValue = component.license
        refreshPalette()
    }

    func refreshPalette() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectedBackgroundView?.backgroundColor = AndroidReplicaTheme.activeIndicator
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        licenseLabel.textColor = AndroidReplicaTheme.secondaryText
    }
}

final class OpenSourceLicensesSectionHeader: UITableViewHeaderFooterView {
    static let reuseIdentifier = "OpenSourceLicensesSectionHeader"
    private let label = UILabel()

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        label.font = .preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .natural
        label.lineBreakMode = .byWordWrapping
        label.adjustsFontSizeToFitWidth = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.accessibilityTraits = .header
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            label.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        refreshPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(category: OpenSourceLicenseCategory, count: Int) {
        label.text = OpenSourceLicensesText.category(category) + " (\(count))"
        refreshPalette()
    }

    func refreshPalette() {
        contentView.backgroundColor = AndroidReplicaTheme.background
        label.textColor = AndroidReplicaTheme.secondaryText
    }
}
