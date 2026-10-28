import UIKit

@MainActor
final class ReaderAutoPageMotion {
    private enum Destination {
        case page(Int)
        case chapter(Int)
        case end
    }

    private weak var reader: ReaderContainerViewController?
    private let speed: () -> Int
    private var displayLink: CADisplayLink?
    private var displayTarget: ReaderAutoPageDisplayTarget?
    private var previousTimestamp: CFTimeInterval?
    private var fraction: CGFloat = 0
    private var isActive = false
    private var isPaused = false
    private var generation = UUID()
    private var preparation: Task<Void, Never>?
    private var destination: Destination?
    private var cover: ReaderAutoPageWipeView?
    private var pendingChapter: Int?
    private var endDistance: CGFloat = 0

    init(reader: ReaderContainerViewController, speed: @escaping () -> Int) {
        self.reader = reader
        self.speed = speed
    }

    deinit {
        displayLink?.invalidate()
        preparation?.cancel()
    }

    func start() {
        stop()
        isActive = true
        let target = ReaderAutoPageDisplayTarget(owner: self)
        let link = CADisplayLink(
            target: target, selector: #selector(ReaderAutoPageDisplayTarget.frame(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        displayTarget = target
        displayLink = link
        link.add(to: .main, forMode: .common)
    }

    func stop() {
        isActive = false
        isPaused = false
        displayLink?.invalidate()
        displayLink = nil
        displayTarget = nil
        pendingChapter = nil
        resetContent()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        previousTimestamp = nil
        displayLink?.isPaused = paused
    }

    func speedDidChange() { previousTimestamp = nil }

    func contentWillChange() {
        guard isActive else { return }
        resetContent(keepingCover: pendingChapter != nil)
    }

    func chapterWillLoad(_ index: Int) {
        if pendingChapter != index { pendingChapter = nil }
        contentWillChange()
    }

    func contentDidRender() {
        guard isActive, let reader else { return }
        if let pendingChapter {
            guard reader.chapterIndex == pendingChapter, !reader.pages.isEmpty else { return }
            self.pendingChapter = nil
        }
        resetContent()
    }

    fileprivate func frame(_ timestamp: CFTimeInterval) {
        guard isActive, !isPaused, let reader else { return }
        guard canUse(reader), reader.isAutoPageRunning else {
            reader.stopAutoPage(showMessage: false)
            return
        }
        guard reader.loadFailureView.isHidden else {
            reader.stopAutoPage(showMessage: false)
            return
        }
        guard pendingChapter == nil, reader.canNavigateReaderPages,
            !reader.pages.isEmpty, reader.pageTurnTransition == nil
        else {
            previousTimestamp = nil
            return
        }

        if reader.isScrollPageMode {
            if destination == nil { prepareContinuation(in: reader) }
            let elapsed = frameInterval(timestamp)
            let distance = reader.renderView.bounds.height / CGFloat(max(1, speed())) * elapsed
            advanceScroll(distance, in: reader)
            return
        }
        if destination == nil { prepareDestination(in: reader) }
        guard destination != nil else {
            previousTimestamp = nil
            return
        }
        let elapsed = frameInterval(timestamp)
        fraction = min(1, fraction + elapsed / CGFloat(max(1, speed())))
        cover?.updateProgress(fraction)
        guard fraction >= 1, let destination else { return }
        switch destination {
        case .page(let index):
            reader.currentPageIndex = index
            reader.renderCurrentPage()
            reader.updateMenuState()
        case .chapter(let index):
            openChapter(index, in: reader)
        case .end:
            reader.stopAutoPage(showMessage: false)
            reader.showToast(L10n.Reader.autoPageReachedEnd)
        }
    }

    private func frameInterval(_ timestamp: CFTimeInterval) -> CGFloat {
        defer { previousTimestamp = timestamp }
        guard timestamp.isFinite, let previousTimestamp, timestamp >= previousTimestamp else {
            return 0
        }
        return CGFloat(timestamp - previousTimestamp)
    }

    private func prepareDestination(in reader: ReaderContainerViewController) {
        guard preparation == nil else { return }
        let next = reader.currentPageIndex + reader.nonScrollPageStep()
        if reader.pages.indices.contains(next) {
            let preview = ReaderRenderView(frame: reader.renderView.bounds)
            preview.theme = reader.readerRenderTheme()
            preview.bookURL = reader.bookURL
            preview.chrome = reader.makeChromeSnapshot(pageIndex: next)
            preview.setPageLayouts(
                primary: reader.pages[next],
                trailing: reader.nonScrollPageStep() == 2 ? reader.pages[safe: next + 1] : nil)
            destination = .page(next)
            install(preview, in: reader)
            return
        }
        let nextChapter = reader.chapterIndex + 1
        guard reader.chapters.indices.contains(nextChapter) else {
            destination = .end
            return
        }
        let id = generation
        preparation = Task { @MainActor [weak self, weak reader] in
            guard let self, let reader else { return }
            defer { if self.generation == id { self.preparation = nil } }
            do {
                let preview = try await ReaderAutoPageChapterPreview.prepare(in: reader, index: nextChapter)
                guard !Task.isCancelled, self.generation == id, self.isActive, self.canUse(reader) else {
                    return
                }
                self.destination = .chapter(nextChapter)
                self.install(preview.view, in: reader)
            } catch {
                guard !Task.isCancelled, self.generation == id, self.isActive else { return }
                // The real chapter loader owns loading/error UI and retry. Never preview fabricated text.
                self.destination = .chapter(nextChapter)
            }
        }
    }

    private func install(_ preview: ReaderRenderView, in reader: ReaderContainerViewController) {
        cover?.removeFromSuperview()
        let wipe = ReaderAutoPageWipeView(target: preview, accentColor: AndroidReplicaTheme.accent)
        wipe.frame = reader.renderView.frame
        reader.view.insertSubview(wipe, aboveSubview: reader.renderView)
        wipe.updateProgress(fraction)
        cover = wipe
    }

    private func openChapter(_ index: Int, in reader: ReaderContainerViewController) {
        pendingChapter = index
        previousTimestamp = nil
        reader.autoPageAdvanceInFlight = true
        reader.openNextChapter()
    }

    private func advanceScroll(_ distance: CGFloat, in reader: ReaderContainerViewController) {
        // UIScrollView supplies its own display and virtualization; no page-sized animations.
        guard distance > 0 else { return }
        switch reader.scrollPagerView.advanceAutoRead(by: distance) {
        case .advanced, .paused, .noContent, .layoutUnavailable, .invalidDistance:
            break
        case .reachedEnd:
            if !reader.scrollPagerView.hasAutoReadContinuation {
                // Without a next-chapter preview, let the last visible page be read before leaving it.
                endDistance += distance
                guard endDistance >= reader.renderView.bounds.height else { return }
            }
            guard reader.chapterIndex + 1 < reader.chapters.count else {
                reader.stopAutoPage(showMessage: false)
                reader.showToast(L10n.Reader.autoPageReachedEnd)
                return
            }
            openChapter(reader.chapterIndex + 1, in: reader)
        }
    }

    private func prepareContinuation(in reader: ReaderContainerViewController) {
        guard preparation == nil else { return }
        let next = reader.chapterIndex + 1
        guard reader.chapters.indices.contains(next) else {
            destination = .end
            return
        }
        let id = generation
        preparation = Task { @MainActor [weak self, weak reader] in
            guard let self, let reader else { return }
            defer { if self.generation == id { self.preparation = nil } }
            do {
                let preview = try await ReaderAutoPageChapterPreview.prepare(in: reader, index: next)
                guard !Task.isCancelled, self.generation == id, self.isActive, self.canUse(reader) else {
                    return
                }
                reader.scrollPagerView.setAutoReadContinuation(pages: preview.pages)
                self.endDistance = 0
                self.destination = .chapter(next)
            } catch {
                guard !Task.isCancelled, self.generation == id, self.isActive else { return }
                self.destination = .chapter(next)
            }
        }
    }

    private func resetContent(keepingCover: Bool = false) {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        destination = nil
        previousTimestamp = nil
        fraction = 0
        endDistance = 0
        if !keepingCover {
            cover?.removeFromSuperview()
            cover = nil
        }
    }

    private func canUse(_ reader: ReaderContainerViewController) -> Bool {
        !reader.isMovingFromParent && !reader.isBeingDismissed
            && reader.navigationController?.isBeingDismissed != true
            && reader.navigationController?.topViewController === reader
            && reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive
    }
}

@MainActor
private final class ReaderAutoPageDisplayTarget: NSObject {
    private weak var owner: ReaderAutoPageMotion?
    init(owner: ReaderAutoPageMotion) { self.owner = owner }
    @objc func frame(_ link: CADisplayLink) { owner?.frame(link.timestamp) }
}
