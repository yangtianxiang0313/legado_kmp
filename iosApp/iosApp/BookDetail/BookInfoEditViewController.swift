import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class BookInfoEditViewController: UIViewController, UITextFieldDelegate, UITextViewDelegate,
    UIDocumentPickerDelegate, ChangeCoverDelegate, UIAdaptivePresentationControllerDelegate
{
    typealias CoverSearchSessionFactory = (
        _ onResult: @escaping (CoverSearchResult) -> Void,
        _ onProgress: @escaping (CoverSearchProgress) -> Void,
        _ onFinished: @escaping () -> Void
    ) async throws -> CoverSearchSession

    private let initialBook: Book
    private let saveEditedBook: (String, String, String, String, Int32) async throws -> Book
    private let createCoverSearchSession: CoverSearchSessionFactory?
    private let onSave: (Book) -> Void
    private var canEditBookType = true
    private var selectedTypeIndex: Int32
    private var isSaving = false
    private var isImportingCover = false
    private var importTask: Task<Void, Never>?
    private var importedCoverFiles: Set<URL> = []
    private var hasDeparted = false
    private var isClosing = false
    private var hasSaved = false
    private var pendingSaveError: String?
    private var isVisible = false
    private var isDepartingTransition = false
    private var sceneObservers: [NSObjectProtocol] = []
    private var previousPopGestureEnabled: Bool?
    private var previousDismissalLocks: (editor: Bool, navigation: Bool)?

    private let form = BookInfoEditFormView()
    private let topBar = AndroidEditorTitleBar(title: "书籍信息编辑")
    private var previousNavigationBarHidden: Bool?
    private lazy var coverPreview = BookInfoEditCoverPreview(
        imageView: form.coverImageView, spinner: form.coverSpinner, placeholder: form.defaultCoverView)
    private var nameField: UITextField { form.nameField }
    private var authorField: UITextField { form.authorField }
    private var typeButton: BookInfoEditTypeButton { form.typeButton }
    private var coverUrlTextView: BookInfoEditGrowingTextView { form.coverUrlTextView }
    private var introTextView: BookInfoEditGrowingTextView { form.introTextView }

    init(
        book: Book,
        saveEditedBook: @escaping (String, String, String, String, Int32) async throws -> Book,
        createCoverSearchSession: CoverSearchSessionFactory? = nil,
        onSave: @escaping (Book) -> Void
    ) {
        initialBook = book
        self.saveEditedBook = saveEditedBook
        self.createCoverSearchSession = createCoverSearchSession
        self.onSave = onSave
        // Book's computed properties also recognize legacy enum values, unlike raw bit checks.
        selectedTypeIndex = book.isImage ? 2 : (book.isAudio ? 1 : 0)
        super.init(nibName: nil, bundle: nil)
    }

    convenience init(
        book: Book,
        saveBookInfo: @escaping (String?, String?, String?, String?) async throws -> Book,
        onSave: @escaping (Book) -> Void
    ) {
        self.init(
            book: book,
            saveEditedBook: { name, author, coverUrl, intro, _ in
                try await saveBookInfo(name, author, coverUrl, intro)
            },
            onSave: onSave
        )
        // The legacy callback cannot persist type changes, so it must not offer them.
        canEditBookType = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        importTask?.cancel()
        for observer in sceneObservers { NotificationCenter.default.removeObserver(observer) }
        for url in importedCoverFiles { try? FileManager.default.removeItem(at: url) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.tintColor = AndroidReplicaTheme.accent
        configureNavigation()
        configureFields()
        configureLayout()
        updateInteractionState()
        refreshCoverPreview()
        sceneObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.isVisible, !self.hasDeparted { self.coverPreview.resume() }
                    self.finishSavePresentation()
                }
            })
        sceneObservers.append(
            NotificationCenter.default.addObserver(
                forName: UIScene.willDeactivateNotification, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, notification.object as? UIScene === self.viewIfLoaded?.window?.windowScene else {
                        return
                    }
                    self.coverPreview.cancel()
                    self.typeButton.dismissPopup()
                }
            })
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
        navigationController?.presentationController?.delegate = self
        isVisible = true
        isDepartingTransition = false
        if !hasDeparted {
            refreshCoverPreview()
            coverPreview.resume()
        }
        finishSavePresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        revealActiveEditor()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isVisible = false
        coverPreview.cancel()
        typeButton.dismissPopup()
        if isDepartingTransition || isBeingDismissed || isMovingFromParent
            || navigationController?.isBeingDismissed == true
        {
            leaveEditor()
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if previousNavigationBarHidden == nil {
            previousNavigationBarHidden = navigationController?.isNavigationBarHidden
        }
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isDepartingTransition = isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true
        typeButton.dismissPopup()
        if isDepartingTransition,
            let previousNavigationBarHidden
        {
            navigationController?.setNavigationBarHidden(previousNavigationBarHidden, animated: animated)
        }
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        if parent == nil { leaveEditor() }
    }

    private func configureNavigation() {
        title = "书籍信息编辑"
        navigationItem.largeTitleDisplayMode = .never
        topBar.backButton.accessibilityIdentifier = "bookInfoEdit.back"
        topBar.saveButton.accessibilityIdentifier = "bookInfoEdit.save"
        topBar.backButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)
        topBar.saveButton.addTarget(self, action: #selector(handleSave), for: .touchUpInside)
    }

    private func configureFields() {
        nameField.text = initialBook.name
        authorField.text = initialBook.author
        for field in [nameField, authorField] {
            field.delegate = self
            field.returnKeyType = .next
            field.addTarget(self, action: #selector(fieldDidBeginEditing), for: .editingDidBegin)
            field.addTarget(self, action: #selector(coverMetadataChanged), for: .editingChanged)
        }
        coverUrlTextView.text = initialBook.displayCoverUrl ?? ""
        introTextView.text = initialBook.displayIntro ?? ""
        coverUrlTextView.delegate = self
        introTextView.delegate = self
        form.setCoverSourceAvailable(createCoverSearchSession != nil)
        form.localCoverButton.addTarget(self, action: #selector(selectLocalCover), for: .touchUpInside)
        form.coverSourceButton.addTarget(self, action: #selector(changeCoverSource), for: .touchUpInside)
        form.refreshCoverButton.addTarget(self, action: #selector(handleRefreshCover), for: .touchUpInside)
        typeButton.onSelectionChanged = { [weak self] index in
            guard let self, self.canEdit, self.canEditBookType else { return }
            self.selectedTypeIndex = Int32(index)
            self.typeButton.setSelectedIndex(index)
        }
        typeButton.setSelectedIndex(Int(selectedTypeIndex))
        form.refreshAppearanceAndFields()
    }

    private func configureLayout() {
        let toolbarBackground = UIView()
        toolbarBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground
        for child in [toolbarBackground, topBar, form] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbarBackground.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            form.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            form.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    // MARK: - Keyboard

    @objc private func fieldDidBeginEditing() { revealActiveEditor() }

    @objc private func coverMetadataChanged() { refreshCoverPreview() }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === nameField {
            authorField.becomeFirstResponder()
        } else {
            coverUrlTextView.becomeFirstResponder()
        }
        return false
    }

    func textViewDidBeginEditing(_ textView: UITextView) { revealActiveEditor() }

    func textViewDidChange(_ textView: UITextView) {
        textView.invalidateIntrinsicContentSize()
        view.layoutIfNeeded()
        revealActiveEditor()
    }

    func textViewDidChangeSelection(_ textView: UITextView) { revealActiveEditor() }

    private func revealActiveEditor() {
        guard !isSaving else { return }
        form.revealActiveEditor()
    }

    // MARK: - Cover drafts

    @objc private func selectLocalCover() {
        guard canEdit, presentedViewController == nil else { return }
        view.endEditing(true)
        typeButton.dismissPopup()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !isSaving, !isImportingCover, !hasDeparted, !isClosing, !hasSaved,
            let sourceURL = urls.first
        else { return }
        isImportingCover = true
        updateInteractionState()
        importTask = Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try BookInfoEditCoverFiles.copyCover(from: sourceURL) }
            }.value
            guard let self, !Task.isCancelled, !self.hasDeparted else {
                if case .success(let url) = result { try? FileManager.default.removeItem(at: url) }
                return
            }
            self.isImportingCover = false
            self.importTask = nil
            self.updateInteractionState()
            switch result {
            case .success(let url):
                self.importedCoverFiles.insert(url)
                self.coverUrlTextView.text = url.path
                self.refreshCoverPreview()
            case .failure(let error):
                self.showError(title: "选择封面失败", message: error.userFacingMessage)
            }
        }
    }

    @objc private func changeCoverSource() {
        guard canEdit, presentedViewController == nil,
            let createCoverSearchSession
        else { return }
        view.endEditing(true)
        typeButton.dismissPopup()
        let picker = ChangeCoverViewController(
            bookURL: initialBook.bookUrl,
            bookName: nameField.text ?? "",
            bookAuthor: authorField.text ?? "",
            originalCoverUrl: coverUrlTextView.text ?? "",
            sessionFactory: createCoverSearchSession
        )
        picker.delegate = self
        present(UINavigationController(rootViewController: picker), animated: true)
    }

    func changeCoverDidSelect(_ coverUrl: String) {
        guard !isSaving, !isImportingCover, !hasDeparted, !isClosing, !hasSaved else { return }
        coverUrlTextView.text = coverUrl
        refreshCoverPreview()
    }

    @objc private func handleRefreshCover() {
        guard canEdit, presentedViewController == nil else { return }
        view.endEditing(true)
        typeButton.dismissPopup()
        refreshCoverPreview(reportFailure: true)
    }

    private func refreshCoverPreview(reportFailure: Bool = false) {
        guard !hasDeparted, !isClosing else { return }
        coverPreview.refresh(
            book: initialBook, draftCoverURL: coverUrlTextView.text ?? "",
            name: nameField.text ?? "", author: authorField.text ?? "", force: reportFailure,
            onFailure: reportFailure
                ? { [weak self] in
                    guard let self, self.canEdit, self.presentedViewController == nil else { return }
                    self.showError(title: "封面加载失败", message: "无法加载当前封面，请检查封面地址后重试。")
                } : nil)
    }

    private func removeUnusedImportedCovers(keeping path: String? = nil) {
        for url in importedCoverFiles where path != url.path && path != url.absoluteString {
            try? FileManager.default.removeItem(at: url)
        }
        importedCoverFiles.removeAll()
    }

    // MARK: - Save and dismissal

    @objc private func handleSave() {
        guard canEdit, presentedViewController == nil else { return }
        view.endEditing(true)
        typeButton.dismissPopup()
        let name = nameField.text ?? ""
        let author = authorField.text ?? ""
        let coverUrl = coverUrlTextView.text ?? ""
        let intro = introTextView.text ?? ""
        // BookInfoEditActivity.saveData maps the fourth "File" entry through its text fallback.
        let typeIndex = selectedTypeIndex == 1 || selectedTypeIndex == 2 ? selectedTypeIndex : 0
        pendingSaveError = nil
        isSaving = true
        updateInteractionState()
        Task { @MainActor [self] in
            do {
                // Empty strings and whitespace are intentional edits; shared normalizes original values.
                let updated = try await saveEditedBook(name, author, coverUrl, intro, typeIndex)
                removeUnusedImportedCovers(keeping: updated.displayCoverUrl)
                isSaving = false
                hasSaved = true
                updateInteractionState()
                onSave(updated)
                finishSavePresentation()
            } catch {
                isSaving = false
                updateInteractionState()
                if hasDeparted {
                    removeUnusedImportedCovers()
                } else {
                    pendingSaveError = error.userFacingMessage
                    finishSavePresentation()
                }
            }
        }
    }

    private func updateInteractionState() {
        let busy = isSaving || isImportingCover || hasSaved
        form.setBusy(busy)
        typeButton.isEnabled = !busy && !hasDeparted && canEditBookType
        topBar.setBusy(busy)
        if busy {
            if previousDismissalLocks == nil {
                previousDismissalLocks = (isModalInPresentation, navigationController?.isModalInPresentation ?? false)
                previousPopGestureEnabled = navigationController?.interactivePopGestureRecognizer?.isEnabled
            }
            isModalInPresentation = true
            navigationController?.isModalInPresentation = true
            navigationController?.interactivePopGestureRecognizer?.isEnabled = false
        } else {
            restoreNavigationInteraction()
        }
    }

    private func restoreNavigationInteraction() {
        if let locks = previousDismissalLocks {
            isModalInPresentation = locks.editor
            navigationController?.isModalInPresentation = locks.navigation
            previousDismissalLocks = nil
        }
        if let wasEnabled = previousPopGestureEnabled {
            navigationController?.interactivePopGestureRecognizer?.isEnabled = wasEnabled
            previousPopGestureEnabled = nil
        }
    }

    @objc private func handleCancel() {
        guard canEdit, presentedViewController == nil else { return }
        view.endEditing(true)
        coverPreview.cancel()
        typeButton.dismissPopup()
        removeUnusedImportedCovers()
        closeEditor()
    }

    private func closeEditor() {
        guard isActuallyVisible, !isClosing else { return }
        isClosing = true
        if let navigationController, navigationController.viewControllers.first !== self {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        if typeButton.dismissPopup() { return true }
        guard canEdit, presentedViewController == nil else { return false }
        handleCancel()
        return true
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        !isSaving && !isImportingCover && !hasSaved && !hasDeparted && !isClosing
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        leaveEditor()
    }

    private var isActuallyVisible: Bool {
        isVisible && !hasDeparted && !isBeingDismissed && !isMovingFromParent
            && !isBeingPresented && navigationController?.isBeingPresented != true
            && navigationController?.isBeingDismissed != true
            && (navigationController == nil || navigationController?.topViewController === self)
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var canEdit: Bool { isActuallyVisible && !isSaving && !isImportingCover && !hasSaved && !isClosing }

    private func leaveEditor() {
        hasDeparted = true
        isVisible = false
        pendingSaveError = nil
        coverPreview.cancel()
        typeButton.dismissPopup()
        importTask?.cancel()
        // An authorized save still owns its draft files until storage returns.
        if !isSaving { removeUnusedImportedCovers() }
        restoreNavigationInteraction()
    }

    private func finishSavePresentation() {
        guard isActuallyVisible, !isClosing, presentedViewController == nil else { return }
        if hasSaved {
            closeEditor()
        } else if let message = pendingSaveError {
            pendingSaveError = nil
            showError(title: L10n.BookDetail.editBookInfoFailed, message: message)
        }
    }

    private func showError(title: String, message: String) {
        guard isActuallyVisible, !isClosing, presentedViewController == nil else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.Common.close, style: .default))
        present(alert, animated: true)
    }

}
