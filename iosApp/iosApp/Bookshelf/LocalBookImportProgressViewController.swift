import UIKit

@MainActor
final class LocalBookImportProgressViewController: UIViewController {
    var onCancel: (() -> Void)?
    private var fileName: String
    private let fileLabel = UILabel()
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    init(fileName: String) {
        self.fileName = fileName
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 360, height: 280)
        sheetPresentationController?.detents = [.medium(), .large()]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        let titleLabel = UILabel()
        titleLabel.text = BookshelfLocalImportText.title
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 0
        fileLabel.text = fileName
        fileLabel.font = .preferredFont(forTextStyle: .subheadline)
        fileLabel.adjustsFontForContentSizeCategory = true
        fileLabel.textColor = AndroidReplicaTheme.secondaryText
        fileLabel.numberOfLines = 0
        fileLabel.lineBreakMode = .byCharWrapping
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = AndroidReplicaTheme.primaryText
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityTraits.insert(.updatesFrequently)
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        var configuration = UIButton.Configuration.plain()
        configuration.title = BookshelfLocalImportText.cancel
        configuration.image = UIImage(systemName: "xmark")
        configuration.imagePadding = 8
        cancelButton.configuration = configuration
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, fileLabel, spinner, statusLabel, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        setStatus(BookshelfLocalImportText.preparing)
    }

    func setFileName(_ fileName: String) {
        self.fileName = fileName
        fileLabel.text = fileName
    }

    func setStatus(_ text: String, cancelling: Bool = false) {
        statusLabel.text = text
        cancelButton.isEnabled = !cancelling
    }
}
