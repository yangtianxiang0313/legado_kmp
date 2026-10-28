import UIKit

final class ReaderRenderView: UIView {
    private let backgroundImageView = UIImageView()
    private let statusBarSpacer = UIView()
    private let headerRow = ReaderTipRowView(left: ReaderChromeLabel(), center: ReaderChromeLabel(), right: ReaderChromeLabel())
    let contentView = ReaderPageContentView()
    private let trailingContentView = ReaderPageContentView()
    private let footerRow = ReaderTipRowView(left: ReaderChromeLabel(), center: ReaderChromeLabel(), right: ReaderChromeLabel())
    private let headerHairline = UIView()
    private let footerHairline = UIView()
    private let navigationBarSpacer = UIView()
    private var headerLeftLabel: ReaderChromeLabel {
        headerRow.leftLabel
    }

    private var headerCenterLabel: ReaderChromeLabel {
        headerRow.centerLabel
    }

    private var headerRightLabel: ReaderChromeLabel {
        headerRow.rightLabel
    }

    private var footerLeftLabel: ReaderChromeLabel {
        footerRow.leftLabel
    }

    private var footerCenterLabel: ReaderChromeLabel {
        footerRow.centerLabel
    }

    private var footerRightLabel: ReaderChromeLabel {
        footerRow.rightLabel
    }

    private var currentPageLayout: ReaderPageLayout?
    private var currentTrailingPageLayout: ReaderPageLayout?
    private var chapterMessageVisible = false

