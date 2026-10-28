import UIKit

final class AndroidReplicaOptionSheetViewController: UIViewController {
    struct Option {
        let title: String
        var systemImage: String? = nil
        let isSelected: Bool
        var isDestructive: Bool = false
        let handler: () -> Void
    }

    private let titleText: String
    private let options: [Option]
    private let stackView = UIStackView()

    init(titleText: String, options: [Option]) {
        self.titleText = titleText
        self.options = options
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: Self.preferredHeight(optionCount: options.count))
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
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        for option in options {
            stackView.addArrangedSubview(optionButton(option))
        }
    }

    private func optionButton(_ option: Option) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = option.title
        let imageName = option.systemImage ?? (option.isSelected ? "checkmark.circle.fill" : "circle")
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 12
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = option.isDestructive ? .systemRed : (option.isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.primaryText)
        configuration.baseBackgroundColor = AndroidReplicaTheme.menuBackground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)

        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        button.addAction(UIAction { [weak self] _ in
            self?.dismiss(animated: true) {
                option.handler()
            }
        }, for: .touchUpInside)
        return button
    }

    static func preferredHeight(optionCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 54
        let spacing: CGFloat = 10
        let chromeHeight: CGFloat = 96
        let contentHeight = chromeHeight + CGFloat(optionCount) * rowHeight + CGFloat(max(optionCount - 1, 0)) * spacing
        return min(max(contentHeight, 260), 640)
    }
}
