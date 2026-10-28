import UIKit

/// Selection stays in the current rendered chapter, as ContentTextView.touchRough does on Android.
@MainActor
final class ReaderTextSelectionCoordinator {
    private typealias CharacterTarget = (index: Int, hit: ReaderTextSelectionGeometry.Hit)

    private struct Boundary {
        let position: Int
        let pageIndex: Int
        let caret: CGRect
    }

    private struct Session {
        let id = UUID()
        let bookURL: String
        let chapterIndex: Int
        let chapterURL: String?
        let origin: String?
        let initialCharacter: CharacterTarget?
        var range: NSRange
        var isSearchResult: Bool
        var showsActionMenu: Bool
        var startBoundary: Boundary? = nil
        var endBoundary: Boundary? = nil
    }

    private struct Drag {
        let fixedBoundary: Int
        let fixedCaret: Boundary?
        let originalEndpoint: ReaderTextSelectionEndpoint
        var endpoint: ReaderTextSelectionEndpoint
        var lastPoint: CGPoint
    }

    private weak var reader: ReaderContainerViewController?
    private var session: Session?
    private var drag: Drag?
    private var isInitialDrag = false
    private var initialLastPoint: CGPoint?
    private var menuPlacement: MenuPlacement?
    private var presentationGeometry: PresentationGeometry?
    private var handles: ReaderTextSelectionHandlesView?
    private var observers: [NSObjectProtocol] = []

    private struct MenuPlacement {
        let start: CGRect
        let end: CGRect
        let available: CGRect
        let origin: CGPoint
    }

    private struct PresentationGeometry: Equatable {
        let bounds: CGRect
        let start: CGRect
        let end: CGRect
        let visibleIndices: [Int]
        let isScrollMode: Bool
    }

