import ImageIO
import Kingfisher
import UIKit
import UniformTypeIdentifiers
import shared

struct BookGroupEditDraft {
    let name: String
    let cover: String?
    let bookSort: Int32
    let enableRefresh: Bool
}

// Legado 5f5d314: GroupEditDialog.kt + dialog_book_group_edit.xml.
// Persistence, delete confirmation, and editor dismissal belong to the presenting picker.
@MainActor
final class BookGroupEditorViewController: UIViewController, UITextViewDelegate,
    UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate, UIGestureRecognizerDelegate
{
    var onSave: ((BookGroupEditDraft) -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    private let content: BookGroupEditorContentView
    private let coverFiles = BookGroupEditorCoverOwnership()
    private let scrollView = UIScrollView()
    private let canvas = UIView()
    private var contentHeight: NSLayoutConstraint?
    private var previousViewport = CGSize.zero
    private var shouldRevealName = false
    private var selectedSort: Int32
    private var draftCover: String?
    private var submittedDraft: BookGroupEditDraft?
    private var isBusy = false
    private var isActive = false
    private var isClosing = false
    private var hasLoadedCover = false
    private var coverGeneration = UUID()
    private var importGeneration = UUID()
    private var coverTask: Task<Void, Never>?
    private var downloadTask: DownloadTask?
    private var importTask: Task<Void, Never>?
    private weak var documentPicker: UIDocumentPickerViewController?

    init(group: BookGroup?) {
        selectedSort = BookGroupEditorSort.normalized(group?.bookSort ?? -1)
        draftCover = group?.cover
        // Android protects built-in groups; its special editable folder uses Long.MIN_VALUE.
        let showsDelete = group.map { $0.groupId > 0 || $0.groupId == Int64.min } ?? false
        let editorTitle = group == nil ? "添加分组" : "编辑分组"
        content = BookGroupEditorContentView(title: editorTitle, name: group?.groupName ?? "", showsDelete: showsDelete)
        super.init(nibName: nil, bundle: nil)
        title = editorTitle
        content.refreshControl.isSelected = group?.enableRefresh ?? true
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        coverTask?.cancel()
        downloadTask?.cancel()
        importTask?.cancel()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard !isBusy, !isClosing else { return nil }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        escape.wantsPriorityOverSystemBehavior = true
        escape.discoverabilityTitle = "取消"
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        updateSortMenu()
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing else { return }
        isActive = true
        if !hasLoadedCover {
            hasLoadedCover = true
            loadCoverPreview()
            becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: content)
        }
        updateInteraction()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isLeavingPresentation { closeDraft() }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isLeavingPresentation || (presentingViewController == nil && parent == nil) { closeDraft() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = scrollView.bounds.width * 0.9
        guard width > 0 else { return }
        let height = content.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        if contentHeight?.constant != height {
            contentHeight?.constant = height
            view.setNeedsLayout()
        }
        if previousViewport != scrollView.bounds.size {
            previousViewport = scrollView.bounds.size
            shouldRevealName = content.nameTextView.isFirstResponder
        }
        if shouldRevealName {
            shouldRevealName = false
            scrollView.scrollRectToVisible(
                content.nameTextView.convert(content.nameTextView.bounds, to: canvas)
                    .insetBy(dx: 0, dy: -12), animated: false)
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canUseUI, !isBusy, presentedViewController == nil else { return false }
        cancel()
        return true
    }

    /// Requests are latched before callbacks. Reset this after a cancelled delete confirmation or failed save.
    func setBusy(_ busy: Bool) {
        isBusy = busy
        if !busy {
            submittedDraft = nil
            coverFiles.releaseSubmission()
            if isClosing { coverFiles.discardUnused() }
        }
        if busy { viewIfLoaded?.endEditing(true) }
        updateInteraction()
    }

    func showError(_ message: String) {
        setBusy(false)
        guard !isClosing else { return }
        loadViewIfNeeded()
        content.setError(message)
        if canUseUI { UIAccessibility.post(notification: .announcement, argument: message) }
    }

    /// Call after onSave's persistence succeeds, BEFORE releasing busy or dismissing this editor.
    /// Marks that submitted cover, not a later preview; never removes the group's previous cover.
    func markCoverCommitted() {
        guard submittedDraft != nil else { return }
        coverFiles.commitSubmission()
        submittedDraft = nil
    }

    private var isLeavingPresentation: Bool {
        var controller: UIViewController? = self
        while let current = controller {
            if current.isBeingDismissed || current.isMovingFromParent { return true }
            controller = current.parent ?? current.presentingViewController
        }
        return false
    }

    private var canUseUI: Bool {
        isActive && !isClosing && !isLeavingPresentation && viewIfLoaded?.window != nil
            && viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }

    private var canEdit: Bool {
        canUseUI && !isBusy && importTask == nil && documentPicker == nil && presentedViewController == nil
    }

    private func configureViews() {
        view.backgroundColor = .clear
        view.accessibilityViewIsModal = true
        let backdrop = UIControl()
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        backdrop.accessibilityElementsHidden = true
        backdrop.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        scrollView.keyboardDismissMode = .interactive
        scrollView.delaysContentTouches = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        let outsideTap = UITapGestureRecognizer(target: self, action: #selector(cancel))
        outsideTap.delegate = self
        outsideTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(outsideTap)
        for child in [backdrop, scrollView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.isAccessibilityElement = false
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(canvas)
        canvas.addSubview(content)
        let preferredHeight = canvas.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        preferredHeight.priority = .defaultLow
        let editorHeight = content.heightAnchor.constraint(equalToConstant: 320)
        contentHeight = editorHeight
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
            canvas.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            canvas.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),
            preferredHeight,
            content.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
            content.widthAnchor.constraint(equalTo: canvas.widthAnchor, multiplier: 0.9),
            content.topAnchor.constraint(greaterThanOrEqualTo: canvas.topAnchor, constant: 8),
            content.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -8),
            editorHeight,
        ])
        content.onLayoutChange = { [weak self] in self?.viewIfLoaded?.setNeedsLayout() }
        content.nameTextView.delegate = self
        content.coverButton.addTarget(self, action: #selector(pickCover), for: .touchUpInside)
        content.refreshControl.addTarget(self, action: #selector(toggleRefresh), for: .touchUpInside)
        content.deleteButton.addTarget(self, action: #selector(requestDelete), for: .touchUpInside)
        content.cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        content.confirmButton.addTarget(self, action: #selector(save), for: .touchUpInside)
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        content.setBusy(isBusy || isClosing, importing: importTask != nil || documentPicker != nil)
    }

    func gestureRecognizer(_: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        touch.view === canvas || touch.view === scrollView
    }

    private func updateSortMenu() {
        content.setSort(selectedSort)
        let actions = BookGroupEditorSort.titles.enumerated().map { index, title in
            let value = Int32(index) - 1
            return UIAction(title: title, state: value == selectedSort ? .on : .off) { [weak self] _ in
                guard let self, self.canUseUI, !self.isBusy, self.importTask == nil else { return }
                self.selectedSort = value
                self.content.setError(nil)
                self.updateSortMenu()
            }
        }
        content.sortButton.menu = UIMenu(options: .singleSelection, children: actions)
    }

    @objc private func toggleRefresh() {
        guard canEdit else { return }
        content.refreshControl.isSelected.toggle()
        content.setError(nil)
    }

    @objc private func save() {
        guard canEdit, let onSave else { return }
        let name = content.nameTextView.text ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showError("分组名称不能为空")
            content.nameTextView.becomeFirstResponder()
            return
        }
        let draft = BookGroupEditDraft(
            name: name, cover: draftCover, bookSort: selectedSort,
            enableRefresh: content.refreshControl.isSelected)
        content.setError(nil)
        submittedDraft = draft
        coverFiles.reserveSubmission(path: draft.cover)
        setBusy(true)
        onSave(draft)
    }

    @objc private func requestDelete() {
        guard canEdit, !content.deleteButton.isHidden, let onDelete else { return }
        content.setError(nil)
        setBusy(true)
        onDelete()
    }

    @objc private func cancel() {
        guard canUseUI, !isBusy, presentedViewController == nil, let onCancel else { return }
        closeDraft()
        onCancel()
    }

    private func closeDraft() {
        guard !isClosing else { return }
        isClosing = true
        isActive = false
        importGeneration = UUID()
        importTask?.cancel()
        importTask = nil
        documentPicker?.delegate = nil
        documentPicker?.presentationController?.delegate = nil
        documentPicker = nil
        cancelCoverPreview()
        coverFiles.discardUnused()
        viewIfLoaded?.endEditing(true)
        onSave = nil
        onDelete = nil
        onCancel = nil
        updateInteraction()
    }

    func textViewDidBeginEditing(_: UITextView) {
        content.setNameEditing(true)
        shouldRevealName = true
        view.setNeedsLayout()
    }

    func textViewDidEndEditing(_: UITextView) { content.setNameEditing(false) }

    func textViewDidChange(_: UITextView) {
        content.setNameEditing(true)
        content.setError(nil)
    }

    @objc private func pickCover() {
        guard canEdit else { return }
        view.endEditing(true)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        documentPicker = picker
        updateInteraction()
        present(picker, animated: true)
        picker.presentationController?.delegate = self
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard documentPicker === controller else { return }
        documentPicker = nil
        updateInteraction()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === documentPicker else { return }
        documentPicker = nil
        updateInteraction()
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard documentPicker === controller, !isClosing, !isBusy, importTask == nil else { return }
        documentPicker = nil
        guard let url = urls.first else {
            updateInteraction()
            return
        }
        let generation = UUID()
        importGeneration = generation
        let worker = Task.detached(priority: .userInitiated) { try BookGroupEditorCoverFiles.copy(from: url) }
        importTask = Task { [weak self] in
            let result = await withTaskCancellationHandler {
                await worker.result
            } onCancel: {
                worker.cancel()
            }
            guard let self, !Task.isCancelled, self.importGeneration == generation,
                !self.isClosing, !self.isLeavingPresentation
            else {
                if case .success(let prepared) = result { try? FileManager.default.removeItem(at: prepared.url) }
                return
            }
            self.importTask = nil
            switch result {
            case .success(let prepared):
                self.cancelCoverPreview()
                self.coverFiles.adopt(prepared.url)
                self.draftCover = prepared.url.path
                self.content.setCoverImage(prepared.preview)
                self.content.setError(nil)
            case .failure(let error):
                if !(error is CancellationError) { self.showError(error.localizedDescription) }
            }
            self.updateInteraction()
        }
        updateInteraction()
    }

    private func loadCoverPreview() {
        cancelCoverPreview()
        guard let cover = draftCover, !cover.isEmpty, cover != "use_default_cover" else { return }
        let generation = coverGeneration
        content.setCoverLoading(true)
        if let url = BookCoverImageLoader.localImageURL(cover) {
            let worker = Task.detached(priority: .userInitiated) { BookGroupEditorCoverFiles.preview(at: url) }
            coverTask = Task { [weak self] in
                let image = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: {
                    worker.cancel()
                }
                guard !Task.isCancelled else { return }
                self?.acceptCover(image, path: cover, generation: generation)
            }
        } else if let url = URL(string: cover), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            // Preview only the already-persisted group URL; no cover search or additional sources.
            downloadTask = KingfisherManager.shared.retrieveImage(
                with: url, options: [.processor(DownsamplingImageProcessor(size: CGSize(width: 180, height: 252)))]
            ) {
                [weak self] result in
                let image = try? result.get().image
                Task { @MainActor [weak self] in self?.acceptCover(image, path: cover, generation: generation) }
            }
        } else {
            content.setCoverLoading(false)
        }
    }

    private func acceptCover(_ image: UIImage?, path: String, generation: UUID) {
        guard !isClosing, !isLeavingPresentation, coverGeneration == generation, draftCover == path else { return }
        coverTask = nil
        downloadTask = nil
        content.setCoverLoading(false)
        content.setCoverImage(image)
    }

    private func cancelCoverPreview() {
        coverGeneration = UUID()
        coverTask?.cancel()
        coverTask = nil
        downloadTask?.cancel()
        downloadTask = nil
        content.setCoverLoading(false)
    }
}

private enum BookGroupEditorCoverFiles {
    struct PreparedCover {
        let url: URL
        let preview: UIImage
    }

    static func preview(at url: URL) -> UIImage? {
        guard !Task.isCancelled, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 520,
                ] as CFDictionary), !Task.isCancelled
        else { return nil }
        return UIImage(cgImage: image)
    }

    static func copy(from url: URL) throws -> PreparedCover {
        guard url.isFileURL else { throw unreadableImage() }
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordinationError: NSError?
        var result: Result<PreparedCover, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) {
            readableURL in
            result = Result {
                try Task.checkCancellation()
                guard let source = CGImageSourceCreateWithURL(readableURL as CFURL, nil),
                    CGImageSourceGetCount(source) > 0, let identifier = CGImageSourceGetType(source),
                    let type = UTType(identifier as String), type.conforms(to: .image)
                else { throw unreadableImage() }
                let manager = FileManager.default
                let support = try manager.url(
                    for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let directory = support.appendingPathComponent("covers", isDirectory: true)
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let destination = directory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(type.preferredFilenameExtension ?? "img")
                do {
                    try manager.copyItem(at: readableURL, to: destination)
                    try Task.checkCancellation()
                    guard let image = preview(at: destination) else { throw unreadableImage() }
                    return PreparedCover(url: destination, preview: image)
                } catch {
                    try? manager.removeItem(at: destination)
                    throw error
                }
            }
        }
        if let result { return try result.get() }
        throw coordinationError ?? NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError)
    }

    private static func unreadableImage() -> NSError {
        NSError(
            domain: "BookGroupEditorCover", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "所选文件不是可读取的图片。"])
    }
}

// Tracks only UUID copies created by this editor, never existing group covers or the user's source file.
private final class BookGroupEditorCoverOwnership {
    private var files: Set<URL> = []
    private var submitted: URL?

    deinit {
        for url in files where url != submitted { try? FileManager.default.removeItem(at: url) }
    }

    func adopt(_ url: URL) {
        files.insert(url)
        discardUnused(keeping: url)
    }

    func reserveSubmission(path: String?) {
        submitted = files.first { $0.path == path || $0.absoluteString == path }
    }

    func releaseSubmission() { submitted = nil }

    func commitSubmission() {
        if let submitted { files.remove(submitted) }
        submitted = nil
    }

    func discardUnused(keeping retained: URL? = nil) {
        let discarded = files.filter { $0 != retained && $0 != submitted }
        for url in discarded {
            try? FileManager.default.removeItem(at: url)
            files.remove(url)
        }
        // A submitted copy survives forced closure until the picker reports the save outcome.
    }
}
