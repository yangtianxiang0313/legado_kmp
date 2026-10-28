import CoreText
import UIKit

enum ReaderChromeMetrics {
    static let labelInsets = UIEdgeInsets(top: 3, left: 4, bottom: 3, right: 6)

    static func rowHeight(font: UIFont, displayScale: CGFloat = 1) -> CGFloat {
        let textHeight: CGFloat
        if font == ReaderChromeNumberFont.font {
            textHeight = ReaderChromeNumberFont.lineHeight
        } else {
            let scale = displayScale.isFinite ? max(displayScale, 1) : 1
            let padding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
            textHeight = ceil((font.lineHeight + padding.top + padding.bottom) * scale) / scale
        }
        return textHeight + labelInsets.top + labelInsets.bottom
    }

    static func font(for tip: Int, readingFont: UIFont) -> UIFont {
        tip == 3 || tip == 8 ? ReaderChromeNumberFont.font : readingFont
    }

    static func rowHeight(
        tips: [Int], readingFont: UIFont, keepsLeftSlot: Bool = false, displayScale: CGFloat = 1
    ) -> CGFloat {
        tips.enumerated().compactMap { index, tip -> CGFloat? in
            guard (1...11).contains(tip) || (keepsLeftSlot && index == 0) else { return nil }
            return rowHeight(font: font(for: tip, readingFont: readingFont), displayScale: displayScale)
        }.max() ?? 0
    }
}

struct ReaderChromeSnapshot: Equatable {
    let title: String?
    let headerLeft: ReaderChromeItem?
    let headerCenter: ReaderChromeItem?
    let headerRight: ReaderChromeItem?
    let footerLeft: ReaderChromeItem?
    let footerCenter: ReaderChromeItem?
    let footerRight: ReaderChromeItem?

    var hasHeaderContent: Bool {
        [headerLeft, headerCenter, headerRight].contains { $0?.isEmpty == false }
    }

    var hasFooterContent: Bool {
        [footerLeft, footerCenter, footerRight].contains { $0?.isEmpty == false }
    }
}

struct ReaderChromeItem: Equatable {
    let text: String?
    let batteryLevel: Int?
    let usesBatteryFont: Bool
    let reservesSpace: Bool

    var hasVisibleContent: Bool {
        text?.isEmpty == false || batteryLevel != nil
    }

    var isEmpty: Bool {
        !reservesSpace && !hasVisibleContent
    }

    static func text(_ value: String?) -> ReaderChromeItem? {
        guard let value = value?.nilIfEmpty else { return nil }
        return ReaderChromeItem(text: value, batteryLevel: nil, usesBatteryFont: false, reservesSpace: false)
    }

    static func battery(level: Int?, text: String? = nil) -> ReaderChromeItem? {
        ReaderChromeItem(
            text: text?.nilIfEmpty, batteryLevel: level.map { min(max($0, 0), 100) },
            usesBatteryFont: true, reservesSpace: true)
    }

    static func emptySlot(usesBatteryFont: Bool = false) -> ReaderChromeItem {
        ReaderChromeItem(text: nil, batteryLevel: nil, usesBatteryFont: usesBatteryFont, reservesSpace: true)
    }
}

final class ReaderChromeLabel: UILabel {
    private var readingFont: UIFont = .systemFont(ofSize: 12)

    private var effectiveDisplayScale: CGFloat {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        return scale.isFinite ? max(scale, 1) : 1
    }

