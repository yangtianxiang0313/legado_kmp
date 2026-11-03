import shared
import UIKit

struct RssFavoriteKey: Hashable {
    let origin: String
    let link: String
    static func equal(_ lhs: String, _ rhs: String) -> Bool { lhs.utf8.elementsEqual(rhs.utf8) }
    static func == (lhs: Self, rhs: Self) -> Bool { equal(lhs.origin, rhs.origin) && equal(lhs.link, rhs.link) }
    func hash(into hasher: inout Hasher) { hasher.combine(Data(origin.utf8)); hasher.combine(Data(link.utf8)) }
}

struct RssFavoriteGroup: Hashable {
    let raw: String
    var bytes: Data { Data(raw.utf8) }
    var label: String { raw.isEmpty ? RssFavoriteText.emptyGroup : raw }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.bytes == rhs.bytes }
    func hash(into hasher: inout Hasher) { hasher.combine(bytes) }
}

struct RssFavoriteSnapshot {
    let star: RssStar
    let key: RssFavoriteKey
    let group: RssFavoriteGroup
    let fields: [Data?]
    init(_ star: RssStar) {
        self.star = star
        key = RssFavoriteKey(origin: star.origin, link: star.link)
        group = RssFavoriteGroup(raw: star.group)
        let values: [String?] = [
            star.origin, star.link, star.sort, star.title, star.group, star.pubDate,
            star.description_, star.content, star.image, star.variable,
        ]
        fields = values.map { $0.map { Data($0.utf8) } }
    }
}

enum RssFavoriteTarget {
    case article(RssFavoriteSnapshot), group(RssFavoriteGroup), all
    func select(from favorites: [RssFavoriteSnapshot]) -> [RssFavoriteSnapshot] {
        switch self {
        case .article(let snapshot): return favorites.filter { $0.key == snapshot.key }
        case .group(let group): return favorites.filter { $0.group == group }
        case .all: return favorites
        }
    }
}

@MainActor
final class RssFavoriteRequest {
    enum Phase { case ready, confirming, authorized, opening, submitted, finished, cancelled }
    let target: RssFavoriteTarget
    let snapshots: [RssFavoriteSnapshot]
    let context: RssFavoriteContext
    let generation: UUID
    var phase: Phase = .ready
    var dialog: ReaderRestoreProgressDialogViewController?
    init(target: RssFavoriteTarget, snapshots: [RssFavoriteSnapshot], context: RssFavoriteContext, generation: UUID) {
        self.target = target
        self.snapshots = snapshots
        self.context = context
        self.generation = generation
    }
}

@MainActor
final class RssFavoriteContext {
    private(set) weak var window: UIWindow?
    private weak var scene: UIWindowScene?
    private weak var root: UIViewController?
    private weak var navigation: UINavigationController?
    private weak var top: UIViewController?
    let ancestry: [ObjectIdentifier]

    init(
        window: UIWindow, scene: UIWindowScene, root: UIViewController, navigation: UINavigationController,
        top: UIViewController
    ) {
        self.window = window
        self.scene = scene
        self.root = root
        self.navigation = navigation
        self.top = top
        var ancestry: [ObjectIdentifier] = []
        var current: UIViewController? = top
        while let controller = current { ancestry.append(ObjectIdentifier(controller)); current = controller.parent }
        self.ancestry = ancestry
    }

    func matches(_ host: UIViewController, dialog: UIViewController?) -> Bool {
        guard let window, let scene, let root, let navigation, let top, top === host,
            UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
            window.isKeyWindow, !window.isHidden, window.alpha > 0.01, window.isUserInteractionEnabled,
            !window.accessibilityElementsHidden, window.windowScene === scene, window.rootViewController === root,
            scene.activationState == .foregroundActive, AppLockManager.shared.isUnlocked(in: window),
            host.viewIfLoaded?.window === window, host.navigationController === navigation,
            navigation.topViewController === top
        else { return false }
        var actual: [ObjectIdentifier] = []
        var current: UIViewController? = host
        while let controller = current {
            guard !controller.isBeingDismissed, !controller.isMovingFromParent, !controller.isMovingToParent else {
                return false
            }
            if let modal = controller.presentedViewController, modal !== dialog { return false }
            if let transition = controller.transitionCoordinator {
                guard let dialog,
                    transition.viewController(forKey: .from) === dialog
                        || transition.viewController(forKey: .to) === dialog
                else { return false }
            } else if controller.isBeingPresented {
                return false
            }
            if let tabs = controller as? UITabBarController, let child = actual.last,
                tabs.selectedViewController.map(ObjectIdentifier.init) != child
            {
                return false
            }
            actual.append(ObjectIdentifier(controller))
            current = controller.parent
        }
        guard actual == ancestry, actual.contains(ObjectIdentifier(root)) else { return false }
        if let dialog, let owner = dialog.presentingViewController {
            return ancestry.contains(ObjectIdentifier(owner)) && owner.presentedViewController === dialog
                && dialog.presentedViewController == nil
                && (dialog.viewIfLoaded?.window === window
                    || (dialog.isBeingPresented && dialog.viewIfLoaded?.window == nil))
        }
        return dialog?.presentedViewController == nil
            && dialog?.viewIfLoaded?.window == nil && dialog?.viewIfLoaded?.superview == nil
    }
}

enum RssFavoriteText {
    private static func text(_ key: String, _ fallback: String) -> String {
        NSLocalizedString(key, value: fallback, comment: "")
    }
    static let groups = text("rss.favorites.groups", "分组")
    static let more = text("rss.favorites.more_actions", "更多操作")
    static let emptyGroup = text("rss.favorites.empty_group", "未命名分组")
    static let deleteGroup = text("rss.favorites.delete_group", "删除当前分组")
    static let deleteAll = text("rss.favorites.delete_all", "删除全部收藏")
    static let confirmArticle = text("rss.favorites.confirm_article", "确定删除收藏？\n<%@>")
    static let confirmGroup = text("rss.favorites.confirm_group", "确定删除此分组的全部收藏？\n<%@>")
    static let confirmAll = text("rss.favorites.confirm_all", "确定删除全部收藏？此操作无法撤销。")
}
