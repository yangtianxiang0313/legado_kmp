import SnapKit
import Then
import UIKit
import UniformTypeIdentifiers
import shared

enum SourceImportCompletionAction {
    case stay
    case goSearch
}

final class SourceImportViewController: UIViewController, UIDocumentPickerDelegate {
    var onImportCompleted: ((SourceImportCompletionAction) -> Void)?

    private let screen = SourceImportScreenAdapter()
    private let scaffoldView = LegacyRootScaffoldView()
    private let stateView = ContentStateView()
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let modeControl = UISegmentedControl(items: [
        L10n.SourceImport.jsonMode,
        L10n.SourceImport.urlMode,
        L10n.SourceImport.fileMode,
    ]).then {
        $0.selectedSegmentIndex = 0
    }
    private let urlField = UITextField().then {
        $0.borderStyle = .roundedRect
        $0.placeholder = L10n.SourceImport.urlPlaceholder
        $0.autocapitalizationType = .none
        $0.autocorrectionType = .no
        $0.smartQuotesType = .no
        $0.smartDashesType = .no
        $0.smartInsertDeleteType = .no
        $0.keyboardType = .URL
        $0.isHidden = true
    }
    private let textView = UITextView().then {
        $0.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        $0.backgroundColor = .secondarySystemGroupedBackground
        $0.layer.cornerRadius = AppUI.CornerRadius.medium
        $0.textContainerInset = UIEdgeInsets(
            top: AppUI.Spacing.medium,
            left: AppUI.Spacing.medium - 2,
            bottom: AppUI.Spacing.medium,
            right: AppUI.Spacing.medium - 2
        )
        $0.autocapitalizationType = .none
        $0.autocorrectionType = .no
        $0.smartQuotesType = .no
        $0.smartDashesType = .no
        $0.smartInsertDeleteType = .no
    }
    private let fileButton = UIButton(type: .system).then {
        $0.configuration = .filled()
        $0.setTitle(L10n.SourceImport.chooseFile, for: .normal)
        $0.isHidden = true
    }
    private let fileNameLabel = UILabel().then {
        $0.font = .preferredFont(forTextStyle: .subheadline)
        $0.textColor = .secondaryLabel
        $0.numberOfLines = 2
        $0.text = L10n.SourceImport.filePlaceholder
        $0.isHidden = true
    }
    private let footerBar = UIView()
    private let cancelButton = UIButton(type: .system)
    private let submitButton = UIButton(type: .system)
    private var selectedImportFile: ImportFileSelection?
    private let preferredMode: ImportMode
    private var previewTask: Task<Void, Never>?
    private var requestGeneration = 0
    private var isScreenActive = false
    private var importPhase: ImportPhase = .idle
    private weak var previewController: SourceImportPreviewViewController?
    private var importedResult: SourceImportResult?

    private enum ImportPhase {
        case idle, preparing, previewing, importing
    }

    init(preferredMode: ImportMode = .json) {
        self.preferredMode = preferredMode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.SourceImport.title
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = UIIdentifiers.SourceImport.root
        layoutUI()
        applyUITestDefaults()
        bootstrapDependencies()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isScreenActive = true
        updateImportControls()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true else {
            return
        }
        isScreenActive = false
        invalidatePreview()
    }

    deinit {
        previewTask?.cancel()
    }

    private func isCurrentRequest(_ generation: Int) -> Bool {
        isScreenActive && generation == requestGeneration && !isMovingFromParent && !isBeingDismissed
            && navigationController?.isBeingDismissed != true
            && (navigationController == nil || navigationController?.topViewController === self)
    }

    private func updateImportControls() {
        submitButton.isEnabled = isScreenActive && importPhase == .idle
        fileButton.isEnabled = importPhase == .idle
        modeControl.isEnabled = importPhase != .importing
    }

