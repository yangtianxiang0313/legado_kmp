import UIKit

final class SearchRecoveryPresentation {
    private let table: UITableView
    private let footer: SearchRecoveryFooterView
    private let emptyView: SearchRecoveryFooterView
    private let emptyViewport: UIScrollView

    init(table: UITableView, footer: SearchRecoveryFooterView, emptyView: SearchRecoveryFooterView, emptyViewport: UIScrollView) {
        self.table = table
        self.footer = footer
        self.emptyView = emptyView
        self.emptyViewport = emptyViewport
    }

    func update(message: String?, isRunning: Bool, showsInputHelp: Bool, hasResults: Bool) {
        let message = message.map { value in
            let firstLine =
                value.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty } ?? L10n.Search.failed
            return firstLine.count > 160 ? String(firstLine.prefix(157)) + "..." : firstLine
        }
        if let message {
            footer.configure(message: message, isRetrying: isRunning)
            emptyView.configure(message: message, isRetrying: isRunning)
        }
        emptyView.isHidden = showsInputHelp || hasResults || message == nil
        emptyViewport.isHidden = emptyView.isHidden
        if hasResults, message != nil {
            if table.tableFooterView !== footer { table.tableFooterView = footer }
            updateLayout()
        } else if table.tableFooterView != nil {
            table.tableFooterView = nil
        }
    }

    func updateLayout() {
        guard table.tableFooterView === footer, table.bounds.width > 0 else { return }
        let size = CGSize(width: table.bounds.width, height: footer.height(for: table.bounds.width))
        guard footer.frame.size != size else { return }
        footer.frame.size = size
        table.tableFooterView = footer
    }
}

final class SearchRecoveryFooterView: UIView {
    var onRetry: (() -> Void)?

    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let messageContent = UIView()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = .clear
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.plain()
        configuration.title = L10n.Common.retry
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.imagePadding = 6
        configuration.baseForegroundColor = AndroidReplicaTheme.accent
        retryButton.configuration = configuration
        retryButton.accessibilityLabel = L10n.Common.retry
        retryButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Common.retry))
        retryButton.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .touchUpInside)

        messageContent.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageContent)
        for item in [messageLabel, retryButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            messageContent.addSubview(item)
        }
        NSLayoutConstraint.activate([
            messageContent.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageContent.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            messageContent.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            messageContent.leadingAnchor.constraint(equalTo: leadingAnchor),
            messageContent.trailingAnchor.constraint(equalTo: trailingAnchor),
            messageLabel.topAnchor.constraint(equalTo: messageContent.topAnchor, constant: 12),
            messageLabel.leadingAnchor.constraint(equalTo: messageContent.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: messageContent.trailingAnchor, constant: -24),
            retryButton.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 4),
            retryButton.centerXAnchor.constraint(equalTo: messageContent.centerXAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: messageContent.leadingAnchor, constant: 24),
            retryButton.trailingAnchor.constraint(lessThanOrEqualTo: messageContent.trailingAnchor, constant: -24),
            retryButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            retryButton.bottomAnchor.constraint(equalTo: messageContent.bottomAnchor, constant: -12),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(message: String, isRetrying: Bool) {
        messageLabel.text = message
        retryButton.isEnabled = !isRetrying
        retryButton.configuration?.showsActivityIndicator = isRetrying
    }

    func height(for width: CGFloat) -> CGFloat {
        ceil(
            systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height)
    }
}
