import UIKit
import UIKit.UIGestureRecognizerSubclass
import shared

/// URL identity follows BookSourceAdapter; requested revisions never follow an older displayed list.
@MainActor
final class SourceManagementListCoordinator: NSObject, UITableViewDelegate {
    private enum Section { case sources }

    final class Binding {
        let sourceURL: String
        fileprivate let context: UUID
        fileprivate let revision: UUID
        fileprivate let input: UUID
        fileprivate let mutationInput: UUID
        fileprivate weak var cell: AndroidReplicaSourceCell?

        fileprivate init(
            sourceURL: String, context: UUID, revision: UUID, input: UUID, mutationInput: UUID,
            cell: AndroidReplicaSourceCell
        ) {
            self.sourceURL = sourceURL
            self.context = context
            self.revision = revision
            self.input = input
            self.mutationInput = mutationInput
            self.cell = cell
        }
    }

    private struct Row {
        let source: BookSource
        let domainHeader: String?
        var revision = UUID()
    }

    private struct Update {
        let urls: [String]
        let rows: [String: Row]
        let context: UUID
        let showsEmpty: Bool
    }

    private struct Anchor {
        let url: String
        let distance: CGFloat
    }

    private struct Restoration {
        let anchors: [Anchor]
        let offset: CGFloat
        let interaction: Int
        let context: UUID
    }

    var canUsePage: (() -> Bool)?
    var onDeliver: ((Int, Bool) -> Void)?
    var onPresentationChange: ((Bool) -> Void)?
    var onPresentationInvalidated: (() -> Void)?
    var onSelectionChange: ((String) -> Void)?
    var onEnabledChange: ((String, Bool) -> Void)?
    var onEdit: ((BookSource) -> Void)?
    var onMore: ((Binding, UIView) -> Void)?

    private let table: UITableView
    private let contact = SourceManagementContactObserver()
    private var dataSource: UITableViewDiffableDataSource<Section, String>!
    private var requested: Update?
    private var presented: Update?
    private var providerRows: [String: Row] = [:]
    private var providerContext = UUID()
    private var bindings: [String: Binding] = [:]
    private var query: String?
    private var configuration: SourceManagementListConfiguration?
    private var context = UUID()
    private var input = UUID()
    private var mutationInput = UUID()
    private var selectedURLs: Set<String> = []
    private var presentedSelection: Set<String> = []
    private var providerSelection: Set<String> = []
    private var mutationsEnabled = true
    private var presentationActive = false
    private var menuCovered = false
    private var modalID: UUID?
    private var applicationSuspended = false
    private var sceneSuspended = false
    private var windowSuspended = false
    private var pending = false
    private var needsDeliveryNotification = false
    private var needsRebinding = false
    private var scheduled = false
    private var applying = false
    private var cancelledContact = false
    private var finishingContact = false
    private var lastInputActive: Bool?
    private var lastCellsActive: Bool?
    private var lastMutationsEnabled: Bool?
    private var interaction = 0
    private var restoration: Restoration?

