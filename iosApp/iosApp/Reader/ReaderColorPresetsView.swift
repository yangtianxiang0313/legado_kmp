import UIKit

/// colorpicker 1.1.0's preset body. The presenter owns confirmation, persistence,
/// and vertical scrolling; the twelve shades retain the original horizontal scroller.
final class ReaderColorPresetsView: UIView {
    var onColorChange: ((UIColor) -> Void)?
    var onConfirm: ((UIColor) -> Void)?

    /// A single original 58pt column plus the layout's two 16pt insets.
    /// Below this width the parent must also provide horizontal overflow/scrolling.
    static let minimumContentWidth: CGFloat = 90

    private enum Metrics {
        static let inset: CGFloat = 16
        static let columnWidth: CGFloat = 58
        static let horizontalSpacing: CGFloat = 4
        static let rowSpacing: CGFloat = 8
        static let itemSize: CGFloat = 50
        static let dividerMargin: CGFloat = 12
        static let dividerHeight: CGFloat = 1
        static let shadeMargin: CGFloat = 4
        static let shadePadding: CGFloat = 8
    }

    private let initialARGB: UInt32
    private var currentARGB: UInt32
    private var presetColors: [UInt32] = []
    private var shadeColors: [UInt32] = []
    private var selectedPreset: Int?
    private var selectedShade: Int?
    private var presetSwatches: [ReaderColorSwatchView] = []
    private var shadeSwatches: [ReaderColorSwatchView] = []
    private let divider = UIView()
    private let shadesScrollView = ReaderColorShadeScrollView()
    private let hintLabel = AndroidExploreTextLabel()
    private weak var hintedSwatch: ReaderColorSwatchView?
    private var hideHintWorkItem: DispatchWorkItem?
    private var shadeLayoutDirection: UIUserInterfaceLayoutDirection?

