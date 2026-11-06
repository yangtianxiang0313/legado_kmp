import UIKit
import shared

final class RuleAssistantViewController: UIViewController {
    var onApply: ((RuleAssistantPreview, String) -> Void)?
    private let form: RuleAssistantFormView
    private var applyButton: UIBarButtonItem!
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var requestID: UUID?
    private var preview: RuleAssistantPreview?
    private var finishing = false

    init(draft: ReplaceRuleEditorDraft) {
        form = RuleAssistantFormView(
            scope: draft.scope, excludeScope: draft.excludeScope, sampleText: draft.isRegex ? "" : draft.pattern,
            replacementText: draft.isRegex ? "" : draft.replacement)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        task?.cancel()
        timeoutTask?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ruleAssistantString("title", "规则助手")
        view.backgroundColor = AndroidReplicaTheme.background
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(close))
        applyButton = UIBarButtonItem(
            image: UIImage(systemName: "checkmark"), style: .done, target: self, action: #selector(apply))
        applyButton.accessibilityLabel = ruleAssistantString("apply", "回填规则草稿")
        applyButton.accessibilityIdentifier = "ruleAssistant.apply"
        navigationItem.rightBarButtonItem = applyButton
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            form.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        form.onChange = { [weak self] in self?.invalidatePreview() }
        form.onGenerate = { [weak self] in
            guard let self else { return }
            if self.task != nil { self.invalidatePreview() } else { self.startPreview(generating: true) }
        }
        form.onPreview = { [weak self] in self?.startPreview(generating: false) }
        form.onWritingTools = { [weak self] in self?.showWritingTools() }
        form.onConfirmationChange = { [weak self] in self?.updateApplyButton() }
        refreshCapabilities(initial: true)
        updateApplyButton()
        NotificationCenter.default.addObserver(
            self, selector: #selector(becameActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { cancelPending() }
    }

    @objc private func becameActive() { refreshCapabilities(initial: false) }

    private func refreshCapabilities(initial: Bool) {
        form.setCapability(
            RuleAssistantModelService.capability,
            writingToolsAvailable: RuleAssistantWritingToolsViewController.isAvailable, initial: initial)
        form.setBusy(task != nil)
    }

    private func startPreview(generating: Bool) {
        guard !finishing, task == nil, presentedViewController == nil else { return }
        view.endEditing(true)
        let sample = form.sample.text
        let protectedText = form.protectedText.text
        let request = form.request.text
        let candidate = form.plan
        do {
            if generating {
                try RuleAssistantModelService.validateGenerationInput(
                    request: request, sample: sample, protectedText: protectedText)
            } else {
                try candidate.validate()
                try RuleAssistantModelService.validatePreviewInput(sample: sample, protectedText: protectedText)
            }
        } catch {
            showTransientMessage(error.userFacingMessage)
            return
        }
        invalidatePreview()
        let id = UUID()
        requestID = id
        form.setBusy(true)
        if generating {
            timeoutTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                guard let self, self.requestID == id else { return }
                self.invalidatePreview()
                self.showTransientMessage(ruleAssistantString("generation_timeout", "本次生成超时，输入内容已保留；可重试或使用模板"))
            }
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.requestID == id {
                    self.requestID = nil
                    self.task = nil
                    self.timeoutTask?.cancel()
                    self.timeoutTask = nil
                    self.form.setBusy(false)
                    self.updateApplyButton()
                }
            }
            do {
                let plan =
                    generating
                    ? try await RuleAssistantModelService.generate(
                        request: request, sample: sample, protectedText: protectedText)
                    : candidate
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                let result = try await RuleAssistantModelService.preview(
                    plan: plan, sample: sample, protectedText: protectedText)
                try Task.checkCancellation()
                guard self.requestID == id else { return }
                self.form.setPlan(plan)
                self.preview = result
                self.form.showPreview(result)
                self.updateApplyButton()
            } catch is CancellationError {
            } catch {
                guard self.requestID == id, !Task.isCancelled else { return }
                self.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func invalidatePreview() {
        cancelPending()
        preview = nil
        form.clearPreview()
        updateApplyButton()
    }

    private func cancelPending() {
        requestID = nil
        task?.cancel()
        task = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        form.setBusy(false)
    }

    private func updateApplyButton() {
        guard isViewLoaded, applyButton != nil else { return }
        guard !finishing, let preview, !preview.matches.isEmpty, preview.protectedMatchCount == 0,
            !preview.output.utf16.elementsEqual(form.sample.text.utf16), task == nil
        else {
            applyButton.isEnabled = false
            return
        }
        applyButton.isEnabled = !preview.requiresDeletionConfirmation || form.deletionConfirmed
    }

    @objc private func apply() {
        guard !finishing, presentedViewController == nil else { return }
        view.endEditing(true)
        updateApplyButton()
        guard applyButton.isEnabled, let preview, task == nil else { return }
        finishing = true
        updateApplyButton()
        let callback = onApply
        let name = form.operation.title
        onApply = nil
        dismiss(animated: true) { callback?(preview, name) }
    }

    @objc private func close() {
        guard !finishing, presentedViewController == nil else { return }
        finishing = true
        cancelPending()
        onApply = nil
        dismiss(animated: true)
    }

    private func showWritingTools() {
        guard !finishing, task == nil, presentedViewController == nil else { return }
        do {
            view.endEditing(true)
            let controller = try RuleAssistantWritingToolsViewController(
                request: form.request.text, sample: form.sample.text, protectedText: form.protectedText.text)
            controller.onPlan = { [weak self] plan, result in
                guard let self, !self.finishing, self.viewIfLoaded?.window != nil else { return }
                self.invalidatePreview()
                self.form.setPlan(plan)
                self.preview = result
                self.form.showPreview(result)
                self.updateApplyButton()
            }
            let navigation = UINavigationController(rootViewController: controller)
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = [.large()]
            present(navigation, animated: true)
        } catch { showTransientMessage(error.userFacingMessage) }
    }
}
