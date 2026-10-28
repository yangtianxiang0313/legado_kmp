import UIKit
import shared

internal final class AndroidExploreKindFlowView: UIView {
    private var buttons: [AndroidExploreKindButton] = []
    private var measuredWidth: CGFloat = 0
    private var cachedLayout:
        (
            width: CGFloat,
            pixelScale: CGFloat,
            isRightToLeft: Bool,
            result: AndroidExploreKindFlowLayout.Result
        )?

    override init(frame: CGRect) {
        super.init(frame: frame)
        measuredWidth = frame.width.isFinite ? max(0, frame.width) : 0
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: layout(width: measuredWidth).height)
    }

    func setKinds(_ kinds: [ExploreKind], onSelect: ((ExploreKind) -> Void)?) {
        for button in buttons {
            button.onSelect = nil
            button.removeFromSuperview()
        }
        buttons = kinds.map { kind in
            let button = AndroidExploreKindButton(kind: kind)
            if button.isEnabled, let onSelect {
                button.onSelect = { onSelect(kind) }
            }
            addSubview(button)
            button.updateFont()
            return button
        }
        accessibilityElements = buttons
        invalidateLayout()
    }

    func prepareLayout(width: CGFloat) {
        let width = width.isFinite ? max(0, width) : 0
        guard width != measuredWidth else { return }
        measuredWidth = width
        invalidateLayout()
    }

    func updateFonts() {
        for button in buttons { button.updateFont() }
        invalidateLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width.isFinite ? max(0, size.width) : measuredWidth
        return CGSize(width: width, height: layout(width: width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A transient zero frame must not discard the width supplied for cell fitting.
        guard bounds.width.isFinite, bounds.width > 0 else { return }
        prepareLayout(width: bounds.width)
        let result = layout(width: measuredWidth)
        for (button, frame) in zip(buttons, result.frames) {
            button.frame = frame
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFonts()
        }
        if previousTraitCollection?.layoutDirection != traitCollection.layoutDirection
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            invalidateLayout()
        }
    }

    private func invalidateLayout() {
        cachedLayout = nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func layout(width: CGFloat) -> AndroidExploreKindFlowLayout.Result {
        let isRightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let pixelScale = max(1, traitCollection.displayScale)
        if let cachedLayout,
            cachedLayout.width == width,
            cachedLayout.pixelScale == pixelScale,
            cachedLayout.isRightToLeft == isRightToLeft
        {
            return cachedLayout.result
        }
        let items = buttons.map {
            AndroidExploreKindFlowLayout.Item(naturalWidth: $0.intrinsicContentSize.width, style: $0.style)
        }
        let result = AndroidExploreKindFlowLayout().layout(
            width: width,
            items: items,
            pixelScale: pixelScale,
            isRightToLeft: isRightToLeft,
            measure: { [buttons] index, width in buttons[index].measurement(width: width) }
        )
        cachedLayout = (width, pixelScale, isRightToLeft, result)
        return result
    }
}

// Android 5f5d314: ExploreAdapter, item_find_book.xml, item_fillet_text.xml, FlexChildStyle.kt.
// Flexbox 3.0.0 uses the full measured parent width for basis percent, and unscaled shrink weights.
// https://github.com/google/flexbox-layout/blob/3.0.0/flexbox/src/main/java/com/google/android/flexbox/FlexboxHelper.java
internal struct AndroidExploreKindFlowLayout {
    static let padding: CGFloat = 3
    static let childMargin: CGFloat = 3
    static let divider: CGFloat = 8

    enum Alignment: Equatable {
        case auto
        case start
        case end
        case center
        case baseline
        case stretch

        init(_ value: String) {
            switch value {
            case "flex_start": self = .start
            case "flex_end": self = .end
            case "center": self = .center
            case "baseline": self = .baseline
            case "stretch": self = .stretch
            default: self = .auto
            }
        }
    }

    struct Style {
        var flexGrow: Float = 0
        var flexShrink: Float = 1
        var alignSelf: Alignment = .auto
        var flexBasisPercent: Float = -1
        var wrapBefore = false
    }

    struct Item {
        var naturalWidth: CGFloat
        var style: Style = .init()
    }

    struct Measurement {
        var height: CGFloat
        var firstBaseline: CGFloat
    }

    struct Result {
        var frames: [CGRect]
        var height: CGFloat
        var lines: [Range<Int>]
    }

    func layout(
        width: CGFloat,
        items: [Item],
        pixelScale: CGFloat = 1,
        isRightToLeft: Bool = false,
        measure: (Int, CGFloat) -> Measurement
    ) -> Result {
        var frames = [CGRect](repeating: .zero, count: items.count)
        guard width.isFinite, width > 0, !items.isEmpty else {
            return Result(frames: frames, height: 0, lines: [])
        }

        let pixelScale = pixelScale.isFinite && pixelScale > 0 ? pixelScale : 1
        let contentWidth = max(0, width - Self.padding * 2)
        let naturalLimit = max(0, contentWidth - Self.childMargin * 2)
        var widths = items.map { item -> CGFloat in
            let natural = min(nonnegative(item.naturalWidth), naturalLimit)
            let percent = item.style.flexBasisPercent
            guard percent.isFinite, percent >= 0 else { return natural }
            let basisPixels = Float(width * pixelScale) * percent
            return basisPixels.isFinite ? floor(CGFloat(basisPixels) + 0.5) / pixelScale : natural
        }
        let lines = collectLines(items: items, widths: widths, contentWidth: contentWidth)
        var y = Self.padding

        for line in lines {
            let decorations =
                CGFloat(line.count) * Self.childMargin * 2
                + CGFloat(line.count - 1) * Self.divider
            resolveWidths(
                &widths,
                items: items,
                line: line,
                target: max(0, contentWidth - decorations),
                pixelScale: pixelScale
            )

            // Main-axis changes can remove or introduce text lines; measure only final widths.
            let measurements = line.map { index -> Measurement in
                let measurement = measure(index, widths[index])
                let height = nonnegative(measurement.height)
                return Measurement(
                    height: height,
                    firstBaseline: min(height, nonnegative(measurement.firstBaseline))
                )
            }
            let baseline = measurements.map { $0.firstBaseline + Self.childMargin }.max() ?? 0
            var crossSize = measurements.map { $0.height + Self.childMargin * 2 }.max() ?? 0
            for (offset, index) in line.enumerated() where items[index].style.alignSelf == .baseline {
                let measurement = measurements[offset]
                crossSize = max(
                    crossSize,
                    baseline - measurement.firstBaseline + measurement.height + Self.childMargin
                )
            }

            var x = Self.padding
            for (offset, index) in line.enumerated() {
                let measurement = measurements[offset]
                let alignment = items[index].style.alignSelf
                let height = alignment == .stretch ? crossSize - Self.childMargin * 2 : measurement.height
                let top: CGFloat
                switch alignment {
                case .auto, .start, .stretch:
                    // The XML leaves alignItems unset; FlexboxLayout 3.0.0 defaults to FLEX_START.
                    top = Self.childMargin
                case .end:
                    top = crossSize - Self.childMargin - height
                case .center:
                    top = (crossSize - height) / 2
                case .baseline:
                    top = max(Self.childMargin, baseline - measurement.firstBaseline)
                }
                let leading = x + Self.childMargin
                frames[index] = CGRect(
                    x: isRightToLeft ? width - leading - widths[index] : leading,
                    y: y + top,
                    width: widths[index],
                    height: height
                )
                x += widths[index] + Self.childMargin * 2 + Self.divider
            }
            y += crossSize
            if line.upperBound < items.count { y += Self.divider }
        }
        return Result(frames: frames, height: ceil(y + Self.padding), lines: lines)
    }

    private func collectLines(items: [Item], widths: [CGFloat], contentWidth: CGFloat) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for index in items.indices {
            let occupied = widths[index] + Self.childMargin * 2
            if index > start,
                items[index].style.wrapBefore || used + Self.divider + occupied > contentWidth
            {
                lines.append(start..<index)
                start = index
                used = 0
            }
            if index > start { used += Self.divider }
            used += occupied
        }
        lines.append(start..<items.count)
        return lines
    }

    private func resolveWidths(
        _ widths: inout [CGFloat],
        items: [Item],
        line: Range<Int>,
        target: CGFloat,
        pixelScale: CGFloat
    ) {
        let used = line.reduce(CGFloat.zero) { $0 + widths[$1] }
        if used < target {
            let total = line.reduce(Float.zero) { $0 + positiveWeight(items[$1].style.flexGrow) }
            guard total > 0 else { return }
            let unitSpace = Float((target - used) * pixelScale) / total
            var roundError: Float = 0
            for index in line where positiveWeight(items[index].style.flexGrow) > 0 {
                let raw = Float(widths[index] * pixelScale) + unitSpace * positiveWeight(items[index].style.flexGrow)
                widths[index] = distributedWidth(
                    raw,
                    isLast: index == line.upperBound - 1,
                    pixelScale: pixelScale,
                    roundError: &roundError
                )
            }
        } else if used > target {
            var active = line.filter { positiveWeight(items[$0].style.flexShrink) > 0 }
            var current = used
            while current > target, !active.isEmpty {
                let total = active.reduce(Float.zero) { $0 + positiveWeight(items[$1].style.flexShrink) }
                let unitShrink = Float((current - target) * pixelScale) / total
                var roundError: Float = 0
                var frozen = Set<Int>()
                for index in active {
                    let raw =
                        Float(widths[index] * pixelScale) - unitShrink * positiveWeight(items[index].style.flexShrink)
                    let resolved = distributedWidth(
                        raw,
                        isLast: index == line.upperBound - 1,
                        pixelScale: pixelScale,
                        roundError: &roundError
                    )
                    widths[index] = max(0, resolved)
                    if resolved < 0 { frozen.insert(index) }
                }
                guard !frozen.isEmpty else { return }
                // A child frozen at zero cannot absorb more deficit; redistribute to the rest.
                active.removeAll { frozen.contains($0) }
                let updated = line.reduce(CGFloat.zero) { $0 + widths[$1] }
                guard updated < current else { return }
                current = updated
            }
        }
    }

    private func distributedWidth(
        _ rawPixels: Float,
        isLast: Bool,
        pixelScale: CGFloat,
        roundError: inout Float
    ) -> CGFloat {
        var pixels = rawPixels
        if isLast {
            pixels += roundError
            roundError = 0
        }
        var rounded = floor(CGFloat(pixels) + 0.5)
        guard rounded >= 0 else { return rounded / pixelScale }
        roundError += pixels - Float(rounded)
        if roundError > 1 {
            rounded += 1
            roundError -= 1
        } else if roundError < -1 {
            rounded -= 1
            roundError += 1
        }
        return rounded / pixelScale
    }

    private func nonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    private func positiveWeight(_ value: Float) -> Float {
        value.isFinite ? max(0, value) : 0
    }
}