    init(tableView: UITableView, interactionView: UIView) {
        table = tableView
        super.init()
        applicationSuspended = UIApplication.shared.applicationState != .active
        table.register(AndroidReplicaSourceCell.self, forCellReuseIdentifier: AndroidReplicaSourceCell.reuseIdentifier)
        table.delegate = self
        dataSource = UITableViewDiffableDataSource<Section, String>(tableView: table) { [weak self] table, path, url in
            guard let self, let row = self.providerRows[url] else { return nil }
            let cell =
                table.dequeueReusableCell(
                    withIdentifier: AndroidReplicaSourceCell.reuseIdentifier, for: path) as! AndroidReplicaSourceCell
            let binding = Binding(
                sourceURL: url, context: self.providerContext, revision: row.revision, input: self.input,
                mutationInput: self.mutationInput, cell: cell)
            self.bindings[url] = binding
            cell.configure(
                source: row.source, isSelected: self.providerSelection.contains(url),
                mutationsEnabled: self.mutationsEnabled, domainHeader: row.domainHeader)
            cell.canInteract = { [weak self] in self?.source(for: binding) != nil }
            cell.onSelectionChange = { [weak self] in
                guard let self, self.source(for: binding) != nil else { return }
                self.onSelectionChange?(url)
            }
            cell.onEnabledChange = { [weak self] enabled in
                guard let self, self.mutationSource(for: binding) != nil else { return }
                self.onEnabledChange?(url, enabled)
            }
            cell.onEdit = { [weak self] in
                guard let self, let source = self.mutationSource(for: binding) else { return }
                self.onEdit?(source)
            }
            cell.onMore = { [weak self, weak cell] in
                guard let self, let cell, self.mutationSource(for: binding) != nil else { return }
                self.onMore?(binding, cell.moreMenuAnchor)
            }
            cell.setPresentationActive(self.isInputActive && !self.applying)
            return cell
        }
        dataSource.defaultRowAnimation = .none
        contact.onBegin = { [weak self] in
            guard let self else { return }
            self.cancelledContact = false
            self.interaction &+= 1
            self.restoration = nil
        }
        contact.onEnd = { [weak self] cancelled in
            guard let self else { return }
            self.cancelledContact = self.cancelledContact || cancelled
            self.finishingContact = true
            // Let UIControl consume touch-up before diffable can reconfigure/reuse its cell.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishingContact = false
                self.resumeDelivery()
            }
        }
        interactionView.addGestureRecognizer(contact)
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Selection and delivery stay available while a source mutation is running.
    var isInputActive: Bool {
        presentationActive && sceneActive && canUsePage?() == true && !menuCovered && modalID == nil
    }

    var isMutationActive: Bool { isInputActive && mutationsEnabled }

    func render(sources: [BookSource], query: String, configuration: SourceManagementListConfiguration, showsEmpty: Bool) {
        if self.query != query || self.configuration != configuration {
            self.query = query
            self.configuration = configuration
            context = UUID()
        }
        let headers = SourceManagementListPolicy.domainHeaders(sources: sources, grouped: configuration.groupsByDomain)
        var urls: [String] = []
        var rows: [String: Row] = [:]
        for source in sources where rows[source.bookSourceUrl] == nil {
            let url = source.bookSourceUrl
            urls.append(url)
            var row = Row(source: source, domainHeader: headers[url])
            if let previous = requested?.rows[url], source.hasSameManagementContent(as: previous.source) {
                row.revision = previous.revision
            }
            rows[url] = row
        }
        // Compare consecutive requests, including those staged during touch/modal/background.
        requested = Update(urls: urls, rows: rows, context: context, showsEmpty: showsEmpty)
        pending = true
        resumeDelivery()
    }

    func setSelection(_ urls: Set<String>) {
        guard selectedURLs != urls else { return }
        selectedURLs = urls
        pending = true
        resumeDelivery()
    }

    func setMutationsEnabled(_ enabled: Bool) {
        guard mutationsEnabled != enabled else { return }
        mutationsEnabled = enabled
        mutationInput = UUID()
        // Renew mutation callbacks after busy without cancelling an in-flight selection touch.
        if enabled { needsRebinding = true }
        updateAvailability()
        resumeDelivery()
    }

    /// This authorizes selection only; source-changing actions must use mutationSource(for:).
    func source(for binding: Binding, allowingMenu: Bool = false) -> BookSource? {
        let pan = table.panGestureRecognizer.state
        guard presentationActive, sceneActive, canUsePage?() == true, modalID == nil, !applying,
            !table.isDragging, !table.isDecelerating, !table.hasActiveDrag, !table.hasActiveDrop,
            pan != .began, pan != .changed,
            allowingMenu || (!menuCovered && !cancelledContact),
            binding.input == input, hasCurrentSource(binding), bindings[binding.sourceURL] === binding,
            presented?.context == binding.context, presented?.rows[binding.sourceURL]?.revision == binding.revision,
            let cell = binding.cell, let window = table.window, cell.window === window,
            let path = table.indexPath(for: cell), table.cellForRow(at: path) === cell,
            dataSource.itemIdentifier(for: path) == binding.sourceURL,
            dataSource.indexPath(for: binding.sourceURL) == path,
            table.indexPathsForVisibleRows?.contains(path) == true,
            isVisible(cell, in: window, allowingMenu: allowingMenu)
        else { return nil }
        return requested?.rows[binding.sourceURL]?.source
    }

    func mutationSource(for binding: Binding, allowingMenu: Bool = false) -> BookSource? {
        guard mutationsEnabled, binding.mutationInput == mutationInput else { return nil }
        return source(for: binding, allowingMenu: allowingMenu)
    }