    private func invalidatePreview() {
        requestGeneration &+= 1
        previewTask?.cancel()
        previewTask = nil
        previewController?.cancelWorkflowPresentation()
        previewController = nil
        if importPhase != .importing {
            importPhase = .idle
            stateView.hide()
        }
        updateImportControls()
    }

    private func layoutUI() {
        let backButton = makeLegacyBarButton(
            imageSystemName: "chevron.left",
            target: self,
            action: #selector(handleBackTapped)
        )
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        scaffoldView.titleBarView.setTitle(L10n.SourceImport.title)
        scaffoldView.titleBarView.setLeftViews([backButton])
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        modeControl.accessibilityIdentifier = UIIdentifiers.SourceImport.modeControl
        urlField.accessibilityIdentifier = UIIdentifiers.SourceImport.urlField
        textView.accessibilityIdentifier = UIIdentifiers.SourceImport.jsonField
        textView.accessibilityLabel = L10n.SourceImport.jsonMode
        fileButton.accessibilityIdentifier = UIIdentifiers.SourceImport.fileSelectButton
        fileNameLabel.accessibilityIdentifier = UIIdentifiers.SourceImport.fileNameLabel
        scrollView.accessibilityIdentifier = UIIdentifiers.SourceImport.contentScroll
        scrollView.keyboardDismissMode = .interactive
        contentStack.axis = .vertical
        contentStack.spacing = AppUI.Spacing.medium
        contentStack.alignment = .fill
        footerBar.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.96)
        footerBar.layer.shadowColor = UIColor.black.withAlphaComponent(0.08).cgColor
        footerBar.layer.shadowOpacity = 1
        footerBar.layer.shadowRadius = 8
        footerBar.layer.shadowOffset = CGSize(width: 0, height: -2)
        cancelButton.accessibilityIdentifier = UIIdentifiers.SourceImport.cancelButton
        submitButton.accessibilityIdentifier = UIIdentifiers.SourceImport.submitButton
        var cancelConfiguration = UIButton.Configuration.plain()
        cancelConfiguration.title = L10n.SourceImport.cancelAction
        cancelConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0)
        cancelButton.configuration = cancelConfiguration
        cancelButton.addTarget(self, action: #selector(handleBackTapped), for: .touchUpInside)
        var submitConfiguration = UIButton.Configuration.filled()
        submitConfiguration.title = L10n.SourceImport.importAction
        submitConfiguration.cornerStyle = .large
        submitConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 18, bottom: 10, trailing: 18)
        submitButton.configuration = submitConfiguration
        submitButton.addTarget(self, action: #selector(importTapped), for: .touchUpInside)

        scaffoldView.contentView.addSubview(scrollView)
        scaffoldView.contentView.addSubview(footerBar)
        scrollView.addSubview(contentStack)
        contentStack.addArrangedSubview(modeControl)
        contentStack.addArrangedSubview(urlField)
        contentStack.addArrangedSubview(fileButton)
        contentStack.addArrangedSubview(fileNameLabel)
        contentStack.addArrangedSubview(textView)
        footerBar.addSubview(cancelButton)
        footerBar.addSubview(submitButton)
        scaffoldView.contentView.addSubview(stateView)
        stateView.setTestingIdentifier(UIIdentifiers.SourceImport.state)

        scrollView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.bottom.equalTo(footerBar.snp.top)
        }

        contentStack.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide).inset(AppUI.Spacing.medium)
            make.width.equalTo(scrollView.frameLayoutGuide).inset(AppUI.Spacing.medium)
        }

        footerBar.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview()
            make.bottom.equalTo(view.keyboardLayoutGuide.snp.top)
        }

        cancelButton.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(AppUI.Spacing.medium)
            make.centerY.equalTo(submitButton)
        }

        submitButton.snp.makeConstraints { make in
            make.top.equalToSuperview().offset(AppUI.Spacing.small)
            make.trailing.equalToSuperview().inset(AppUI.Spacing.medium)
            make.bottom.equalToSuperview().inset(AppUI.Spacing.small)
        }

        textView.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(240)
        }

        stateView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func applyUITestDefaults() {
        modeControl.selectedSegmentIndex = preferredMode.segmentIndex
        applyImportMode()
    }

    private func bootstrapDependencies() {
        stateView.showLoading(message: L10n.SourceImport.loadingPrepare)
        switch screen.bootstrap() {
        case .success:
            stateView.hide()
            modeControl.addTarget(self, action: #selector(handleModeChanged), for: .valueChanged)
            fileButton.addTarget(self, action: #selector(selectFileTapped), for: .touchUpInside)
            applyImportMode()
        case .failure(let error):
            stateView.showMessage(
                title: L10n.SourceImport.unavailable,
                message: error.message,
                actionTitle: L10n.Common.retry
            ) { [weak self] in
                self?.bootstrapDependencies()
            }
        }
    }

    @objc private func importTapped() {
        guard isCurrentRequest(requestGeneration), importPhase == .idle, presentedViewController == nil else { return }
        let mode = ImportMode(selectedIndex: modeControl.selectedSegmentIndex)
        if mode == .url {
            let url = urlField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !url.isEmpty else {
                presentError(
                    NSError(
                        domain: "io.legado.kmp.ios",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourceUrlEmpty]
                    ))
                return
            }
            importSources(source: .url(url))
            return
        }

        if mode == .file {
            guard let selectedImportFile else {
                presentError(
                    NSError(
                        domain: "io.legado.kmp.ios",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourceFileEmpty]
                    ))
                return
            }
            importSources(source: .file(selectedImportFile))
            return
        }

        let payload = textView.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else {
            presentError(
                NSError(
                    domain: "io.legado.kmp.ios",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourcePayloadEmpty]
                ))
            return
        }
        importSources(source: .payload(payload))
    }

    private func importSources(source: ImportSource) {
        guard isCurrentRequest(requestGeneration), importPhase == .idle else { return }
        view.endEditing(true)
        importedResult = nil
        invalidatePreview()
        let generation = requestGeneration
        importPhase = .preparing
        updateImportControls()
        stateView.showLoading(message: L10n.SourceManagement.importPreviewParsing)
        previewTask = Task { @MainActor [weak self, screen] in
            do {
                try Task.checkCancellation()
                guard self?.isCurrentRequest(generation) == true else { return }
                let preview = try await screen.preparePreview(source: source)
                try Task.checkCancellation()
                guard let self, self.isCurrentRequest(generation) else { return }
                self.previewTask = nil
                self.stateView.hide()
                if preview.candidates.isEmpty {
                    self.importPhase = .idle
                    self.updateImportControls()
                    self.presentError(
                        NSError(
                            domain: "io.legado.kmp.ios",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourcePayloadInvalid]
                        ))
                } else {
                    self.showImportPreview(preview, generation: generation)
                }
            } catch {
                guard !Task.isCancelled, let self, self.isCurrentRequest(generation) else { return }
                self.previewTask = nil
                self.importPhase = .idle
                self.stateView.hide()
                self.updateImportControls()
                self.presentError(error)
            }
        }
    }

    private func showImportPreview(_ preview: SourceImportPreview, generation: Int) {
        guard isCurrentRequest(generation), presentedViewController == nil else {
            invalidatePreview()
            return
        }
        importPhase = .previewing
        updateImportControls()
        let controller = SourceImportPreviewViewController(preview: preview)
        controller.onCancel = { [weak self] in
            guard let self, self.isCurrentRequest(generation), self.importPhase == .previewing else { return }
            self.invalidatePreview()
        }
        controller.onConfirm = { [weak self, screen] sources, options in
            guard let self, self.isCurrentRequest(generation), self.importPhase == .previewing else {
                throw CancellationError()
            }
            self.importPhase = .importing
            self.updateImportControls()
            do {
                self.importedResult = try await screen.importSelected(sources: sources, options: options)
                self.importPhase = .idle
                self.updateImportControls()
            } catch {
                self.importPhase = .previewing
                self.updateImportControls()
                throw error
            }
        }
        controller.onImported = { [weak self] in
            guard let self, self.isCurrentRequest(generation), let result = self.importedResult else { return }
            self.importedResult = nil
            self.previewController = nil
            self.showImportSuccess(result: result, generation: generation)
        }
        previewController = controller
        present(controller, animated: true)
    }

    @objc private func handleModeChanged() {
        guard importPhase != .importing else { return }
        invalidatePreview()
        applyImportMode()
    }

    private func applyImportMode() {
        let mode = ImportMode(selectedIndex: modeControl.selectedSegmentIndex)
        let isUrlMode = mode == .url
        let isFileMode = mode == .file
        urlField.isHidden = !isUrlMode
        textView.isHidden = isUrlMode || isFileMode
        fileButton.isHidden = !isFileMode
        fileNameLabel.isHidden = !isFileMode
        switch mode {
        case .json:
            break
        case .url:
            break
        case .file:
            updateSelectedFileUI()
        }
    }

    private func showImportSuccess(result: SourceImportResult, generation: Int) {
        guard isCurrentRequest(generation), presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: L10n.SourceImport.successTitle,
            message: L10n.SourceImport.successMessage(
                importedCount: Int(result.importedCount),
                addedCount: Int(result.addedCount),
                updatedCount: Int(result.updatedCount),
                duplicateCount: Int(result.duplicateCount),
                invalidCount: Int(result.invalidCount)
            ),
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(title: L10n.SourceImport.stayImporting, style: .default) { [weak self] _ in
                guard let self, self.isCurrentRequest(generation) else { return }
                self.onImportCompleted?(.stay)
            })
        alert.addAction(
            UIAlertAction(title: L10n.SourceImport.openSearch, style: .default) { [weak self] _ in
                guard let self, self.isCurrentRequest(generation) else { return }
                self.popAfterImport(action: .goSearch, generation: generation)
            })
        alert.addAction(
            UIAlertAction(title: L10n.SourceImport.backToSourceManagement, style: .default) { [weak self] _ in
                guard let self, self.isCurrentRequest(generation) else { return }
                self.popAfterImport(action: .stay, generation: generation)
            })
        present(alert, animated: true)
    }

    private func popAfterImport(action: SourceImportCompletionAction, generation: Int) {
        let pop = { [weak self] in
            guard let self, self.isCurrentRequest(generation), let navigationController = self.navigationController,
                navigationController.topViewController === self
            else { return }
            let completion = self.onImportCompleted
            guard navigationController.popViewController(animated: true) === self else { return }
            let notify = { [weak navigationController] in
                guard let navigationController,
                    !navigationController.viewControllers.contains(where: { $0 === self })
                else { return }
                completion?(action)
            }
            if let coordinator = navigationController.transitionCoordinator {
                coordinator.animate(alongsideTransition: nil) { context in
                    guard !context.isCancelled else { return }
                    notify()
                }
            } else {
                notify()
            }
        }
        if let alert = presentedViewController as? UIAlertController {
            alert.dismiss(animated: true, completion: pop)
        } else if presentedViewController == nil {
            pop()
        }
    }

    @objc private func selectFileTapped() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json, .plainText], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let payload = try String(contentsOf: url, encoding: .utf8)
            selectedImportFile = ImportFileSelection(displayName: url.lastPathComponent, payload: payload)
            updateSelectedFileUI()
        } catch {
            presentError(
                NSError(
                    domain: "io.legado.kmp.ios",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: L10n.Errors.sourceFileReadFailed]
                ))
        }
    }

    private func updateSelectedFileUI() {
        fileNameLabel.text = selectedImportFile?.displayName ?? L10n.SourceImport.filePlaceholder
    }
    @objc private func handleBackTapped() {
        navigationController?.popViewController(animated: true)
    }
}
