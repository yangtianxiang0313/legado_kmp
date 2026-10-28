import UIKit

@MainActor
final class CoverConfigurationTextEditorViewController: UIViewController {
    private let textView = UITextView()
    private let initialText: String
    private let identifier: String
    private let onSave: (String) -> Void

    init(title: String, text: String, identifier: String, onSave: @escaping (String) -> Void) {
        self.initialText = text
        self.identifier = identifier
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.tintColor = AndroidReplicaTheme.accent
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "完成编辑"
        textView.backgroundColor = AndroidReplicaTheme.background
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.adjustsFontForContentSizeCategory = true
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.text = initialText
        textView.accessibilityIdentifier = identifier
        textView.accessibilityLabel = title
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.addSubview(textView)
        textView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    @objc private func save() {
        onSave(textView.text ?? "")
        navigationController?.popViewController(animated: true)
    }
}
