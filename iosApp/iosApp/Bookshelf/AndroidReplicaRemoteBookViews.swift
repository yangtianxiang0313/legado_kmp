import shared
import UIKit

final class AndroidReplicaRemoteBookCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaRemoteBookCell"

    var onMore: (() -> Void)?

    private let iconContainerView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let accessoryImageView = UIImageView()
    private let moreButton = UIButton(type: .system)
    private let dividerView = UIView()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onMore = nil
    }

    func configure(remoteBook: RemoteBook) {
        let detailText = remoteBook.isDir ? remoteBook.path : remoteBook.fileSummary
        iconView.image = UIImage(systemName: remoteBook.isDir ? "folder" : "doc.text")
        titleLabel.text = remoteBook.filename
        subtitleLabel.text = detailText
        accessoryImageView.image = UIImage(systemName: remoteBook.isDir ? "chevron.right" : "square.and.arrow.down")
        moreButton.accessibilityLabel = "\(remoteBook.filename) \(L10n.Bookshelf.moreActions)"
        accessibilityLabel = "\(remoteBook.filename), \(detailText)"
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        selectionStyle = .default
        isAccessibilityElement = true

        let selectedView = UIView()
        selectedView.backgroundColor = AndroidReplicaTheme.activeIndicator.withAlphaComponent(0.35)
        selectedBackgroundView = selectedView

        iconContainerView.backgroundColor = AndroidReplicaTheme.coverBackground
        iconContainerView.layer.cornerRadius = 20
        iconContainerView.layer.masksToBounds = true

        iconView.tintColor = AndroidReplicaTheme.secondaryText
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 16, weight: .regular)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingMiddle

        subtitleLabel.font = .systemFont(ofSize: 13)
        subtitleLabel.textColor = AndroidReplicaTheme.secondaryText
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byTruncatingMiddle

        accessoryImageView.tintColor = AndroidReplicaTheme.secondaryText
        accessoryImageView.contentMode = .scaleAspectFit

        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        moreButton.tintColor = AndroidReplicaTheme.primaryText
        moreButton.backgroundColor = .clear
        moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)

        dividerView.backgroundColor = AndroidReplicaTheme.divider

        for item in [iconContainerView, titleLabel, subtitleLabel, accessoryImageView, moreButton, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(item)
        }
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconContainerView.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconContainerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            iconContainerView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            iconContainerView.widthAnchor.constraint(equalToConstant: 40),
            iconContainerView.heightAnchor.constraint(equalToConstant: 40),
            iconContainerView.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),

            iconView.centerXAnchor.constraint(equalTo: iconContainerView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconContainerView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            moreButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            moreButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 44),
            moreButton.heightAnchor.constraint(equalToConstant: 44),

            accessoryImageView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            accessoryImageView.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -2),
            accessoryImageView.widthAnchor.constraint(equalToConstant: 18),
            accessoryImageView.heightAnchor.constraint(equalToConstant: 18),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 11),
            titleLabel.leadingAnchor.constraint(equalTo: iconContainerView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: accessoryImageView.leadingAnchor, constant: -12),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -11),

            dividerView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerView.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
    }

    @objc private func handleMore() {
        onMore?()
    }
}

final class AndroidReplicaRemoteBookStateView: UIView {
    enum State {
        case hidden
        case loading(String)
        case empty(String)
        case error(String)
    }

    var onRetry: (() -> Void)?

    private let stackView = UIStackView()
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let iconView = UIImageView(image: UIImage(systemName: "folder"))
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func apply(_ state: State) {
        switch state {
        case .hidden:
            isHidden = true
            activityIndicator.stopAnimating()
        case let .loading(message):
            isHidden = false
            iconView.isHidden = true
            activityIndicator.isHidden = false
            activityIndicator.startAnimating()
            messageLabel.text = message
            retryButton.isHidden = true
        case let .empty(message):
            isHidden = false
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "folder")
            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
            messageLabel.text = message
            retryButton.isHidden = true
        case let .error(message):
            isHidden = false
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "exclamationmark.circle")
            activityIndicator.stopAnimating()
            activityIndicator.isHidden = true
            messageLabel.text = message
            retryButton.isHidden = false
        }
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        isHidden = true

        stackView.axis = .vertical
        stackView.alignment = .center
        stackView.spacing = 14
        stackView.translatesAutoresizingMaskIntoConstraints = false

        activityIndicator.color = AndroidReplicaTheme.secondaryText
        activityIndicator.hidesWhenStopped = true

        iconView.tintColor = AndroidReplicaTheme.secondaryText
        iconView.contentMode = .scaleAspectFit

        messageLabel.font = .systemFont(ofSize: 15)
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        retryButton.setTitle(L10n.Common.retry, for: .normal)
        retryButton.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        retryButton.backgroundColor = AndroidReplicaTheme.menuBackground
        retryButton.layer.cornerRadius = 18
        retryButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 18, bottom: 8, right: 18)
        retryButton.addTarget(self, action: #selector(handleRetry), for: .touchUpInside)

        addSubview(stackView)
        for item in [activityIndicator, iconView, messageLabel, retryButton] {
            stackView.addArrangedSubview(item)
        }

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -24),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),

            iconView.widthAnchor.constraint(equalToConstant: 36),
            iconView.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    @objc private func handleRetry() {
        onRetry?()
    }
}

final class AndroidReplicaRemoteBookConfirmSheetViewController: UIViewController {
    private let titleText: String
    private let messageText: String
    private let confirmTitle: String
    private let confirmHandler: () -> Void
    private let stackView = UIStackView()

    init(titleText: String, messageText: String, confirmTitle: String, confirmHandler: @escaping () -> Void) {
        self.titleText = titleText
        self.messageText = messageText
        self.confirmTitle = confirmTitle
        self.confirmHandler = confirmHandler
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: 300)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleText
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        stackView.axis = .vertical
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        let messageLabel = UILabel()
        messageLabel.text = messageText
        messageLabel.textColor = AndroidReplicaTheme.primaryText
        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center

        let confirmButton = makeButton(title: confirmTitle, systemImage: "trash", destructive: true, action: #selector(handleConfirm))
        let cancelButton = makeButton(title: L10n.Common.cancel, systemImage: "chevron.down.circle", destructive: false, action: #selector(handleCancel))

        for item in [messageLabel, confirmButton, cancelButton] {
            stackView.addArrangedSubview(item)
        }

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),

            confirmButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    private func makeButton(title: String, systemImage: String, destructive: Bool, action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 10
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = destructive ? .systemRed : AndroidReplicaTheme.primaryText
        configuration.baseBackgroundColor = destructive
            ? UIColor.systemRed.withAlphaComponent(0.14)
            : AndroidReplicaTheme.menuBackground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)

        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func handleConfirm() {
        dismiss(animated: true) { [confirmHandler] in
            confirmHandler()
        }
    }

    @objc private func handleCancel() {
        dismiss(animated: true)
    }
}

extension RemoteBook {
    var fileSummary: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

extension String {
    var remoteBookLastPathComponentFallback: String {
        let trimmed = trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init) ?? self
    }
}
