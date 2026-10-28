import UIKit
import shared

final class ReplaceRuleEditorViewController: UIViewController,
    UIGestureRecognizerDelegate, UIAdaptivePresentationControllerDelegate
{
    private enum State { case editing, saving, finished }

    var onSaved: ((ReplaceRule) -> Void)?

    private let originalRule: ReplaceRule?
    private let facade: ReplaceRuleFacade?
    private let newID = Int64(Date().timeIntervalSince1970 * 1000)
    private let initialDraft: ReplaceRuleEditorDraft
    private let topBar = AndroidEditorTitleBar(title: "替换规则编辑", showsMore: true)
    private let form = ReplaceRuleEditorFormView()
    private let toolbarBackdrop = UIView()
    private var state = State.editing
    private var overflowMenu: ReaderOverflowMenuView?
    private weak var previousPopDelegate: UIGestureRecognizerDelegate?
    private weak var previousDismissDelegate: UIAdaptivePresentationControllerDelegate?
    private var previousModalProtection: Bool?

    init(
        rule: ReplaceRule?, facade: ReplaceRuleFacade?,
        initialDraft: ReplaceRuleEditorDraft? = nil,
        onSaved: ((ReplaceRule) -> Void)? = nil
    ) {
        originalRule = rule
        self.facade = facade
        self.onSaved = onSaved
        // Prefill is the cancellation baseline, not a persisted record or a user edit.
        if rule == nil {
            self.initialDraft = initialDraft ?? ReplaceRuleEditorDraft(rule: nil)
        } else {
            self.initialDraft = ReplaceRuleEditorDraft(rule: rule)
        }
        super.init(nibName: nil, bundle: nil)
        hidesBottomBarWhenPushed = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "替换规则编辑"
        view.backgroundColor = AndroidReplicaTheme.background
        toolbarBackdrop.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbarBackdrop.isUserInteractionEnabled = false
        for child in [toolbarBackdrop, topBar, form] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbarBackdrop.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarBackdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarBackdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarBackdrop.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            form.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        topBar.backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)
        topBar.saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
        topBar.moreButton.addTarget(self, action: #selector(handleMore), for: .touchUpInside)
        topBar.accessibilityIdentifier = "replaceRule.editor.toolbar"
        form.populate(initialDraft)
        form.onChange = { [weak self] in self?.updateDismissalProtection() }
        form.onHelp = { [weak self] in self?.showRegexHelp() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
        if previousModalProtection == nil {
            previousModalProtection = dismissalHost.isModalInPresentation
        }
        updateDismissalProtection()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let gesture = navigationController?.interactivePopGestureRecognizer,
            gesture.delegate !== self
        {
            previousPopDelegate = gesture.delegate
            gesture.delegate = self
        }
        if let presentation = dismissalHost.presentationController,
            presentation.delegate !== self
        {
            previousDismissDelegate = presentation.delegate
            presentation.delegate = self
        }
        updateDismissalProtection()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        overflowMenu?.dismiss()
        if let gesture = navigationController?.interactivePopGestureRecognizer,
            gesture.delegate === self
        {
            gesture.delegate = previousPopDelegate
        }
        if let presentation = dismissalHost.presentationController, presentation.delegate === self {
            presentation.delegate = previousDismissDelegate
        }
        if let previousModalProtection {
            dismissalHost.isModalInPresentation = previousModalProtection
            self.previousModalProtection = nil
        }
    }

    private var hasChanges: Bool { form.draft != initialDraft }

    private var dismissalHost: UIViewController {
        if let navigation = navigationController,
            navigation.presentingViewController != nil || navigation.viewControllers.first === self
        {
            return navigation
        }
        return self
    }

    private func updateDismissalProtection() {
        let protected = state == .saving || (state == .editing && hasChanges)
        isModalInPresentation = protected
        dismissalHost.isModalInPresentation = protected || previousModalProtection == true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard state == .editing, presentedViewController == nil,
            navigationController?.transitionCoordinator == nil
        else { return false }
        if hasChanges {
            handleBack()
            return false
        }
        return previousPopDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) ?? true
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        guard state == .editing, !hasChanges, previousModalProtection != true else { return false }
        return previousDismissDelegate?.presentationControllerShouldDismiss?(presentationController) ?? true
    }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) {
        handleBack()
    }

    override func accessibilityPerformEscape() -> Bool {
        if let overflowMenu {
            overflowMenu.dismiss()
            return true
        }
        handleBack()
        return true
    }

    @objc private func handleBack() {
        guard state == .editing, presentedViewController == nil else { return }
        overflowMenu?.dismiss()
        guard hasChanges else {
            state = .finished
            closeEditor()
            return
        }
        let alert = UIAlertController(title: "放弃未保存的修改？", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "继续编辑", style: .cancel))
        alert.addAction(
            UIAlertAction(title: "放弃修改", style: .destructive) { [weak self, weak alert] _ in
                guard let self, let alert else { return }
                self.afterDismissing(alert) { [weak self] in
                    guard let self, self.state == .editing else { return }
                    self.state = .finished
                    self.closeEditor()
                }
            })
        present(alert, animated: true)
    }

    @objc private func handleSave() {
        guard state == .editing, presentedViewController == nil else { return }
        overflowMenu?.dismiss()
        view.endEditing(true)
        guard let facade else {
            showError("规则服务不可用，尚未保存。请返回规则列表重新打开编辑器。")
            return
        }
        let candidate: ReplaceRule
        do {
            let draft = form.draft
            guard !draft.pattern.isEmpty else { throw ReplaceRuleEditorDraft.DraftError.emptyPattern }
            candidate = try draft.makeRule(original: originalRule, newID: newID)
            guard candidate.isValid else { throw ReplaceRuleEditorDraft.DraftError.invalidPattern }
        } catch {
            showError(error.localizedDescription)
            return
        }
        state = .saving
        setBusy(true)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await facade.saveRuleAsync(rule: candidate)
                guard self.state == .saving else { return }
                self.state = .finished
                self.updateDismissalProtection()
                let callback = self.onSaved
                self.onSaved = nil
                self.closeEditor { callback?(candidate) }
            } catch {
                self.state = .editing
                self.setBusy(false)
                self.showError(error.userFacingMessage, allowsRetry: true)
            }
        }
    }

    private func setBusy(_ busy: Bool) {
        topBar.setBusy(busy)
        form.setEditable(!busy)
        updateDismissalProtection()
    }

    private func closeEditor(completion: (() -> Void)? = nil) {
        view.endEditing(true)
        updateDismissalProtection()
        if let navigation = navigationController, navigation.viewControllers.first !== self {
            navigation.popViewController(animated: true)
            if let transition = navigation.transitionCoordinator {
                transition.animate(alongsideTransition: nil) { _ in completion?() }
            } else {
                completion?()
            }
        } else if dismissalHost.presentingViewController != nil {
            dismissalHost.dismiss(animated: true, completion: completion)
        } else {
            completion?()
        }
    }

    @objc private func handleMore() {
        guard state == .editing, presentedViewController == nil else { return }
        if let overflowMenu {
            overflowMenu.dismiss()
            return
        }
        let menu = ReaderOverflowMenuView(
            items: [
                .init(identifier: "copyRule", title: L10n.ReplaceRule.copyRule) { [weak self] in
                    self?.copyRule()
                },
                .init(identifier: "pasteRule", title: L10n.ReplaceRule.pasteRule) { [weak self] in
                    self?.pasteRule()
                },
            ],
            anchorView: topBar.moreButton,
            interfaceStyle: traitCollection.userInterfaceStyle
        )
        menu.onDismiss = { [weak self] in self?.overflowMenu = nil }
        overflowMenu = menu
        menu.present(in: view)
    }

    private func copyRule() {
        guard state == .editing else { return }
        do {
            let candidate = try form.draft.makeRule(original: originalRule, newID: newID)
            UIPasteboard.general.string = try ReplaceRuleEditorClipboard.encode(candidate)
            showTransientMessage(L10n.ReplaceRule.copyRuleSuccess)
        } catch {
            showError(error.localizedDescription, title: "复制失败")
        }
    }

    private func pasteRule() {
        guard state == .editing else { return }
        do {
            guard let text = UIPasteboard.general.string, !text.isEmpty else {
                throw ReplaceRuleEditorDraft.DraftError.invalidClipboard
            }
            let draft = try ReplaceRuleEditorClipboard.decode(text)
            view.endEditing(true)
            form.populate(draft)
            updateDismissalProtection()
        } catch {
            showError(L10n.ReplaceRule.pasteRuleInvalid, title: "粘贴失败")
        }
    }

    private func showRegexHelp() {
        guard state == .editing, presentedViewController == nil else { return }
        view.endEditing(true)
        present(ReplaceRuleEditorHelpViewController(), animated: true)
    }

    private func showError(_ message: String, allowsRetry: Bool = false, title: String? = "未保存") {
        guard presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .cancel))
        if allowsRetry {
            alert.addAction(
                UIAlertAction(title: "重试", style: .default) { [weak self, weak alert] _ in
                    guard let self, let alert else { return }
                    self.afterDismissing(alert) { [weak self] in self?.handleSave() }
                })
        }
        present(alert, animated: true)
    }

    private func afterDismissing(_ alert: UIAlertController, action: @escaping () -> Void) {
        if alert.isBeingDismissed, let transition = alert.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in action() }
        } else if alert.presentingViewController != nil {
            alert.dismiss(animated: true, completion: action)
        } else {
            action()
        }
    }
}
