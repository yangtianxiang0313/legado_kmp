import UIKit

private struct ReaderChromeContext {
    let pageIndex: Int
    let chapterIndex: Int
    let chapterTitle: String
    let pageCount: Int
}

extension ReaderContainerViewController {
    func emptyChrome() -> ReaderChromeSnapshot {
        ReaderChromeSnapshot(
            title: nil, headerLeft: nil, headerCenter: nil, headerRight: nil, footerLeft: nil,
            footerCenter: nil, footerRight: nil)
    }

    func startChromeRefresh() {
        guard chromeRefreshTimer == nil else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReaderChromeMetricChange),
            name: UIDevice.batteryLevelDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleReaderChromeMetricChange),
            name: UIDevice.batteryStateDidChangeNotification,
            object: nil
        )
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refreshChromeSnapshot(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        chromeRefreshTimer = timer
        refreshChromeSnapshot(force: true)
    }

    func stopChromeRefresh() {
        chromeRefreshTimer?.invalidate()
        chromeRefreshTimer = nil
        NotificationCenter.default.removeObserver(
            self, name: UIDevice.batteryLevelDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: UIDevice.batteryStateDidChangeNotification, object: nil)
    }

    @objc func handleReaderChromeMetricChange() {
        refreshChromeSnapshot(force: true)
    }

    func refreshChromeSnapshot(force: Bool) {
        let snapshot = makeChromeSnapshot(pageIndex: currentPageIndex)
        guard force || snapshot != lastChromeSnapshot else { return }
        lastChromeSnapshot = snapshot
        if isScrollPageMode {
            scrollPagerView.updateChrome(theme: readerRenderTheme()) { [weak self] index in
                self?.makeChromeSnapshot(pageIndex: index)
                    ?? ReaderChromeSnapshot(
                        title: nil, headerLeft: nil, headerCenter: nil, headerRight: nil, footerLeft: nil,
                        footerCenter: nil, footerRight: nil)
            }
        } else {
            renderView.chrome = snapshot
        }
    }

    func currentReaderSafeAreaPolicy() -> ReaderSafeAreaPolicy {
        ReaderSafeAreaPolicy(view: view, theme: themeController)
    }

    func readerRenderTheme() -> ReaderThemeController {
        var theme = currentReaderSafeAreaPolicy().applying(to: themeController)
        let scale = view.window?.screen.scale ?? traitCollection.displayScale
        theme.chromeDisplayScale = scale.isFinite ? max(scale, 1) : 1
        return theme
    }

    func makeChromeSnapshot(pageIndex: Int) -> ReaderChromeSnapshot {
        makeChromeSnapshot(
            pageIndex: pageIndex,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            pageCount: pages.count
        )
    }

    func makeChromeSnapshot(pageIndex: Int, chapterIndex: Int, chapterTitle: String, pageCount: Int)
        -> ReaderChromeSnapshot
    {
        let context = ReaderChromeContext(
            pageIndex: pageIndex,
            chapterIndex: chapterIndex,
            chapterTitle: chapterTitle,
            pageCount: pageCount
        )
        let theme = readerRenderTheme()
        let configuredHeaderLeft = configuredTipItem(for: theme.tipHeaderLeft, context: context)
        let configuredHeaderCenter = configuredTipItem(for: theme.tipHeaderMiddle, context: context)
        let configuredHeaderRight = configuredTipItem(for: theme.tipHeaderRight, context: context)
        let configuredFooterLeft = configuredTipItem(for: theme.tipFooterLeft, context: context, keepsEmptySlot: true)
        let configuredFooterCenter = configuredTipItem(for: theme.tipFooterMiddle, context: context)
        let configuredFooterRight = configuredTipItem(for: theme.tipFooterRight, context: context)
        // Keep each configured slot authoritative, even when its content is temporarily empty.
        return ReaderChromeSnapshot(
            title: nil,
            headerLeft: configuredHeaderLeft,
            headerCenter: configuredHeaderCenter,
            headerRight: configuredHeaderRight,
            footerLeft: configuredFooterLeft,
            footerCenter: configuredFooterCenter,
            footerRight: configuredFooterRight
        )
    }

    var isScrollPageMode: Bool {
        effectiveReaderPageAnimation() == 3
    }

    private func overallProgressText(pageIndex: Int, context: ReaderChromeContext) -> String {
        // Empty pages can be transient while pagination restores the saved position.
        let chapterCount = ReaderSimulatedReadingPolicy.count(in: self)
        guard chapterCount > 0, context.pageCount > 0 else { return "0.0%" }
        let clampedChapterIndex = min(max(context.chapterIndex, 0), chapterCount - 1)
        let clampedPageIndex = min(max(pageIndex, 0), max(context.pageCount - 1, 0))
        let pageProgress =
            Double(clampedPageIndex + 1) / Double(max(context.pageCount, 1))
            / Double(chapterCount)
        var percent =
            (Double(clampedChapterIndex) / Double(chapterCount) + pageProgress) * 100
        if percent >= 100,
            clampedChapterIndex + 1 != chapterCount || clampedPageIndex + 1 != context.pageCount
        {
            percent = 99.9
        }
        return String(format: "%.1f%%", percent)
    }

    private func tipItem(for tip: Int, context: ReaderChromeContext) -> ReaderChromeItem? {
        switch tip {
        case 1:
            return .text(context.chapterTitle.nilIfEmpty)
        case 2:
            return .text(DateFormatter.readerChromeTime.string(from: Date()))
        case 3:
            return .battery(level: batteryLevel())
        case 10:
            return .text(batteryText())
        case 4:
            return .text(pageText(context: context, includeProgress: false))
        case 5:
            return .text(overallProgressText(pageIndex: context.pageIndex, context: context))
        case 6:
            return .text(pageText(context: context, includeProgress: true))
        case 7:
            return .text(book?.name.nilIfEmpty)
        case 8:
            return .battery(
                level: batteryLevel(), text: DateFormatter.readerChromeTime.string(from: Date()))
        case 9:
            return .text(
                [DateFormatter.readerChromeTime.string(from: Date()), batteryText()]
                    .compactMap { $0?.nilIfEmpty }
                    .joined(separator: " ")
                    .nilIfEmpty)
        case 11:
            let count = ReaderSimulatedReadingPolicy.count(in: self)
            guard count > 0 else { return nil }
            return .text("\(min(context.chapterIndex + 1, count))/\(count)")
        default:
            return nil
        }
    }

    private func configuredTipItem(
        for tip: Int, context: ReaderChromeContext, keepsEmptySlot: Bool = false
    ) -> ReaderChromeItem? {
        guard (1...11).contains(tip) else {
            return keepsEmptySlot ? .emptySlot() : nil
        }
        // Android visibility follows the selected tip, not whether its metadata has arrived yet.
        return tipItem(for: tip, context: context) ?? .emptySlot(usesBatteryFont: tip == 3 || tip == 8)
    }

    private func pageText(context: ReaderChromeContext, includeProgress: Bool) -> String {
        guard chapters.isEmpty == false, context.pageCount > 0 else {
            return includeProgress
                ? "0/0  \(overallProgressText(pageIndex: context.pageIndex, context: context))" : "0/0"
        }
        let clampedPageIndex = min(max(context.pageIndex, 0), max(context.pageCount - 1, 0))
        let bounds = renderView.bounds.width > 0 ? renderView.bounds : view.bounds
        let dualPageChrome = shouldUseDualPageMode(in: bounds)
        let startIndex = dualPageChrome ? (clampedPageIndex / 2) * 2 : clampedPageIndex
        let endIndex = dualPageChrome ? min(startIndex + 1, max(context.pageCount - 1, 0)) : startIndex
        let page =
            startIndex == endIndex
            ? "\(startIndex + 1)/\(max(context.pageCount, 1))"
            : "\(startIndex + 1)-\(endIndex + 1)/\(max(context.pageCount, 1))"
        return includeProgress
            ? "\(page)  \(overallProgressText(pageIndex: endIndex, context: context))" : page
    }

    private func batteryText() -> String? {
        guard let batteryLevel = batteryLevel() else { return nil }
        return "\(batteryLevel)%"
    }

    private func batteryLevel() -> Int? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else {
            #if targetEnvironment(simulator)
                return 100
            #else
                return nil
            #endif
        }
        return min(max(Int((level * 100).rounded()), 0), 100)
    }
}
