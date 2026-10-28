import UIKit

/// The owner pins this view at the reader's bottom and calls setReaderVisible on visibility changes.
/// Height is intrinsic (or sizeThatFits); it includes any bottom safe-area inset reaching this view.
@MainActor
final class MangaReaderInfoBar: UIView {
    private let chapterNameLabel = UILabel()
    private let pageNumberLabel = UILabel()
    private let chapterLabel = UILabel()
    private let progressLabel = UILabel()
    private let timeLabel = UILabel()
    private let timeFormatter = DateFormatter()
    private var configuration = MangaFooterConfiguration()
    private var hasContent = false
    private var readerVisible = false
    private var clockSuspended = false
    private var clockTimer: Timer?
    private var lastLayoutWidth: CGFloat = 0
    private var foregroundColor = UIColor.white.withAlphaComponent(200.0 / 255)
    private var outlineColor = UIColor.black.withAlphaComponent(200.0 / 255)

    private var labels: [UILabel] {
        [chapterNameLabel, pageNumberLabel, chapterLabel, progressLabel, timeLabel]
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityIdentifier = "manga.footer"
        let identifiers = ["chapterName", "pageNumber", "chapter", "progressRatio", "time"]
        for (label, identifier) in zip(labels, identifiers) {
            label.accessibilityIdentifier = "manga.footer.\(identifier)"
            label.isAccessibilityElement = true
            label.accessibilityTraits = .staticText
            label.numberOfLines = 0
            label.lineBreakMode = .byCharWrapping
            addSubview(label)
        }
        chapterNameLabel.numberOfLines = 1
        chapterNameLabel.lineBreakMode = .byTruncatingTail
        timeLabel.numberOfLines = 1
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.textAlignment = .right
        isHidden = true
        refreshAppearance()
        let center = NotificationCenter.default
        for name in [
            UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIApplication.didBecomeActiveNotification, UIApplication.significantTimeChangeNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIScene.didActivateNotification,
            UIWindow.didResignKeyNotification, UIWindow.didBecomeKeyNotification,
            UIWindow.didBecomeHiddenNotification, UIWindow.didBecomeVisibleNotification,
            .appLockWillCover, .appLockStatusDidChange,
        ] {
            center.addObserver(self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit {
        clockTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override var isHidden: Bool {
        didSet { synchronizeClock() }
    }

    override var alpha: CGFloat {
        didSet { synchronizeClock() }
    }

    /// Indexes are zero-based and counts describe the visible chapter, not the prefetch window.
    func update(
        configuration: MangaFooterConfiguration,
        chapterName: String, chapterIndex: Int, chapterCount: Int,
        pageIndex: Int, imageCount: Int
    ) {
        self.configuration = configuration
        hasContent = true
        let chapterTotal = max(0, chapterCount)
        let imageTotal = max(0, imageCount)
        let chapter = chapterTotal > 0 ? min(max(0, chapterIndex), chapterTotal - 1) + 1 : 0
        let page = imageTotal > 0 ? min(max(0, pageIndex), imageTotal - 1) + 1 : 0
        set(
            chapterNameLabel, text: chapterName, hidden: configuration.hideChapterName || chapterName.isEmpty,
            accessibility: "章节名称，\(chapterName)")
        set(
            pageNumberLabel,
            text: "\(configuration.hidePageNumberLabel ? "" : "页数")\(page)/\(imageTotal)",
            hidden: configuration.hidePageNumber,
            accessibility: "本章图片，第 \(page) 张，共 \(imageTotal) 张")
        set(
            chapterLabel,
            text: "\(configuration.hideChapterLabel ? "" : "章节")\(chapter)/\(chapterTotal)",
            hidden: configuration.hideChapter,
            accessibility: "第 \(chapter) 章，共 \(chapterTotal) 章")
        let progress = Self.progressText(
            chapterIndex: chapterIndex, chapterCount: chapterTotal, pageIndex: pageIndex, imageCount: imageTotal)
        set(
            progressLabel,
            text: "\(configuration.hideProgressRatioLabel ? "" : "总进度")\(progress)",
            hidden: configuration.hideProgressRatio,
            accessibility: "总进度，\(progress)")
        isHidden = configuration.hideFooter
        refreshAppearance()
        accessibilityElements = labels.filter { !$0.isHidden }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        synchronizeClock()
    }

    /// Set false before covering, pushing away, or dismissing the reading screen.
    func setReaderVisible(_ visible: Bool) {
        readerVisible = visible
        accessibilityElementsHidden = !visible
        if visible, UIApplication.shared.applicationState == .active,
            window?.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        {
            clockSuspended = false
        }
        synchronizeClock()
    }

    func applyColors(text: UIColor, outline: UIColor) {
        foregroundColor = text
        outlineColor = outline
        refreshAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        synchronizeClock()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        synchronizeClock()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layoutPlan(width: bounds.width > 0 ? bounds.width : 320).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: max(0, size.width), height: layoutPlan(width: max(0, size.width)).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastLayoutWidth != bounds.width {
            lastLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        let plan = layoutPlan(width: bounds.width)
        for label in labels { label.frame = .zero }
        for placement in plan.items { placement.label.frame = placement.frame }
        synchronizeClock()
    }

    private func set(_ label: UILabel, text: String, hidden: Bool, accessibility: String) {
        label.text = text
        label.accessibilityLabel = accessibility
        label.isHidden = hidden
    }

    private func refreshAppearance() {
        for label in labels {
            let base =
                label === chapterNameLabel
                ? UIFont.systemFont(ofSize: 12) : UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: base, compatibleWith: traitCollection)
            label.font = font
            label.textColor = foregroundColor
            label.attributedText = NSAttributedString(
                string: label.text ?? "",
                attributes: [.font: font, .foregroundColor: foregroundColor, .strokeColor: outlineColor, .strokeWidth: -2])
        }
    }

    private struct Placement {
        let label: UILabel
        let frame: CGRect
    }

    private func layoutPlan(width: CGFloat) -> (height: CGFloat, items: [Placement]) {
        guard hasContent, !configuration.hideFooter, width > 0 else { return (0, []) }
        let left = min(width, 10 + safeAreaInsets.left)
        let right = max(left, width - 10 - safeAreaInsets.right)
        let available = right - left
        guard available > 0 else { return (0, []) }
        let gap: CGFloat = 6
        let rowGap: CGFloat = 4
        let top: CGFloat = 4
        let bottom = 4 + safeAreaInsets.bottom
        var items: [Placement] = []
        let metrics = [pageNumberLabel, chapterLabel, progressLabel].filter { !$0.isHidden }
        let information = (chapterNameLabel.isHidden ? [] : [chapterNameLabel]) + metrics
        func naturalWidth(_ label: UILabel) -> CGFloat {
            ceil(
                label.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width)
        }
        func size(_ label: UILabel, width: CGFloat) -> CGSize {
            let fitted = label.sizeThatFits(CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude))
            return CGSize(width: min(width, ceil(fitted.width)), height: ceil(fitted.height))
        }
        func origin(for groupWidth: CGFloat, endingAt end: CGFloat) -> CGFloat {
            guard configuration.orientation == .center else { return left }
            return max(left, min((left + right - groupWidth) / 2, end - groupWidth))
        }
        let clockSize = size(timeLabel, width: min(available, naturalWidth(timeLabel)))
        let firstRight = max(left, right - clockSize.width - (clockSize.width > 0 ? gap : 0))
        let fullWidth =
            information.reduce(CGFloat.zero) { $0 + naturalWidth($1) }
            + CGFloat(max(0, information.count - 1)) * gap
        var firstHeight = max(ceil(timeLabel.font.lineHeight), clockSize.height)
        var y = top
        if clockSize.width > 0 {
            items.append(
                Placement(
                    label: timeLabel,
                    frame: CGRect(x: right - clockSize.width, y: y, width: clockSize.width, height: clockSize.height)))
        }
        if fullWidth <= firstRight - left {
            var x = origin(for: fullWidth, endingAt: firstRight)
            for label in information {
                let fitted = size(label, width: naturalWidth(label))
                items.append(Placement(label: label, frame: CGRect(origin: CGPoint(x: x, y: y), size: fitted)))
                firstHeight = max(firstHeight, fitted.height)
                x += fitted.width + gap
            }
            return (top + firstHeight + bottom, items)
        }

        // A long title can truncate, but numeric fields get their own wrapping rows, never the clock's space.
        var titleNeedsRow = false
        if !chapterNameLabel.isHidden {
            let titleRoom = firstRight - left
            if titleRoom > 0, titleRoom >= min(available, min(60, naturalWidth(chapterNameLabel))) {
                let fitted = size(chapterNameLabel, width: titleRoom)
                items.append(
                    Placement(
                        label: chapterNameLabel,
                        frame: CGRect(
                            x: origin(for: fitted.width, endingAt: firstRight), y: y, width: fitted.width, height: fitted.height))
                )
                firstHeight = max(firstHeight, fitted.height)
            } else {
                titleNeedsRow = true
            }
        }
        y += firstHeight
        if titleNeedsRow {
            y += rowGap
            let fitted = size(chapterNameLabel, width: available)
            items.append(
                Placement(
                    label: chapterNameLabel,
                    frame: CGRect(x: origin(for: fitted.width, endingAt: right), y: y, width: fitted.width, height: fitted.height)
                ))
            y += fitted.height
        }
        if !metrics.isEmpty { y += rowGap }
        var row: [(UILabel, CGSize)] = []
        var rowWidth: CGFloat = 0
        func appendRow() {
            guard !row.isEmpty else { return }
            let height = row.map { $0.1.height }.max() ?? 0
            var x = origin(for: rowWidth, endingAt: right)
            for (label, fitted) in row {
                items.append(Placement(label: label, frame: CGRect(origin: CGPoint(x: x, y: y), size: fitted)))
                x += fitted.width + gap
            }
            y += height + rowGap
            row.removeAll()
            rowWidth = 0
        }
        for label in metrics {
            let fitted = size(label, width: min(available, naturalWidth(label)))
            if !row.isEmpty, rowWidth + gap + fitted.width > available { appendRow() }
            if !row.isEmpty { rowWidth += gap }
            row.append((label, fitted))
            rowWidth += fitted.width
        }
        appendRow()
        if !metrics.isEmpty { y -= rowGap }
        return (y + bottom, items)
    }

    private static func progressText(chapterIndex: Int, chapterCount: Int, pageIndex: Int, imageCount: Int) -> String {
        guard chapterCount > 0 else { return "0.0%" }
        let chapter = min(max(0, chapterIndex), chapterCount - 1)
        let ratio: Double
        if imageCount == 0 {
            ratio = chapter == 0 ? 0 : (Double(chapter) + 1) / Double(chapterCount)
        } else {
            let page = min(max(0, pageIndex), imageCount - 1)
            ratio = (Double(chapter) + (Double(page) + 1) / Double(imageCount)) / Double(chapterCount)
        }
        let isEnd = chapterIndex == chapterCount - 1 && (imageCount == 0 || pageIndex == imageCount - 1)
        let tenths = min(isEnd ? 1000 : 999, max(0, (ratio * 1000).rounded(.toNearestOrEven)))
        return String(format: "%.1f%%", locale: Locale(identifier: "en_US_POSIX"), tenths / 10)
    }

    private var canRunClock: Bool {
        guard hasContent, readerVisible, !clockSuspended, UIApplication.shared.applicationState == .active,
            let window, !window.isHidden, window.isKeyWindow, window.alpha > 0.01,
            window.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        var ancestor: UIView? = self
        while let view = ancestor {
            if view.isHidden || view.alpha <= 0.01 { return false }
            ancestor = view.superview
        }
        return true
    }

    private func synchronizeClock() {
        guard canRunClock else { stopClock(); return }
        guard clockTimer == nil else { return }
        updateClock()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.canRunClock else { self.stopClock(); return }
                self.updateClock()
            }
        }
        timer.fireDate = Date(timeIntervalSinceReferenceDate: (floor(Date().timeIntervalSinceReferenceDate / 60) + 1) * 60)
        timer.tolerance = 1
        clockTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateClock() {
        timeFormatter.locale = .autoupdatingCurrent
        timeFormatter.timeZone = .autoupdatingCurrent
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        timeLabel.text = timeFormatter.string(from: Date())
        timeLabel.accessibilityLabel = "时间，\(timeLabel.text ?? "")"
        refreshAppearance()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func stopClock() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    @objc private func environmentChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== window?.windowScene { return }
        if let changedWindow = notification.object as? UIWindow, changedWindow !== window { return }
        switch notification.name {
        case UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
            UIScene.didDisconnectNotification, UIWindow.didResignKeyNotification,
            UIWindow.didBecomeHiddenNotification, .appLockWillCover:
            clockSuspended = true
            stopClock()
        default:
            clockSuspended = false
            stopClock()
            synchronizeClock()
        }
    }
}
