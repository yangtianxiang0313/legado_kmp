import UIKit

@MainActor
final class AppLockFormView: UIView {
    let heading = UILabel()
    let message = UILabel()
    let error = UILabel()
    let submit = UIButton(type: .system)
    let activity = UIActivityIndicatorView(style: .medium)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private let fieldsStack = UIStackView()
    private(set) var fields: [UITextField] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemBackground
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        fieldsStack.axis = .vertical
        fieldsStack.spacing = 16
        heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true
        heading.textColor = .label
        heading.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.textColor = .secondaryLabel
        message.numberOfLines = 0
        error.font = .preferredFont(forTextStyle: .footnote)
        error.adjustsFontForContentSizeCategory = true
        error.textColor = .systemRed
        error.numberOfLines = 0
        error.isHidden = true
        error.accessibilityIdentifier = "app-lock.error"
        submit.configuration = .filled()
        submit.configuration?.title = "确认"
        submit.accessibilityIdentifier = "app-lock.submit"
        activity.hidesWhenStopped = true
        addSubview(scroll)
        scroll.addSubview(stack)
        [heading, message, fieldsStack, error, activity, submit].forEach { stack.addArrangedSubview($0) }
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 32),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.centerXAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            scroll.contentLayoutGuide.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            preferredWidth,
            submit.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func addPasswordField(title: String, identifier: String, newPassword: Bool = false) -> UITextField {
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .label
        label.numberOfLines = 0
        let field = UITextField()
        field.isSecureTextEntry = true
        field.textContentType = newPassword ? .newPassword : .password
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.spellCheckingType = .no
        field.borderStyle = .roundedRect
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.returnKeyType = .done
        field.accessibilityLabel = title
        field.accessibilityIdentifier = identifier
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
        let group = UIStackView(arrangedSubviews: [label, field])
        group.axis = .vertical
        group.spacing = 6
        fieldsStack.addArrangedSubview(group)
        fields.append(field)
        return field
    }

    func showFields(_ visible: Bool) {
        fieldsStack.isHidden = !visible
        if !visible { clearSensitiveInput() }
    }

    func setProcessing(_ processing: Bool) {
        fields.forEach { $0.isEnabled = !processing }
        submit.isEnabled = !processing
        if processing { activity.startAnimating() } else { activity.stopAnimating() }
    }

    func showError(_ failure: Error?) {
        error.text = failure.map { ($0 as? AppLockFailure)?.errorDescription ?? "密码操作未完成，请重试" }
        error.isHidden = failure == nil
        if failure != nil { UIAccessibility.post(notification: .announcement, argument: error.text) }
    }

    func clearSensitiveInput() {
        fields.forEach { $0.text = nil }
        endEditing(true)
    }
}
