import UIKit

final class AndroidReaderOptionSheetViewController: UIViewController {
    struct Option {
        let title: String
        var systemImage: String? = nil
        var subtitle: String? = nil
        let isSelected: Bool
        var isDestructive: Bool = false
        let handler: () -> Void
    }

    private let titleText: String
    private let options: [Option]
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private weak var selectedButton: UIButton?

    init(titleText: String, options: [Option]) {
        self.titleText = titleText
        self.options = options
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = titleText
        view.backgroundColor = AndroidReplicaTheme.background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        stackView.axis = .vertical
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
        for option in options {
            let button = optionButton(option)
            if option.isSelected, selectedButton == nil {
                selectedButton = button
            }
            stackView.addArrangedSubview(button)
        }
        if let selectedButton {
            DispatchQueue.main.async { [weak self, weak selectedButton] in
                guard let self, let selectedButton else { return }
                let targetRect = self.scrollView.convert(selectedButton.bounds, from: selectedButton)
                self.scrollView.scrollRectToVisible(targetRect.insetBy(dx: 0, dy: -16), animated: false)
            }
        }
    }

    private func optionButton(_ option: Option) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.title = option.title
        configuration.subtitle = option.subtitle
        let imageName = option.systemImage ?? (option.isSelected ? "checkmark.circle.fill" : "circle")
        configuration.image = UIImage(systemName: imageName)
        configuration.imagePlacement = .leading
        configuration.imagePadding = 12
        configuration.titleAlignment = .leading
        configuration.baseForegroundColor = option.isDestructive ? .systemRed : (option.isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.primaryText)
        configuration.baseBackgroundColor = option.isSelected ? AndroidReplicaTheme.accent.withAlphaComponent(0.14) : AndroidReplicaTheme.menuBackground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)
        let button = UIButton(configuration: configuration)
        button.contentHorizontalAlignment = .leading
        button.layer.cornerRadius = 10
        button.layer.borderWidth = option.isSelected ? 1.5 : 1 / UIScreen.main.scale
        button.layer.borderColor = (option.isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.divider).cgColor
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: option.subtitle == nil ? 50 : 66).isActive = true
        button.accessibilityLabel = [option.title, option.subtitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
            .joined(separator: ", ")
        button.accessibilityValue = [
            option.isSelected ? L10n.ReaderAppearance.optionSelected : L10n.ReaderAppearance.optionNotSelected,
            option.isDestructive ? L10n.ReaderAppearance.optionDestructive : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
        button.accessibilityTraits = option.isSelected ? [.button, .selected] : .button
        button.addAction(UIAction { [weak self, weak button] _ in
            button?.isEnabled = false
            self?.dismiss(animated: true) {
                option.handler()
            }
        }, for: .touchUpInside)
        return button
    }
}