    /// Confirmation callbacks retain source/filter identity, not a potentially reused cell or index.
    func hasCurrentSource(_ binding: Binding) -> Bool {
        binding.context == context && requested?.rows[binding.sourceURL]?.revision == binding.revision
    }

    func setPresentationActive(_ active: Bool) {
        if active != presentationActive {
            presentationActive = active
            if !active {
                invalidateInput()
            } else {
                applicationSuspended = UIApplication.shared.applicationState != .active
                sceneSuspended = table.window?.windowScene?.activationState != .foregroundActive
                windowSuspended = table.window?.isKeyWindow != true
                cancelledContact = false
            }
        }
        updateAvailability()
        resumeDelivery()
    }

    func setMenuCovered(_ covered: Bool) {
        menuCovered = covered
        updateAvailability()
        resumeDelivery()
    }

    func observePresentation(of controller: UIViewController) {
        let id = UUID()
        modalID = id
        invalidateInput()
        let observer = SourceManagementPresentationObserver(frame: .zero)
        observer.isUserInteractionEnabled = false
        observer.isAccessibilityElement = false
        observer.onDetach = { [weak self, weak controller] in
            let resume = { [weak self] in
                guard let self, self.modalID == id else { return }
                self.modalID = nil
                self.updateAvailability()
                self.resumeDelivery()
            }
            if let transition = controller?.transitionCoordinator {
                if !transition.animate(alongsideTransition: nil, completion: { _ in resume() }) { resume() }
            } else {
                resume()
            }
        }
        controller.view.addSubview(observer)
        updateAvailability()
    }

