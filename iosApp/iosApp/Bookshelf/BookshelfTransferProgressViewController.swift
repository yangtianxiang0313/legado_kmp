import UIKit

@MainActor
final class BookshelfTransferProgressViewController: UIViewController {
    var onStop: (() -> Void)?
    var onUnexpectedDismiss: (() -> Void)?
    var expectsDismissal = false

    private let statusLabel = UILabel()
    private let stopButton = UIButton(type: .system)
    private let canStopBetweenURLs: Bool
    private var status: String
    private var didReportDismissal = false

    init(status: String, canStopBetweenURLs: Bool = false) {
        self.status = status
        self.canStopBetweenURLs = canStopBetweenURLs
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.28)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = "bookshelf.transfer.progress"
        let panel = UIView()
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 6
        panel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(panel)

        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        spinner.setContentHuggingPriority(.required, for: .horizontal)
        spinner.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusLabel.text = status
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = AndroidReplicaTheme.primaryText
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityTraits.insert(.updatesFrequently)
        let row = UIStackView(arrangedSubviews: [spinner, statusLabel])
        row.alignment = .center
        row.spacing = 20

        stopButton.setTitle("本项结束后停止", for: .normal)
        stopButton.titleLabel?.font = .preferredFont(forTextStyle: .callout)
        stopButton.titleLabel?.adjustsFontForContentSizeCategory = true
        stopButton.titleLabel?.numberOfLines = 0
        stopButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        stopButton.addAction(
            UIAction { [weak self] _ in
                guard let self, self.stopButton.isEnabled else { return }
                self.stopButton.isEnabled = false
                self.setStatus("等待当前网址完成后停止...")
                self.onStop?()
            }, for: .touchUpInside)
        stopButton.isHidden = !canStopBetweenURLs
        let content = UIStackView(arrangedSubviews: [row, stopButton])
        content.axis = .vertical
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(content)
        let width = panel.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -48)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            width,
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            panel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            panel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            panel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
            content.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),
            content.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -20),
        ])
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !expectsDismissal, !didReportDismissal else { return }
        didReportDismissal = true
        onUnexpectedDismiss?()
    }

    func setStatus(_ text: String) {
        status = text
        statusLabel.text = text
    }
}
