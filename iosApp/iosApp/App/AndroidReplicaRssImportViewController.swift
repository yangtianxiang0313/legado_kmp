import shared
import UIKit

final class AndroidReplicaRssImportViewController: UIViewController {
    private let screen: RssSourceManagementScreenAdapter
    private lazy var topBar = AndroidReplicaDetailBar(title: "RSS JSON 导入", target: self, backAction: #selector(handleBack))
    private let textView = UITextView()
    private let importButton = UIButton(type: .system)
    private let feedbackLabel = UILabel()
    private var importTask: Task<Void, Never>?

    init(screen: RssSourceManagementScreenAdapter) {
        self.screen = screen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { importTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.backgroundColor = AndroidReplicaTheme.menuBackground
        textView.textColor = AndroidReplicaTheme.primaryText
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        textView.accessibilityIdentifier = "rss.sourceImport.jsonField"
        textView.accessibilityLabel = "RSS JSON"
        feedbackLabel.numberOfLines = 3
        feedbackLabel.font = .preferredFont(forTextStyle: .footnote)
        feedbackLabel.textColor = .systemRed
        feedbackLabel.accessibilityIdentifier = "rss.sourceImport.feedback"
        importButton.setTitle(L10n.RSS.sourceManagementImportAction, for: .normal)
        importButton.setImage(UIImage(systemName: "square.and.arrow.down"), for: .normal)
        importButton.accessibilityIdentifier = "rss.sourceImport.submit"
        importButton.addTarget(self, action: #selector(previewImport), for: .touchUpInside)
        let footer = UIStackView(arrangedSubviews: [feedbackLabel, importButton])
        footer.axis = .vertical
        footer.spacing = 8
        for item in [topBar, textView, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            textView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            textView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            textView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),
            footer.leadingAnchor.constraint(equalTo: textView.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: textView.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -12),
            importButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    @objc private func handleBack() {
        guard importTask == nil else { return }
        navigationController?.popViewController(animated: true)
    }

    @objc private func previewImport() {
        guard importTask == nil, presentedViewController == nil else { return }
        feedbackLabel.text = nil
        feedbackLabel.textColor = .systemRed
        let payload = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard let data = payload.data(using: .utf8),
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !rows.isEmpty else {
                throw importError("请输入非空 RSS 源 JSON 数组")
            }
            var names: [String] = []
            var urls = Set<String>()
            for row in rows {
                guard let name = row["sourceName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let url = row["sourceUrl"] as? String, !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw importError("每个 RSS 源都必须包含 sourceName 和 sourceUrl")
                }
                guard urls.insert(url.trimmingCharacters(in: .whitespacesAndNewlines)).inserted else {
                    throw importError("JSON 中存在重复的 sourceUrl")
                }
                names.append(name)
            }
            view.endEditing(true)
            let preview = UIAlertController(title: "导入 \(names.count) 个 RSS 源", message: names.prefix(8).joined(separator: "\n") + "\n同网址源将更新配置。", preferredStyle: .alert)
            preview.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
            preview.addAction(UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self] _ in self?.performImport(payload) })
            present(preview, animated: true)
        } catch {
            feedbackLabel.text = error.userFacingMessage
        }
    }

    private func performImport(_ payload: String) {
        importButton.isEnabled = false
        textView.isEditable = false
        importTask = Task { [weak self] in
            guard let self else { return }
            do {
                let count = try await screen.importSources(payload: payload)
                guard !Task.isCancelled else { return }
                feedbackLabel.textColor = AndroidReplicaTheme.accent
                feedbackLabel.text = L10n.RSS.sourceManagementImportSuccess(count)
            } catch {
                guard !Task.isCancelled else { return }
                feedbackLabel.textColor = .systemRed
                feedbackLabel.text = error.userFacingMessage
            }
            importTask = nil
            importButton.isEnabled = true
            textView.isEditable = true
        }
    }

    private func importError(_ message: String) -> Error {
        NSError(domain: "RSSImport", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