    private var textInsets: UIEdgeInsets {
        let insets = ReaderChromeMetrics.labelInsets
        guard chromeItem?.usesBatteryFont != true else { return insets }
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: effectiveDisplayScale)
        return UIEdgeInsets(
            top: insets.top + padding.top, left: insets.left,
            bottom: insets.bottom + padding.bottom, right: insets.right)
    }

    override var font: UIFont! {
        get { super.font }
        set {
            readingFont = newValue ?? .systemFont(ofSize: 12)
            updateDrawingFont()
        }
    }

    var chromeItem: ReaderChromeItem? {
        didSet {
            updateDrawingFont()
            text = displayText
            accessibilityLabel = accessibilityText
            isAccessibilityElement = accessibilityText?.isEmpty == false
            invalidateTextMetrics()
        }
    }

    private var displayText: String? {
        guard let chromeItem else { return nil }
        let value: String?
        if let batteryLevel = chromeItem.batteryLevel {
            value = [chromeItem.text, String(batteryLevel)].compactMap { $0?.nilIfEmpty }.joined(separator: "  ")
        } else {
            value = chromeItem.text
        }
        // Android SingleLineTransformationMethod preserves carriage returns as zero-width characters.
        return value?.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    private func updateDrawingFont() {
        super.font = chromeItem?.usesBatteryFont == true ? ReaderChromeNumberFont.font : readingFont
        invalidateTextMetrics()
    }

    private func invalidateTextMetrics() {
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
        superview?.setNeedsLayout()
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        invalidateTextMetrics()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            invalidateTextMetrics()
        }
    }

    private var accessibilityText: String? {
        guard let chromeItem else { return nil }
        if let batteryLevel = chromeItem.batteryLevel {
            return [chromeItem.text, "\(batteryLevel)%"].compactMap { $0?.nilIfEmpty }.joined(separator: " ")
        }
        return chromeItem.text
    }

    override var intrinsicContentSize: CGSize {
        let horizontalInsets = textInsets.left + textInsets.right
        let textWidth = ceil(((text ?? "") as NSString).size(withAttributes: [.font: font as Any]).width)
        return CGSize(
            width: textWidth + horizontalInsets,
            height: ReaderChromeMetrics.rowHeight(font: font, displayScale: effectiveDisplayScale))
    }

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insets = textInsets
        let textRect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        // UILabel passes this rect to drawText; include padding here so drawing removes it only once.
        return CGRect(
            x: textRect.minX - insets.left,
            y: textRect.minY - insets.top,
            width: textRect.width + insets.left + insets.right,
            height: textRect.height + insets.top + insets.bottom
        )
    }

    override func drawText(in rect: CGRect) {
        guard chromeItem?.usesBatteryFont == true else {
            super.drawText(in: rect.inset(by: textInsets))
            return
        }
        guard let value = displayText, let context = UIGraphicsGetCurrentContext() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font as Any,
            .foregroundColor: textColor.resolvedColor(with: traitCollection),
        ]
        let attributedText = NSAttributedString(string: value, attributes: attributes)
        let fullLine = CTLineCreateWithAttributedString(attributedText as CFAttributedString)
        let contentRect = bounds.inset(by: textInsets)
        let availableWidth = max(contentRect.width, 0)
        guard availableWidth > 0 else { return }
        let line: CTLine
        if CTLineGetTypographicBounds(fullLine, nil, nil, nil) > Double(availableWidth) {
            let token = NSAttributedString(string: "\u{2026}", attributes: attributes)
            line =
                CTLineCreateTruncatedLine(
                    fullLine, Double(availableWidth), .end, CTLineCreateWithAttributedString(token as CFAttributedString)) ?? fullLine
        } else {
            line = fullLine
        }
        let alignmentOffset = textAlignmentOffset(line: line, availableWidth: availableWidth)
        context.saveGState()
        context.clip(to: bounds)
        context.textMatrix = .identity
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        // TextView's included font padding uses the base face's top/bottom, not fallback run metrics.
        context.textPosition = CGPoint(
            x: contentRect.minX + alignmentOffset,
            y: bounds.height - textInsets.top - ReaderChromeNumberFont.baselineOffset)
        CTLineDraw(line, context)
        context.restoreGState()
        drawBattery(in: bounds, line: line, alignmentOffset: alignmentOffset)
    }

    private func textAlignmentOffset(line: CTLine, availableWidth: CGFloat) -> CGFloat {
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let spareWidth = max(availableWidth - textWidth, 0)
        switch textAlignment {
        case .center: return spareWidth / 2
        case .right: return spareWidth
        default: return 0
        }
    }

    private func drawBattery(in rect: CGRect, line: CTLine, alignmentOffset: CGFloat) {
        guard let chromeItem, let batteryLevel = chromeItem.batteryLevel else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font as Any]
        let digits = "\(batteryLevel)"
        let value = displayText ?? digits
        let digitIndex = (value as NSString).length - (digits as NSString).length
        let digitOffset = CTLineGetOffsetForStringIndex(line, digitIndex, nil)
        let displayScale = max(traitCollection.displayScale, 1)
        // BatteryView uses layout coordinates (without TextView's left padding) for the outline.
        let batteryRect = CGRect(
            x: rect.minX + alignmentOffset + floor(digitOffset * displayScale) / displayScale + 2,
            y: rect.minY + 2,
            width: floor((digits as NSString).size(withAttributes: attributes).width * displayScale) / displayScale + 4,
            height: max(rect.height - 4, 0)
        )
        let poleInset = floor(batteryRect.height * displayScale / 3) / displayScale
        let capRect = CGRect(
            x: batteryRect.maxX,
            y: batteryRect.minY + poleInset,
            width: 2,
            height: batteryRect.height - poleInset * 2
        )
        let path = UIBezierPath(rect: batteryRect)
        path.lineWidth = 1
        textColor.setStroke()
        path.stroke()
        textColor.setFill()
        UIBezierPath(rect: capRect).fill()
    }
}