    var isSelecting: Bool { session != nil }
    var isSearchResultSelection: Bool { session?.isSearchResult == true }

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        for name in [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] notification in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if let scene = notification.object as? UIScene,
                            scene !== self.reader?.viewIfLoaded?.window?.windowScene
                        {
                            return
                        }
                        self.dismiss(clearSelection: true)
                    }
                })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func begin(range: NSRange, pageIndex: Int, initiallyDragging: Bool, initialPoint: CGPoint? = nil) {
        begin(
            range: range, pageIndex: pageIndex, initiallyDragging: initiallyDragging,
            initialPoint: initialPoint, isSearchResult: false)
    }

    func beginSearchResult(range: NSRange, pageIndex: Int) {
        begin(
            range: range, pageIndex: pageIndex, initiallyDragging: false,
            initialPoint: nil, isSearchResult: true)
    }

    private func begin(
        range: NSRange, pageIndex: Int, initiallyDragging: Bool, initialPoint: CGPoint?, isSearchResult: Bool
    ) {
        guard let reader, reader.canPerformNavigationAction,
            reader.pages.indices.contains(pageIndex), range.location >= 0, range.location != NSNotFound,
            range.length > 0, range.length <= Int.max - range.location,
            reader.pages[pageIndex].selectionEndpoints(for: range) != nil
        else { return }
        // The existing caller supplies the tokenizer range, not the touched character.
        // Read its active long press without changing gesture ownership or failure rules.
        let sourceView: UIView = reader.isScrollPageMode ? reader.scrollPagerView : reader.renderView
        let gesture = sourceView.gestureRecognizers?.compactMap { $0 as? UILongPressGestureRecognizer }
            .first { $0.state == .began }
        let point = initiallyDragging ? (initialPoint ?? gesture?.location(in: reader.view)) : nil
        let initialCharacter = point.flatMap { point -> CharacterTarget? in
            guard let target = selectionHit(at: point), target.index == pageIndex, target.hit.isCharacter,
                NSIntersectionRange(target.hit.range, range) == target.hit.range
            else { return nil }
            return target
        }
        if isSearchResult {
            // Adopt the rendered hit without clearing its glyph or selection styling.
            dismiss(clearSelection: false)
        } else {
            reader.clearSearchSelection()
        }
        reader.setMenuVisible(false)
        session = Session(
            bookURL: reader.bookURL, chapterIndex: reader.chapterIndex,
            chapterURL: reader.currentChapterURL, origin: reader.book?.origin,
            initialCharacter: initialCharacter, range: range,
            isSearchResult: isSearchResult, showsActionMenu: !isSearchResult)
        isInitialDrag = initiallyDragging
        initialLastPoint = point
        reader.selectedTextRange = range
        reader.selectedTextPageIndex = pageIndex
        let handles = ReaderTextSelectionHandlesView(frame: reader.view.bounds)
        handles.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        handles.onDrag = { [weak self] endpoint, point, state in self?.move(endpoint: endpoint, to: point, state: state)
        }
        handles.onStep = { [weak self] endpoint, delta in self?.step(endpoint: endpoint, by: delta) }
        self.handles = handles
        reader.view.addSubview(handles)
        if !isSearchResult { installMenu() }
        paint()
    }

    func moveInitialSelection(to point: CGPoint, state: UIGestureRecognizer.State) {
        guard isInitialDrag else { return }
        guard let session, isCurrent else {
            dismiss(clearSelection: true)
            return
        }
        if state == .ended || state == .cancelled || state == .failed {
            isInitialDrag = false
            initialLastPoint = nil
            paint()
        } else if state == .changed, point.x.isFinite, point.y.isFinite, point != initialLastPoint {
            initialLastPoint = point
            guard let initialCharacter = session.initialCharacter, let target = selectionHit(at: point) else { return }
            // ReadView.selectText excludes the initial character when moving backwards.
            let fixed = initialCharacter.hit.range.location
            let backwards = target.hit.startBoundary < fixed
            let start = backwards ? target.hit.startBoundary : fixed
            let end = backwards ? fixed : target.hit.endBoundary
            if end > start {
                let initialCaret = boundary(for: initialCharacter, endpoint: .start)
                update(
                    range: NSRange(location: start, length: end - start),
                    startBoundary: backwards ? boundary(for: target, endpoint: .start) : initialCaret,
                    endBoundary: backwards ? initialCaret : boundary(for: target, endpoint: .end))
            }
        }
    }

    func dismiss(clearSelection: Bool) {
        session = nil
        drag = nil
        isInitialDrag = false
        initialLastPoint = nil
        menuPlacement = nil
        presentationGeometry = nil
        let oldHandles = handles
        handles = nil
        oldHandles?.onDrag = nil
        oldHandles?.onStep = nil
        oldHandles?.cancelInteraction()
        oldHandles?.removeFromSuperview()
        guard let reader else { return }
        reader.textSelectionMenu?.removeFromSuperview()
        reader.textSelectionMenu = nil
        if clearSelection {
            reader.selectedTextRange = nil
            reader.selectedTextPageIndex = nil
            reader.renderView.selectionRange = nil
            reader.scrollPagerView.clearTextSelection()
        }
    }

    func relayout() {
        guard session != nil else { return }
        guard isCurrent else {
            dismiss(clearSelection: true)
            return
        }
        paint(invalidatingDragForLayoutChange: true)
    }

    private var isCurrent: Bool {
        guard let reader, let session, reader.canPerformNavigationAction, !reader.isMenuVisible,
            reader.bookURL == session.bookURL, reader.chapterIndex == session.chapterIndex,
            reader.book?.origin == session.origin,
            reader.currentChapterURL == session.chapterURL, reader.selectedTextRange == session.range,
            reader.selectedTextPageIndex.map(reader.pages.indices.contains) == true
        else { return false }
        return true
    }

    private func installMenu() {
        guard let reader, let session, session.showsActionMenu else { return }
        let id = session.id
        let menu = AndroidReaderTextActionMenuView(
            expandAll: ReaderLocalSettings.load().expandTextMenu,
            onAction: { [weak self] action in self?.perform(action, sessionID: id) },
            onLayoutChange: { [weak self] in self?.relayout() })
        menu.canInteract = { [weak self] in
            guard let self else { return false }
            return self.session?.id == id && self.session?.showsActionMenu == true
                && self.isCurrent && self.drag == nil && !self.isInitialDrag
        }
        reader.textSelectionMenu = menu
        reader.view.addSubview(menu)
    }

    private func perform(_ action: AndroidReaderTextActionMenuView.Action, sessionID: UUID) {
        guard let reader, let session, session.id == sessionID, session.showsActionMenu, isCurrent,
            drag == nil, !isInitialDrag, let menu = reader.textSelectionMenu,
            !menu.isHidden, menu.isUserInteractionEnabled
        else { return }
        let text = ReaderPageLayout.selectedText(for: session.range, in: reader.pages)
        guard !text.isEmpty else {
            dismiss(clearSelection: true)
            return
        }
        menu.isUserInteractionEnabled = false
        reader.handleTextSelection(action, range: session.range, selectedText: text)
    }

    private func move(endpoint: ReaderTextSelectionEndpoint, to point: CGPoint, state: UIGestureRecognizer.State) {
        guard isCurrent, let session else {
            dismiss(clearSelection: true)
            return
        }
        if state == .began {
            guard drag == nil, !isInitialDrag, point.x.isFinite, point.y.isFinite else {
                handles?.cancelInteraction()
                return
            }
            // Android dismisses on handle down, then shows a newly anchored primary menu on up.
            menuPlacement = nil
            let fixedEndpoint: ReaderTextSelectionEndpoint = endpoint == .start ? .end : .start
            drag = Drag(
                fixedBoundary: endpoint == .start ? session.range.upperBound : session.range.location,
                fixedCaret: (endpoint == .start ? session.endBoundary : session.startBoundary)
                    ?? renderedBoundary(for: session.range, endpoint: fixedEndpoint),
                originalEndpoint: endpoint, endpoint: endpoint, lastPoint: point)
            paint()
            return
        }
        if state == .ended || state == .cancelled || state == .failed {
            guard drag != nil else { return }
            drag = nil
            if state == .ended { self.session?.showsActionMenu = true }
            paint()
            return
        }
        guard state == .changed, var drag, point != drag.lastPoint,
            point.x.isFinite, point.y.isFinite
        else { return }
        drag.lastPoint = point
        self.drag = drag
        let cursorSpan = 2 * ReaderTextSelectionHandlesView.cursorWidth
        // The overlay keeps the original physical tip + cumulative translation contract.
        // Activity.onTouch changes rawX +/- cursorWidth when that handle reverses roles.
        let roleOffset: CGFloat =
            drag.originalEndpoint == drag.endpoint
            ? 0
            : (drag.endpoint == .end ? -cursorSpan : cursorSpan)
        let tip = CGPoint(x: point.x + roleOffset, y: point.y)
        guard let target = handleHit(at: tip, endpoint: drag.endpoint) else { return }
        let hit = target.hit
        var movingTarget = target
        let start: Int
        let end: Int
        if drag.endpoint == .start {
            if hit.startBoundary < drag.fixedBoundary {
                start = hit.startBoundary
                end = drag.fixedBoundary
            } else {
                let reversedTip = CGPoint(x: tip.x - cursorSpan, y: tip.y)
                guard let reversed = handleHit(at: reversedTip, endpoint: .end),
                    reversed.hit.startBoundary >= drag.fixedBoundary, reversed.hit.endBoundary > drag.fixedBoundary
                else { return }
                start = drag.fixedBoundary
                end = reversed.hit.endBoundary
                drag.endpoint = .end
                movingTarget = reversed
            }
        } else {
            if hit.endBoundary > drag.fixedBoundary {
                start = drag.fixedBoundary
                end = hit.endBoundary
            } else {
                let reversedTip = CGPoint(x: tip.x + cursorSpan, y: tip.y)
                guard let reversed = handleHit(at: reversedTip, endpoint: .start),
                    reversed.hit.endBoundary <= drag.fixedBoundary, reversed.hit.startBoundary < drag.fixedBoundary
                else { return }
                start = reversed.hit.startBoundary
                end = drag.fixedBoundary
                drag.endpoint = .start
                movingTarget = reversed
            }
        }
        let movingCaret = boundary(for: movingTarget, endpoint: drag.endpoint)
        update(
            range: NSRange(location: start, length: end - start),
            startBoundary: drag.endpoint == .start ? movingCaret : drag.fixedCaret,
            endBoundary: drag.endpoint == .end ? movingCaret : drag.fixedCaret, movingDrag: drag)
    }

    private func handleHit(at point: CGPoint, endpoint: ReaderTextSelectionEndpoint) -> CharacterTarget? {
        selectionHit(at: CGPoint(x: point.x + (endpoint == .end ? -0.25 : 0.25), y: point.y - 0.5))
    }

    private func boundary(for target: CharacterTarget, endpoint: ReaderTextSelectionEndpoint) -> Boundary? {
        let hit = target.hit
        guard let caret = endpoint == .start ? hit.startCaret : hit.endCaret else { return nil }
        return Boundary(
            position: endpoint == .start ? hit.startBoundary : hit.endBoundary,
            pageIndex: target.index, caret: caret)
    }

    private func renderedBoundary(for range: NSRange, endpoint: ReaderTextSelectionEndpoint) -> Boundary? {
        guard let reader else { return nil }
        let indices = endpoint == .start ? visibleIndices : visibleIndices.reversed().map { $0 }
        for index in indices {
            if let endpoints = reader.pages[index].selectionEndpoints(for: range) {
                return Boundary(
                    position: endpoint == .start ? range.location : range.upperBound, pageIndex: index,
                    caret: endpoint == .start ? endpoints.start : endpoints.end)
            }
        }
        return nil
    }

    private func step(endpoint: ReaderTextSelectionEndpoint, by delta: Int) {
        guard isCurrent, drag == nil, !isInitialDrag, let session, let reader, delta != 0 else { return }
        let ranges = visibleIndices.flatMap { reader.pages[$0].selectionCharacterRanges }.sorted {
            $0.location < $1.location
        }
        let boundary = endpoint == .start ? session.range.location : session.range.upperBound
        let candidate =
            delta > 0
            ? ranges.first(where: { $0.upperBound > boundary })
            : ranges.last(where: { $0.location < boundary })
        guard let candidate else { return }
        let start =
            endpoint == .start ? (delta > 0 ? candidate.upperBound : candidate.location) : session.range.location
        let end = endpoint == .end ? (delta > 0 ? candidate.upperBound : candidate.location) : session.range.upperBound
        guard end > start else { return }
        update(range: NSRange(location: start, length: end - start))
    }

    private func update(
        range: NSRange, startBoundary: Boundary? = nil, endBoundary: Boundary? = nil, movingDrag: Drag? = nil
    ) {
        guard ReaderTextSelectionGeometry.isValidSelectionRange(range), let reader, let session,
            let first = visibleIndices.first(where: { reader.pages[$0].selectionEndpoints(for: range) != nil })
        else { return }
        if let movingDrag { drag = movingDrag }
        if session.isSearchResult, range != session.range || movingDrag != nil {
            // Android upSelectChars clears search flags on a valid handle move, even within one column.
            self.session?.isSearchResult = false
            self.session?.showsActionMenu = true
            reader.clearSearchHighlight()
            guard self.session?.id == session.id, isCurrent else { return }
        }
        self.session?.range = range
        self.session?.startBoundary = startBoundary
        self.session?.endBoundary = endBoundary
        reader.selectedTextRange = range
        reader.selectedTextPageIndex = first
        paint()
    }

    private var visibleIndices: [Int] {
        guard let reader else { return [] }
        if reader.isScrollPageMode { return reader.scrollPagerView.selectionVisiblePageIndices }
        return reader.renderView.selectionVisiblePageOffsets.map { reader.currentPageIndex + $0 }.filter(
            reader.pages.indices.contains)
    }

    private func selectionHit(at point: CGPoint) -> CharacterTarget? {
        guard let reader else { return nil }
        func geometryHit(in page: ReaderPageLayout, at point: CGPoint) -> ReaderTextSelectionGeometry.Hit? {
            guard !page.attachmentFragments.contains(where: { $0.frame.contains(point) }) else { return nil }
            for fragment in page.textFragments {
                if let hit = ReaderTextSelectionGeometry(fragment: fragment).selectionHit(at: point) { return hit }
            }
            return nil
        }
        func layoutTarget(at point: CGPoint) -> (index: Int, point: CGPoint)? {
            if reader.isScrollPageMode {
                let local = reader.view.convert(point, to: reader.scrollPagerView)
                guard let target = reader.scrollPagerView.selectionTarget(at: local),
                    reader.pages.indices.contains(target.pageIndex)
                else { return nil }
                return (target.pageIndex, target.contentPoint)
            }
            let local = reader.view.convert(point, to: reader.renderView)
            guard let target = reader.renderView.layoutTarget(at: local),
                reader.pages.indices.contains(reader.currentPageIndex + target.pageOffset)
            else { return nil }
            return (reader.currentPageIndex + target.pageOffset, target.layoutPoint)
        }
        if let target = layoutTarget(at: point) {
            return geometryHit(in: reader.pages[target.index], at: target.point).map { (target.index, $0) }
        }

        // Unlike a tap, touchRough accepts x outside the text viewport. Retain the
        // existing page conversion and choose a column by x; y must still hit a real row.
        guard point.x.isFinite, point.y.isFinite,
            point.y >= reader.view.bounds.minY, point.y < reader.view.bounds.maxY
        else { return nil }
        let candidates = visibleIndices.compactMap { index -> (index: Int, frame: CGRect)? in
            let page = reader.pages[index]
            guard let frame = converted(CGRect(origin: .zero, size: page.contentSize), pageIndex: index),
                !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0,
                point.y >= frame.minY, point.y < frame.maxY
            else { return nil }
            return (index, frame)
        }
        func horizontalDistance(to frame: CGRect) -> CGFloat {
            max(frame.minX - point.x, point.x - frame.maxX, 0)
        }
        guard
            let target = candidates.min(by: {
                horizontalDistance(to: $0.frame) < horizontalDistance(to: $1.frame)
            })
        else { return nil }
        let page = reader.pages[target.index]
        let probe = CGPoint(x: target.frame.midX, y: point.y)
        // Reuse the real viewport mapping to keep headers, footers and clipped scroll rows excluded.
        guard let mapped = layoutTarget(at: probe), mapped.index == target.index else { return nil }
        let local = CGPoint(
            x: mapped.point.x + (point.x - probe.x) * page.contentSize.width / target.frame.width,
            y: mapped.point.y)
        return geometryHit(in: page, at: local).map { (target.index, $0) }
    }

    private func converted(_ rect: CGRect, pageIndex: Int) -> CGRect? {
        guard let reader else { return nil }
        if reader.isScrollPageMode {
            return reader.scrollPagerView.selectionViewRect(rect, pageIndex: pageIndex, in: reader.view)
        }
        let offset = pageIndex - reader.currentPageIndex
        guard reader.renderView.selectionVisiblePageOffsets.contains(offset) else { return nil }
        return reader.renderView.convert(reader.renderView.viewRect(for: rect, pageOffset: offset), to: reader.view)
    }

    private func paint(invalidatingDragForLayoutChange: Bool = false) {
        guard let reader, let session, let handles else { return }
        if reader.isScrollPageMode {
            reader.scrollPagerView.setSelectionRange(session.range)
        } else {
            reader.renderView.selectionRange = session.range
        }
        var start: CGRect?
        var end: CGRect?
        var anchor = CGRect.null
        let indices = visibleIndices
        for index in indices {
            let page = reader.pages[index]
            guard let endpoints = page.selectionEndpoints(for: session.range) else { continue }
            if start == nil { start = converted(endpoints.start, pageIndex: index) }
            end = converted(endpoints.end, pageIndex: index)
            for rect in page.selectionRects(for: session.range) {
                if let frame = converted(rect, pageIndex: index) { anchor = anchor.union(frame) }
            }
        }
        if let boundary = session.startBoundary, boundary.position == session.range.location,
            indices.contains(boundary.pageIndex), let caret = converted(boundary.caret, pageIndex: boundary.pageIndex)
        {
            start = caret
        }
        if let boundary = session.endBoundary, boundary.position == session.range.upperBound,
            indices.contains(boundary.pageIndex), let caret = converted(boundary.caret, pageIndex: boundary.pageIndex)
        {
            end = caret
        }
        guard let start, let end, !anchor.isNull else {
            dismiss(clearSelection: true)
            return
        }
        let geometry = PresentationGeometry(
            bounds: reader.view.bounds, start: start, end: end, visibleIndices: indices,
            isScrollMode: reader.isScrollPageMode)
        if invalidatingDragForLayoutChange, let previous = presentationGeometry, previous != geometry {
            // A layout callback is not a selection move: never reuse its old physical drag origin.
            isInitialDrag = false
            initialLastPoint = nil
            drag = nil
            handles.cancelInteraction()
        }
        presentationGeometry = geometry
        handles.frame = reader.view.bounds
        handles.isUserInteractionEnabled = !isInitialDrag
        handles.update(start: start, end: end, activeEndpoint: drag?.endpoint, color: AndroidReplicaTheme.accent)
        guard self.session?.id == session.id else { return }
        if session.showsActionMenu, !isInitialDrag, drag == nil, reader.textSelectionMenu == nil {
            installMenu()
        }
        guard let menu = reader.textSelectionMenu else { return }
        menu.isHidden = !session.showsActionMenu || isInitialDrag || drag != nil
        guard !menu.isHidden else { return }
        let available = reader.view.bounds.inset(by: reader.view.safeAreaInsets)
        let retainedOrigin = menuPlacement.flatMap {
            $0.start == start && $0.end == end && $0.available == available ? $0.origin : nil
        }
        let frame = TextSelectionMenuPlacement.frame(
            for: menu, start: start, end: end, safeFrame: available,
            pixelScale: reader.view.window?.screen.scale ?? reader.traitCollection.displayScale,
            preservedOrigin: retainedOrigin)
        guard let frame else {
            menu.isHidden = true
            return
        }
        if menu.frame != frame {
            menu.frame = frame
            menu.setNeedsLayout()
        }
        // PopupWindow keeps its top/start location when its more-list changes the wrap size.
        menuPlacement = MenuPlacement(start: start, end: end, available: available, origin: frame.origin)
    }
}
