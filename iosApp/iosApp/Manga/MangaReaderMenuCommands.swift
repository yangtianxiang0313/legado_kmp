import UIKit

@MainActor
enum MangaReaderMenuCommands {
    static func existingMore(
        recoveryItems: [UIMenuElement], progressItems: [UIMenuElement], automaticItems: [UIMenuElement],
        onDownload: @escaping @MainActor () -> Void, onSettings: @escaping @MainActor () -> Void
    ) -> [UIMenuElement] {
        let recoveryItems = recoveryItems.filter {
            ($0 as? UIAction)?.identifier != UIAction.Identifier("mangaReader.changeSource")
        }
        var elements: [UIMenuElement] = []
        if !recoveryItems.isEmpty {
            elements.append(UIMenu(options: .displayInline, children: recoveryItems))
        }
        elements.append(
            UIMenu(
                title: L10n.text("manga.flow.cloud_progress", "云端进度"), image: UIImage(systemName: "icloud"),
                children: progressItems))
        elements.append(
            UIMenu(title: L10n.text("manga.flow.automatic_reading", "自动阅读"), children: automaticItems))
        // The owner resolves the current reader and checks its interaction gates when each action runs.
        elements.append(
            UIMenu(
                options: .displayInline,
                children: [
                    UIAction(
                        title: L10n.text("manga.ui.chrome.offline_cache", "离线缓存"),
                        image: UIImage(systemName: "arrow.down.circle"),
                        identifier: UIAction.Identifier("mangaReader.download")
                    ) { _ in onDownload() },
                    UIAction(
                        title: L10n.text("manga.ui.settings.title", "漫画设置"),
                        image: UIImage(systemName: "slider.horizontal.3"),
                        identifier: UIAction.Identifier("mangaReader.settings")
                    ) { _ in onSettings() },
                ]))
        return elements
    }
}
