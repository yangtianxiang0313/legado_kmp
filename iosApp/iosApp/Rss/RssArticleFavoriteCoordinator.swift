import shared
import UIKit

@MainActor
final class RssArticleFavoriteCoordinator: NSObject {
    private weak var owner: UIViewController?
    private weak var button: UIButton?
    private let screen: RssScreenAdapter
    private let currentArticle: @MainActor () -> RssArticle?
    private let currentContent: @MainActor () -> String?
    private let currentPageID: @MainActor () -> UUID?
    private let canUseActions: @MainActor () -> Bool
    private var favoriteTask: Task<Void, Never>?
    private var favoritesSubscription: FlowSubscription?
    private var favoritesObservationID: UUID?
    private var hasObservedFavorites = false
    private var isFavoriteSynchronized = false
    private var isPageActive = false
    private var isFavorite = false

    init(
        owner: UIViewController, button: UIButton, screen: RssScreenAdapter, favorites: [RssStar],
        currentArticle: @escaping @MainActor () -> RssArticle?,
        currentContent: @escaping @MainActor () -> String?,
        currentPageID: @escaping @MainActor () -> UUID?,
        canUseActions: @escaping @MainActor () -> Bool
    ) {
        self.owner = owner
        self.button = button
        self.screen = screen
        self.currentArticle = currentArticle
        self.currentContent = currentContent
        self.currentPageID = currentPageID
        self.canUseActions = canUseActions
        super.init()
        if let article = currentArticle() {
            isFavorite = favorites.contains { $0.origin == article.origin && $0.link == article.link }
        }
    }

    deinit {
        favoriteTask?.cancel()
        favoritesSubscription?.cancel()
    }

    func configureButton() {
        button?.accessibilityIdentifier = UIIdentifiers.RSS.articleFavoriteButton
        button?.addTarget(self, action: #selector(toggleFavorite), for: .touchUpInside)
        updateButton()
    }

    func activate() {
        isPageActive = true
        refreshFavoriteState()
        observeFavorites()
    }

    func deactivate() {
        isPageActive = false
        stopObservingFavorites()
        updateButton()
    }

    @objc private func toggleFavorite() {
        guard canUseActions(), isFavoriteSynchronized, favoriteTask == nil,
            let id = currentPageID(), let article = currentArticle()
        else { return }
        stopObservingFavorites()
        let favoriteArticle = RssArticleContentResolver.favoriteArticle(article, content: currentContent())
        favoriteTask = Task { @MainActor [weak self, article = favoriteArticle] in
            do {
                let facade = try RssArticleFavoritesFacade.companion.create()
                let existing: RssStar? = try await SharedAsync.optionalValue {
                    facade.getFavorite(origin: article.origin, link: article.link, completionHandler: $0)
                }
                let star: RssStar
                if let existing {
                    star = existing
                } else {
                    star = try await SharedAsync.value {
                        facade.saveFavorite(
                            article: article, title: article.title, group: article.group, completionHandler: $0)
                    }
                }
                let groups: [String] = try await SharedAsync.value { facade.favoriteGroups(completionHandler: $0) }
                guard let self else { return }
                self.favoriteTask = nil
                self.observeFavorites()
                guard self.currentPageID() == id, self.canUseActions(), let owner = self.owner else { return }
                let editor = RssArticleFavoriteEditorViewController(star: star, groups: groups)
                editor.onSave = { title, group in
                    let _: RssStar = try await SharedAsync.value {
                        facade.saveFavorite(article: article, title: title, group: group, completionHandler: $0)
                    }
                }
                editor.onDelete = {
                    try await SharedAsync.void {
                        facade.deleteFavorite(origin: article.origin, link: article.link, completionHandler: $0)
                    }
                }
                owner.present(UINavigationController(rootViewController: editor), animated: true)
            } catch {
                guard let self else { return }
                self.favoriteTask = nil
                self.observeFavorites()
                if self.currentPageID() == id, self.canUseActions() { self.owner?.presentError(error) }
            }
        }
        updateButton()
    }

    private func refreshFavoriteState() {
        if hasObservedFavorites, favoriteTask == nil, let article = currentArticle() {
            isFavorite = screen.currentFavorites.contains { $0.origin == article.origin && $0.link == article.link }
        }
        updateButton()
    }

    private func observeFavorites() {
        stopObservingFavorites()
        guard isPageActive, favoriteTask == nil else { return }
        switch SharedRuntime.rssFacade() {
        case .success(let facade):
            button?.accessibilityHint = nil
            let observationID = UUID()
            favoritesObservationID = observationID
            favoritesSubscription = facade.watchFavorites { [weak self] favorites in
                DispatchQueue.main.async {
                    guard let self, self.isPageActive, self.favoritesObservationID == observationID,
                        let article = self.currentArticle()
                    else { return }
                    self.isFavorite = favorites.contains { $0.origin == article.origin && $0.link == article.link }
                    self.hasObservedFavorites = true
                    self.isFavoriteSynchronized = true
                    self.updateButton()
                }
            }
        case .failure(let error):
            button?.accessibilityHint = error.message
        }
        updateButton()
    }

    private func stopObservingFavorites() {
        favoritesObservationID = nil
        favoritesSubscription?.cancel()
        favoritesSubscription = nil
        isFavoriteSynchronized = false
    }

    private func updateButton() {
        button?.setImage(UIImage(systemName: isFavorite ? "star.fill" : "star"), for: .normal)
        button?.accessibilityLabel = isFavorite ? L10n.RSS.editFavoriteTitle : L10n.RSS.markFavorite
        button?.isEnabled = isPageActive && isFavoriteSynchronized && favoriteTask == nil
    }
}
