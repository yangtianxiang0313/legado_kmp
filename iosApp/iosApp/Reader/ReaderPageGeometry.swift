import UIKit

struct ReaderPageGeometry {
    let bounds: CGRect
    let displayScale: CGFloat
    let statusBarFrame: CGRect
    let headerRowFrame: CGRect
    let headerHairlineFrame: CGRect
    let contentHostFrame: CGRect
    let contentFrame: CGRect
    let footerRowFrame: CGRect
    let footerHairlineFrame: CGRect
    let navigationBarFrame: CGRect
    let statusBarHeight: CGFloat
    let headerHeight: CGFloat
    let footerHeight: CGFloat
    let navigationBarHeight: CGFloat
    let dividerHeight: CGFloat
    let rootFrame: CGRect

    static func estimated(
        bounds: CGRect, theme: ReaderThemeController, displayScale: CGFloat? = nil
    ) -> ReaderPageGeometry {
        let requestedScale = displayScale ?? theme.chromeDisplayScale
        let scale = requestedScale.isFinite ? max(requestedScale, 1) : 1
        return ReaderPageGeometry(
            bounds: bounds,
            theme: theme,
            headerContentHeight: theme.headerRowHeight(displayScale: scale),
            footerContentHeight: theme.footerRowHeight(displayScale: scale),
            displayScale: scale
        )
    }

    init(
        bounds: CGRect,
        theme: ReaderThemeController,
        headerContentHeight: CGFloat,
        footerContentHeight: CGFloat,
        displayScale: CGFloat? = nil
    ) {
        self.bounds = bounds
        let requestedScale = displayScale ?? theme.chromeDisplayScale
        let scale = requestedScale.isFinite ? max(requestedScale, 1) : 1
        self.displayScale = scale
        dividerHeight = 0.5
        let rootInsets = UIEdgeInsets(
            top: min(max(theme.rootInsets.top, 0), max(bounds.height - 1, 0)),
            left: min(max(theme.rootInsets.left, 0), max(bounds.width - 1, 0)),
            bottom: min(max(theme.rootInsets.bottom, 0), max(bounds.height - 1, 0)),
            right: min(max(theme.rootInsets.right, 0), max(bounds.width - 1, 0))
        )
        rootFrame = CGRect(
            x: rootInsets.left,
            y: rootInsets.top,
            width: max(bounds.width - rootInsets.left - rootInsets.right, 1),
            height: max(bounds.height - rootInsets.top - rootInsets.bottom, 1)
        )

        let headerVisible = theme.isHeaderVisible()
        let footerVisible = theme.isFooterVisible()
        let headerDividerHeight = headerVisible && theme.showHeaderLine ? dividerHeight : 0
        let footerDividerHeight = footerVisible && theme.showFooterLine ? dividerHeight : 0
        statusBarHeight = max(ceil(theme.statusBarSpacerHeight), 0)
        navigationBarHeight = max(ceil(theme.navigationBarSpacerHeight), 0)
        let measuredHeaderContentHeight = headerVisible ? max(ceil(headerContentHeight * scale) / scale, 0) : 0
        let measuredFooterContentHeight = footerVisible ? max(ceil(footerContentHeight * scale) / scale, 0) : 0

        statusBarFrame = CGRect(x: rootFrame.minX, y: rootFrame.minY, width: rootFrame.width, height: statusBarHeight)
        navigationBarFrame = CGRect(
            x: rootFrame.minX,
            y: rootFrame.maxY - navigationBarHeight,
            width: rootFrame.width,
            height: navigationBarHeight
        )

        headerHeight = headerVisible
            ? theme.headerInsets.top + measuredHeaderContentHeight + theme.headerInsets.bottom + headerDividerHeight
            : 0
        footerHeight = footerVisible
            ? theme.footerInsets.top + measuredFooterContentHeight + theme.footerInsets.bottom + footerDividerHeight
            : 0

        if headerVisible {
            headerRowFrame = CGRect(
                x: rootFrame.minX + theme.headerInsets.left,
                y: rootFrame.minY + statusBarHeight + theme.headerInsets.top,
                width: max(rootFrame.width - theme.headerInsets.left - theme.headerInsets.right, 1),
                height: measuredHeaderContentHeight
            )
            headerHairlineFrame = CGRect(
                x: rootFrame.minX,
                y: headerRowFrame.maxY + theme.headerInsets.bottom,
                width: rootFrame.width,
                height: headerDividerHeight
            )
        } else {
            headerRowFrame = .zero
            headerHairlineFrame = .zero
        }

        contentHostFrame = CGRect(
            x: rootFrame.minX,
            y: rootFrame.minY + statusBarHeight + headerHeight,
            width: rootFrame.width,
            height: max(rootFrame.height - statusBarHeight - navigationBarHeight - headerHeight - footerHeight, 1)
        )
        contentFrame = CGRect(
            x: contentHostFrame.minX + theme.contentInsets.left,
            y: contentHostFrame.minY + theme.contentInsets.top,
            width: max(contentHostFrame.width - theme.contentInsets.left - theme.contentInsets.right, 1),
            height: max(contentHostFrame.height - theme.contentInsets.top - theme.contentInsets.bottom, 1)
        )

        if footerVisible {
            footerRowFrame = CGRect(
                x: rootFrame.minX + theme.footerInsets.left,
                y: rootFrame.maxY - navigationBarHeight - theme.footerInsets.bottom - measuredFooterContentHeight,
                width: max(rootFrame.width - theme.footerInsets.left - theme.footerInsets.right, 1),
                height: measuredFooterContentHeight
            )
            footerHairlineFrame = CGRect(
                x: rootFrame.minX,
                y: footerRowFrame.minY - theme.footerInsets.top - footerDividerHeight,
                width: rootFrame.width,
                height: footerDividerHeight
            )
        } else {
            footerRowFrame = .zero
            footerHairlineFrame = .zero
        }
    }
}

struct ReaderSpreadGeometry {
    let paginationBounds: CGRect
    let leadingContentHostFrame: CGRect
    let trailingContentHostFrame: CGRect
    let visibleRect: CGRect

    init(bounds: CGRect, theme: ReaderThemeController, displayScale: CGFloat? = nil) {
        let pageGeometry = ReaderPageGeometry.estimated(bounds: bounds, theme: theme, displayScale: displayScale)
        let columnWidth = max(pageGeometry.rootFrame.width / 2, 1)
        // The layout engine still removes rootInsets from its viewport once.
        paginationBounds = CGRect(
            x: 0,
            y: 0,
            width: columnWidth + max(theme.rootInsets.left, 0) + max(theme.rootInsets.right, 0),
            height: max(bounds.height, 1)
        )
        let columnGeometry = ReaderPageGeometry.estimated(
            bounds: paginationBounds, theme: theme, displayScale: pageGeometry.displayScale)
        leadingContentHostFrame = CGRect(
            x: pageGeometry.contentHostFrame.minX,
            y: columnGeometry.contentHostFrame.minY,
            width: columnGeometry.contentHostFrame.width,
            height: columnGeometry.contentHostFrame.height
        )
        trailingContentHostFrame = leadingContentHostFrame.offsetBy(dx: columnWidth, dy: 0)
        visibleRect = columnGeometry.contentFrame.offsetBy(
            dx: -columnGeometry.contentHostFrame.minX,
            dy: -columnGeometry.contentHostFrame.minY
        )
    }
}