extension AndroidExploreKindFlowLayout.Style {
    fileprivate init(sharedStyle: FlexChildStyle?) {
        self.init(
            flexGrow: sharedStyle?.flexGrow ?? 0,
            flexShrink: sharedStyle?.flexShrink ?? 1,
            alignSelf: .init(sharedStyle?.alignSelf ?? "auto"),
            flexBasisPercent: sharedStyle?.flexBasisPercent ?? -1,
            wrapBefore: sharedStyle?.wrapBefore ?? false
        )
    }
}

private final class AndroidExploreKindButton: UIButton {
    let style: AndroidExploreKindFlowLayout.Style
    var onSelect: (() -> Void)?

    private let horizontalPadding: CGFloat = 12
    private let verticalPadding: CGFloat = 4

    init(kind: ExploreKind) {
        style = .init(sharedStyle: kind.style)
        super.init(frame: .zero)
        setTitle(kind.title, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        setTitleColor(AndroidReplicaTheme.primaryText, for: .disabled)
        titleLabel?.textAlignment = .center
        titleLabel?.lineBreakMode = .byTruncatingTail
        titleLabel?.adjustsFontSizeToFitWidth = false
        layer.cornerRadius = 16
        clipsToBounds = true
        isEnabled = kind.url?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        isUserInteractionEnabled = isEnabled
        isAccessibilityElement = true
        accessibilityIdentifier = "discovery.kind"
        accessibilityLabel = kind.title
        accessibilityTraits = isEnabled ? .button : .staticText
        addTarget(self, action: #selector(selectKind), for: .touchUpInside)
        updateFont()
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override var intrinsicContentSize: CGSize {
        let width = naturalWidth
        return CGSize(width: width, height: measurement(width: width).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let limit = size.width.isFinite ? max(0, size.width) : naturalWidth
        let width = min(limit, naturalWidth)
        return CGSize(width: width, height: measurement(width: width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let text = textGeometry(width: bounds.width)
        let padding = fontPadding
        titleLabel?.frame = CGRect(
            x: text.inset,
            y: max(verticalPadding, (bounds.height - text.height) / 2) + padding.top,
            width: max(0, bounds.width - text.inset * 2),
            height: max(0, text.height - padding.top - padding.bottom)
        )
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, onSelect != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func updateFont() {
        // item_fillet_text keeps maxLines=1 at every font scale; AX retains the full title.
        titleLabel?.numberOfLines = 1
        titleLabel?.font = AndroidExploreTextMetrics.font(compatibleWith: traitCollection)
        titleLabel?.adjustsFontForContentSizeCategory = false
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func measurement(width: CGFloat) -> AndroidExploreKindFlowLayout.Measurement {
        let text = textGeometry(width: width)
        let font = titleLabel?.font ?? .systemFont(ofSize: 14)
        let firstBaseline =
            verticalPadding + fontPadding.top + (ceil(font.lineHeight) - font.lineHeight) / 2 + font.ascender
        return .init(height: text.height + verticalPadding * 2, firstBaseline: firstBaseline)
    }

    private var fontPadding: UIEdgeInsets {
        AndroidExploreTextMetrics.padding(
            font: titleLabel?.font ?? .systemFont(ofSize: 14), scale: traitCollection.displayScale)
    }

    private var naturalWidth: CGFloat {
        let size =
            titleLabel?.sizeThatFits(
                CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            ) ?? .zero
        return ceil(size.width) + horizontalPadding * 2
    }

    private func textGeometry(width: CGFloat) -> (inset: CGFloat, height: CGFloat) {
        guard let titleLabel else { return (0, 0) }
        let width = width.isFinite ? max(0, width) : naturalWidth
        let padding = fontPadding
        let extraHeight = padding.top + padding.bottom
        guard width > 0 else { return (0, ceil(titleLabel.font.lineHeight) + extraHeight) }
        let inset = min(horizontalPadding, width / 2)
        let size = titleLabel.sizeThatFits(
            CGSize(width: max(1, width - inset * 2), height: CGFloat.greatestFiniteMagnitude)
        )
        return (inset, ceil(max(size.height, titleLabel.font.lineHeight)) + extraHeight)
    }

    private func updateBackground() {
        backgroundColor = isHighlighted ? ExploreAndroidGraphics.kindPressedBackground : ExploreAndroidGraphics.kindBackground
    }

    @objc private func selectKind() {
        guard isEnabled else { return }
        onSelect?()
    }
}
