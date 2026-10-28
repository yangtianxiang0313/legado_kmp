import UIKit

enum AndroidToolbarLayout {
    static let titleVerticalMargins: CGFloat = 8

    static func minimumHeight(for availableSize: CGSize) -> CGFloat {
        guard isValid(availableSize) else { return 56 }
        if isWide(availableSize) { return 64 }
        return availableSize.width > availableSize.height ? 48 : 56
    }

    static func horizontalPadding(for availableSize: CGSize) -> CGFloat {
        isWide(availableSize) ? 8 : 0
    }

    static func contentInsetStart(for _: CGSize) -> CGFloat {
        // Toolbar uses a literal 16dp inset; sw600 adds 8dp outer padding separately.
        16
    }

    static func contentInsetStartWithNavigation(for availableSize: CGSize) -> CGFloat {
        isWide(availableSize) ? 80 : 72
    }

    static func searchSurfaceHeight(font: UIFont, displayScale: CGFloat) -> CGFloat {
        let scale = displayScale.isFinite ? max(displayScale, 1) : 1
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
        return max(30, ceil((font.lineHeight + padding.top + padding.bottom) * scale) / scale)
    }

    private static func isWide(_ size: CGSize) -> Bool {
        isValid(size) && min(size.width, size.height) >= 600
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}

/// Owns only the toolbar surface; content colors and control states belong to each bar.
class NavigationToolbarView: UIView {
    var usesOpaqueToolbarBackground: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        applyToolbarSurface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        applyToolbarSurface()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyToolbarSurface()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else { return }
        applyToolbarSurface()
    }

    private func applyToolbarSurface() {
        backgroundColor = usesOpaqueToolbarBackground ? AndroidReplicaTheme.toolbarBackground : .clear
        tintColor = AndroidReplicaTheme.toolbarText
    }
}
