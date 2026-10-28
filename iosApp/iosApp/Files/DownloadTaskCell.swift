import UIKit
import shared

final class DownloadTaskCell: UITableViewCell {
    static let reuseIdentifier = "DownloadTaskCell"
    private let nameLabel = UILabel()
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()
    private let progress = UIProgressView(progressViewStyle: .default)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let actionButton = UIButton(type: .system)
    private var onAction: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 2
        nameLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.numberOfLines = 0
        [nameLabel, statusLabel, detailLabel].forEach { $0.adjustsFontForContentSizeCategory = true }
        let labels = UIStackView(arrangedSubviews: [nameLabel, statusLabel, detailLabel, progress])
        labels.axis = .vertical
        labels.spacing = 6
        let actions = UIStackView(arrangedSubviews: [spinner, actionButton])
        actions.axis = .vertical
        actions.spacing = 4
        let row = UIStackView(arrangedSubviews: [labels, actions])
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4),
            actionButton.widthAnchor.constraint(equalToConstant: 44),
            actionButton.heightAnchor.constraint(equalToConstant: 44),
            progress.heightAnchor.constraint(equalToConstant: 3),
        ])
        actionButton.addTarget(self, action: #selector(invokeAction), for: .touchUpInside)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        spinner.stopAnimating()
    }

    func configure(_ task: FileDownloadTask, onAction: @escaping () -> Void) {
        self.onAction = onAction
        backgroundColor = AndroidReplicaTheme.background
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        statusLabel.textColor = task.status == .failed ? .systemRed : AndroidReplicaTheme.secondaryText
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        progress.progressTintColor = AndroidReplicaTheme.accent
        actionButton.tintColor = AndroidReplicaTheme.accent
        nameLabel.text = task.fileName
        statusLabel.text = "\(task.downloadStatusText) · \(task.downloadSizeText)"
        detailLabel.text = task.errorMessage.flatMap { message in
            message.count <= 160 && !message.contains("://") && !message.contains("/") ? message : nil
        }
        detailLabel.isHidden = detailLabel.text?.isEmpty != false
        let total = task.totalBytes?.doubleValue ?? 0
        progress.isHidden = !(task.isActive || task.canResume) || total <= 0
        progress.setProgress(total > 0 ? Float(min(1, max(0, Double(task.bytesDownloaded) / total))) : 0, animated: false)
        if task.isActive && total <= 0 { spinner.startAnimating() } else { spinner.stopAnimating() }
        let symbol: String
        let actionName: String
        if task.canPause {
            symbol = "pause.circle"
            actionName = "暂停下载"
        } else if task.canResume {
            symbol = "play.circle"
            actionName = "继续下载"
        } else if task.canRetry {
            symbol = "arrow.clockwise"
            actionName = "重新下载"
        } else {
            symbol = "square.and.arrow.up"
            actionName = "分享文件"
        }
        actionButton.setImage(UIImage(systemName: symbol), for: .normal)
        actionButton.accessibilityLabel = actionName
        actionButton.accessibilityIdentifier = "downloads.action.\(task.id)"
        actionButton.isHidden = !(task.canPause || task.canResume || task.canRetry || task.status == .completed)
        accessoryType = task.status == .completed ? .disclosureIndicator : .none
        selectionStyle = task.status == .completed ? .default : .none
        accessibilityIdentifier = "downloads.task.\(task.id)"
    }

    @objc private func invokeAction() { onAction?() }
}
