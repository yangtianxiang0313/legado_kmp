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
        imageStyle: String,
        isCancelled: () -> Bool = { false }
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
        layoutSignature = layout.layoutSignature(isCancelled: isCancelled)
    }
}

extension ReaderChapterLayout {
    // A cancelled signature is deliberately unusable: the worker must check its
    // token before lookup/insert, not interpret this partial digest as a cache key.
    fileprivate func layoutSignature(isCancelled: () -> Bool) -> Int {
        var hasher = Hasher()
        guard combinePaginationText(chapterTitle, into: &hasher, isCancelled: isCancelled),
            combinePaginationText(searchableText, into: &hasher, isCancelled: isCancelled)
        else { return hasher.finalize() }
        for page in pages {
            guard !isCancelled() else { return hasher.finalize() }
            hasher.combine(Int(page.pageIndex))
            hasher.combine(Int(page.chapterStartPosition))
            hasher.combine(Int(page.chapterEndPosition))
            guard combinePaginationText(page.previewText, into: &hasher, isCancelled: isCancelled) else {
                return hasher.finalize()
            }
            for fragment in page.fragments {
                guard !isCancelled() else { return hasher.finalize() }
                hasher.combine(Int(fragment.blockIndex))
                hasher.combine(String(describing: fragment.kind))
                guard combinePaginationText(fragment.text, into: &hasher, isCancelled: isCancelled) else {
                    return hasher.finalize()
                }
                for value in [fragment.imageUrl, fragment.imageAlt] {
                    hasher.combine(value != nil)
                    if let value, !combinePaginationText(value, into: &hasher, isCancelled: isCancelled) {
                        return hasher.finalize()
                    }
                }
                hasher.combine(Int(fragment.chapterStartPosition))
                hasher.combine(Int(fragment.chapterEndPosition))
                hasher.combine(fragment.isContinuation)
                hasher.combine(fragment.isParagraphEnd)
            }
        }
        return hasher.finalize()
    }
}

// Bound time between cancellation checks even for a chapter with one huge text
// block. Native UTF-8 storage avoids copying; foreign strings use the same chunks.
private func combinePaginationText(_ text: String, into hasher: inout Hasher, isCancelled: () -> Bool) -> Bool {
    guard !isCancelled() else { return false }
    if let completed = text.utf8.withContiguousStorageIfAvailable({ bytes -> Bool in
        let raw = UnsafeRawBufferPointer(bytes)
        for start in stride(from: 0, to: raw.count, by: 4096) {
            guard !isCancelled() else { return false }
            let end = min(start + 4096, raw.count)
            hasher.combine(bytes: UnsafeRawBufferPointer(rebasing: raw[start..<end]))
        }
        hasher.combine(raw.count)
        return true
    }) {
        return completed
    }
    var buffer: [UInt8] = []
    buffer.reserveCapacity(4096)
    var count = 0
    for byte in text.utf8 {
        buffer.append(byte)
        count += 1
        if buffer.count == 4096 {
            guard !isCancelled() else { return false }
            buffer.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
            buffer.removeAll(keepingCapacity: true)
        }
    }
    guard !isCancelled() else { return false }
    if !buffer.isEmpty {
        buffer.withUnsafeBufferPointer { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
    }
    hasher.combine(count)
    return true
}
