import UIKit
import shared

/// Keeps restored Android type-0 keyboard assists usable in rule editors.
@MainActor
final class RestoredKeyboardAccessory: UIScrollView {
    private weak var textView: UITextView?
    private let stack = UIStackView()

    init(textView: UITextView) {
        self.textView = textView
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        backgroundColor = .secondarySystemBackground
        alwaysBounceHorizontal = true
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
        let dismiss = UIButton(type: .system)
        dismiss.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        dismiss.accessibilityLabel = "收起键盘"
        dismiss.addAction(UIAction { [weak textView] _ in textView?.resignFirstResponder() }, for: .touchUpInside)
        stack.addArrangedSubview(dismiss)
        Task { [weak self] in
            do {
                let facade = try BootstrapApiKt.sharedBackupCapabilitiesFacade()
                let assists: [KeyboardAssist] = try await SharedAsync.value { facade.loadKeyboardAssists(completionHandler: $0) }
                guard let self else { return }
                for assist in assists {
                    let button = UIButton(type: .system)
                    button.setTitle(assist.key, for: .normal)
                    button.titleLabel?.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
                    button.addAction(UIAction { [weak textView] _ in
                        guard let textView else { return }
                        textView.insertText(assist.value)
                        textView.delegate?.textViewDidChange?(textView)
                    }, for: .touchUpInside)
                    stack.addArrangedSubview(button)
                }
            } catch { SharedRuntime.log("Keyboard assists: \(error.localizedDescription)") }
        }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
}
