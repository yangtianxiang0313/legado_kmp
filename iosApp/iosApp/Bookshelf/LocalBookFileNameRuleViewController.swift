import shared
import UIKit

@MainActor
final class LocalBookFileNameRuleViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let editor = UITextView()
    private let status = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(type: .system)
    private let reset = UIButton(type: .system)
    private var facade: LocalBookFileNameFacade?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var loaded = false
    private var isSaving = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导入文件名规则"
        view.backgroundColor = AndroidReplicaTheme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save))
        navigationItem.leftBarButtonItem?.accessibilityIdentifier = "localImport.nameRule.cancel"
        navigationItem.rightBarButtonItem?.accessibilityIdentifier = "localImport.nameRule.save"
        editor.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        editor.backgroundColor = AndroidReplicaTheme.background
        editor.textColor = AndroidReplicaTheme.primaryText
        editor.autocorrectionType = .no
        editor.autocapitalizationType = .none
        editor.smartQuotesType = .no
        editor.smartDashesType = .no
        editor.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        editor.accessibilityIdentifier = "localImport.nameRule.script"
        editor.accessibilityLabel = "文件名规则"
        status.font = .preferredFont(forTextStyle: .subheadline)
        status.textColor = AndroidReplicaTheme.secondaryText
        status.numberOfLines = 0
        status.accessibilityIdentifier = "localImport.nameRule.status"
        var configuration = UIButton.Configuration.plain()
        configuration.title = "使用默认规则"
        configuration.image = UIImage(systemName: "arrow.counterclockwise")
        configuration.imagePadding = 8
        reset.configuration = configuration
        reset.accessibilityIdentifier = "localImport.nameRule.reset"
        reset.addAction(
            UIAction { [weak self] _ in
                guard let self, self.loaded, !self.isSaving else { return }
                self.editor.text = ""
            }, for: .touchUpInside)
        retry.setImage(UIImage(systemName: "arrow.clockwise"), for: .normal)
        retry.accessibilityLabel = "重新加载规则"
        retry.accessibilityIdentifier = "localImport.nameRule.reload"
        retry.addAction(
            UIAction { [weak self] _ in
                guard self?.loaded == false, self?.isSaving == false else { return }
                self?.load()
            }, for: .touchUpInside)
        retry.heightAnchor.constraint(equalToConstant: 44).isActive = true
        let footer = UIStackView(arrangedSubviews: [status, spinner, retry, reset])
        footer.axis = .vertical
        footer.alignment = .fill
        footer.spacing = 8
        spinner.hidesWhenStopped = true
        for item in [editor, footer] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            editor.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            editor.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])
        load()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }

    deinit { loadTask?.cancel() }

    private func load() {
        guard loadTask == nil, !isSaving else { return }
        loaded = false
        updateControls()
        status.text = nil
        spinner.startAnimating()
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil; self.spinner.stopAnimating(); self.updateControls() }
            do {
                let facade = try LocalBookFileNameFacade.companion.create()
                let rule = try await facade.load()
                try Task.checkCancellation()
                self.facade = facade
                self.editor.text = rule
                self.loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                self.status.text = error.userFacingMessage
            }
        }
        updateControls()
    }

    private func updateControls() {
        editor.isEditable = loaded && !isSaving
        reset.isEnabled = loaded && !isSaving
        retry.isHidden = loaded || loadTask != nil
        navigationItem.rightBarButtonItem?.isEnabled = loaded && !isSaving
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        isModalInPresentation = isSaving
        navigationController?.isModalInPresentation = isSaving
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { !isSaving }

    @objc private func cancel() {
        guard !isSaving else { return }
        loadTask?.cancel()
        dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func save() {
        guard loaded, !isSaving, let facade, canPerformNavigationAction,
            UIApplication.shared.applicationState == .active,
            view.window.map({ AppLockManager.shared.isUnlocked(in: $0) }) == true
        else { return }
        let value = editor.text ?? ""
        isSaving = true
        status.text = nil
        editor.resignFirstResponder()
        updateControls()
        saveTask = Task { [self] in
            defer { isSaving = false; saveTask = nil; updateControls() }
            do {
                try await facade.save(rule: value)
                dismiss(animated: !UIAccessibility.isReduceMotionEnabled)
            } catch {
                status.text = error.userFacingMessage
            }
        }
    }
}
