import UIKit
import shared

final class MainTabBarController: UIViewController, NavigationCustomToolbarProviding {
    private struct Tab {
        let title: String
        let icon: AndroidMainTabIcon
        let accessibilityIdentifier: String
        let controller: UIViewController
    }

    private enum AppearancePhase {
        case hidden, appearing, visible, disappearing
    }

    private let contentContainer = UIView()
    private let bottomNavigationBackground = UIView()
    private let bottomNavigationDivider = UIView()
    private let bottomNavigationView = UIStackView()
    private let audioPlaybackBar = AudioPlaybackBar()
    private var audioPlaybackBarHeight: NSLayoutConstraint?
    private var allTabs: [Tab] = []
    private lazy var pendingUpdates = BookshelfUpdateBadgeBinding { [weak self] count in
        self?.renderPendingUpdates(count)
    }
    private var tabs: [Tab] = []
    private lazy var appPreferences = RestoredAppPreferences { [weak self] _ in
        self?.applyTabVisibility()
    }
    private var selectedIndex = -1
    private var selectedController: UIViewController?
    private var tabButtons: [AndroidReplicaBottomTabButton] = []
    private var appearancePhase: AppearancePhase = .hidden
    private var childAppearanceTransition: (controller: UIViewController, appearing: Bool)?
    private var isChangingSelection = false
    private var needsTabVisibilityUpdate = false
    var onStartupNavigationReady: (() -> Void)?

    var isReadyForStartupNavigation: Bool {
        appearancePhase == .visible && !isChangingSelection && canPerformNavigationAction
    }

    func selectBookshelfForStartup() -> UIViewController? {
        guard isReadyForStartupNavigation,
            let index = tabs.firstIndex(where: { $0.controller is AndroidReplicaBookshelfViewController })
        else { return nil }
        selectTab(at: index)
        return selectedController as? AndroidReplicaBookshelfViewController
    }

    override var shouldAutomaticallyForwardAppearanceMethods: Bool { false }

    override var childForStatusBarStyle: UIViewController? {
        selectedController?.parent === self ? selectedController : nil
    }

    override var childForStatusBarHidden: UIViewController? {
        selectedController?.parent === self ? selectedController : nil
    }

    override var childForHomeIndicatorAutoHidden: UIViewController? {
        selectedController?.parent === self ? selectedController : nil
    }