    private var effectiveDisplayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale.isFinite ? max(scale, 1) : 1
    }

    var pageGeometry: ReaderPageGeometry {
        ReaderPageGeometry.estimated(bounds: bounds, theme: theme, displayScale: effectiveDisplayScale)
    }

    var chapterMessageContentFrame: CGRect {
        pageGeometry.contentFrame
    }

    func setChapterMessageVisible(_ visible: Bool) {
        chapterMessageVisible = visible
        contentView.isHidden = visible
        trailingContentView.isHidden = visible || currentTrailingPageLayout == nil
        rebuildAccessibilityElements()
    }

    var bookURL: String? {
        didSet {
            contentView.bookURL = bookURL
            trailingContentView.bookURL = bookURL
        }
    }

    var chrome: ReaderChromeSnapshot? {
        didSet {
            rebuildChrome()
        }
    }

    var pageLayout: ReaderPageLayout? {
        didSet {
            currentPageLayout = pageLayout
            currentTrailingPageLayout = nil
            rebuildContent()
        }
    }

    func setPageLayouts(primary: ReaderPageLayout?, trailing: ReaderPageLayout?) {
        currentPageLayout = primary
        currentTrailingPageLayout = trailing
        rebuildContent()
    }

    var highlightedBlockIndex: Int? {
        didSet {
            contentView.highlightedBlockIndex = highlightedBlockIndex
            trailingContentView.highlightedBlockIndex = highlightedBlockIndex
            if oldValue != highlightedBlockIndex {
                setNeedsDisplay()
            }
        }
    }

    var selectionRange: NSRange? {
        didSet {
            contentView.selectionRange = selectionRange
            trailingContentView.selectionRange = selectionRange
        }
    }

    var searchResultRange: NSRange? {
        didSet {
            contentView.searchResultRange = searchResultRange
            trailingContentView.searchResultRange = searchResultRange
        }
    }

    var theme: ReaderThemeController = .init() {
        didSet {
            backgroundColor = theme.visibleBackgroundColor
            for item in [headerLeftLabel, headerCenterLabel, headerRightLabel, footerLeftLabel, footerCenterLabel, footerRightLabel] {
                item.textColor = theme.tipColor
                item.font = theme.tipFont
            }
            contentView.theme = theme
            trailingContentView.theme = theme
            rebuildContent()
            rebuildChrome()
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = false
        isOpaque = true
        backgroundColor = theme.visibleBackgroundColor
        backgroundImageView.contentMode = .scaleAspectFill
        backgroundImageView.clipsToBounds = true
        addSubview(backgroundImageView)
        addSubview(statusBarSpacer)
        configureChromeLabel(headerLeftLabel, alignment: .left)
        configureChromeLabel(headerCenterLabel, alignment: .center)
        configureChromeLabel(headerRightLabel, alignment: .right)
        configureChromeLabel(footerLeftLabel, alignment: .left)
        configureChromeLabel(footerCenterLabel, alignment: .center)
        configureChromeLabel(footerRightLabel, alignment: .right)
        addSubview(headerRow)
        addSubview(contentView)
        addSubview(trailingContentView)
        addSubview(footerRow)
        addSubview(headerHairline)
        addSubview(footerHairline)
        addSubview(navigationBarSpacer)
        contentView.isOpaque = false
        contentView.backgroundColor = .clear
        contentView.theme = theme
        trailingContentView.isOpaque = false
        trailingContentView.backgroundColor = .clear
        trailingContentView.theme = theme
        trailingContentView.isHidden = true
        contentView.updatePageContentAccessibility()
        trailingContentView.updatePageContentAccessibility()
        rebuildAccessibilityElements()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func rebuildContent() {
        backgroundColor = theme.visibleBackgroundColor
        statusBarSpacer.backgroundColor = theme.visibleBackgroundColor
        navigationBarSpacer.backgroundColor = theme.visibleBackgroundColor
        contentView.theme = theme
        trailingContentView.theme = theme
        contentView.pageLayout = currentPageLayout
        trailingContentView.pageLayout = currentTrailingPageLayout
        contentView.highlightedBlockIndex = highlightedBlockIndex
        trailingContentView.highlightedBlockIndex = highlightedBlockIndex
        trailingContentView.selectionRange = selectionRange
        contentView.searchResultRange = searchResultRange
        trailingContentView.searchResultRange = searchResultRange
        contentView.isHidden = chapterMessageVisible
        trailingContentView.isHidden = chapterMessageVisible || currentTrailingPageLayout == nil

        if let path = theme.backgroundImagePath, path.isEmpty == false {
            backgroundImageView.image = ReaderBackgroundImageCatalog.image(forStoredPath: path)
            backgroundImageView.alpha = theme.backgroundAlpha
        } else {
            backgroundImageView.image = nil
        }

        rebuildAccessibilityElements()
        setNeedsLayout()
    }

    private func rebuildChrome() {
        let chrome = chrome
        headerLeftLabel.chromeItem = chrome?.headerLeft
        headerCenterLabel.chromeItem = chrome?.headerCenter
        headerRightLabel.chromeItem = chrome?.headerRight
        footerLeftLabel.chromeItem = chrome?.footerLeft
        footerCenterLabel.chromeItem = chrome?.footerCenter
        footerRightLabel.chromeItem = chrome?.footerRight
        for item in [headerLeftLabel, headerCenterLabel, headerRightLabel, footerLeftLabel, footerCenterLabel, footerRightLabel] {
            item.isHidden = item.chromeItem?.isEmpty ?? true
        }
        headerRow.isHidden = !theme.isHeaderVisible() || chrome?.hasHeaderContent != true
        footerRow.isHidden = !theme.isFooterVisible() || chrome?.hasFooterContent != true
        headerHairline.isHidden = !theme.showHeaderLine || !theme.isHeaderVisible()
        footerHairline.isHidden = !theme.showFooterLine || !theme.isFooterVisible()
        headerHairline.backgroundColor = theme.tipDividerColor
        footerHairline.backgroundColor = theme.tipDividerColor
        statusBarSpacer.isHidden = theme.statusBarSpacerHeight <= 0
        navigationBarSpacer.isHidden = theme.navigationBarSpacerHeight <= 0
        headerRow.setNeedsLayout()
        footerRow.setNeedsLayout()
        rebuildAccessibilityElements()
        setNeedsLayout()
    }

    var headerAccessibilityElements: [UIView] {
        guard !headerRow.isHidden else { return [] }
        return [headerLeftLabel, headerCenterLabel, headerRightLabel].filter { !$0.isHidden && $0.chromeItem?.isEmpty == false }
    }

    var footerAccessibilityElements: [UIView] {
        guard !footerRow.isHidden else { return [] }
        return [footerLeftLabel, footerCenterLabel, footerRightLabel].filter { !$0.isHidden && $0.chromeItem?.isEmpty == false }
    }

    private func rebuildAccessibilityElements() {
        let body = [contentView, trailingContentView].filter {
            $0.isHidden == false && $0.isAccessibilityElement
        }
        accessibilityElements = headerAccessibilityElements + body + footerAccessibilityElements
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundImageView.frame = bounds
        // Reserve chrome by configuration, not by transient metadata availability.
        let geometry = pageGeometry
        statusBarSpacer.frame = geometry.statusBarFrame
        headerRow.frame = geometry.headerRowFrame
        headerHairline.frame = geometry.headerHairlineFrame
        if currentTrailingPageLayout == nil {
            contentView.frame = geometry.contentHostFrame
            contentView.visibleRect = geometry.contentFrame.offsetBy(dx: -geometry.contentHostFrame.minX, dy: -geometry.contentHostFrame.minY)
            trailingContentView.frame = .zero
            trailingContentView.visibleRect = .zero
        } else {
            let spreadGeometry = ReaderSpreadGeometry(bounds: bounds, theme: theme, displayScale: geometry.displayScale)
            contentView.frame = spreadGeometry.leadingContentHostFrame
            trailingContentView.frame = spreadGeometry.trailingContentHostFrame
            contentView.visibleRect = spreadGeometry.visibleRect
            trailingContentView.visibleRect = spreadGeometry.visibleRect
        }
        footerRow.frame = geometry.footerRowFrame
        footerHairline.frame = geometry.footerHairlineFrame
        navigationBarSpacer.frame = geometry.navigationBarFrame
    }

    private func configureChromeLabel(_ label: UILabel, alignment: NSTextAlignment) {
        label.font = theme.tipFont
        label.textAlignment = alignment
        label.textColor = theme.tipColor
        label.numberOfLines = 1
    }

    func layoutTarget(at point: CGPoint) -> (pageOffset: Int, layoutPoint: CGPoint)? {
        guard !chapterMessageVisible else { return nil }
        let primaryPoint = contentView.convert(point, from: self)
        if let layoutPoint = contentView.layoutPoint(at: primaryPoint) {
            return (0, layoutPoint)
        }
        guard trailingContentView.isHidden == false else { return nil }
        let trailingPoint = trailingContentView.convert(point, from: self)
        if let layoutPoint = trailingContentView.layoutPoint(at: trailingPoint) {
            return (1, layoutPoint)
        }
        return nil
    }

    var selectionVisiblePageOffsets: [Int] {
        guard !chapterMessageVisible else { return [] }
        return trailingContentView.isHidden ? [0] : [0, 1]
    }

    func loadedImage(for url: URL, pageOffset: Int) -> UIImage? {
        guard !chapterMessageVisible else { return nil }
        return contentView(for: pageOffset).loadedImages[url]
    }

    func removeCachedImage(for url: URL) {
        contentView.removeCachedImage(for: url)
        trailingContentView.removeCachedImage(for: url)
    }

    func cacheLoadedImage(_ image: UIImage, for url: URL) {
        contentView.cacheLoadedImage(image, for: url)
        trailingContentView.cacheLoadedImage(image, for: url)
    }

    func viewRect(for layoutRect: CGRect, pageOffset: Int) -> CGRect {
        let pageContentView = contentView(for: pageOffset)
        return pageContentView.convert(pageContentView.viewRect(for: layoutRect), to: self)
    }

    private func contentView(for pageOffset: Int) -> ReaderPageContentView {
        pageOffset == 1 && trailingContentView.isHidden == false ? trailingContentView : contentView
    }
}
