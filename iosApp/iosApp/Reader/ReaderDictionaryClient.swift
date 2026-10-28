import SafariServices
import UIKit
import shared

@MainActor
struct ReaderDictionaryClient {
    let facade: DictionaryFacade

    func loadRules() async throws -> [DictRule] {
        try await facade.loadRules()
    }

    func lookup(rule: DictRule, word: String) async throws -> String {
        let result: DictionaryLookupResult = try await SharedCancellableAsync.value { complete in
            facade.lookupRequest(rule: rule, word: word) { complete($0, nil) }
        }
        try Task.checkCancellation()
        if result.isCancelled { throw CancellationError() }
        if let error = result.errorMessage {
            throw NSError(domain: "io.legado.kmp.dictionary", code: -1, userInfo: [NSLocalizedDescriptionKey: error])
        }
        guard let html = result.html else {
            throw NSError(
                domain: "io.legado.kmp.dictionary", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "词典查询未返回结果"])
        }
        return html
    }
}

extension ReaderContainerViewController {
    func showDictionary(word: String) {
        guard canPerformNavigationAction else { return }
        do {
            let expectedBookURL = bookURL
            let expectedOrigin = book?.origin
            let client = ReaderDictionaryClient(facade: try SharedRuntime.dictionaryFacade().get())
            weak var dialog: ReaderDictionaryDialogViewController?
            let controller = ReaderDictionaryDialogViewController(
                word: word, loadRules: { try await client.loadRules() },
                lookup: { try await client.lookup(rule: $0, word: $1) },
                onOpenURL: { [weak self] url in
                    guard let self, let dialog, self.presentedViewController === dialog,
                        dialog.presentedViewController == nil
                    else { return }
                    switch url.scheme?.lowercased() {
                    case "http", "https": dialog.present(SFSafariViewController(url: url), animated: true)
                    case "mailto", "tel": UIApplication.shared.open(url)
                    default: break
                    }
                })
            dialog = controller
            controller.canSubmit = { [weak self] in
                guard let self else { return false }
                return self.bookURL == expectedBookURL && self.book?.origin == expectedOrigin
                    && self.navigationController?.topViewController === self
                    && !self.isBeingDismissed && !self.isMovingFromParent
            }
            controller.overrideUserInterfaceStyle = readMenu.overflowInterfaceStyle
            present(controller, animated: true)
        } catch {
            showToast(error.userFacingMessage)
        }
    }
}