    override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
        selectedController?.parent === self ? selectedController : nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = UIIdentifiers.Tabs.root
        view.accessibilityValue = "android-replica"
        configureLayout()
        updateRootInteraction()
        appPreferences.start()
        configureTabs()
        ThemeBackgroundConsumer.attach(to: view)
        pendingUpdates.start()
        SubscriptionStartupUpdater.shared.startIfNeeded()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        appearancePhase = .appearing
        updateRootInteraction()
        beginSelectedAppearance(true, animated: animated)
        pendingUpdates.start()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        endSelectedAppearance()
        appearancePhase = .visible
        applyPendingTabVisibility()
        updateRootInteraction()
        // UIKit clears transition/moving flags after this appearance callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isReadyForStartupNavigation else { return }
            self.onStartupNavigationReady?()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        appearancePhase = .disappearing
        updateRootInteraction()
        beginSelectedAppearance(false, animated: animated)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        endSelectedAppearance()
        appearancePhase = .hidden
        applyPendingTabVisibility()
        updateRootInteraction()
    }

    private func configureLayout() {
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.backgroundColor = AndroidReplicaTheme.background
        bottomNavigationBackground.translatesAutoresizingMaskIntoConstraints = false
        bottomNavigationBackground.backgroundColor = AndroidReplicaTheme.bottomBackground

        bottomNavigationDivider.translatesAutoresizingMaskIntoConstraints = false
        bottomNavigationDivider.backgroundColor = AndroidReplicaTheme.divider

        bottomNavigationView.translatesAutoresizingMaskIntoConstraints = false
        bottomNavigationView.axis = .horizontal
        bottomNavigationView.alignment = .center
        bottomNavigationView.distribution = .fillEqually
        bottomNavigationView.backgroundColor = .clear
        bottomNavigationView.spacing = 0
        bottomNavigationView.isLayoutMarginsRelativeArrangement = false

        view.addSubview(contentContainer)
        audioPlaybackBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(audioPlaybackBar)
        let playbackHeight = audioPlaybackBar.heightAnchor.constraint(
            equalToConstant: AudioPlaybackSession.shared.bookURL == nil ? 0 : 56)
        audioPlaybackBarHeight = playbackHeight
        audioPlaybackBar.onVisibilityChange = { [weak self] visible in
            self?.audioPlaybackBarHeight?.constant = visible ? 56 : 0
        }
        audioPlaybackBar.onOpen = { [weak self] in
            guard let self, self.canPerformNavigationAction, self.presentedViewController == nil,
                let url = AudioPlaybackSession.shared.bookURL
            else { return }
            self.present(AudioPlayViewController(bookUrl: url), animated: true)
        }
        view.addSubview(bottomNavigationBackground)
        bottomNavigationBackground.addSubview(bottomNavigationDivider)
        bottomNavigationBackground.addSubview(bottomNavigationView)

        let preferredNavigationWidth = bottomNavigationView.widthAnchor.constraint(
            equalTo: bottomNavigationBackground.widthAnchor)
        preferredNavigationWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contentContainer.topAnchor.constraint(equalTo: view.topAnchor),
            contentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentContainer.bottomAnchor.constraint(equalTo: audioPlaybackBar.topAnchor),
            audioPlaybackBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            audioPlaybackBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            audioPlaybackBar.bottomAnchor.constraint(equalTo: bottomNavigationBackground.topAnchor),
            playbackHeight,

            bottomNavigationBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomNavigationBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomNavigationBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomNavigationBackground.topAnchor.constraint(equalTo: bottomNavigationView.topAnchor),

            bottomNavigationDivider.topAnchor.constraint(equalTo: bottomNavigationBackground.topAnchor),
            bottomNavigationDivider.leadingAnchor.constraint(equalTo: bottomNavigationBackground.leadingAnchor),
            bottomNavigationDivider.trailingAnchor.constraint(equalTo: bottomNavigationBackground.trailingAnchor),
            bottomNavigationDivider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            bottomNavigationView.topAnchor.constraint(equalTo: bottomNavigationBackground.topAnchor),
            bottomNavigationView.centerXAnchor.constraint(equalTo: bottomNavigationBackground.centerXAnchor),
            bottomNavigationView.leadingAnchor.constraint(
                greaterThanOrEqualTo: bottomNavigationBackground.leadingAnchor),
            bottomNavigationView.trailingAnchor.constraint(
                lessThanOrEqualTo: bottomNavigationBackground.trailingAnchor),
            bottomNavigationView.widthAnchor.constraint(lessThanOrEqualToConstant: 672),
            preferredNavigationWidth,
            bottomNavigationView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            bottomNavigationView.heightAnchor.constraint(equalToConstant: 50),
        ])
    }

    private func configureTabs() {
        allTabs = [
            makeTab(
                root: AndroidReplicaBookshelfViewController(),
                title: L10n.Tabs.bookshelf,
                icon: .books,
                accessibilityIdentifier: UIIdentifiers.Tabs.bookshelf
            ),
            makeTab(
                root: AndroidReplicaExploreViewController(),
                title: L10n.Tabs.discovery,
                icon: .explore,
                accessibilityIdentifier: UIIdentifiers.Tabs.discovery
            ),
            makeTab(
                root: AndroidReplicaRssViewController(),
                title: L10n.Tabs.rss,
                icon: .rss,
                accessibilityIdentifier: UIIdentifiers.Tabs.rss
            ),
            makeTab(
                root: AndroidReplicaMyViewController(),
                title: L10n.Tabs.settings,
                icon: .person,
                accessibilityIdentifier: UIIdentifiers.Tabs.settings
            ),
        ]

        applyTabVisibility()
    }

    private func applyTabVisibility() {
        guard !allTabs.isEmpty else { return }
        guard !isChangingSelection, appearancePhase == .hidden || appearancePhase == .visible else {
            needsTabVisibilityUpdate = true
            return
        }
        needsTabVisibilityUpdate = false
        let previousController = selectedController
        let defaults = UserDefaults.standard
        let visible = allTabs.filter { tab in
            if tab.accessibilityIdentifier == UIIdentifiers.Tabs.discovery {
                return defaults.bool(forKey: "show_discovery")
            }
            if tab.accessibilityIdentifier == UIIdentifiers.Tabs.rss { return defaults.bool(forKey: "show_rss") }
            return true
        }
        guard visible.map(\.accessibilityIdentifier) != tabs.map(\.accessibilityIdentifier) else { return }
        tabs = visible
        for item in bottomNavigationView.arrangedSubviews {
            bottomNavigationView.removeArrangedSubview(item)
            item.removeFromSuperview()
        }
        tabButtons = tabs.enumerated().map { index, tab in
            let button = AndroidReplicaBottomTabButton(title: tab.title, icon: tab.icon)
            button.tag = index
            button.accessibilityIdentifier = tab.accessibilityIdentifier
            button.accessibilityLabel = tab.title
            button.addTarget(self, action: #selector(handleTabTap(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(equalToConstant: 50).isActive = true
            bottomNavigationView.addArrangedSubview(button)
            return button
        }
        let nextIndex =
            previousController.flatMap { previous in tabs.firstIndex { $0.controller === previous } }
            ?? (previousController == nil ? preferredHomeIndex() : 0)
        selectTab(at: nextIndex)
        renderPendingUpdates(pendingUpdates.displayedCount)
    }

    private func applyPendingTabVisibility() {
        if needsTabVisibilityUpdate { applyTabVisibility() }
    }

    private func renderPendingUpdates(_ count: Int) {
        for button in tabButtons { button.setPendingUpdateCount(count) }
    }

    private func makeTab(
        root: UIViewController, title: String, icon: AndroidMainTabIcon, accessibilityIdentifier: String
    ) -> Tab {
        root.title = title
        return Tab(
            title: title,
            icon: icon,
            accessibilityIdentifier: accessibilityIdentifier,
            controller: root
        )
    }

    @objc private func handleTabTap(_ sender: AndroidReplicaBottomTabButton) {
        guard appearancePhase == .visible, !isChangingSelection, canPerformNavigationAction,
            tabButtons.indices.contains(sender.tag), tabButtons[sender.tag] === sender,
            sender.superview === bottomNavigationView, tabs.indices.contains(sender.tag)
        else { return }
        // Only a real reselect enters discovery's shortcut; visibility rebuilds must not trigger it.
        if selectedController === tabs[sender.tag].controller,
            let discovery = selectedController as? AndroidReplicaExploreViewController
        {
            discovery.handleTabReselection()
            return
        }
        selectTab(at: sender.tag)
    }

    private func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        let nextController = tabs[index].controller
        if selectedController === nextController {
            selectedIndex = index
            updateBottomNavigation()
            return
        }
        guard !isChangingSelection else { return }
        isChangingSelection = true
        defer {
            isChangingSelection = false
            applyPendingTabVisibility()
        }

        let forwardsAppearance = appearancePhase == .visible
        let previousController = selectedController
        if let previousController {
            previousController.willMove(toParent: nil)
            if forwardsAppearance { previousController.beginAppearanceTransition(false, animated: false) }
            previousController.viewIfLoaded?.endEditing(true)
        }

        selectedController = nextController
        selectedIndex = index
        // Android switches its retained tab fragments without fading through an empty host.
        // Keep the old page covered until the incoming page has its first complete layout.
        UIView.performWithoutAnimation {
            addChild(nextController)
            nextController.view.frame = contentContainer.bounds
            nextController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            nextController.view.alpha = 1
            if forwardsAppearance { beginSelectedAppearance(true, animated: false) }
            contentContainer.addSubview(nextController.view)
            nextController.didMove(toParent: self)
            nextController.view.layoutIfNeeded()
            if let previousController {
                previousController.viewIfLoaded?.removeFromSuperview()
                previousController.removeFromParent()
                if forwardsAppearance { previousController.endAppearanceTransition() }
            }
        }

        updateBottomNavigation()
        refreshSystemBarAppearance()
        ThemeBackgroundConsumer.refresh(in: view)
        if forwardsAppearance { endSelectedAppearance() }
    }

    private func beginSelectedAppearance(_ appearing: Bool, animated: Bool) {
        guard let controller = selectedController, controller.parent === self else { return }
        if let transition = childAppearanceTransition,
            transition.controller === controller, transition.appearing == appearing
        {
            return
        }
        // Reverse the pending transition with UIKit when an interactive push/pop is cancelled.
        childAppearanceTransition = (controller, appearing)
        controller.beginAppearanceTransition(appearing, animated: animated)
    }

    private func endSelectedAppearance() {
        let controller = childAppearanceTransition?.controller
        childAppearanceTransition = nil
        controller?.endAppearanceTransition()
    }

    private func updateRootInteraction() {
        let visible = appearancePhase == .visible
        contentContainer.isUserInteractionEnabled = visible
        contentContainer.accessibilityElementsHidden = !visible
        bottomNavigationBackground.isUserInteractionEnabled = visible
        bottomNavigationBackground.accessibilityElementsHidden = !visible
    }

    private func updateBottomNavigation() {
        for (index, button) in tabButtons.enumerated() {
            let selected = index == selectedIndex
            button.setSelected(selected)
        }
    }

    private func refreshSystemBarAppearance() {
        setNeedsStatusBarAppearanceUpdate()
        setNeedsUpdateOfHomeIndicatorAutoHidden()
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
    }

    private func preferredHomeIndex() -> Int {
        let page = RestoredAppPreferences.homeIndex(UserDefaults.standard.object(forKey: "default_home_page"))
        guard allTabs.indices.contains(page) else { return 0 }
        let identifier = allTabs[page].accessibilityIdentifier
        return tabs.firstIndex { $0.accessibilityIdentifier == identifier } ?? 0
    }
}
private final class AndroidReplicaRssViewController: UIViewController, UICollectionViewDataSource,
    UICollectionViewDelegateFlowLayout
{

    private let screen = RssScreenAdapter()
    private let titleBar = AndroidReplicaTitleBar(title: L10n.Tabs.rss)
    private let searchPill = AndroidReplicaSearchPill()
    private let emptyLabel = UILabel()
    private var collectionView: UICollectionView!
    private var sources: [RssSource] = []

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
        bindScreen()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit {
        screen.unbind()
    }

    private func configureViews() {
        titleBar.addAction(
            systemName: "slider.horizontal.3", accessibilityLabel: L10n.RSS.sourceManagementTitle, target: self,
            action: #selector(openRssManagement))
        titleBar.addAction(
            systemName: "star", accessibilityLabel: L10n.RSS.favoritesTitle, target: self,
            action: #selector(openRssFavorites))
        searchPill.addTarget(self, action: #selector(openRssManagement), for: .touchUpInside)

        let layout = UICollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 0
        layout.minimumLineSpacing = 6
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = AndroidReplicaTheme.background
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(
            AndroidReplicaRssCell.self, forCellWithReuseIdentifier: AndroidReplicaRssCell.reuseIdentifier)
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.text = L10n.RSS.emptySourcesTitle
        emptyLabel.textColor = AndroidReplicaTheme.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(titleBar)
        view.addSubview(searchPill)
        view.addSubview(collectionView)
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            searchPill.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 10),
            searchPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            searchPill.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            collectionView.topAnchor.constraint(equalTo: searchPill.bottomAnchor, constant: 10),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: collectionView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: collectionView.leadingAnchor, constant: 24),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: collectionView.trailingAnchor, constant: -24),
        ])
    }

    private func bindScreen() {
        screen.onSourcesChange = { [weak self] sources in
            self?.sources = sources.filter(\.enabled)
            self?.collectionView.reloadData()
            self?.emptyLabel.isHidden = self?.sources.isEmpty == false
        }
        if case .failure(let error) = screen.bootstrap() {
            showMessage(error.message)
        }
    }

    @objc private func openRssManagement() {
        navigationController?.pushViewController(AndroidReplicaRssSourceManagementViewController(), animated: true)
    }

    @objc private func openRssFavorites() {
        navigationController?.pushViewController(AndroidReplicaRssFavoritesViewController(), animated: true)
    }

    private func showMessage(_ message: String) {
        showTransientMessage(message)
    }

    func collectionView(_: UICollectionView, numberOfItemsInSection _: Int) -> Int {
        sources.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell =
            collectionView.dequeueReusableCell(
                withReuseIdentifier: AndroidReplicaRssCell.reuseIdentifier, for: indexPath) as! AndroidReplicaRssCell
        cell.configure(source: sources[indexPath.item])
        return cell
    }

    func collectionView(_: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        let source = sources[indexPath.item]
        if source.singleUrl {
            let article = RssArticle(
                origin: source.sourceUrl, sort: "", title: source.sourceName, order: 0,
                link: source.sourceUrl, pubDate: nil, description: nil, content: nil, image: nil,
                group: RssArticle.companion.DEFAULT_GROUP, read: false, variable: nil)
            navigationController?.pushViewController(
                AndroidReplicaRssArticleViewController(
                    article: article, source: source, screen: screen, favorites: screen.currentFavorites),
                animated: true)
            return
        }
        navigationController?.pushViewController(
            AndroidReplicaRssDetailViewController(source: source),
            animated: true
        )
    }

    func collectionView(
        _ collectionView: UICollectionView, layout _: UICollectionViewLayout, sizeForItemAt _: IndexPath
    ) -> CGSize {
        CGSize(width: floor(collectionView.bounds.width / 4), height: 92)
    }
}
