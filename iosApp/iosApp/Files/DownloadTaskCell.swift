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
    private let actionToolTip = UIToolTipInteraction(defaultToolTip: "")
    private var onAction: (() -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.numberOfLines = 0
        nameLabel.lineBreakMode = .byCharWrapping
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byWordWrapping
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.numberOfLines = 0
        detailLabel.lineBreakMode = .byCharWrapping
        for label in [nameLabel, statusLabel, detailLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let labels = UIStackView(arrangedSubviews: [nameLabel, statusLabel, detailLabel, progress])
        labels.axis = .vertical
        labels.spacing = 6
        let actions = UIStackView(arrangedSubviews: [spinner, actionButton])
        actions.axis = .vertical
        actions.spacing = 4
        actions.alignment = .center
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
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
            actions.widthAnchor.constraint(equalToConstant: 44),
            progress.heightAnchor.constraint(equalToConstant: 3),
        ])
        actionButton.addTarget(self, action: #selector(invokeAction), for: .touchUpInside)
        actionButton.addInteraction(actionToolTip)
        progress.isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func prepareForReuse() {
        super.prepareForReuse()
        onAction = nil
        actionButton.isEnabled = false
        actionToolTip.defaultToolTip = nil
        spinner.stopAnimating()
    }

    func configure(_ task: FileDownloadTask, actionEnabled: Bool, onAction: @escaping () -> Void) {
        self.onAction = onAction
        backgroundColor = AndroidReplicaTheme.background
        nameLabel.textColor = AndroidReplicaTheme.primaryText
        statusLabel.textColor = task.status == .failed ? .systemRed : AndroidReplicaTheme.secondaryText
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        progress.progressTintColor = AndroidReplicaTheme.accent
        actionButton.tintColor = AndroidReplicaTheme.accent
        nameLabel.text = task.fileName
        nameLabel.accessibilityLabel = task.fileName
        statusLabel.text = DownloadPresentationText.statusAndSize(task.downloadStatusText, task.downloadSizeText)
        detailLabel.text = DownloadPresentationText.detailError(task.errorMessage)
        detailLabel.isHidden = detailLabel.text?.isEmpty != false
        let total = task.totalBytes?.doubleValue ?? 0
        progress.isHidden = !(task.isActive || task.canResume) || total <= 0
        progress.setProgress(
            total > 0 ? Float(min(1, max(0, Double(task.bytesDownloaded) / total))) : 0, animated: false)
        if task.isActive && total <= 0 { spinner.startAnimating() } else { spinner.stopAnimating() }
        let symbol: String
        let actionName: String
        if task.canPause {
            symbol = "pause.circle"
            actionName = DownloadPresentationText.pause
        } else if task.canResume {
            symbol = "play.circle"
            actionName = DownloadPresentationText.resume
        } else if task.canRetry {
            symbol = "arrow.clockwise"
            actionName = DownloadPresentationText.retry
        } else {
            symbol = "square.and.arrow.up"
            actionName = DownloadPresentationText.shareFile
        }
        actionButton.setImage(UIImage(systemName: symbol), for: .normal)
        actionButton.accessibilityLabel = actionName
        actionToolTip.defaultToolTip = actionName
        actionButton.isEnabled = actionEnabled
        actionButton.accessibilityIdentifier = "downloads.action.\(task.id)"
        actionButton.isHidden = !(task.canPause || task.canResume || task.canRetry || task.status == .completed)
        accessoryType = task.status == .completed ? .disclosureIndicator : .none
        selectionStyle = task.status == .completed ? .default : .none
        accessibilityIdentifier = "downloads.task.\(task.id)"
    }

    @objc private func invokeAction() {
        guard actionButton.isEnabled, let onAction else { return }
        // The controller consumes accepted actions; a rejected tap must remain retryable.
        onAction()
    }
}
