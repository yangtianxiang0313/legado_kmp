import UIKit

@MainActor
final class ConfigurationEditorFieldCell: UITableViewCell, UITextFieldDelegate, UITextViewDelegate {
    private let caption = UILabel()
    private var field: UITextField?
    private var editor: UITextView?
    var onChange: ((String) -> Void)?

    init(definition: ConfigurationEditorField, value: String, identifier: String) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        caption.text = definition.title
        caption.font = .preferredFont(forTextStyle: .subheadline)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = .secondaryLabel
        caption.numberOfLines = 0
        let input: UIView
        switch definition.kind {
        case .multiline:
            let textView = UITextView()
            textView.text = value
            textView.delegate = self
            textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
            textView.adjustsFontForContentSizeCategory = true
            textView.backgroundColor = .clear
            textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
            textView.textContainer.lineFragmentPadding = 0
            textView.autocapitalizationType = .none
            textView.autocorrectionType = .no
            textView.smartDashesType = .no
            textView.smartQuotesType = .no
            textView.spellCheckingType = .no
            textView.accessibilityLabel = definition.title
            textView.accessibilityIdentifier = identifier
            textView.inputAccessoryView = makeToolbar()
            editor = textView
            input = textView
        default:
            let textField = UITextField()
            textField.text = value
            textField.delegate = self
            textField.font = .preferredFont(forTextStyle: .body)
            textField.adjustsFontForContentSizeCategory = true
            textField.autocapitalizationType = .none
            textField.autocorrectionType = .no
            textField.smartDashesType = .no
            textField.smartQuotesType = .no
            textField.spellCheckingType = .no
            textField.clearButtonMode = .whileEditing
            textField.returnKeyType = .done
            textField.accessibilityLabel = definition.title
            textField.accessibilityIdentifier = identifier
            if case let .text(keyboard) = definition.kind { textField.keyboardType = keyboard }
            if case .password = definition.kind {
                textField.isSecureTextEntry = true
                textField.textContentType = .password
                textField.keyboardType = .asciiCapable
                textField.clearButtonMode = .never
            } else if definition.key == "username" {
                textField.textContentType = .username
            }
            textField.addTarget(self, action: #selector(textChanged), for: .editingChanged)
            textField.inputAccessoryView = makeToolbar()
            field = textField
            input = textField
        }
        let stack = UIStackView(arrangedSubviews: [caption, input])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10),
        ])
        if editor != nil {
            input.heightAnchor.constraint(equalToConstant: 160).isActive = true
        } else {
            input.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func focus() {
        if let field { field.becomeFirstResponder() } else { editor?.becomeFirstResponder() }
    }

    private func makeToolbar() -> UIToolbar {
        let toolbar = UIToolbar()
        toolbar.items = [
            UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
            UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(finishEditing)),
        ]
        toolbar.sizeToFit()
        return toolbar
    }

    @objc private func finishEditing() { endEditing(true) }
    @objc private func textChanged() { onChange?(field?.text ?? "") }
    func textViewDidChange(_ textView: UITextView) { onChange?(textView.text ?? "") }
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
