import SnapKit
import UIKit

// Android hides review editing; retain the existing iOS JSON editor outside the six primary forms.
final class BookSourceEditorReviewCommand: UIViewController {
    var canSave: (() -> Bool)?
    private let textView = UITextView()
    private let initialText: String
    private let onSave: (String) -> Void

    init(text: String, onSave: @escaping (String) -> Void) {
        initialText = text
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.SourceEdit.ruleReviewTitle
        view.backgroundColor = .systemBackground
        isModalInPresentation = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(save))
        navigationItem.rightBarButtonItem?.accessibilityLabel = L10n.Common.save
        textView.text = initialText
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.accessibilityIdentifier = UIIdentifiers.SourceEdit.reviewRuleField
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        view.addSubview(textView)
        textView.snp.makeConstraints { make in
            make.top.leading.trailing.equalTo(view.safeAreaLayoutGuide)
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }
    }

    @objc private func cancel() { dismiss(animated: true) }

    @objc private func save() {
        guard canSave?() == true else { return }
        do {
            textView.unmarkText()
            let text = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { _ = try BookSourceEditorDraft.decodePayload(text) }
            onSave(text)
            dismiss(animated: true)
        } catch { presentError(error) }
    }
}
