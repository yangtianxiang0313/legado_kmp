import CoreText
import UIKit
import UIKit.UIGestureRecognizerSubclass
import shared

/// item_log.xml: selectable, web-linked text without row padding or separators.
final class BookSourceDebugLogCell: UITableViewCell, UITextViewDelegate {
    static let reuseIdentifier = "BookSourceDebugLogCell"

    var onInteractionChange: (() -> Void)?
    private(set) var isInteracting = false
    private var logID: UUID?
    private var interactionGeneration: UInt64 = 0

    private let messageView = UITextView()
    private var hasTouches = false
    private var menuPresented = false
    private var paletteUpdateInProgress = false
    private let touchMonitor = BookSourceDebugTouchMonitor()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func configure(id: UUID, message: String) {
        guard logID != id || messageView.text != message else { return }
        interactionGeneration &+= 1
        logID = id
        messageView.text = message
        messageView.selectedRange = NSRange(location: 0, length: 0)
        applyTypographyAndPalette()
        updateInteraction()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        interactionGeneration &+= 1
        messageView.selectedRange = NSRange(location: 0, length: 0)
        messageView.text = nil
        logID = nil
        hasTouches = false
        menuPresented = false
        touchMonitor.isEnabled = false
        touchMonitor.isEnabled = true
        updateInteraction()
        onInteractionChange = nil
    }

    func suspendTransientInteraction() {
        interactionGeneration &+= 1
        hasTouches = false
        menuPresented = false
        touchMonitor.isEnabled = false
        touchMonitor.isEnabled = true
        updateInteraction()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTypographyAndPalette()
    }

    private func configureViews() {
        selectionStyle = .none
        isAccessibilityElement = false
        accessibilityIdentifier = "bookSource.debug.log"
        preservesSuperviewLayoutMargins = false
        contentView.preservesSuperviewLayoutMargins = false
        directionalLayoutMargins = .zero
        contentView.directionalLayoutMargins = .zero
        separatorInset = .zero

        messageView.delegate = self
        touchMonitor.cancelsTouchesInView = false
        touchMonitor.delaysTouchesBegan = false
        touchMonitor.delaysTouchesEnded = false
        touchMonitor.onTouchesChange = { [weak self] active in
            guard let self else { return }
            self.hasTouches = active
            self.updateInteraction()
        }
        messageView.addGestureRecognizer(touchMonitor)
        messageView.isEditable = false
        messageView.isSelectable = true
        messageView.isScrollEnabled = false
        messageView.dataDetectorTypes = .link
        messageView.backgroundColor = .clear
        messageView.textContainerInset = .zero
        messageView.textContainer.lineFragmentPadding = 0
        messageView.textContainer.widthTracksTextView = true
        messageView.contentInsetAdjustmentBehavior = .never
        // Reopen the file-backed variable font on trait changes; UIKit's automatic
        // font scaling can substitute a different face for this unregistered asset.
        messageView.adjustsFontForContentSizeCategory = false
        messageView.scrollsToTop = false
        messageView.accessibilityIdentifier = "bookSource.debug.log.message"
        messageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(messageView)
        NSLayoutConstraint.activate([
            messageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            messageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            messageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            messageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        applyTypographyAndPalette()
    }

    private func applyTypographyAndPalette() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        if messageView.font != font { messageView.font = font }
        // item_log.xml inherits includeFontPadding=true. TextKit already lays out
        // ascent/descent; add only the font-wide top/bottom difference, once around
        // the complete message, rather than adding padding to every wrapped line.
        let bounds = CTFontGetBoundingBox(font as CTFont)
        let scale = max(1, traitCollection.displayScale)
        let fontPadding = UIEdgeInsets(
            top: max(0, ceil(bounds.maxY * scale) / scale - font.ascender), left: 0,
            bottom: max(0, -floor(bounds.minY * scale) / scale + font.descender), right: 0)
        if messageView.textContainerInset != fontPadding { messageView.textContainerInset = fontPadding }
        applyPalette()
    }

    @objc private func applyPalette() {
        let palette = ReaderTocPalette(traits: traitCollection)
        backgroundColor = palette.background
        contentView.backgroundColor = palette.background
        // Keep text storage, selection, responder and scroll state in place.
        paletteUpdateInProgress = true
        // Widget.TextView -> TextAppearance.AppCompat.Small uses textColorTertiary.
        messageView.textColor = palette.secondaryText
        messageView.tintColor = palette.accent
        messageView.linkTextAttributes = [
            .foregroundColor: palette.accent,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        paletteUpdateInProgress = false
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
        guard !paletteUpdateInProgress else { return }
        updateInteraction()
    }

    func textView(_ textView: UITextView, willPresentEditMenuWith animator: UIEditMenuInteractionAnimating) {
        interactionGeneration &+= 1
        menuPresented = true
        updateInteraction()
    }

    func textView(_ textView: UITextView, willDismissEditMenuWith animator: UIEditMenuInteractionAnimating) {
        let generation = interactionGeneration
        animator.addCompletion { [weak self] in
            guard let self, self.interactionGeneration == generation else { return }
            self.menuPresented = false
            self.updateInteraction(notifyEvenIfUnchanged: true)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            interactionGeneration &+= 1
            hasTouches = false
            menuPresented = false
        }
        updateInteraction()
    }

    private func updateInteraction(notifyEvenIfUnchanged: Bool = false) {
        let active = window != nil && (hasTouches || menuPresented || messageView.selectedRange.length > 0)
        let changed = isInteracting != active
        isInteracting = active
        if changed || notifyEvenIfUnchanged { onInteractionChange?() }
    }
}

/// Observes from touch-down without recognizing or competing with UIKit gestures.
final class BookSourceDebugTouchMonitor: UIGestureRecognizer {
    var onTouchesChange: ((Bool) -> Void)?
    private var touches = Set<UITouch>()

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        self.touches.formUnion(touches)
        onTouchesChange?(true)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        finish(touches)
    }

    override func reset() {
        super.reset()
        touches.removeAll()
        onTouchesChange?(false)
    }

    private func finish(_ endedTouches: Set<UITouch>) {
        touches.subtract(endedTouches)
        if touches.isEmpty {
            onTouchesChange?(false)
            state = .failed
        }
    }
}

/// Owns both streamed and terminal delivery; UIKit only sees a stable, reconciled snapshot.
@MainActor
final class BookSourceDebugLogDelivery: NSObject, UITableViewDataSource, UITableViewDelegate {
    private struct Key: Hashable {
        let state: Int32
        let message: String
        let elapsed: Int64

