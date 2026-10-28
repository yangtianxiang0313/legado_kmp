import UIKit
import shared

@MainActor
final class BookDetailCoverActions {
    private struct CoverKey: Equatable {
        let origin: String
        let bookURL: String
        let coverURL: String
        let name: String
        let author: String
        let variable: String?
        let tocURL: String
        let loadingPolicy: String

        init(_ book: Book) {
            origin = book.origin
            bookURL = book.bookUrl
            coverURL = book.displayCoverUrl ?? ""
            name = book.name
            author = book.author
            variable = book.variable
            tocURL = book.tocUrl
            loadingPolicy = CoverConfigurationLoadingPolicy().signature
        }

        init(_ candidate: SearchBook) {
            origin = candidate.origin
            bookURL = candidate.bookUrl
            coverURL = candidate.coverUrl ?? ""
            name = candidate.name
            author = candidate.author
            variable = candidate.variable
            tocURL = candidate.tocUrl
            loadingPolicy = CoverConfigurationLoadingPolicy().signature
        }
    }

    private weak var presenter: UIViewController?
    private weak var pageView: AndroidReplicaBookDetailPageView?
    private weak var imageView: UIImageView?
    private weak var picker: UINavigationController?
    private weak var preview: BookCoverPreviewViewController?
    private let adapter: AndroidReplicaBookDetailAdapter
    private let defaultCoverView = AndroidDefaultBookCoverView()
    private var defaultBackdropImage: UIImage? {
        AndroidDefaultBookCoverRenderer.backgroundImage(traits: presenter?.traitCollection ?? .current)
    }
    private let currentBook: () -> Book?
    private let isActive: () -> Bool
    private let canPresent: () -> Bool
    private let waitForDetailLoad: () async -> Void
    private let onBusyChange: (Bool) -> Void
    private let onCommitted: (Book) -> Void
    private var coverTask: Task<Void, Never>?
    private var coverGeneration = UUID()
    private var requestKey: CoverKey?
    private var displayedKey: CoverKey?
    private var interactionGeneration = UUID()
    private var selectionID: UUID?
    private var selectionDelegate: BookDetailCoverSelection?
    private var searchSession: CoverSearchSession?
    private var saveTask: Task<Void, Never>?

    init(
        presenter: UIViewController,
        pageView: AndroidReplicaBookDetailPageView,
        imageView: UIImageView,
        adapter: AndroidReplicaBookDetailAdapter,
        currentBook: @escaping () -> Book?,
        isActive: @escaping () -> Bool,
        canPresent: @escaping () -> Bool,
        waitForDetailLoad: @escaping () async -> Void,
        onBusyChange: @escaping (Bool) -> Void,
        onCommitted: @escaping (Book) -> Void
    ) {
        self.presenter = presenter
        self.pageView = pageView
        self.imageView = imageView
        self.adapter = adapter
        self.currentBook = currentBook
        self.isActive = isActive
        self.canPresent = canPresent
        self.waitForDetailLoad = waitForDetailLoad
        self.onBusyChange = onBusyChange
        self.onCommitted = onCommitted
    }

    deinit { coverTask?.cancel() }

    func loadCover(_ book: Book) {
        defaultCoverView.onLoadingPolicyChange = { [weak self] in self?.loadCover(book) }
        defaultCoverView.onAppearanceChange = { [weak self] in
            guard let self, let key = self.requestKey else { return }
            self.resumeBackdrop(for: key)
        }
        let key = CoverKey(book)
        guard let generation = beginLoading(key: key) else { return }
        guard Self.hasRealCover(key.coverURL) else { return }
        coverTask = Task { [weak self] in
            let image = await Self.loadImage(book)
            self?.accept(image, key: key, generation: generation)
        }
    }