final class ReaderTipRowView: UIView {
    let leftLabel: ReaderChromeLabel
    let centerLabel: ReaderChromeLabel
    let rightLabel: ReaderChromeLabel
    private let rightSlotMargin: CGFloat = 3

    init(left: ReaderChromeLabel, center: ReaderChromeLabel, right: ReaderChromeLabel) {
        leftLabel = left
        centerLabel = center
        rightLabel = right
        super.init(frame: .zero)
        for item in [leftLabel, centerLabel, rightLabel] {
            addSubview(item)
            item.lineBreakMode = .byTruncatingTail
            item.clipsToBounds = true
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        let height =
            [leftLabel, centerLabel, rightLabel]
            .filter { !$0.isHidden }
            .map { $0.intrinsicContentSize.height }
            .max() ?? 0
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let readableWidth = max(bounds.width, 0)
        let labels = [leftLabel, centerLabel, rightLabel]
        let widths = labels.map { $0.isHidden ? 0 : ceil($0.intrinsicContentSize.width) }
        let centerWidth = min(widths[1], readableWidth)
        let centerX = (readableWidth - centerWidth) / 2
        let centerHasContent = !centerLabel.isHidden && centerLabel.chromeItem?.hasVisibleContent == true
        let leftWidth: CGFloat
        let rightWidth: CGFloat
        if centerHasContent {
            // Keep the XML's geometric center, but constrain both neighbors to disjoint drawing rects.
            leftWidth = leftLabel.isHidden ? 0 : max(centerX - rightSlotMargin, 0)
            rightWidth = min(widths[2], max(readableWidth - centerX - centerWidth - rightSlotMargin, 0))
        } else {
            rightWidth = min(widths[2], readableWidth)
            let gap = leftLabel.isHidden || rightLabel.isHidden ? 0 : min(rightSlotMargin, readableWidth)
            leftWidth = leftLabel.isHidden ? 0 : max(readableWidth - rightWidth - gap, 0)
        }
        let frames = [
            CGRect(x: 0, y: 0, width: leftWidth, height: 0),
            CGRect(x: centerX, y: 0, width: centerWidth, height: 0),
            CGRect(x: readableWidth - rightWidth, y: 0, width: rightWidth, height: 0),
        ]
        for (label, frame) in zip(labels, frames) {
            let height = label.isHidden ? 0 : min(label.intrinsicContentSize.height, bounds.height)
            label.frame = CGRect(x: frame.minX, y: (bounds.height - height) / 2, width: frame.width, height: height)
        }
    }
}
