import UIKit

@MainActor
final class MangaReaderStateView: UIView {
    private let message = UILabel()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let button = UIButton(type: .system)
    private var action: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        spinner.color = .white
        spinner.hidesWhenStopped = true
        message.textColor = .lightGray
        message.font = .preferredFont(forTextStyle: .body)
        message.numberOfLines = 0
        message.textAlignment = .center
        button.tintColor = .white
        button.addTarget(self, action: #selector(performAction), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [spinner, message, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func show(
        message: String, loading: Bool = false, actionTitle: String? = nil,
        icon: String = "arrow.clockwise", action: (() -> Void)? = nil
    ) {
        isHidden = false
        self.message.text = message
        self.action = action
        button.isHidden = actionTitle == nil
        var configuration = UIButton.Configuration.plain()
        configuration.title = actionTitle
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 8
        button.configuration = configuration
        if loading { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    func hide() {
        isHidden = true
        spinner.stopAnimating()
        action = nil
    }

    @objc private func performAction() { action?() }
}