    func loadSeedCover(_ candidate: SearchBook) {
        defaultCoverView.onLoadingPolicyChange = { [weak self] in self?.loadSeedCover(candidate) }
        defaultCoverView.onAppearanceChange = { [weak self] in
            guard let self, let key = self.requestKey else { return }
            self.resumeBackdrop(for: key)
        }
        let key = CoverKey(candidate)
        guard let generation = beginLoading(key: key) else { return }
        guard Self.hasRealCover(key.coverURL) else { return }
        coverTask = Task { [weak self] in
            let image = await BookCoverImageLoader.loadDecodedCover(searchBook: candidate)
            self?.accept(image, key: key, generation: generation)
        }
    }

    func cancelLoading() {
        cancelCoverRequest()
        pageView?.cancelBackdropRendering()
    }

    private func cancelCoverRequest() {
        coverGeneration = UUID()
        coverTask?.cancel()
        coverTask = nil
    }

    func cancel() {
        cancelLoading()
        cancelInteractions()
        // An already-started shared save is allowed to finish; leaving is not a rollback.
    }

    func presentPicker() {
        guard saveTask == nil, canPresent(), let presenter, presenter.presentedViewController == nil,
            let book = currentBook()
        else { return }
        cancelInteractions()
        let key = CoverKey(book)
        let id = UUID()
        selectionID = id
        let delegate = BookDetailCoverSelection { [weak self] coverURL in
            self?.selectCover(coverURL, id: id, key: key)
        }
        selectionDelegate = delegate
        let controller = ChangeCoverViewController(
            bookURL: book.bookUrl, bookName: book.name, bookAuthor: book.author,
            originalCoverUrl: book.displayCoverUrl,
            sessionFactory: { [weak self, adapter] result, progress, finished in
                guard let self, self.acceptsSelection(id: id, key: key) else { throw CancellationError() }
                let session = try await adapter.createCoverSearchSession(
                    expectedBookURL: key.bookURL, onResult: result, onProgress: progress, onFinished: finished)
                guard !Task.isCancelled, self.acceptsSelection(id: id, key: key) else {
                    session.dispose()
                    throw CancellationError()
                }
                self.searchSession = session
                return session
            })
        controller.delegate = delegate
        let navigation = UINavigationController(rootViewController: controller)
        // Keep the underlying detail mounted, including both scroll views and their anchors.
        navigation.modalPresentationStyle = .overFullScreen
        picker = navigation
        presenter.present(navigation, animated: true)
    }

    func presentPreview() {
        guard saveTask == nil, canPresent(), let presenter, presenter.presentedViewController == nil,
            let book = currentBook()
        else { return }
        let key = CoverKey(book)
        guard Self.hasRealCover(key.coverURL) else {
            presenter.showTransientMessage("暂无可预览的封面")
            return
        }
        cancelInteractions()
        let initialImage = displayedKey == key ? imageView?.image : nil
        let controller = BookCoverPreviewViewController(image: initialImage) {
            await Self.loadImage(book, fullResolution: true)
        }
        preview = controller
        presenter.present(controller, animated: true)
    }

    private func acceptsSelection(id: UUID, key: CoverKey) -> Bool {
        selectionID == id && isActive() && currentBook().map { CoverKey($0) == key } == true
    }

