import ObjectiveC
import UIKit

/// A single wallpaper below the main tab tree, not a tiled image on every list cell.
/// Only roots explicitly attached by MainTabBarController participate. No UIKit lifecycle hooks.
enum ThemeBackgroundConsumer {
    private static var started = false
    private static var observers: [NSObjectProtocol] = []
    private static let roots = NSHashTable<UIView>.weakObjects()
    private static var surfaceKey: UInt8 = 0
    private static var bindingKey: UInt8 = 0

    static func attach(to root: UIView) {
        precondition(Thread.isMainThread)
        guard root.next is MainTabBarController else { return }
        startObservingIfNeeded()
        _ = surface(in: root)
        refresh(in: root)
    }

    static func refresh(in root: UIView) {
        precondition(Thread.isMainThread)
        guard roots.contains(root), let backdrop = backdrop(in: root) else { return }
        backdrop.refresh()
        reconcile(root, backdrop: backdrop)
    }

    private static func reconcile(_ root: UIView, backdrop: ThemeBackgroundSurfaceView) {
        backdrop.restoreDetachedSurfaces(from: root)
        reconcileTree(root, hasImage: backdrop.hasImage, backdrop: backdrop)
        backdrop.observeScrollSurfaces(in: root)
    }

    static func detach(from root: UIView) {
        precondition(Thread.isMainThread)
        guard roots.contains(root) else { return }
        let backdrop = backdrop(in: root)
        reconcileTree(root, hasImage: false, backdrop: backdrop, removingBindings: true)
        backdrop?.restoreDetachedSurfaces(from: nil)
        backdrop?.removeFromSuperview()
        objc_setAssociatedObject(root, &surfaceKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        roots.remove(root)
    }

    static func refreshAll() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { refreshAll() }
            return
        }
        for root in roots.allObjects { refresh(in: root) }
    }

    private static func startObservingIfNeeded() {
        guard !started else { return }
        started = true
        for name in [
            UserDefaults.didChangeNotification, UIApplication.didBecomeActiveNotification,
            Notification.Name.androidReplicaThemeDidChange,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    refreshAll()
                })
        }
    }

    private static func isThemeSurface(_ color: UIColor?, view: UIView) -> Bool {
        guard let color else { return false }
        if color === AndroidReplicaTheme.background { return true }
        // BookshelfRootView resolves its UIColor before assignment; other solid fills stay untouched.
        if view is BookshelfRootView,
            color.isEqual(AndroidReplicaTheme.background.resolvedColor(with: view.traitCollection))
        {
            return true
        }
        // Discovery uses its root primary fill as the status-bar backdrop. Its toolbar remains opaque.
        return view.next is AndroidReplicaExploreViewController && color === AndroidReplicaTheme.toolbarBackground
    }

    private static func apply(_ value: ThemeBackgroundBinding, to view: UIView, hasImage: Bool) {
        if hasImage {
            if !value.isCleared || view.backgroundColor?.cgColor.alpha != 0 { view.backgroundColor = .clear }
            if view.isOpaque { view.isOpaque = false }
        } else {
            if value.isCleared { view.backgroundColor = value.color }
            if view.isOpaque != value.isOpaque { view.isOpaque = value.isOpaque }
        }
        value.isCleared = hasImage
    }

    private static func binding(on view: UIView) -> ThemeBackgroundBinding? {
        objc_getAssociatedObject(view, &bindingKey) as? ThemeBackgroundBinding
    }

    private static func backdrop(in root: UIView) -> ThemeBackgroundSurfaceView? {
        objc_getAssociatedObject(root, &surfaceKey) as? ThemeBackgroundSurfaceView
    }

    private static func surface(in root: UIView) -> ThemeBackgroundSurfaceView {
        if let surface = objc_getAssociatedObject(root, &surfaceKey) as? ThemeBackgroundSurfaceView { return surface }
        let backdrop = ThemeBackgroundSurfaceView(frame: root.bounds)
        backdrop.onImageChange = { [weak root, weak backdrop] in
            guard let root, let backdrop else { return }
            reconcile(root, backdrop: backdrop)
        }
        objc_setAssociatedObject(root, &surfaceKey, backdrop, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        roots.add(root)
        backdrop.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        root.insertSubview(backdrop, at: 0)
        return backdrop
    }

    private static func reconcileTree(
        _ view: UIView, hasImage: Bool, backdrop: ThemeBackgroundSurfaceView?, removingBindings: Bool = false
    ) {
        guard view !== backdrop else { return }
        var current = binding(on: view)
        if let stored = current, stored.isCleared, view.backgroundColor?.cgColor.alpha != 0 {
            view.isOpaque = stored.isOpaque
            objc_setAssociatedObject(view, &bindingKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            current = nil
        }
        if !removingBindings, hasImage, current == nil, isThemeSurface(view.backgroundColor, view: view) {
            let color = view is BookshelfRootView ? AndroidReplicaTheme.background : view.backgroundColor
            let value = ThemeBackgroundBinding(color: color, isOpaque: view.isOpaque)
            objc_setAssociatedObject(view, &bindingKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            current = value
        }
        if let current {
            backdrop?.track(view)
            apply(current, to: view, hasImage: hasImage)
            if removingBindings || !hasImage {
                objc_setAssociatedObject(view, &bindingKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
        }
        for child in view.subviews {
            reconcileTree(child, hasImage: hasImage, backdrop: backdrop, removingBindings: removingBindings)
        }
    }

    fileprivate static func restore(_ view: UIView) {
        guard let value = binding(on: view) else { return }
        if value.isCleared {
            if view.backgroundColor?.cgColor.alpha == 0 { view.backgroundColor = value.color }
            view.isOpaque = value.isOpaque
        }
        objc_setAssociatedObject(view, &bindingKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private final class ThemeBackgroundBinding {
    let color: UIColor?
    let isOpaque: Bool
    var isCleared = false

    init(color: UIColor?, isOpaque: Bool) {
        self.color = color
        self.isOpaque = isOpaque
    }
}

private final class ThemeBackgroundSurfaceView: UIView {
    var onImageChange: (() -> Void)?
    var hasImage: Bool { imageView.image != nil && !isHidden }
    private let imageView = UIImageView()
    private var renderKey: String?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var scrollObservations: [NSKeyValueObservation] = []
    private var observedScrollViews: [ObjectIdentifier] = []
    private var refreshScheduled = false
    private let managedViews = NSHashTable<UIView>.weakObjects()
    private var lastSize = CGSize.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        accessibilityIdentifier = "theme.background.surface"
        // BitmapDrawable is stretched over Android's decor background; no per-cell cropping.
        imageView.contentMode = .scaleToFill
        imageView.clipsToBounds = true
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.frame = bounds
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { task?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastSize != bounds.size {
            lastSize = bounds.size
            refresh()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refresh() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refresh()
        scheduleRefresh()
    }

    func observeScrollSurfaces(in root: UIView) {
        guard hasImage else {
            observedScrollViews = []
            scrollObservations = []
            return
        }
        var scrollViews: [UIScrollView] = []
        func collect(_ view: UIView) {
            if view === self { return }
            if let scrollView = view as? UIScrollView { scrollViews.append(scrollView) }
            for child in view.subviews { collect(child) }
        }
        collect(root)
        let identifiers = scrollViews.map(ObjectIdentifier.init)
        guard identifiers != observedScrollViews else { return }
        observedScrollViews = identifiers
        scrollObservations = scrollViews.flatMap { scrollView in
            [
                scrollView.observe(\.contentOffset, options: []) { [weak self] _, _ in self?.scheduleRefresh() },
                scrollView.observe(\.contentSize, options: []) { [weak self] _, _ in self?.scheduleRefresh() },
            ]
        }
    }

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.onImageChange?()
        }
    }

    func track(_ view: UIView) { managedViews.add(view) }

    func restoreDetachedSurfaces(from root: UIView?) {
        for view in managedViews.allObjects {
            if let root, view.isDescendant(of: root) { continue }
            ThemeBackgroundConsumer.restore(view)
            managedViews.remove(view)
        }
    }

    func refresh() {
        backgroundColor = AndroidReplicaTheme.background
        guard window != nil else { return }
        let mode = UserDefaults.standard.string(forKey: "theme_mode") ?? "SYSTEM"
        let isNight: Bool
        switch mode {
        case "LIGHT", "E_INK": isNight = false
        case "DARK": isNight = true
        default: isNight = traitCollection.userInterfaceStyle == .dark
        }
        let configuration = ThemeBackgroundConfiguration.read(channel: .init(isNight: isNight))
        let path = configuration.imagePath
        let available = path.flatMap(ThemeBackgroundImageStore.fileURL(for:)) != nil && mode != "E_INK"
        let pixels = min(2048, max(256, Int(ceil(max(bounds.width, bounds.height) * max(1, traitCollection.displayScale)))))
        let key = "\(isNight)|\(path ?? "")|\(configuration.blurring)|\(pixels)|\(available)"
        guard renderKey != key else { return }
        renderKey = key
        generation &+= 1
        let expected = generation
        task?.cancel()
        task = nil
        imageView.image = nil
        isHidden = true
        onImageChange?()
        guard available else { return }
        task = Task { @MainActor [weak self] in
            do {
                let image = try await ThemeBackgroundImageStore.shared.image(configuration: configuration, maximumPixels: pixels)
                guard let self, !Task.isCancelled, self.generation == expected else { return }
                self.imageView.image = image
                self.isHidden = image == nil
                if image == nil { self.renderKey = nil }
                self.task = nil
                self.onImageChange?()
            } catch {
                guard let self, !Task.isCancelled, self.generation == expected else { return }
                self.task = nil
                self.renderKey = nil
                self.onImageChange?()
            }
        }
    }
}