    init(initialColor: UIColor, color: UIColor) {
        initialARGB = Self.argb(from: initialColor, traits: .current)
        currentARGB = Self.argb(from: color, traits: .current)
        super.init(frame: .zero)
        isAccessibilityElement = false
        divider.backgroundColor = .separator
        divider.isAccessibilityElement = false
        addSubview(divider)

        shadesScrollView.isAccessibilityElement = false
        shadesScrollView.contentInsetAdjustmentBehavior = .never
        shadesScrollView.showsHorizontalScrollIndicator = false
        shadesScrollView.showsVerticalScrollIndicator = false
        shadesScrollView.bounces = false
        shadesScrollView.delaysContentTouches = false
        shadesScrollView.canCancelContentTouches = true
        shadesScrollView.isDirectionalLockEnabled = true
        shadesScrollView.scrollsToTop = false
        addSubview(shadesScrollView)

        hintLabel.isHidden = true
        hintLabel.isUserInteractionEnabled = false
        hintLabel.isAccessibilityElement = false
        hintLabel.textAlignment = .center
        hintLabel.numberOfLines = 0
        hintLabel.lineBreakMode = .byCharWrapping
        hintLabel.textColor = .label
        hintLabel.backgroundColor = .secondarySystemBackground
        hintLabel.layer.cornerRadius = 4
        hintLabel.clipsToBounds = true
        hintLabel.adjustsFontForContentSizeCategory = false
        addSubview(hintLabel)
        updateFonts(compatibleWith: traitCollection)
        reloadPresets()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    /// External synchronization only; no callback. An echoed shade selection must
    /// not rebuild its shades or turn its first tap into a confirmation.
    func setColor(_ color: UIColor) {
        let argb = Self.argb(from: color, traits: traitCollection)
        guard argb != currentARGB else { return }
        currentARGB = argb
        reloadPresets()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = fittingWidth(size.width)
        return CGSize(width: width, height: layoutContent(width: width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = layoutContent(width: fittingWidth(bounds.width), applyFrames: true)
        layoutHint()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts(compatibleWith: traitCollection)
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    func updateFonts(compatibleWith traits: UITraitCollection) {
        hintLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traits)
        // Only the transient hint uses text; font changes never resize grid cells.
        setNeedsLayout()
    }

    private func reloadPresets() {
        hideHint()
        presetColors = ReaderColorPalette.loadPresets(initialColor: initialARGB, color: currentARGB)
        shadeColors = ReaderColorPalette.getColorShades(currentARGB)
        selectedPreset = presetColors.firstIndex(of: currentARGB)
        selectedShade = nil
        reconcileSwatches()
        updateSwatches()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func reconcileSwatches() {
        while presetSwatches.count > presetColors.count {
            presetSwatches.removeLast().removeFromSuperview()
        }
        while presetSwatches.count < presetColors.count {
            let index = presetSwatches.count
            let swatch = makeSwatch(kind: .preset, index: index)
            swatch.onSelect = { [weak self] in self?.selectPreset(at: index) }
            addSubview(swatch)
            presetSwatches.append(swatch)
        }
        while shadeSwatches.count < shadeColors.count {
            let index = shadeSwatches.count
            let swatch = makeSwatch(kind: .shade, index: index)
            swatch.onSelect = { [weak self] in self?.selectShade(at: index) }
            shadesScrollView.addSubview(swatch)
            shadeSwatches.append(swatch)
        }
        accessibilityElements = presetSwatches.map { $0 as Any } + [shadesScrollView]
        shadesScrollView.accessibilityElements = shadeSwatches.map { $0 as Any }
        bringSubviewToFront(hintLabel)
    }

    private func makeSwatch(kind: ReaderColorPalette.SwatchKind, index: Int) -> ReaderColorSwatchView {
        let swatch = ReaderColorSwatchView()
        switch kind {
        case .preset:
            swatch.accessibilityIdentifier = "reader.colorPicker.preset.\(index)"
            swatch.accessibilityLabel = "预置颜色 \(index + 1)"
        case .shade:
            swatch.accessibilityIdentifier = "reader.colorPicker.shade.\(index)"
            swatch.accessibilityLabel = "色阶 \(index + 1)"
        }
        swatch.onShowHint = { [weak self, weak swatch] in
            guard let swatch else { return }
            self?.showHint(for: swatch)
        }
        return swatch
    }

    private func updateSwatches() {
        for (index, swatch) in presetSwatches.enumerated() {
            let argb = presetColors[index]
            swatch.configure(
                color: Self.uiColor(from: argb), argb: argb,
                selected: selectedPreset == index, kind: .preset)
        }
        for (index, swatch) in shadeSwatches.enumerated() {
            let argb = shadeColors[index]
            swatch.configure(
                color: Self.uiColor(from: argb), argb: argb,
                selected: selectedShade == index, kind: .shade)
        }
    }

    private func selectPreset(at index: Int) {
        guard presetColors.indices.contains(index) else { return }
        hideHint()
        let color = presetColors[index]
        selectedPreset = index
        // The original dialog compares ARGB, even after the matching shade was selected.
        if color == currentARGB {
            updateSwatches()
            onConfirm?(Self.uiColor(from: currentARGB))
            return
        }
        currentARGB = color
        selectedShade = nil
        shadeColors = ReaderColorPalette.getColorShades(color)
        updateSwatches()
        onColorChange?(Self.uiColor(from: color))
    }

    private func selectShade(at index: Int) {
        guard shadeColors.indices.contains(index) else { return }
        hideHint()
        if selectedShade == index {
            onConfirm?(Self.uiColor(from: currentARGB))
            return
        }
        currentARGB = shadeColors[index]
        selectedPreset = nil
        selectedShade = index
        // Do not derive a new twelve-color array from a shade on its first tap.
        updateSwatches()
        onColorChange?(Self.uiColor(from: currentARGB))
    }

    private func fittingWidth(_ proposed: CGFloat) -> CGFloat {
        let fallback = bounds.width.isFinite ? bounds.width : Self.minimumContentWidth
        let width = proposed.isFinite && proposed < .greatestFiniteMagnitude ? proposed : fallback
        return max(Self.minimumContentWidth, width)
    }

    private func layoutContent(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let innerWidth = width - 2 * Metrics.inset
        let requestedColumns = floor(
            (innerWidth + Metrics.horizontalSpacing) / (Metrics.columnWidth + Metrics.horizontalSpacing))
        let columns = max(1, Int(min(CGFloat(presetColors.count), requestedColumns)))
        let rows = (presetColors.count + columns - 1) / columns
        // GridView AUTO_FIT + STRETCH_SPACING_UNIFORM; children are 50pt wide
        // and start-aligned within their original 58pt columns.
        let remainder =
            innerWidth - CGFloat(columns) * Metrics.columnWidth
            - CGFloat(columns - 1) * Metrics.horizontalSpacing
        let spacing = Metrics.horizontalSpacing + remainder / CGFloat(columns > 1 ? columns + 1 : 1)
        let gridHeight = CGFloat(rows) * Metrics.itemSize + CGFloat(max(0, rows - 1)) * Metrics.rowSpacing
        let dividerY = Metrics.inset + gridHeight + Metrics.dividerMargin
        let shadesY = dividerY + Metrics.dividerHeight + Metrics.dividerMargin
        let height = shadesY + Metrics.itemSize + Metrics.inset
        guard applyFrames else { return height }

        let direction = effectiveUserInterfaceLayoutDirection
        let rtl = direction == .rightToLeft
        for (index, swatch) in presetSwatches.enumerated() {
            let leading = Metrics.inset + spacing + CGFloat(index % columns) * (Metrics.columnWidth + spacing)
            swatch.frame = CGRect(
                x: rtl ? width - leading - Metrics.itemSize : leading,
                y: Metrics.inset + CGFloat(index / columns) * (Metrics.itemSize + Metrics.rowSpacing),
                width: Metrics.itemSize, height: Metrics.itemSize)
        }
        divider.frame = CGRect(
            x: Metrics.inset, y: dividerY, width: innerWidth, height: Metrics.dividerHeight)
        shadesScrollView.frame = CGRect(
            x: Metrics.inset, y: shadesY, width: innerWidth, height: Metrics.itemSize)
        let shadeStride = Metrics.itemSize + 2 * Metrics.shadePadding
        let shadeWidth = 2 * Metrics.shadeMargin + CGFloat(shadeSwatches.count) * shadeStride
        let contentWidth = max(innerWidth, shadeWidth)
        for (index, swatch) in shadeSwatches.enumerated() {
            let leading = Metrics.shadeMargin + Metrics.shadePadding + CGFloat(index) * shadeStride
            swatch.frame = CGRect(
                x: rtl ? contentWidth - leading - Metrics.itemSize : leading,
                y: 0, width: Metrics.itemSize, height: Metrics.itemSize)
        }
        shadesScrollView.contentSize = CGSize(width: contentWidth, height: Metrics.itemSize)
        let maximumOffset = max(0, contentWidth - innerWidth)
        if shadeLayoutDirection != direction {
            shadesScrollView.contentOffset = CGPoint(x: rtl ? maximumOffset : 0, y: 0)
            shadeLayoutDirection = direction
        } else if !shadesScrollView.isDragging && !shadesScrollView.isDecelerating {
            let offset = min(maximumOffset, max(0, shadesScrollView.contentOffset.x))
            shadesScrollView.contentOffset = CGPoint(x: offset, y: 0)
        }
        return height
    }

    private func showHint(for swatch: ReaderColorSwatchView) {
        hideHintWorkItem?.cancel()
        hintedSwatch = swatch
        hintLabel.text = swatch.accessibilityValue
        hintLabel.isHidden = false
        bringSubviewToFront(hintLabel)
        layoutHint()
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: hintLabel.text)
        }
        let workItem = DispatchWorkItem { [weak self] in self?.hideHint() }
        hideHintWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: workItem)
    }

    private func hideHint() {
        hideHintWorkItem?.cancel()
        hideHintWorkItem = nil
        hintedSwatch = nil
        hintLabel.isHidden = true
    }

    private func layoutHint() {
        guard !hintLabel.isHidden, let swatch = hintedSwatch, bounds.width > 0 else { return }
        let availableWidth = max(1, bounds.width - 8)
        let textSize = hintLabel.sizeThatFits(
            CGSize(width: max(1, availableWidth - 16), height: .greatestFiniteMagnitude))
        let width = min(availableWidth, ceil(textSize.width) + 16)
        let height = ceil(textSize.height) + 12
        let anchor = swatch.convert(swatch.bounds, to: self)
        let x = min(max(4, anchor.midX - width / 2), max(4, bounds.width - width - 4))
        let below = anchor.maxY + 6
        let y = below + height <= bounds.height ? below : max(0, anchor.minY - height - 6)
        hintLabel.frame = CGRect(x: x, y: y, width: width, height: height)
    }

    private static func uiColor(from argb: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((argb >> 16) & 0xFF) / 255,
            green: CGFloat((argb >> 8) & 0xFF) / 255,
            blue: CGFloat(argb & 0xFF) / 255,
            alpha: CGFloat(argb >> 24) / 255)
    }

    private static func argb(from color: UIColor, traits: UITraitCollection) -> UInt32 {
        let resolved = color.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha = resolved.cgColor.alpha
        if !resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha),
            let space = CGColorSpace(name: CGColorSpace.sRGB),
            let converted = resolved.cgColor.converted(to: space, intent: .defaultIntent, options: nil),
            let components = converted.components, components.count >= 3
        {
            red = components[0]
            green = components[1]
            blue = components[2]
            alpha = converted.alpha
        }
        func channel(_ value: CGFloat) -> UInt32 {
            guard value.isFinite else { return 0 }
            return UInt32((min(1, max(0, value)) * 255).rounded())
        }
        return (channel(alpha) << 24) | (channel(red) << 16) | (channel(green) << 8) | channel(blue)
    }
}

private final class ReaderColorShadeScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
