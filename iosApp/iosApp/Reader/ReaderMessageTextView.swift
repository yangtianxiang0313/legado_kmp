import UIKit

/// TextPage.format(): centered body text, line-spacing multiplier 1 and extra spacing 0.
final class ReaderMessageTextView: UITextView {
    var onEscape: (() -> Bool)?

    private struct ScrollAnchor {
        let characterIndex: Int
        let lineFraction: CGFloat

        static let start = ScrollAnchor(characterIndex: 0, lineFraction: 0)
    }

    private var pendingAnchor: ScrollAnchor? = .start
    private var needsMessageLayout = true
    private var lastViewportSize: CGSize = .zero
    private let retainedTextStorage: NSTextStorage

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        let container =
            textContainer ?? NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        let manager: NSLayoutManager
        if let existing = container.layoutManager {
            manager = existing
        } else {
            manager = NSLayoutManager()
            manager.addTextContainer(container)
        }
        if let existing = manager.textStorage {
            retainedTextStorage = existing
        } else {
            retainedTextStorage = NSTextStorage()
            retainedTextStorage.addLayoutManager(manager)
        }
        super.init(frame: frame, textContainer: container)

        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true
        isEditable = false
        isSelectable = false
        isScrollEnabled = false
        bounces = false
        alwaysBounceVertical = false
        showsHorizontalScrollIndicator = false
        scrollsToTop = false
        contentInsetAdjustmentBehavior = .never
        automaticallyAdjustsScrollIndicatorInsets = false
        contentInset = .zero
        textContainerInset = .zero
        self.textContainer.lineFragmentPadding = 0
        self.textContainer.widthTracksTextView = true
        self.textContainer.heightTracksTextView = false
        dataDetectorTypes = []
        adjustsFontForContentSizeCategory = false
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func setMessage(_ message: String, theme: ReaderThemeController) {
        pendingAnchor = .start
        isScrollEnabled = false
        font = theme.font
        textColor = theme.textColor
        attributedText = NSAttributedString(string: message, attributes: attributes(theme: theme))
        accessibilityLabel = message
        accessibilityValue = nil
        accessibilityHint = nil
        needsMessageLayout = true
        setContentOffset(.zero, animated: false)
        setNeedsLayout()
    }

    func clearMessage() {
        onEscape = nil
        accessibilityCustomActions = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        isScrollEnabled = false
        attributedText = NSAttributedString(string: "")
        pendingAnchor = .start
        needsMessageLayout = true
        setContentOffset(.zero, animated: false)
        setNeedsLayout()
    }

    func apply(theme: ReaderThemeController) {
        preserveAnchor()
        isScrollEnabled = false
        font = theme.font
        textColor = theme.textColor
        textStorage.setAttributes(attributes(theme: theme), range: NSRange(location: 0, length: textStorage.length))
        needsMessageLayout = true
        setNeedsLayout()
    }

    func setViewportFrame(_ frame: CGRect) {
        guard self.frame != frame else { return }
        if bounds.size != frame.size {
            preserveAnchor()
            needsMessageLayout = true
        }
        self.frame = frame
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard needsMessageLayout || lastViewportSize != bounds.size,
            bounds.width > 0, bounds.height > 0
        else { return }
        let anchor = pendingAnchor ?? .start
        pendingAnchor = nil
        needsMessageLayout = false
        lastViewportSize = bounds.size

        textContainerInset = .zero
        textContainer.size = CGSize(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        var textHeight = layoutManager.usedRect(for: textContainer).maxY
        if layoutManager.extraLineFragmentTextContainer === textContainer {
            textHeight = max(textHeight, layoutManager.extraLineFragmentRect.maxY)
        }
        textHeight = ceil(max(textHeight, 0))
        let padding = max((bounds.height - textHeight) / 2, 0)
        textContainerInset = UIEdgeInsets(top: padding, left: 0, bottom: padding, right: 0)
        contentSize = CGSize(width: bounds.width, height: max(textHeight, bounds.height))
        isScrollEnabled = textHeight > bounds.height
        restore(anchor)
    }

    override func accessibilityPerformEscape() -> Bool {
        onEscape?() ?? false
    }

    private func attributes(theme: ReaderThemeController) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1
        paragraph.lineSpacing = 0
        paragraph.paragraphSpacing = 0
        paragraph.paragraphSpacingBefore = 0
        var attributes: [NSAttributedString.Key: Any] = [
            .font: theme.font, .foregroundColor: theme.textColor, .paragraphStyle: paragraph,
            .kern: theme.letterSpacing * theme.font.pointSize,
            .underlineStyle: theme.underline ? NSUnderlineStyle.single.rawValue : 0,
        ]
        if theme.bodyStrokeWidth != 0 {
            attributes[.strokeWidth] = theme.bodyStrokeWidth
            attributes[.strokeColor] = theme.textColor
        }
        return attributes
    }

    private func preserveAnchor() {
        guard pendingAnchor == nil else { return }
        pendingAnchor = captureAnchor()
    }

    private func captureAnchor() -> ScrollAnchor {
        guard textStorage.length > 0, bounds.width > 0, bounds.height > 0,
            contentOffset.y > 0, isScrollEnabled
        else { return .start }
        layoutManager.ensureLayout(for: textContainer)
        guard layoutManager.numberOfGlyphs > 0 else { return .start }
        let y = max(contentOffset.y - textContainerInset.top, 0)
        let glyph = min(
            layoutManager.glyphIndex(for: CGPoint(x: 0, y: y), in: textContainer),
            layoutManager.numberOfGlyphs - 1
        )
        var glyphRange = NSRange()
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphRange)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let fraction = line.height > 0 ? min(max((y - line.minY) / line.height, 0), 1) : 0
        return ScrollAnchor(characterIndex: characterRange.location, lineFraction: fraction)
    }

    private func restore(_ anchor: ScrollAnchor) {
        guard isScrollEnabled, textStorage.length > 0, layoutManager.numberOfGlyphs > 0 else {
            setContentOffset(.zero, animated: false)
            return
        }
        // Use a logical character and its position within the line, not a stale pixel offset.
        let characterIndex = min(anchor.characterIndex, textStorage.length - 1)
        let glyph = layoutManager.glyphIndexForCharacter(at: characterIndex)
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let offset = line.minY + line.height * anchor.lineFraction + textContainerInset.top
        let maximum = max(contentSize.height - bounds.height, 0)
        setContentOffset(CGPoint(x: 0, y: min(max(offset, 0), maximum)), animated: false)
    }
}