    func resumeDelivery() {
        updateAvailability()
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.deliver()
        }
    }

    func scrollViewWillBeginDragging(_: UIScrollView) {
        interaction &+= 1
        restoration = nil
        cancelledContact = true
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate: Bool) {
        if !willDecelerate { resumeDelivery() }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) { resumeDelivery() }
    func scrollViewDidEndScrollingAnimation(_: UIScrollView) { resumeDelivery() }

    func tableView(_: UITableView, willDisplay cell: UITableViewCell, forRowAt _: IndexPath) {
        guard let cell = cell as? AndroidReplicaSourceCell else { return }
        cell.setMutationEnabled(mutationsEnabled)
        cell.setPresentationActive(isInputActive && !applying)
    }

    func tableView(_: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt _: IndexPath) {
        if !table.visibleCells.contains(where: { $0 === cell }) {
            (cell as? AndroidReplicaSourceCell)?.setPresentationActive(false)
        }
    }

    private var sceneActive: Bool {
        guard !applicationSuspended, !sceneSuspended, !windowSuspended,
            UIApplication.shared.applicationState == .active, let window = table.window
        else { return false }
        return window.isKeyWindow && !window.isHidden && window.alpha > 0.01
            && window.windowScene?.activationState == .foregroundActive
    }

    private var canDeliver: Bool {
        let pan = table.panGestureRecognizer.state
        return isInputActive && !applying && !contact.hasContact && !finishingContact && !table.isTracking
            && !table.isDragging && !table.isDecelerating && !table.hasActiveDrag && !table.hasActiveDrop
            && pan != .began && pan != .changed
    }

    private func invalidateInput() {
        input = UUID()
        bindings.removeAll()
        needsRebinding = true
        contact.cancelContact()
        cancelledContact = true
    }

    private func updateAvailability() {
        let active = isInputActive
        let cellsActive = active && !applying
        if lastCellsActive != cellsActive || lastMutationsEnabled != mutationsEnabled {
            lastCellsActive = cellsActive
            lastMutationsEnabled = mutationsEnabled
            for case let cell as AndroidReplicaSourceCell in table.visibleCells {
                cell.setMutationEnabled(mutationsEnabled)
                cell.setPresentationActive(cellsActive)
            }
        }
        guard lastInputActive != active else { return }
        lastInputActive = active
        onPresentationChange?(active)
    }

    @objc private func activationChanged(_ notification: Notification) {
        switch notification.name {
        case UIApplication.willResignActiveNotification: applicationSuspended = true
        case UIApplication.didBecomeActiveNotification: applicationSuspended = false
        case UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification:
            guard let scene = notification.object as? UIScene, scene === table.window?.windowScene else { return }
            sceneSuspended = notification.name != UIScene.didActivateNotification
        case UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification:
            guard let window = notification.object as? UIWindow, window === table.window else { return }
            windowSuspended = notification.name == UIWindow.didResignKeyNotification
        default: return
        }
        if !sceneActive {
            invalidateInput()
            onPresentationInvalidated?()
        }
        resumeDelivery()
    }

    private func deliver() {
        guard canDeliver else { return }
        cancelledContact = false
        restorePosition()
        guard pending || needsRebinding, let update = requested else {
            notifyDelivery()
            return
        }
        let rebind = needsRebinding
        pending = false
        needsRebinding = false
        let selection = selectedURLs
        let previous = dataSource.snapshot().itemIdentifiers
        let retained = Set(previous)
        // BookSourceActivity replaces adapter items without scrollToPosition on query/sort changes.
        let position = capturePosition(context: update.context)
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.sources])
        snapshot.appendItems(update.urls)
        snapshot.reconfigureItems(
            update.urls.filter { url in
                retained.contains(url)
                    && (rebind || presented?.context != update.context
                        || presented?.rows[url]?.revision != update.rows[url]?.revision
                        || presented?.rows[url]?.domainHeader != update.rows[url]?.domainHeader
                        || presentedSelection.contains(url) != selection.contains(url))
            })
        providerRows = (presented?.rows ?? [:]).merging(update.rows) { _, new in new }
        providerContext = update.context
        providerSelection = selection
        applying = true
        updateAvailability()
        dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
            guard let self else { return }
            self.presented = update
            self.presentedSelection = selection
            self.needsDeliveryNotification = true
            self.providerRows = update.rows
            self.bindings = self.bindings.filter { url, binding in
                binding.cell != nil && binding.context == update.context && binding.input == self.input
                    && binding.revision == update.rows[url]?.revision
            }
            self.applying = false
            self.updateAvailability()
            self.restoration = position
            if self.canDeliver {
                self.restorePosition()
                self.notifyDelivery()
            }
            if self.pending || self.needsRebinding { self.resumeDelivery() }
        }
    }

    private func notifyDelivery() {
        guard canDeliver, !pending, !needsRebinding, needsDeliveryNotification,
            let update = presented, update.context == context
        else { return }
        needsDeliveryNotification = false
        onDeliver?(update.urls.count, update.showsEmpty)
    }

    private func capturePosition(context: UUID) -> Restoration {
        let anchors = (table.indexPathsForVisibleRows ?? []).sorted().compactMap { path -> Anchor? in
            guard let url = dataSource.itemIdentifier(for: path) else { return nil }
            return Anchor(url: url, distance: table.rectForRow(at: path).minY - table.contentOffset.y)
        }
        return Restoration(
            anchors: anchors, offset: table.contentOffset.y, interaction: interaction, context: context)
    }

    private func restorePosition() {
        guard canDeliver, let position = restoration else { return }
        restoration = nil
        guard position.interaction == interaction, position.context == context else { return }
        table.layoutIfNeeded()
        let top = -table.adjustedContentInset.top
        let bottom = max(top, table.contentSize.height - table.bounds.height + table.adjustedContentInset.bottom)
        let anchor = position.anchors.first { dataSource.indexPath(for: $0.url) != nil }
        let y =
            anchor.flatMap { anchor in
                dataSource.indexPath(for: anchor.url).map { table.rectForRow(at: $0).minY - anchor.distance }
            } ?? position.offset
        let offset = CGPoint(x: table.contentOffset.x, y: min(bottom, max(top, y)))
        if table.contentOffset != offset { table.setContentOffset(offset, animated: false) }
    }

    private func isVisible(_ cell: UIView, in window: UIWindow, allowingMenu: Bool) -> Bool {
        var visible = cell.convert(cell.bounds, to: window).intersection(window.bounds)
        var opacity: CGFloat = 1
        var ancestor: UIView? = cell
        while let view = ancestor {
            opacity *= view.alpha
            guard !view.isHidden, opacity > 0.01,
                allowingMenu || (view.isUserInteractionEnabled && !view.accessibilityElementsHidden)
            else { return false }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            guard !visible.isNull, !visible.isEmpty, !visible.isInfinite,
                visible.minX.isFinite, visible.minY.isFinite, visible.width.isFinite, visible.height.isFinite
            else { return false }
            if view === window { return true }
            ancestor = view.superview
        }
        return false
    }
}

