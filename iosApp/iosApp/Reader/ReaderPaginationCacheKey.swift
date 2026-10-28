import UIKit
import shared

struct ReaderPaginationCacheKey: Hashable {
    private let chapterIndex: Int
    private let pageCount: Int
    private let width: CGFloat
    private let height: CGFloat
    private let contentWidth: CGFloat
    private let contentHeight: CGFloat
    private let contentHostHeight: CGFloat
    private let headerHeight: CGFloat
    private let footerHeight: CGFloat
    private let headerVisible: Bool
    private let footerVisible: Bool
    private let headerMode: Int
    private let footerMode: Int
    private let font: UIFont
    private let titleFont: UIFont
    private let bodyStrokeWidth: CGFloat
    private let titleStrokeWidth: CGFloat
    private let bodyLineHeight: CGFloat
    private let titleLineHeight: CGFloat
    private let lineSpacing: CGFloat
    private let letterSpacing: CGFloat
    private let paragraphSpacing: CGFloat
    private let headingParagraphSpacing: CGFloat
    private let paragraphIndent: Int
    private let rootInsetTop: CGFloat
    private let rootInsetLeft: CGFloat
    private let rootInsetBottom: CGFloat
    private let rootInsetRight: CGFloat
    private let insetTop: CGFloat
    private let insetLeft: CGFloat
    private let insetBottom: CGFloat
    private let insetRight: CGFloat
    private let headerInsetTop: CGFloat
    private let headerInsetLeft: CGFloat
    private let headerInsetBottom: CGFloat
    private let headerInsetRight: CGFloat
    private let footerInsetTop: CGFloat
    private let footerInsetLeft: CGFloat
    private let footerInsetBottom: CGFloat
    private let footerInsetRight: CGFloat
    private let statusBarSpacerHeight: CGFloat
    private let navigationBarSpacerHeight: CGFloat
    private let textAlignmentRawValue: Int
    private let underline: Bool
    private let titleMode: Int
    private let titleTopSpacing: CGFloat
    private let titleBottomSpacing: CGFloat
    private let showHeaderLine: Bool
    private let showFooterLine: Bool
    private let prefersBottomAlignedContent: Bool
    private let chineseMode: Int
    private let useZhLayout: Bool
    private let textColor: UIColor
    private let backgroundColor: UIColor
    private let imageStyle: String
    private let layoutSignature: Int

    init(
        layout: ReaderChapterLayout,
        bounds: CGRect,
        pageGeometry: ReaderPageGeometry,
        theme: ReaderThemeController,
        imageStyle: String
    ) {
        chapterIndex = Int(layout.chapterIndex)
        pageCount = layout.pages.count
        // Keep layout inputs exact; sub-point changes can move a line across a page boundary.
        width = bounds.width
        height = bounds.height
        contentWidth = pageGeometry.contentFrame.width
        contentHeight = pageGeometry.contentFrame.height
        contentHostHeight = pageGeometry.contentHostFrame.height
        headerHeight = pageGeometry.headerHeight
        footerHeight = pageGeometry.footerHeight
        headerVisible = theme.isHeaderVisible()
        footerVisible = theme.isFooterVisible()
        headerMode = theme.headerMode
        footerMode = theme.footerMode
        // UIKit value equality retains font descriptors and color components without quantization.
        font = theme.font
        titleFont = theme.titleFont
        bodyStrokeWidth = theme.bodyStrokeWidth
        titleStrokeWidth = theme.titleStrokeWidth
        bodyLineHeight = theme.bodyLineHeight
        titleLineHeight = theme.titleLineHeight
        lineSpacing = theme.lineSpacing
        letterSpacing = theme.letterSpacing
        paragraphSpacing = theme.paragraphSpacing
        headingParagraphSpacing = theme.headingParagraphSpacing
        paragraphIndent = theme.paragraphIndentCount
        rootInsetTop = theme.rootInsets.top
        rootInsetLeft = theme.rootInsets.left
        rootInsetBottom = theme.rootInsets.bottom
        rootInsetRight = theme.rootInsets.right
        insetTop = theme.contentInsets.top
        insetLeft = theme.contentInsets.left
        insetBottom = theme.contentInsets.bottom
        insetRight = theme.contentInsets.right
        headerInsetTop = theme.headerInsets.top
        headerInsetLeft = theme.headerInsets.left
        headerInsetBottom = theme.headerInsets.bottom
        headerInsetRight = theme.headerInsets.right
        footerInsetTop = theme.footerInsets.top
        footerInsetLeft = theme.footerInsets.left
        footerInsetBottom = theme.footerInsets.bottom
        footerInsetRight = theme.footerInsets.right
        statusBarSpacerHeight = theme.statusBarSpacerHeight
        navigationBarSpacerHeight = theme.navigationBarSpacerHeight
        textAlignmentRawValue = theme.textAlignment.rawValue
        underline = theme.underline
        titleMode = theme.titleMode
        titleTopSpacing = theme.titleTopSpacing
        titleBottomSpacing = theme.titleBottomSpacing
        showHeaderLine = theme.showHeaderLine
        showFooterLine = theme.showFooterLine
        prefersBottomAlignedContent = theme.prefersBottomAlignedContent
        chineseMode = theme.chineseMode
        useZhLayout = theme.useZhLayout
        textColor = theme.textColor
        backgroundColor = theme.backgroundColor
        self.imageStyle = imageStyle
        layoutSignature = layout.layoutSignature
    }
}

extension ReaderChapterLayout {
    fileprivate var layoutSignature: Int {
        var hasher = Hasher()
        hasher.combine(chapterTitle)
        hasher.combine(searchableText)
        return pages.reduce(into: hasher) { hasher, page in
            hasher.combine(Int(page.pageIndex))
            hasher.combine(Int(page.chapterStartPosition))
            hasher.combine(Int(page.chapterEndPosition))
            hasher.combine(page.previewText)
            for fragment in page.fragments {
                hasher.combine(Int(fragment.blockIndex))
                hasher.combine(String(describing: fragment.kind))
                hasher.combine(fragment.text)
                hasher.combine(fragment.imageUrl)
                hasher.combine(fragment.imageAlt)
                hasher.combine(Int(fragment.chapterStartPosition))
                hasher.combine(Int(fragment.chapterEndPosition))
                hasher.combine(fragment.isContinuation)
                hasher.combine(fragment.isParagraphEnd)
            }
        }.finalize()
    }
}
