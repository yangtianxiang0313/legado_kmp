import UIKit

extension ReaderContainerViewController {
    @objc func handleReaderPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { beginReaderBodyTouch() }
        autoPageCoordinator.setGestureInteracting(gesture.state == .began || gesture.state == .changed)
        guard !textSelectionCoordinator.isSelecting, !isMenuVisible, canNavigateReaderPages else {
            cancelPageTurnForContentChange()
            return
        }
        if gesture.state == .began {
            settlePageTurnForNewInput()
            cancelPageTurnForContentChange()
        }
        guard pageTurnTransition?.isFinishing != true else { return }
        let style = effectiveReaderPageAnimation()
        let vertical = style == 3
        let context = ReaderPageTurnGestureDecision.Context(
            bookURL: bookURL, chapterIndex: chapterIndex, chapterURL: currentChapterURL,
            pageIndex: currentPageIndex, bounds: renderView.bounds, style: style)
        if gesture.state == .began { pageTurnGesture.begin(in: context) }
        guard pageTurnGesture.context == context else {
            cancelPageTurnForContentChange()
            return
        }

        switch gesture.state {
        case .began, .changed:
            resetReaderScreenTimeoutTimer()
            guard
                let update = pageTurnGesture.move(
                    translation: gesture.translation(in: renderView), touch: gesture.location(in: renderView),
                    slop: ReaderLocalSettings.load().effectivePageTouchSlop)
            else {
                if pageTurnGesture.context == nil { cancelPageTurnForContentChange() }
                return
            }
            guard style != 4 else { return }
            beginInteractivePageTurn(
                next: update.direction > 0, vertical: vertical, style: style, origin: update.origin, touch: update.touch)
            updateInteractivePageTurn(offset: update.offset, touch: update.touch)
        case .ended:
            // UP does not sample movement again; the final MOVE owns reversal/cancellation.
            let direction = pageTurnGesture.finish(in: context)
            if pageTurnTransition == nil {
                if let direction { animateDiscretePageTurn(next: direction > 0, vertical: vertical, style: style) }
            } else {
                finishInteractivePageTurn(commit: direction != nil)
            }
        case .cancelled, .failed:
            pageTurnGesture.reset()
            finishInteractivePageTurn(commit: false)
        default:
            break
        }
    }

    func turnPageByTap(next: Bool, point: CGPoint? = nil) {
        guard canNavigateReaderPages else { return }
        settlePageTurnForNewInput()
        guard pageTurnTransition == nil else { return }
        let pageAnimation = effectiveReaderPageAnimation()
        switch pageAnimation {
        case 4:
            next ? nextPage() : previousPage()
        case 3:
            let animated = ReaderLocalSettings.load().noAnimScrollPage == false
            guard scrollPagerView.scrollByViewport(forward: next, animated: animated) else {
                next ? openNextChapter() : openPreviousChapter(toLast: true)
                return
            }
        default:
            animateDiscretePageTurn(next: next, vertical: false, style: pageAnimation, origin: point)
        }
    }

    private func animateDiscretePageTurn(next: Bool, vertical: Bool, style: Int, origin: CGPoint? = nil) {
        guard pageTurnTransition == nil, canNavigateReaderPages else { return }
        guard style != 4, beginInteractivePageTurn(next: next, vertical: vertical, style: style, origin: origin) else {
            next ? nextPage() : previousPage()
            return
        }
        finishInteractivePageTurn(commit: true)
    }

    @discardableResult
    private func beginInteractivePageTurn(
        next: Bool, vertical: Bool, style: Int, origin: CGPoint? = nil, touch: CGPoint? = nil
    ) -> Bool {
        let direction = next ? 1 : -1
        if let transition = pageTurnTransition {
            return transition.direction == direction && transition.vertical == vertical && transition.style == style
        }
        let targetIndex = currentPageIndex + direction * nonScrollPageStep()
        guard canNavigateReaderPages, pages.indices.contains(targetIndex) else { return false }
        let snapshot: UIView
        if style == 2 {
            snapshot = UIView(frame: renderView.frame)
        } else {
            guard let captured = renderView.snapshotView(afterScreenUpdates: false) else { return false }
            snapshot = captured
        }

        // Preview the target without changing the committed page, anchor, or progress queue.
        let preview = ReaderRenderView(frame: renderView.frame)
        preview.isUserInteractionEnabled = false
        preview.accessibilityElementsHidden = true
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true
        preview.theme = readerRenderTheme()
        preview.bookURL = bookURL
        preview.chrome = makeChromeSnapshot(pageIndex: targetIndex)
        preview.highlightedBlockIndex = readAloudHighlightedBlockIndex()
        preview.setPageLayouts(
            primary: pages[targetIndex],
            trailing: nonScrollPageStep() == 2 ? pages[safe: targetIndex + 1] : nil
        )
        let transition = ReaderPageTurnTransition(
            sourceIndex: currentPageIndex, targetIndex: targetIndex,
            bookURL: bookURL, chapterIndex: chapterIndex, chapterURL: currentChapterURL,
            bounds: renderView.bounds, direction: direction, vertical: vertical, style: style,
            outgoing: snapshot, incoming: preview
        )
        snapshot.frame = renderView.frame
        if let viewport = transition.coverViewport {
            snapshot.frame = viewport.bounds
            preview.frame = viewport.bounds
        }
        if style == 2 {
            let scale = renderView.window?.screen.scale ?? renderView.traitCollection.displayScale
            let background = readerRenderTheme().visibleBackgroundColor
            guard
                let bitmaps = ReaderPageTurnBitmaps.capture(
                    outgoing: renderView, incoming: preview, displayScale: scale, backgroundColor: background
                )
            else { return false }
            let start = origin ?? CGPoint(x: renderView.bounds.width * 0.9, y: renderView.bounds.height * 0.9)
            let initialTouch =
                touch
                ?? CGPoint(
                    x: next ? renderView.bounds.width * 0.9 : 0,
                    y: next && start.y <= renderView.bounds.height / 2
                        ? 1 / scale : renderView.bounds.height * (next ? 0.9 : 1)
                )
            let simulation = ReaderSimulationTurnView(
                frame: renderView.frame, bitmaps: bitmaps, direction: direction,
                origin: start, touch: initialTouch, backgroundColor: background
            )
            if touch != nil { simulation.update(touch: initialTouch) }
            transition.simulationView = simulation
            view.insertSubview(simulation, aboveSubview: renderView)
        } else if let viewport = transition.coverViewport {
            snapshot.transform = transition.outgoingTransform(progress: 0)
            preview.transform = transition.incomingTransform(progress: 0)
            if transition.coverIncomingAboveOutgoing {
                viewport.addSubview(snapshot)
                viewport.addSubview(preview)
            } else {
                viewport.addSubview(preview)
                viewport.addSubview(snapshot)
            }
            view.insertSubview(viewport, aboveSubview: renderView)
        } else {
            snapshot.transform = transition.outgoingTransform(progress: 0)
            preview.transform = transition.incomingTransform(progress: 0)
            view.insertSubview(preview, aboveSubview: renderView)
            view.insertSubview(snapshot, aboveSubview: preview)
        }
        preview.layoutIfNeeded()
        transition.installCoverShadow(
            displayScale: renderView.window?.screen.scale ?? renderView.traitCollection.displayScale)
        pageTurnTransition = transition
        // Opaque previews cover the body; keep its recognizers reachable during animation.
        return true
    }

    private func updateInteractivePageTurn(offset: CGFloat, touch: CGPoint) {
        guard let transition = pageTurnTransition, !transition.isFinishing, offset.isFinite else { return }
        if let simulation = transition.simulationView {
            simulation.update(touch: touch)
            return
        }
        let progress = min(max(-offset * CGFloat(transition.direction) / max(transition.travel, 1), 0), 1)
        applyPageTurn(progress: progress, transition: transition)
    }

    private func applyPageTurn(progress: CGFloat, transition: ReaderPageTurnTransition) {
        transition.progress = progress
        let snapshot = transition.outgoing
        snapshot.transform = transition.outgoingTransform(progress: progress)
        transition.incoming.transform = transition.incomingTransform(progress: progress)
    }

    private func finishInteractivePageTurn(commit: Bool) {
        guard let transition = pageTurnTransition, !transition.isFinishing else { return }
        transition.isFinishing = true
        transition.commitsPage = commit
        if let simulation = transition.simulationView {
            simulation.animate(commit: commit) { [weak self] finished in
                self?.completePageTurn(finished: finished, commit: commit, transition: transition)
            }
            return
        }
        let remaining = transition.travel * abs((commit ? 1 : 0) - transition.progress)
        let duration = ReaderPageTurnGestureDecision.animationDuration(
            horizontalDistance: transition.vertical ? 0 : remaining,
            verticalDistance: transition.vertical ? remaining : 0, bounds: transition.bounds.size)
        UIView.animate(
            withDuration: duration, delay: 0,
            options: [.curveLinear, .allowUserInteraction]
        ) { [weak self] in
            self?.applyPageTurn(progress: commit ? 1 : 0, transition: transition)
        } completion: { [weak self] finished in
            self?.completePageTurn(finished: finished, commit: commit, transition: transition)
        }
    }

    private func completePageTurn(finished: Bool, commit: Bool, transition: ReaderPageTurnTransition) {
        guard pageTurnTransition === transition else { return }
        let accepts =
            finished && commit && canNavigateReaderPages
            && bookURL == transition.bookURL && chapterIndex == transition.chapterIndex
            && currentChapterURL == transition.chapterURL && currentPageIndex == transition.sourceIndex
            && renderView.bounds == transition.bounds && pages.indices.contains(transition.targetIndex)
        cancelPageTurnForContentChange()
        guard accepts else { return }
        currentPageIndex = transition.targetIndex
        renderCurrentPage()
        updateMenuState()
    }

    private func settlePageTurnForNewInput() {
        guard let transition = pageTurnTransition, transition.isFinishing else { return }
        // Android abortAnim commits the pending destination before a new DOWN begins.
        completePageTurn(finished: true, commit: transition.commitsPage, transition: transition)
    }

    func cancelPageTurnForContentChange() {
        pageTurnGesture.reset()
        guard let transition = pageTurnTransition else { return }
        // Revoke ownership before removing animations, whose completion may run immediately.
        pageTurnTransition = nil
        transition.simulationView?.stop()
        transition.simulationView?.removeFromSuperview()
        transition.outgoing.layer.removeAllAnimations()
        transition.incoming.layer.removeAllAnimations()
        transition.removeCoverShadow()
        transition.outgoing.removeFromSuperview()
        transition.incoming.removeFromSuperview()
        transition.coverViewport?.removeFromSuperview()
        renderView.alpha = 1
    }

}