/// The popup owns input; pausing its original control must not revoke its anchor.
@MainActor
final class SourceManagementMenuCoordinator {
    private weak var host: UIView?
    private let canPresent: () -> Bool
    private let onCoverageChange: (Bool) -> Void
    private var popup: ReaderOverflowMenuView?
    private let sortPopup = SearchOverflowMenuView()
    private var anchor: SourceManagementOwnedMenuAnchor?
    private var validation: (() -> Bool)?
    private var actionID: UUID?

    init(host: UIView, canPresent: @escaping () -> Bool, onCoverageChange: @escaping (Bool) -> Void) {
        self.host = host
        self.canPresent = canPresent
        self.onCoverageChange = onCoverageChange
    }

    func show(
        _ items: [ReaderOverflowMenuView.Item], anchor original: UIView,
        isCurrent: @escaping () -> Bool = { true }
    ) {
        guard !items.isEmpty, let host, let (id, proxy) = begin(anchor: original, isCurrent: isCurrent) else { return }
        let ownedItems = items.map { item in
            ReaderOverflowMenuView.Item(
                identifier: item.identifier, title: item.title, image: item.image,
                isChecked: item.isChecked, isEnabled: item.isEnabled
            ) { [weak self] in
                guard let self, self.canActivate(id, proxy: proxy, isCurrent: isCurrent) else { return }
                self.actionID = nil
                proxy.restoreAccessibilityFocus()
                item.handler()
            }
        }
        let menu = ReaderOverflowMenuView(
            items: ownedItems, anchorView: proxy.view, interfaceStyle: host.traitCollection.userInterfaceStyle,
            placement: .automatic)
        popup = menu
        menu.canActivateItem = { [weak self, weak menu] in
            guard let self, self.popup === menu else { return false }
            return self.canActivate(id, proxy: proxy, isCurrent: isCurrent)
        }
        menu.onDismiss = { [weak self, weak menu] in
            guard let self, self.popup === menu else { return }
            self.finish(id, proxy: proxy)
        }
        onCoverageChange(true)
        menu.present(in: host)
        if menu.superview == nil { menu.onDismiss?() }
    }

    func showSort(
        anchor original: UIView, items: [SearchOverflowMenuView.Item], onSelect: @escaping (String) -> Void
    ) {
        guard !items.isEmpty, let host, let (id, proxy) = begin(anchor: original, isCurrent: { true }) else { return }
        sortPopup.canActivateItem = { [weak self] in
            self?.canActivate(id, proxy: proxy, isCurrent: { true }) == true
        }
        sortPopup.onVisibilityChange = { [weak self] visible in
            guard let self, self.actionID == id else { return }
            if visible { self.onCoverageChange(true) } else { self.finish(id, proxy: proxy) }
        }
        sortPopup.show(in: host, anchor: proxy.view, items: items) { [weak self] value in
            guard let self, self.canActivate(id, proxy: proxy, isCurrent: { true }) else { return }
            self.actionID = nil
            proxy.restoreAccessibilityFocus()
            onSelect(value)
        }
        if sortPopup.superview == nil { finish(id, proxy: proxy) }
    }

    func dismiss() {
        let previousAnchor = anchor
        let restoresFocus = validation?() != false
        popup?.dismiss()
        sortPopup.dismiss()
        actionID = nil
        if restoresFocus, canPresent() { previousAnchor?.restoreAccessibilityFocus() }
    }

    @discardableResult
    func dismissIfPresented() -> Bool {
        guard popup?.superview != nil || sortPopup.isPresented else { return false }
        dismiss()
        return true
    }

    func refreshLayout() {
        if anchor != nil, !canPresent() || anchor?.refresh() != true || validation?() == false { dismiss() }
    }

    func invalidateIfNeeded() {
        if validation?() == false { dismiss() }
    }

    func refreshAppearance(interfaceStyle: UIUserInterfaceStyle) {
        popup?.overrideUserInterfaceStyle = interfaceStyle
        sortPopup.refreshAppearance(interfaceStyle: interfaceStyle)
    }

