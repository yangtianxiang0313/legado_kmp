import PDFKit
import UIKit

@MainActor
final class PdfReaderLocationCoordinator {
    private weak var view: PDFView?
    private let store: PdfReadingLocationStore
    private var fileURL: URL?
    private var scrollObservation: NSKeyValueObservation?
    private weak var observedScroll: UIScrollView?
    private var pendingSave: Task<Void, Never>?
    private var isApplying = false
    private var isReady = false
    private var isActive = false
    private var lastError: String?
    var onError: ((String) -> Void)?

    init(view: PDFView, bookURL: String) {
        self.view = view
        store = PdfReadingLocationStore(bookURL: bookURL)
    }

    deinit { pendingSave?.cancel() }

    func bind(fileURL: URL, pageIndex: Int, useSavedAnchor: Bool) {
        guard let view, let document = view.document else { return }
        self.fileURL = fileURL
        let saved = store.load(fileURL: fileURL, pageCount: document.pageCount)
        let index = max(0, min(pageIndex, document.pageCount - 1))
        let mode = saved?.mode ?? .continuous
        isReady = true
        if useSavedAnchor, let saved, saved.pageIndex == index {
            apply(saved)
        } else if let page = document.page(at: index) {
            let bounds = page.bounds(for: view.displayBox)
            apply(PdfReadingLocation(mode: mode, pageIndex: index, pointX: bounds.minX, pointY: bounds.maxY, relativeScale: 1))
        }
        observeScrolling()
    }

    var mode: PdfReadingMode { view?.displayMode == .singlePage ? .paged : .continuous }
    var isRestoring: Bool { isApplying }

    func capture() -> PdfReadingLocation? {
        guard isReady, !isApplying, let view, let document = view.document,
            let destination = view.currentDestination, let page = destination.page
        else { return nil }
        let index = document.index(for: page)
        let fit = view.scaleFactorForSizeToFit
        let point = destination.point
        guard index != NSNotFound, index < document.pageCount, fit.isFinite, fit > 0,
            view.scaleFactor.isFinite, view.scaleFactor > 0,
            point.x.isFinite, point.y.isFinite, abs(point.x) <= 10_000_000, abs(point.y) <= 10_000_000
        else { return nil }
        return PdfReadingLocation(
            mode: mode, pageIndex: index, pointX: point.x, pointY: point.y,
            relativeScale: min(16, max(0.1, view.scaleFactor / fit)))
    }

    func apply(_ location: PdfReadingLocation) {
        guard isReady, let view, let page = view.document?.page(at: location.pageIndex) else { return }
        pendingSave?.cancel()
        isApplying = true
        view.displayMode = location.mode == .continuous ? .singlePageContinuous : .singlePage
        view.displayDirection = location.mode == .continuous ? .vertical : .horizontal
        view.autoScales = true
        view.go(to: page)
        view.layoutDocumentView()
        let fit = view.scaleFactorForSizeToFit
        if fit.isFinite, fit > 0, abs(location.relativeScale - 1) > 0.01 {
            view.autoScales = false
            view.scaleFactor = min(view.maxScaleFactor, max(view.minScaleFactor, fit * location.relativeScale))
            view.layoutDocumentView()
        }
        view.go(to: PDFDestination(page: page, at: CGPoint(x: location.pointX, y: location.pointY)))
        isApplying = false
        observeScrolling()
    }

    func setMode(_ mode: PdfReadingMode) {
        guard let previous = capture() else { return }
        apply(
            PdfReadingLocation(
                mode: mode, pageIndex: previous.pageIndex, pointX: previous.pointX, pointY: previous.pointY,
                relativeScale: previous.relativeScale))
        checkpoint()
    }

    func fitPage() {
        guard let view, let page = view.currentPage else { return }
        view.autoScales = true
        view.go(to: page)
        checkpoint()
    }

    func setActive(_ active: Bool) {
        if !active { checkpoint() }
        isActive = active
        if active { observeScrolling() }
    }

    func observeScrolling() {
        var ancestor = view?.documentView?.superview
        while let current = ancestor, current !== view {
            if let scroll = current as? UIScrollView {
                guard observedScroll !== scroll else { return }
                observedScroll = scroll
                scrollObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    DispatchQueue.main.async { self?.scheduleCheckpoint() }
                }
                return
            }
            ancestor = current.superview
        }
    }

    func scheduleCheckpoint() {
        guard isActive, isReady, !isApplying else { return }
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            self?.checkpoint()
        }
    }

    func checkpoint() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let fileURL, let view, let document = view.document, let snapshot = capture() else { return }
        do {
            try store.save(snapshot, fileURL: fileURL, pageCount: document.pageCount)
            lastError = nil
        } catch {
            let message = error.userFacingMessage
            if lastError != message { onError?(message) }
            lastError = message
        }
    }
}
