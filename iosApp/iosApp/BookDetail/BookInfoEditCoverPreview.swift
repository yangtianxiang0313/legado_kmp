import ImageIO
import UIKit
import shared

/// BookInfoEditActivity.upCover / activity_book_info_edit.xml at Legado 5f5d314.
/// The host owns the sibling views' hierarchy and 90 x 130 cover frame.
@MainActor
final class BookInfoEditCoverPreview {
    private struct RequestKey: Equatable {
        let bookURL: String
        let bookContext: NSString
        let coverURL: String

        init(book: Book, draftCoverURL: String) {
            bookURL = book.bookUrl
            bookContext = BookCoverImageLoader.coverCacheKey(for: book)
            coverURL = draftCoverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var usesDefaultCover: Bool {
            coverURL.isEmpty || coverURL == "use_default_cover"
        }
    }

    private struct Request {
        let key: RequestKey
        let force: Bool
    }

    private let imageView: UIImageView
    private let spinner: UIActivityIndicatorView
    private let placeholder: AndroidDefaultBookCoverView
    private var request: Request?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var needsLoad = false
    private var isSuspended = false
    private var onFailure: (() -> Void)?

    init(
        imageView: UIImageView,
        spinner: UIActivityIndicatorView,
        placeholder: AndroidDefaultBookCoverView
    ) {
        self.imageView = imageView
        self.spinner = spinner
        self.placeholder = placeholder
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        placeholder.isUserInteractionEnabled = false
        spinner.hidesWhenStopped = true
        spinner.stopAnimating()
        showDefaultCover()
    }

    deinit { task?.cancel() }

    /// Pass the editor's initial book, not a book mutated with draft metadata.
    /// A settled URL (including failure) is retried only with force; metadata edits never flash it.
    func refresh(
        book: Book,
        draftCoverURL: String,
        name: String,
        author: String,
        force: Bool = false,
        onFailure: (() -> Void)? = nil
    ) {
        placeholder.onLoadingPolicyChange = { [weak self] in
            self?.refresh(
                book: book, draftCoverURL: draftCoverURL, name: name, author: author,
                force: true)
        }
        placeholder.configure(name: name, author: author)
        let key = RequestKey(book: book, draftCoverURL: draftCoverURL)
        let changed = request?.key != key
        guard changed || force else { return }

        invalidateLoading()
        request = Request(key: key, force: force)
        self.onFailure = onFailure
        needsLoad = !key.usesDefaultCover
        if changed || !needsLoad { showDefaultCover() }
        guard needsLoad else {
            self.onFailure = nil
            return
        }
        startLoadingIfNeeded()
    }

    /// Call on leaving the window or entering the background. No failure callback survives cancellation.
    /// The current image stays visible; refresh while suspended only records the latest draft.
    func cancel() {
        isSuspended = true
        invalidateLoading()
        onFailure = nil
    }

    /// Call when visible and active again. Only interrupted or newly recorded requests restart.
    func resume() {
        isSuspended = false
        startLoadingIfNeeded()
    }

    private func startLoadingIfNeeded() {
        guard !isSuspended, needsLoad, task == nil, let request else { return }
        let id = UUID()
        generation = id
        spinner.startAnimating()
        task = Task { @MainActor [weak self] in
            let image: UIImage?
            if let localURL = BookCoverImageLoader.localImageURL(request.key.coverURL) {
                image = await BookInfoEditLocalCoverPreview.load(at: localURL)
            } else {
                // Keep the original book's source/header/variable context and the explicit draft URL.
                image = await BookCoverImageLoader.loadDecodedImage(
                    bookUrl: request.key.bookURL,
                    imageUrl: request.key.coverURL,
                    isCover: true,
                    refresh: request.force
                )
            }
            guard let self, !Task.isCancelled, self.generation == id, !self.isSuspended,
                self.request?.key == request.key
            else { return }

            self.task = nil
            self.needsLoad = false
            self.spinner.stopAnimating()
            let failure = self.onFailure
            self.onFailure = nil
            if let image, !image.isSymbolImage {
                self.imageView.image = image.withRenderingMode(.alwaysOriginal)
                self.imageView.contentMode = .scaleAspectFill
                self.imageView.isHidden = false
                self.placeholder.isHidden = true
            } else {
                self.showDefaultCover()
                failure?()
            }
        }
    }

    private func invalidateLoading() {
        generation = UUID()
        task?.cancel()
        task = nil
        spinner.stopAnimating()
    }

    private func showDefaultCover() {
        imageView.image = nil
        // The placeholder is a sibling, so an opaque empty UIImageView must not cover it.
        imageView.isHidden = true
        placeholder.isHidden = false
    }
}

private enum BookInfoEditLocalCoverPreview {
    static func load(at url: URL) async -> UIImage? {
        let task = Task.detached(priority: .userInitiated) {
            preview(at: url)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private static func preview(at url: URL) -> UIImage? {
        guard !Task.isCancelled, url.isFileURL,
            url.host == nil || url.host == "" || url.host?.lowercased() == "localhost"
        else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var result: UIImage?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) {
            readableURL in
            guard !Task.isCancelled,
                let values = try? readableURL.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                let source = CGImageSourceCreateWithURL(
                    readableURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetCount(source) > 0,
                !Task.isCancelled,
                let image = CGImageSourceCreateThumbnailAtIndex(
                    source, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 520,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary),
                !Task.isCancelled
            else { return }
            result = UIImage(cgImage: image)
        }
        return coordinationError == nil && !Task.isCancelled ? result : nil
    }
}
