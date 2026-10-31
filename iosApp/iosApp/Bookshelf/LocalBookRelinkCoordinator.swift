import UIKit
import UniformTypeIdentifiers
import shared

@MainActor
final class LocalBookRelinkCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    private final class Session {
        let expectedBook: Book
        weak var scene: UIWindowScene?
        var isCancelled = false

        init(book: Book, scene: UIWindowScene) {
            expectedBook = book
            self.scene = scene
        }
    }

    private struct Selection {
        let lease: SandboxFileReadLease
        let activityID: UUID
    }

    private weak var presenter: UIViewController?
    private let currentBook: () -> Book?
    private let canPresent: () -> Bool
    private let canContinue: (UIViewController?) -> Bool
    private let waitForDetailLoad: () async -> Void
    private let onBusyChange: (Bool) -> Void
    private let onCommitted: (Book) -> Void
    private var session: Session?
    private var task: Task<Void, Never>?
    private var activityID = UUID()
    private var confirmation: UIAlertController?
    private var confirmationContinuation: CheckedContinuation<Bool, Never>?
    private var picker: UIDocumentPickerViewController?
    private var pickerContinuation: CheckedContinuation<Selection?, Never>?
    private var progress: LocalBookRelinkProgressViewController?

    init(
        presenter: UIViewController?, currentBook: @escaping () -> Book?, canPresent: @escaping () -> Bool,
        canContinue: @escaping (UIViewController?) -> Bool, waitForDetailLoad: @escaping () async -> Void,
        onBusyChange: @escaping (Bool) -> Void, onCommitted: @escaping (Book) -> Void
    ) {
        self.presenter = presenter
        self.currentBook = currentBook
        self.canPresent = canPresent
        self.canContinue = canContinue
        self.waitForDetailLoad = waitForDetailLoad
        self.onBusyChange = onBusyChange
        self.onCommitted = onCommitted
    }

    func present() {
        guard session == nil, task == nil, canPresent(), let presenter,
            presenter.presentedViewController == nil,
            let scene = presenter.viewIfLoaded?.window?.windowScene, scene.activationState == .foregroundActive,
            let book = currentBook(), book.isLocal, !book.isNotShelf
        else { return }
        let context = Session(book: book, scene: scene)
        session = context
        let activity = activityID
        onBusyChange(true)
        // Own the coordinator until the shared terminal result and file-lease cleanup have finished.
        task = Task { [self] in await run(context, activity: activity) }
    }

    func cancel() {
        guard let session else { return }
        session.isCancelled = true
        task?.cancel()
        resolveConfirmation(false)
        resolvePicker(nil)
        progress?.setCancelling()
    }

    func sceneDidDeactivate() {
        activityID = UUID()
        // An in-flight commit may finish, but pending presentation work cannot survive a new activity.
        if confirmationContinuation != nil { cancel() }
    }

    private func run(_ context: Session, activity: UUID) async {
        var prepared: PreparedLocalBookFile?
        var selection: Selection?
        var committed: Book?
        var failure: Error?
        var operationActivity = activity
        do {
            try validate(context, activity: activity)
            guard await confirm(context, activity: activity) else { throw CancellationError() }
            try validate(context, activity: activity)
            selection = await selectFile()
            guard let selection else { throw CancellationError() }
            operationActivity = selection.activityID
            try validate(context, activity: operationActivity)
            guard LocalBookFormats.bookExtensions.contains(selection.lease.source.pathExtension.lowercased()) else {
                throw NSError(
                    domain: "io.legado.local-book-relink", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "请选择 TXT、EPUB、UMD、MOBI、AZW、AZW3 或 PDF 原文件，不支持压缩包"])
            }
            await waitForDetailLoad()
            try validate(context, activity: operationActivity)
            try await showProgress(context, activity: operationActivity, fileName: selection.lease.source.lastPathComponent)
            let file = try await LocalBookFileStore.prepare(from: selection.lease.source)
            prepared = file
            try validate(context, activity: operationActivity, modal: progress)
            try SharedRuntime.bootstrap().get()
            let facade = try LocalBookRelinkFacade.companion.create()
            progress?.setStatus("正在解析原文件")
            let updated = try await SharedLocalBookImportAsync.value { onResult in
                facade.prepareRelinkRequest(
                    bookUrl: context.expectedBook.bookUrl, path: file.url.path, onResult: onResult)
            }
            // An acknowledged shared commit wins over cancellation, scene changes and navigation.
            await LocalBookFileStore.retain(file)
            prepared = nil
            committed = updated
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled, !context.isCancelled { failure = error }
        }
        // The shared async bridge does not return on cancellation until Kotlin reaches a terminal state.
        if let prepared { await LocalBookFileStore.discard(prepared) }
        selection?.lease.cancel()
        if let progress {
            progress.onCancel = nil
            await Self.dismiss(progress)
            self.progress = nil
        }
        guard session === context else { return }
        if let committed, committed.bookUrl == context.expectedBook.bookUrl, isSameBook(context) {
            onCommitted(committed)
        }
        let shouldReport = failure != nil && accepts(context, activity: operationActivity)
        session = nil
        task = nil
        onBusyChange(false)
        if shouldReport, canPresent(), let presenter, presenter.presentedViewController == nil,
            presenter.viewIfLoaded?.window?.windowScene === context.scene,
            context.scene?.activationState == .foregroundActive, UIApplication.shared.applicationState == .active,
            let failure
        {
            presenter.showTransientMessage(failure.userFacingMessage)
        }
    }

    private func confirm(_ context: Session, activity: UUID) async -> Bool {
        guard let presenter else { return false }
        let alert = UIAlertController(
            title: "重新选择原文件", message: "请选择这本书的原文件，而非其他版本。", preferredStyle: .alert)
        alert.view.accessibilityIdentifier = "bookDetail.relink.confirmation"
        alert.addAction(
            UIAlertAction(title: L10n.Common.cancel, style: .cancel) { [weak self, weak alert] _ in
                guard let self, let alert, self.session === context, self.confirmation === alert else { return }
                self.resolveConfirmation(false)
            })
        alert.addAction(
            UIAlertAction(title: "重新选择原文件", style: .default) { [weak self, weak alert] _ in
                guard let self, let alert, self.confirmation === alert else { return }
                self.resolveConfirmation(
                    self.session === context && !context.isCancelled && self.activityID == activity
                        && self.hasActiveOwner(context, modal: alert))
            })
        confirmation = alert
        let confirmed = await withCheckedContinuation { continuation in
            confirmationContinuation = continuation
            presenter.present(alert, animated: true)
        }
        await Self.dismiss(alert)
        if confirmation === alert { confirmation = nil }
        return confirmed
    }

    private func selectFile() async -> Selection? {
        guard let presenter else { return nil }
        var types: [UTType] = []
        for fileExtension in ["txt", "epub", "umd", "mobi", "azw", "azw3", "pdf"] {
            let type = UTType(filenameExtension: fileExtension) ?? .data
            if !types.contains(type) { types.append(type) }
        }
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = self
        controller.view.accessibilityIdentifier = "bookDetail.relink.picker"
        picker = controller
        let selection: Selection? = await withCheckedContinuation { continuation in
            pickerContinuation = continuation
            presenter.present(controller, animated: true)
            controller.presentationController?.delegate = self
        }
        await Self.dismiss(controller)
        if picker === controller { picker = nil }
        return selection
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard picker === controller, pickerContinuation != nil else { return }
        guard let context = session, !context.isCancelled, urls.count == 1, let url = urls.first,
            isSameBook(context), hasActiveOwner(context, modal: controller)
        else {
            resolvePicker(nil)
            return
        }
        // Keep the delivered security scope alive before UIKit releases its picker callback.
        resolvePicker(Selection(lease: SandboxFileReadLease(url), activityID: activityID))
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard picker === controller else { return }
        resolvePicker(nil)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let controller = presentationController.presentedViewController
        if controller === picker { resolvePicker(nil) }
        if controller === confirmation { resolveConfirmation(false) }
        if controller === progress { cancel() }
    }

    private func resolveConfirmation(_ confirmed: Bool) {
        let continuation = confirmationContinuation
        confirmationContinuation = nil
        continuation?.resume(returning: confirmed)
    }

    private func resolvePicker(_ selection: Selection?) {
        let continuation = pickerContinuation
        pickerContinuation = nil
        continuation?.resume(returning: selection)
    }

    private func showProgress(_ context: Session, activity: UUID, fileName: String) async throws {
        try validate(context, activity: activity)
        guard let presenter else { throw CancellationError() }
        let controller = LocalBookRelinkProgressViewController(fileName: fileName)
        controller.onCancel = { [weak self, weak controller] in
            guard let self, let controller, self.session === context, self.progress === controller else { return }
            self.cancel()
        }
        progress = controller
        await withCheckedContinuation { continuation in
            presenter.present(controller, animated: true) { continuation.resume() }
            controller.presentationController?.delegate = self
        }
        try validate(context, activity: activity, modal: controller)
    }

    private func validate(_ context: Session, activity: UUID, modal: UIViewController? = nil) throws {
        try Task.checkCancellation()
        guard accepts(context, activity: activity, modal: modal) else { throw CancellationError() }
    }

    private func accepts(_ context: Session, activity: UUID, modal: UIViewController? = nil) -> Bool {
        session === context && !context.isCancelled && activityID == activity && isSameBook(context)
            && hasActiveOwner(context, modal: modal) && canContinue(modal)
    }

    private func isSameBook(_ context: Session) -> Bool {
        guard let book = currentBook() else { return false }
        return book.isLocal && !book.isNotShelf && book.bookUrl == context.expectedBook.bookUrl
            && book.origin == context.expectedBook.origin
    }

    private func hasActiveOwner(_ context: Session, modal: UIViewController?) -> Bool {
        guard let presenter, let scene = context.scene,
            presenter.navigationController?.topViewController === presenter,
            !presenter.isMovingFromParent, !presenter.isBeingDismissed,
            scene.activationState == .foregroundActive, UIApplication.shared.applicationState == .active
        else { return false }
        let window = modal?.viewIfLoaded?.window ?? presenter.viewIfLoaded?.window
        return window?.windowScene === scene && window?.isKeyWindow == true
    }

    private static func dismiss(_ controller: UIViewController) async {
        if controller.isBeingPresented, let transition = controller.transitionCoordinator {
            await waitForTransition(transition)
        }
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            await waitForTransition(transition)
        } else if controller.presentingViewController != nil {
            await withCheckedContinuation { continuation in
                controller.dismiss(animated: true) { continuation.resume() }
            }
        }
    }

    private static func waitForTransition(_ transition: UIViewControllerTransitionCoordinator) async {
        await withCheckedContinuation { continuation in
            if !transition.animate(alongsideTransition: nil, completion: { _ in continuation.resume() }) {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class LocalBookRelinkProgressViewController: UIViewController {
    var onCancel: (() -> Void)?
    private let fileName: String
    private let statusLabel = UILabel()
    private let cancelButton = UIButton(type: .system)

    init(fileName: String) {
        self.fileName = fileName
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .formSheet
        isModalInPresentation = true
        preferredContentSize = CGSize(width: 360, height: 280)
        sheetPresentationController?.detents = [.medium(), .large()]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        let title = UILabel()
        title.text = "重新选择原文件"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = AndroidReplicaTheme.primaryText
        let file = UILabel()
        file.text = fileName
        file.font = .preferredFont(forTextStyle: .subheadline)
        file.textColor = AndroidReplicaTheme.secondaryText
        file.lineBreakMode = .byCharWrapping
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.textColor = AndroidReplicaTheme.primaryText
        statusLabel.accessibilityTraits.insert(.updatesFrequently)
        for label in [title, file, statusLabel] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        var configuration = UIButton.Configuration.plain()
        configuration.title = L10n.Common.cancel
        configuration.image = UIImage(systemName: "xmark")
        configuration.imagePadding = 8
        cancelButton.configuration = configuration
        cancelButton.accessibilityIdentifier = "bookDetail.relink.cancel"
        cancelButton.addAction(UIAction { [weak self] _ in self?.onCancel?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, file, spinner, statusLabel, cancelButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
        ])
        setStatus("正在准备原文件")
    }

    func setStatus(_ text: String) { statusLabel.text = text }

    func setCancelling() {
        setStatus("正在取消，请稍候")
        cancelButton.isEnabled = false
    }
}