    private func begin(
        anchor original: UIView, isCurrent: @escaping () -> Bool
    ) -> (UUID, SourceManagementOwnedMenuAnchor)? {
        guard canPresent(), isCurrent(), let host, original.window === host.window else { return nil }
        host.endEditing(true)
        dismiss()
        host.layoutIfNeeded()
        guard canPresent(), isCurrent(), let proxy = SourceManagementOwnedMenuAnchor(original: original, host: host)
        else { return nil }
        let id = UUID()
        actionID = id
        anchor = proxy
        validation = isCurrent
        return (id, proxy)
    }

    private func canActivate(
        _ id: UUID, proxy: SourceManagementOwnedMenuAnchor, isCurrent: () -> Bool
    ) -> Bool {
        actionID == id && canPresent() && proxy.refresh() && isCurrent()
    }

    private func finish(_ id: UUID, proxy: SourceManagementOwnedMenuAnchor) {
        guard actionID == id, anchor === proxy else { return }
        let restoresFocus = validation?() != false
        popup = nil
        anchor = nil
        validation = nil
        onCoverageChange(false)
        // Both menu types recheck context after dismissal and before delivering the action.
        DispatchQueue.main.async { [weak self] in
            if let self, self.actionID == id {
                if restoresFocus, self.canPresent() { proxy.restoreAccessibilityFocus() }
                self.actionID = nil
            }
            proxy.view.removeFromSuperview()
        }
    }
}

@MainActor
private final class SourceManagementOwnedMenuAnchor {
    let view = UIView()
    private weak var original: UIView?
    private weak var host: UIView?
    private weak var window: UIWindow?

    init?(original: UIView, host: UIView) {
        self.original = original
        self.host = host
        window = host.window
        guard refresh() else { return nil }
        view.isAccessibilityElement = false
        view.semanticContentAttribute =
            original.effectiveUserInterfaceLayoutDirection == .rightToLeft
            ? .forceRightToLeft : .forceLeftToRight
        host.addSubview(view)
    }

    func refresh() -> Bool {
        guard let original, let host, let window, host.window === window, original.window === window,
            original === host || original.isDescendant(of: host), !original.bounds.isEmpty
        else { return false }
        var visible = original.convert(original.bounds, to: window).intersection(window.bounds)
        var opacity: CGFloat = 1
        var ancestor: UIView? = original
        while let candidate = ancestor {
            opacity *= candidate.alpha
            guard !candidate.isHidden, opacity > 0.01 else { return false }
            // Disabled, non-interactive and AX-hidden are the underlying page's intentional pause.
            if candidate.clipsToBounds { visible = visible.intersection(candidate.convert(candidate.bounds, to: window)) }
            ancestor = candidate.superview
        }
        guard !visible.isNull, !visible.isEmpty, !visible.isInfinite,
            visible.minX.isFinite, visible.minY.isFinite, visible.width.isFinite, visible.height.isFinite
        else { return false }
        let frame = original.convert(original.bounds, to: host)
        if view.frame != frame { view.frame = frame }
        return true
    }

    func restoreAccessibilityFocus() {
        guard refresh(), let original else { return }
        UIAccessibility.post(notification: .screenChanged, argument: original)
    }
}

@MainActor
private final class SourceManagementContactObserver: UIGestureRecognizer {
    var onBegin: (() -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var contacts: Set<UITouch> = []
    var hasContact: Bool { !contacts.isEmpty }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by _: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if contacts.isEmpty { onBegin?() }
        contacts.formUnion(touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: false) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches, cancelled: true) }

    override func reset() {
        super.reset()
        guard hasContact else { return }
        contacts.removeAll()
        onEnd?(true)
    }

    func cancelContact() {
        guard hasContact else { return }
        contacts.removeAll()
        state = .failed
        onEnd?(true)
    }

    private func finish(_ touches: Set<UITouch>, cancelled: Bool) {
        contacts.subtract(touches)
        guard contacts.isEmpty else { return }
        state = .failed
        onEnd?(cancelled)
    }
}

/// Alerts and page sheets need a detach event even when the list receives no appearance callback.
@MainActor
private final class SourceManagementPresentationObserver: UIView {
    var onDetach: (() -> Void)?
    private var wasAttached = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wasAttached = true
        } else if wasAttached {
            wasAttached = false
            let callback = onDetach
            onDetach = nil
            DispatchQueue.main.async { callback?() }
            removeFromSuperview()
        }
    }
}
