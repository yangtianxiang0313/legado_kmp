import UIKit
import shared

struct MangaReadingOptions: Equatable, Sendable {
    var horizontalScroll = false
    var pageSnap = true
    var animatesPages = true
    var allowsZoom = false
    var clickScroll = true
    var autoPageSpeed = 3
    var prefetchCount = 10
    var displayStyle: MangaImageDisplayStyle = .original
    var eInkThreshold = 150
    var hideChapterTitle = false
    var colorFilter = MangaColorFilter()
    var footer = MangaFooterConfiguration()

    init() {}

    init(_ config: AppRuntimeConfig) {
        horizontalScroll = config.enableMangaHorizontalScroll
        pageSnap = !config.disableHorizontalPageSnap
        animatesPages = !config.disableMangaPageAnim
        allowsZoom = !config.disableMangaScale
        clickScroll = !config.disableClickScroll
        autoPageSpeed = max(1, Int(config.mangaAutoPageSpeed))
        prefetchCount = min(100, max(0, Int(config.mangaPreDownloadNum)))
        eInkThreshold = min(255, max(0, Int(config.mangaEInkThreshold)))
        displayStyle = config.enableMangaGray ? .grayscale : config.enableMangaEInk ? .eInk(threshold: eInkThreshold) : .original
        hideChapterTitle = config.hideMangaTitle
        colorFilter = MangaColorFilter(json: config.mangaColorFilter)
        footer = MangaFooterConfiguration(json: config.mangaFooterConfig)
    }
}

@MainActor
final class MangaReadingSettings {
    enum Change {
        case horizontal(Bool), pageSnap(Bool), animation(Bool), zoom(Bool), clickScroll(Bool)
        case autoPageSpeed(Int), prefetch(Int), displayStyle(MangaImageDisplayStyle), threshold(Int)
        case hideTitle(Bool)
    }

    private var facade: SettingsFacade?
    private var observation: FlowSubscription?
    private var writeTask: Task<Void, Never>?
    private var filterPreview: MangaColorFilter?
    private(set) var options = MangaReadingOptions()
    private(set) var isReady = false
    private(set) var isSaving = false
    private(set) var lastError: String?
    var onChange: ((MangaReadingOptions) -> Void)?
    var onError: ((String) -> Void)?
    var onStateChange: (() -> Void)?

    deinit { observation?.cancel() }

    func load() {
        guard observation == nil else { return }
        do {
            let facade = try SharedRuntime.settingsFacade().get()
            self.facade = facade
            observation = facade.watchRuntimeConfig { [weak self] config in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let updated = MangaReadingOptions(config)
                    let changed = !self.isReady || self.options != updated
                    self.options = updated
                    self.isReady = true
                    if changed { self.notifyOptions() }
                    self.onStateChange?()
                }
            }
        } catch {
            lastError = error.userFacingMessage
            onError?(error.userFacingMessage)
            onStateChange?()
        }
    }

    func set(_ change: Change) {
        guard isReady, !isSaving, let facade else { return }
        lastError = nil
        isSaving = true
        onStateChange?()
        writeTask = Task { [self] in
            defer {
                isSaving = false
                writeTask = nil
                onStateChange?()
            }
            do { try await persist(change, facade: facade) } catch {
                lastError = error.userFacingMessage
                onError?(error.userFacingMessage)
            }
        }
    }

    private func persist(_ change: Change, facade: SettingsFacade) async throws {
        switch change {
        case .horizontal(let enabled):
            try await facade.setEnableMangaHorizontalScroll(enabled: enabled)
        case .pageSnap(let enabled):
            try await facade.setDisableHorizontalPageSnap(enabled: !enabled)
        case .animation(let enabled):
            try await facade.setDisableMangaPageAnim(enabled: !enabled)
        case .zoom(let enabled):
            try await facade.setDisableMangaScale(enabled: !enabled)
        case .clickScroll(let enabled):
            try await facade.setDisableClickScroll(enabled: !enabled)
        case .autoPageSpeed(let speed):
            try await facade.setMangaAutoPageSpeed(speed: Int32(clamping: max(1, speed)))
        case .prefetch(let count):
            try await facade.setMangaPreDownloadNum(num: Int32(clamping: min(100, max(0, count))))
        case .threshold(let value):
            try await facade.setMangaEInkThreshold(threshold: Int32(clamping: min(255, max(0, value))))
        case .hideTitle(let hidden):
            try await facade.setHideMangaTitle(enabled: hidden)
        case .displayStyle(let style):
            switch style {
            case .original:
                try await facade.setEnableMangaGray(enabled: false)
                try await facade.setEnableMangaEInk(enabled: false)
            case .grayscale:
                try await facade.setEnableMangaEInk(enabled: false)
                try await facade.setEnableMangaGray(enabled: true)
            case .eInk(let threshold):
                try await facade.setMangaEInkThreshold(threshold: Int32(clamping: min(255, max(0, threshold))))
                try await facade.setEnableMangaGray(enabled: false)
                try await facade.setEnableMangaEInk(enabled: true)
            }
        }
    }

    func previewColorFilter(_ filter: MangaColorFilter?) {
        filterPreview = filter
        notifyOptions()
    }

    func saveColorFilter(_ filter: MangaColorFilter) async throws {
        try await saveConfiguration { try await $0.setMangaColorFilter(filter: filter.json) }
        options.colorFilter = filter
        filterPreview = nil
        notifyOptions()
    }

    func saveFooter(_ footer: MangaFooterConfiguration) async throws {
        try await saveConfiguration { try await $0.setMangaFooterConfig(config: footer.json) }
        options.footer = footer
        notifyOptions()
    }

    private func saveConfiguration(_ write: (SettingsFacade) async throws -> Void) async throws {
        guard isReady, !isSaving, let facade else { throw CancellationError() }
        isSaving = true
        onStateChange?()
        defer { isSaving = false; onStateChange?() }
        try await write(facade)
    }

    private func notifyOptions() {
        var effective = options
        if let filterPreview { effective.colorFilter = filterPreview }
        onChange?(effective)
    }

    func present(from presenter: UIViewController) {
        guard presenter.presentedViewController == nil, presenter.canPerformNavigationAction else { return }
        load()
        let controller = MangaReadingSettingsViewController(settings: self)
        let navigation = UINavigationController(rootViewController: controller)
        navigation.overrideUserInterfaceStyle = .dark
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