        init(_ line: BookSourceDebugLogLine) {
            state = line.state
            message = line.message
            elapsed = line.elapsedMs
        }

        init(message: String) {
            state = -1
            self.message = message
            elapsed = 0
        }

        init(state: Int32, message: String, elapsed: Int64) {
            self.state = state
            self.message = message
            self.elapsed = elapsed
        }
    }

    private struct Row {
        let id: UUID
        let key: Key
    }

    private struct Anchor {
        let id: UUID?
        let distance: CGFloat
        let offset: CGPoint
        let followsTail: Bool
    }

    private let table: UITableView
    private let touchMonitor = BookSourceDebugTouchMonitor()
    private var displayed: [Row] = []
    private var pending: [Row] = []
    private var work: DispatchWorkItem?
    private var active = false
    private var hasTouches = false
    private var applying = false
    private var layoutAnchor: Anchor?
    var canDeliver: (() -> Bool)?

    init(table: UITableView) {
        self.table = table
        super.init()
        table.dataSource = self
        table.delegate = self
        touchMonitor.cancelsTouchesInView = false
        touchMonitor.delaysTouchesBegan = false
        touchMonitor.delaysTouchesEnded = false
        touchMonitor.onTouchesChange = { [weak self] active in
            self?.hasTouches = active
            self?.interactionChanged()
        }
        table.addGestureRecognizer(touchMonitor)
    }

    deinit { work?.cancel() }

    func reset() {
        work?.cancel()
        work = nil
        layoutAnchor = nil
        displayed = []
        pending = []
        table.reloadData()
        table.setContentOffset(CGPoint(x: 0, y: -table.adjustedContentInset.top), animated: false)
    }

    func append(state: Int32, message: String, elapsed: Int64) {
        pending.append(Row(id: UUID(), key: Key(state: state, message: message, elapsed: elapsed)))
        requestDelivery()
    }

    func append(error: String) {
        pending.append(Row(id: UUID(), key: Key(message: error)))
        requestDelivery()
    }

    func finish(_ logs: [BookSourceDebugLogLine]) {
        // Match occurrence as well as content: repeated identical logs remain distinct rows.
        var identities: [Key: [UUID]] = [:]
        for row in pending { identities[row.key, default: []].append(row.id) }
        var occurrences: [Key: Int] = [:]
        pending = logs.filter { ![10, 20, 30, 40].contains($0.state) }.map { line in
            let key = Key(line)
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            let ids = identities[key] ?? []
            return Row(id: ids.indices.contains(occurrence) ? ids[occurrence] : UUID(), key: key)
        }
        requestDelivery()
    }

    func setPresentationActive(_ active: Bool) {
        guard self.active != active else { return }
        self.active = active
        if active {
            requestDelivery()
        } else {
            work?.cancel()
            work = nil
            hasTouches = false
            touchMonitor.isEnabled = false
            touchMonitor.isEnabled = true
            for cell in table.visibleCells {
                (cell as? BookSourceDebugLogCell)?.suspendTransientInteraction()
            }
        }
    }

