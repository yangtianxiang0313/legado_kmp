import shared
import UIKit

@MainActor
final class RssArticleLinkActionCoordinator {
    private weak var owner: UIViewController?
    private let canAct: () -> Bool
    private var bookLink: ExternalBookLinkCoordinator?
    private var ruleImport: ExternalRuleImportCoordinator?
    private var readerConfig: ExternalReaderConfigImportCoordinator?

    init(owner: UIViewController, canAct: @escaping () -> Bool) {
        self.owner = owner
        self.canAct = canAct
    }

    func perform(_ actions: [RssArticleNavigationAction]) {
        guard canAct(), let owner, owner.presentedViewController == nil, !actions.isEmpty else { return }
        if actions.count == 1 {
            perform(actions[0])
        } else {
            let prompt = UIAlertController(title: "选择文章操作", message: nil, preferredStyle: .actionSheet)
            for action in actions {
                let keyword = String(action.value.prefix(24)) + (action.value.count > 24 ? "…" : "")
                let title = action.kind == .searchBook ? "搜索：\(keyword)" : "打开书籍"
                prompt.addAction(
                    UIAlertAction(title: title, style: .default) { [weak self, weak prompt] _ in
                        self?.afterDismissal(prompt) { [weak self] in self?.perform(action) }
                    })
            }
            prompt.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
            anchor(prompt, owner: owner)
            owner.present(prompt, animated: true)
        }
    }

    func open(_ url: URL) {
        guard canAct(), let owner, owner.presentedViewController == nil else { return }
        do {
            switch try ExternalOpenRoute.parse(url) {
            case .bookSource(let address):
                let screen = SourceImportScreenAdapter()
                try screen.bootstrap().get()
                let preview = SourceImportPreviewViewController {
                    try await screen.preparePreview(source: .url(address.absoluteString))
                }
                preview.onConfirm = { sources, options in
                    _ = try await screen.importSelected(sources: sources, options: options)
                }
                owner.present(preview, animated: true)
            case .rules(let address, let kind):
                let coordinator = ExternalRuleImportCoordinator(owner: owner)
                ruleImport = coordinator
                coordinator.start(input: .remote(address), expected: kind)
            case .readerConfig(let address):
                let coordinator = ExternalReaderConfigImportCoordinator(owner: owner)
                readerConfig = coordinator
                coordinator.start(input: .remote(address))
            case .bookLink(let address):
                openBook(address)
            case .file:
                owner.showTransientMessage("文章不能直接打开本地文件")
            }
        } catch {
            owner.showTransientMessage(error.userFacingMessage)
        }
    }

    func offerExternal(_ url: URL) {
        guard canAct(), let owner, owner.presentedViewController == nil,
            !["javascript", "file", "data", "blob", "about", "jsbridge"].contains(url.scheme?.lowercased() ?? "")
        else { return }
        let prompt = UIAlertController(title: "在其他应用中打开？", message: nil, preferredStyle: .alert)
        prompt.addAction(UIAlertAction(title: L10n.Common.cancel, style: .cancel))
        prompt.addAction(
            UIAlertAction(title: L10n.Common.confirm, style: .default) { [weak self, weak prompt] _ in
                self?.afterDismissal(prompt) {
                    guard self?.canAct() == true else { return }
                    UIApplication.shared.open(url)
                }
            })
        owner.present(prompt, animated: true)
    }

    func cancel() {
        bookLink?.cancel()
        ruleImport?.cancel()
        readerConfig?.cancel()
    }

    private func perform(_ action: RssArticleNavigationAction) {
        guard canAct(), let owner, owner.presentedViewController == nil else { return }
        if action.kind == .searchBook {
            owner.navigationController?.pushViewController(
                AndroidReplicaSearchViewController(initialKeyword: action.value), animated: true)
        } else if action.kind == .addBook {
            openBook(action.value)
        }
    }

    private func openBook(_ address: String) {
        guard canAct(), let owner else { return }
        guard ExternalBookLinkCoordinator.accepts(address) else { owner.showTransientMessage("书籍链接无效"); return }
        let coordinator = ExternalBookLinkCoordinator(owner: owner)
        bookLink = coordinator
        coordinator.start(address: address)
    }

    private func afterDismissal(_ prompt: UIAlertController?, action: @escaping () -> Void) {
        guard let prompt else { return }
        let completion = { DispatchQueue.main.async(execute: action) }
        if prompt.isBeingDismissed, let transition = prompt.transitionCoordinator {
            if !transition.animate(alongsideTransition: nil, completion: { _ in completion() }) { completion() }
        } else {
            prompt.dismiss(animated: true, completion: completion)
        }
    }

    private func anchor(_ prompt: UIAlertController, owner: UIViewController) {
        prompt.popoverPresentationController?.sourceView = owner.view
        prompt.popoverPresentationController?.sourceRect = CGRect(
            x: owner.view.bounds.midX, y: owner.view.bounds.midY, width: 1, height: 1)
    }
}
