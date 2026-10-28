import UIKit

struct ReaderSafeAreaPolicy: Equatable {
    let insets: UIEdgeInsets
    let headerVisible: Bool
    let footerVisible: Bool
    let navigationBarVisible: Bool

    static let zero = ReaderSafeAreaPolicy(insets: .zero, headerVisible: true, footerVisible: true, navigationBarVisible: true)

    init(insets: UIEdgeInsets, headerVisible: Bool, footerVisible: Bool, navigationBarVisible: Bool) {
        self.insets = UIEdgeInsets(
            top: ceil(max(insets.top, 0)),
            left: ceil(max(insets.left, 0)),
            bottom: ceil(max(insets.bottom, 0)),
            right: ceil(max(insets.right, 0))
        )
        self.headerVisible = headerVisible
        self.footerVisible = footerVisible
        self.navigationBarVisible = navigationBarVisible
    }

    init(view: UIView, theme: ReaderThemeController) {
        var sourceInsets = view.safeAreaInsets
        if let window = view.window, !view.bounds.isEmpty {
            let bounds = view.bounds
            let windowSafeFrame = view.convert(window.bounds.inset(by: window.safeAreaInsets), from: window)
            // Intersect per axis with this view; an entirely unsafe axis consumes its full extent.
            let safeMinX = min(max(windowSafeFrame.minX, bounds.minX), bounds.maxX)
            let safeMaxX = max(min(windowSafeFrame.maxX, bounds.maxX), bounds.minX)
            let safeMinY = min(max(windowSafeFrame.minY, bounds.minY), bounds.maxY)
            let safeMaxY = max(min(windowSafeFrame.maxY, bounds.maxY), bounds.minY)
            sourceInsets = UIEdgeInsets(
                top: max(sourceInsets.top, safeMinY - bounds.minY),
                left: max(sourceInsets.left, safeMinX - bounds.minX),
                bottom: max(sourceInsets.bottom, bounds.maxY - safeMaxY),
                right: max(sourceInsets.right, bounds.maxX - safeMaxX)
            )
        }
        self.init(
            insets: sourceInsets, headerVisible: theme.isHeaderVisible(), footerVisible: theme.isFooterVisible(), navigationBarVisible: !theme.hideNavigationBar
        )
    }

    func applying(to theme: ReaderThemeController) -> ReaderThemeController {
        var copy = theme
        // Each edge belongs to either the root or its visible system-bar spacer, never both.
        copy.rootInsets = UIEdgeInsets(
            top: theme.hideStatusBar ? insets.top : 0,
            left: insets.left,
            bottom: theme.hideNavigationBar ? insets.bottom : 0,
            right: insets.right
        )
        copy.statusBarSpacerHeight = theme.hideStatusBar ? 0 : insets.top
        copy.navigationBarSpacerHeight = theme.hideNavigationBar ? 0 : insets.bottom
        return copy
    }
}