    private var isInteracting: Bool {
        let pan = table.panGestureRecognizer.state
        return hasTouches || table.isTracking || table.isDragging || table.isDecelerating
            || pan == .began || pan == .changed
            || table.visibleCells.contains { ($0 as? BookSourceDebugLogCell)?.isInteracting == true }
    }

    private func interactionChanged() {
        work?.cancel()
        work = nil
        requestDelivery()
    }

    private func requestDelivery() {
        guard active, !applying, work == nil, displayed.map(\.id) != pending.map(\.id) else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.work = nil
            guard self.active, !self.isInteracting else { return }
            guard self.canDeliver?() != false else {
                // A non-fullscreen presentation may not send this page appearance callbacks.
                self.requestDelivery()
                return
            }
            self.deliver()
        }
        work = item
        // Touch-up, edit-menu dismissal and navigation completion must settle before layout.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func captureAnchor(survivors: Set<UUID>? = nil) -> Anchor {
        table.layoutIfNeeded()
        let minimum = -table.adjustedContentInset.top
        let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let epsilon = 1 / max(1, table.window?.screen.scale ?? 1)
        let visibleTop = table.contentOffset.y + table.adjustedContentInset.top
        let visibleBottom = table.contentOffset.y + table.bounds.height - table.adjustedContentInset.bottom
        let paths = (table.indexPathsForVisibleRows ?? []).sorted()
        let lastPath = IndexPath(row: max(0, displayed.count - 1), section: 0)
        let lastLogVisible =
            displayed.isEmpty
            || (paths.contains(lastPath) && table.rectForRow(at: lastPath).maxY <= visibleBottom + epsilon)
        let followsTail = lastLogVisible && abs(table.contentOffset.y - maximum) <= epsilon
        var path = paths.first { path in
            displayed.indices.contains(path.row)
                && (survivors?.contains(displayed[path.row].id) ?? true)
                && table.rectForRow(at: path).maxY > visibleTop
        }
        if path == nil, let survivors, !survivors.isEmpty {
            let pivot = min(paths.first?.row ?? 0, displayed.count)
            let forward = (pivot..<displayed.count).first { survivors.contains(displayed[$0].id) }
            let backward = (0..<pivot).reversed().first { survivors.contains(displayed[$0].id) }
            path = (forward ?? backward).map { IndexPath(row: $0, section: 0) }
        }
        return Anchor(
            id: path.map { displayed[$0.row].id },
            distance: path.map { table.rectForRow(at: $0).minY - visibleTop } ?? 0,
            offset: table.contentOffset, followsTail: followsTail)
    }

    private func restore(_ anchor: Anchor) {
        guard !displayed.isEmpty else { return }
        if anchor.followsTail {
            table.scrollToRow(at: IndexPath(row: displayed.count - 1, section: 0), at: .bottom, animated: false)
        }
        for _ in 0..<2 {
            table.layoutIfNeeded()
            let minimum = -table.adjustedContentInset.top
            let maximum = max(minimum, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
            let target: CGFloat
            if anchor.followsTail {
                target = maximum
            } else if let index = displayed.firstIndex(where: { $0.id == anchor.id }) {
                target =
                    table.rectForRow(at: IndexPath(row: index, section: 0)).minY
                    - anchor.distance - table.adjustedContentInset.top
            } else {
                target = anchor.offset.y
            }
            table.setContentOffset(CGPoint(x: anchor.offset.x, y: min(maximum, max(minimum, target))), animated: false)
        }
    }

    private func deliver() {
        let target = pending
        let difference = target.map(\.id).difference(from: displayed.map(\.id))
        guard !difference.isEmpty else { return }
        applying = true
        let anchor = layoutAnchor ?? captureAnchor(survivors: Set(target.map(\.id)))
        layoutAnchor = nil
        UIView.performWithoutAnimation {
            displayed = target
            table.beginUpdates()
            for change in difference {
                switch change {
                case .remove(let index, _, _): table.deleteRows(at: [IndexPath(row: index, section: 0)], with: .none)
                case .insert(let index, _, _): table.insertRows(at: [IndexPath(row: index, section: 0)], with: .none)
                }
            }
            table.endUpdates()
            restore(anchor)
        }
        applying = false
    }

    func prepareForViewportChange() {
        guard !applying, !isInteracting, !displayed.isEmpty else { return }
        layoutAnchor = captureAnchor()
    }

    func finishViewportChange() {
        guard !applying, let anchor = layoutAnchor else { return }
        layoutAnchor = nil
        if !isInteracting { restore(anchor) }
        requestDelivery()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { displayed.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: BookSourceDebugLogCell.reuseIdentifier, for: indexPath) as! BookSourceDebugLogCell
        let row = displayed[indexPath.row]
        cell.onInteractionChange = { [weak self] in self?.interactionChanged() }
        cell.configure(id: row.id, message: row.key.message)
        return cell
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { interactionChanged() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { interactionChanged() }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { interactionChanged() }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { interactionChanged() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { interactionChanged() }
}