    private func selectCover(_ coverURL: String, id: UUID, key: CoverKey) {
        guard saveTask == nil, acceptsSelection(id: id, key: key), canPresent(),
            presenter?.presentedViewController == nil
        else { return }
        selectionID = nil
        selectionDelegate = nil
        searchSession?.dispose()
        searchSession = nil
        picker = nil
        // The existing iOS picker returns an empty string for Android's default-cover item.
        let selected =
            coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "use_default_cover" : coverURL
        guard selected != key.coverURL else { return }
        let generation = interactionGeneration
        onBusyChange(true)
        saveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.saveTask = nil
                self.onBusyChange(false)
            }
            // Let existing info/chapter writes settle before saving the cover-only patch.
            await self.waitForDetailLoad()
            guard !Task.isCancelled, self.interactionGeneration == generation, self.isActive(),
                self.currentBook().map({ CoverKey($0) == key }) == true
            else { return }
            do {
                let updated = try await self.adapter.updateCover(expectedBookURL: key.bookURL, coverURL: selected)
                // Publish completed persistence only to the same book/source, even if its page has left.
                guard let current = self.currentBook(), current.bookUrl == key.bookURL,
                    current.origin == key.origin, updated.bookUrl == key.bookURL, updated.origin == key.origin,
                    CoverKey(current) == key || current.displayCoverUrl == updated.displayCoverUrl
                else { return }
                self.onCommitted(updated)
            } catch {
                guard self.interactionGeneration == generation, self.isActive(),
                    !(error is CancellationError), self.presenter?.presentedViewController == nil,
                    self.presenter?.viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active
                else { return }
                self.presenter?.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func cancelInteractions() {
        interactionGeneration = UUID()
        selectionID = nil
        selectionDelegate = nil
        searchSession?.dispose()
        searchSession = nil
        let ownedPicker = picker
        picker = nil
        if let ownedPicker, ownedPicker.presentingViewController === presenter {
            ownedPicker.dismiss(animated: false)
        }
        let ownedPreview = preview
        preview = nil
        if let ownedPreview, ownedPreview.presentingViewController === presenter {
            ownedPreview.dismiss(animated: false)
        }
    }

    private func beginLoading(key: CoverKey) -> UUID? {
        if requestKey == key, coverTask != nil || displayedKey == key {
            resumeBackdrop(for: key)
            return nil
        }
        if requestKey != key { cancelInteractions() }
        // A cover retry must not cancel the unchanged default backdrop's pending render.
        cancelCoverRequest()
        requestKey = key
        if displayedKey != key {
            displayedKey = nil
            imageView?.image = nil
            if let imageView {
                if defaultCoverView.superview !== imageView {
                    defaultCoverView.frame = imageView.bounds
                    defaultCoverView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                    defaultCoverView.isUserInteractionEnabled = false
                    imageView.addSubview(defaultCoverView)
                }
                defaultCoverView.configure(name: key.name, author: key.author)
                defaultCoverView.isHidden = false
            }
            pageView?.updateBackdropImage(defaultBackdropImage)
            if !Self.hasRealCover(key.coverURL) { displayedKey = key }
        }
        return coverGeneration
    }

    private func accept(_ image: UIImage?, key: CoverKey, generation: UUID) {
        guard coverGeneration == generation, requestKey == key else { return }
        coverTask = nil
        guard !Task.isCancelled, isActive() else { return }
        guard let image, !image.isSymbolImage else {
            resumeBackdrop(for: key)
            return
        }
        displayedKey = key
        imageView?.image = image
        defaultCoverView.isHidden = true
        pageView?.updateBackdropImage(image, animated: true)
    }

    private func resumeBackdrop(for key: CoverKey) {
        let image = !CoverConfigurationStore.shared.usesDefaultCover && displayedKey == key ? imageView?.image : nil
        pageView?.updateBackdropImage(image ?? defaultBackdropImage, animated: image != nil)
    }

    private static func hasRealCover(_ url: String) -> Bool {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        return !value.isEmpty && value != "use_default_cover"
    }

    private static func loadImage(_ book: Book, fullResolution: Bool = false) async -> UIImage? {
        guard !Task.isCancelled, let url = book.displayCoverUrl, hasRealCover(url) else { return nil }
        if let localURL = BookCoverImageLoader.localImageURL(url) {
            guard fullResolution else { return await BookCoverImageLoader.loadDecodedCover(book: book) }
            let task = Task.detached(priority: .userInitiated) {
                guard !Task.isCancelled else { return nil as UIImage? }
                let image = UIImage(contentsOfFile: localURL.path)
                return Task.isCancelled ? nil : image
            }
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        // Load the captured display URL, not whichever cover a later database read happens to find.
        return await BookCoverImageLoader.loadDecodedImage(bookUrl: book.bookUrl, imageUrl: url, isCover: true)
    }
}

private final class BookDetailCoverSelection: ChangeCoverDelegate {
    private let onSelect: (String) -> Void

    init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

    func changeCoverDidSelect(_ coverUrl: String) { onSelect(coverUrl) }
}
