import UIKit

@MainActor
final class ReaderImageInteractionCoordinator {
    private struct Context {
        let id = UUID()
        let bookURL: String
        let origin: String
        let chapterURL: String?
        let imageURL: URL
        let requestRule: String?
    }

    private weak var reader: ReaderContainerViewController?
    private weak var menu: ReaderImageActionMenuView?
    private var task: Task<Void, Never>?
    private var context: Context?
    private lazy var exporter: ReaderImageExportCoordinator? = {
        guard let reader else { return nil }
        return ReaderImageExportCoordinator(presenter: reader) { [weak reader] message in reader?.showToast(message) }
    }()

    init(reader: ReaderContainerViewController) { self.reader = reader }

    func presentPreview(url: URL, image: UIImage?, requestRule: String? = nil) {
        guard let selected = begin(url: url, requestRule: requestRule), let reader else { return }
        if let image {
            reader.present(ImagePreviewViewController(image: image, imageURL: url), animated: true)
        } else {
            load(selected, action: .show)
        }
    }

    func presentMenu(url: URL, image: UIImage?, anchor: CGRect, requestRule: String? = nil) {
        guard let selected = begin(url: url, requestRule: requestRule), let reader else { return }
        let popup = ReaderImageActionMenuView { [weak self] action in
            guard let self, self.accepts(selected), let reader = self.reader else { return }
            switch action {
            case .show:
                if let image {
                    reader.present(ImagePreviewViewController(image: image, imageURL: url), animated: true)
                } else {
                    self.load(selected, action: action)
                }
            case .refresh, .save:
                self.load(selected, action: action)
            case .mainMenu:
                reader.setMenuVisible(true)
            case .selectFolder:
                self.exporter?.selectFolder()
            }
        }
        popup.onDismiss = { [weak self, weak popup] in
            if self?.menu === popup { self?.menu = nil }
        }
        menu = popup
        popup.present(in: reader.view, anchor: anchor, interfaceStyle: reader.traitCollection.userInterfaceStyle)
    }

    func suspend() {
        if exporter?.ownsPresentation == true, let reader,
            reader.navigationController?.topViewController === reader,
            !reader.isMovingFromParent, !reader.isBeingDismissed,
            reader.navigationController?.isBeingDismissed != true
        {
            return
        }
        context = nil
        task?.cancel()
        task = nil
        menu?.dismiss()
        menu = nil
        exporter?.suspend()
    }

    private func begin(url: URL, requestRule: String?) -> Context? {
        guard task == nil, let reader, reader.canNavigateReaderPages,
            reader.presentedViewController == nil, let book = reader.book,
            book.bookUrl == reader.bookURL, reader.viewIfLoaded?.window != nil
        else { return nil }
        menu?.dismiss()
        reader.setMenuVisible(false)
        reader.dismissTextSelectionMenu(clearSelection: true)
        reader.stopAutoPage(showMessage: false)
        let selected = Context(
            bookURL: book.bookUrl, origin: book.origin, chapterURL: reader.currentChapterURL, imageURL: url,
            requestRule: requestRule)
        context = selected
        return selected
    }

    private func accepts(_ selected: Context) -> Bool {
        guard context?.id == selected.id, let reader,
            reader.bookURL == selected.bookURL, reader.book?.origin == selected.origin,
            reader.currentChapterURL == selected.chapterURL,
            reader.navigationController?.topViewController === reader,
            reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            !reader.isMovingFromParent, !reader.isBeingDismissed,
            reader.presentedViewController == nil
        else { return false }
        return true
    }

    private func load(_ selected: Context, action: ReaderImageActionMenuView.Action) {
        guard task == nil, accepts(selected) else { return }
        reader?.showToast(ReaderImageActionText.loading)
        task = Task { @MainActor [weak self] in
            defer {
                if self?.context?.id == selected.id { self?.task = nil }
            }
            do {
                let data = try await BookCoverImageLoader.loadImageData(
                    bookUrl: selected.bookURL, imageUrl: selected.requestRule ?? selected.imageURL.absoluteString,
                    refresh: action == .refresh)
                try Task.checkCancellation()
                guard let self, self.accepts(selected), let reader = self.reader else { return }
                guard let data, let image = UIImage(data: data) else {
                    reader.showToast("图片加载失败")
                    return
                }
                switch action {
                case .show:
                    reader.present(ImagePreviewViewController(image: image, imageURL: selected.imageURL), animated: true)
                case .refresh:
                    reader.renderView.cacheLoadedImage(image, for: selected.imageURL)
                    reader.scrollPagerView.cacheLoadedImage(image, for: selected.imageURL)
                    reader.showToast(ReaderImageActionText.refreshed)
                case .save:
                    self.exporter?.save(
                        imageData: data,
                        sourceURL: Self.exportSourceURL(requestRule: selected.requestRule, fallback: selected.imageURL))
                case .mainMenu, .selectFolder:
                    break
                }
            } catch {
                guard let self, !Task.isCancelled, self.accepts(selected) else { return }
                self.reader?.showToast(error.userFacingMessage)
            }
        }
    }

    static func exportSourceURL(requestRule: String?, fallback: URL) -> URL {
        guard let requestRule else { return fallback }
        let end =
            requestRule.range(of: "\\s*,\\s*(?=\\{)", options: .regularExpression)?.lowerBound
            ?? requestRule.endIndex
        let address = requestRule[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address),
            let scheme = url.scheme?.lowercased(),
            ["http", "https", "file", "epub-resource", "mobi-resource"].contains(scheme)
        else { return URL(string: "image")! }
        // The filename needs the resource address, never credentials or script text in its rule suffix.
        return url
    }
}
