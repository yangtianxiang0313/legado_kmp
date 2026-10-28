import CoreText
import UIKit

struct ReaderPageBuildState {
    let contentSize: CGSize
    var textFragments: [ReaderTextLayoutFragment] = []
    var attachmentFragments: [ReaderAttachmentLayoutFragment] = []
    var cursorY: CGFloat = 0
    var pendingBlockSpacing: CGFloat = 0
    var previewParts: [String] = []
    private var firstCharacterOffset: Int?
    private let bodyLineAdvance: CGFloat

    init(contentSize: CGSize, bodyLineAdvance: CGFloat = 0) {
        self.contentSize = contentSize
        self.bodyLineAdvance = bodyLineAdvance
    }

    var isEmpty: Bool {
        textFragments.isEmpty && attachmentFragments.isEmpty
    }

    func spacingBeforeContent(height: CGFloat) -> CGFloat {
        let spacing = max(pendingBlockSpacing, 0)
        guard isEmpty else { return spacing }
        return min(spacing, max(contentSize.height - cursorY - height, 0))
    }

    func remainingHeight(reservingContentHeight height: CGFloat) -> CGFloat {
        max(contentSize.height - cursorY - spacingBeforeContent(height: height), 0)
    }

    mutating func appendPendingBlockSpacing(before sourceLocation: Int, contentHeight: CGFloat) {
        let height = spacingBeforeContent(height: contentHeight)
        pendingBlockSpacing = 0
        guard height > 0 else { return }
        // Defer spacing until real content fits so it cannot create a page on its own.
        appendAttachment(
            sourceRange: NSRange(location: sourceLocation, length: 0),
            frame: CGRect(x: 0, y: cursorY, width: contentSize.width, height: height),
            contentMode: .scaleToFill,
            source: .spacer(height: height),
            previewText: nil
        )
    }

    mutating func appendText(
        _ attributed: NSAttributedString,
        sourceRange: NSRange,
        height: CGFloat,
        kind: ReaderTextBlockKind,
        blockIndex: Int,
        isContinuation: Bool,
        advance: CGFloat? = nil
    ) {
        if firstCharacterOffset == nil {
            firstCharacterOffset = sourceRange.location
        }
        textFragments.append(
            ReaderTextLayoutFragment(
                attributedText: attributed,
                sourceRange: sourceRange,
                frame: CGRect(x: 0, y: cursorY, width: contentSize.width, height: height),
                kind: kind,
                blockIndex: blockIndex,
                isContinuation: isContinuation
            )
        )
        cursorY += advance ?? height
        if previewParts.count < 3 {
            let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty == false {
                previewParts.append(text)
            }
        }
    }

    mutating func appendAttachment(
        sourceRange: NSRange,
        frame: CGRect,
        contentMode: UIView.ContentMode,
        source: ReaderAttachmentSource,
        previewText: String?
    ) {
        if firstCharacterOffset == nil {
            firstCharacterOffset = sourceRange.location
        }
        attachmentFragments.append(
            ReaderAttachmentLayoutFragment(
                sourceRange: sourceRange,
                frame: frame,
                contentMode: contentMode,
                source: source
            )
        )
        cursorY = max(cursorY, frame.maxY)
        if let previewText, previewParts.count < 3 {
            let text = previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty == false {
                previewParts.append(text)
            }
        }
    }

    func build(chapterTitle: String, bottomJustify: Bool = false) -> ReaderPageLayout {
        let fragments = bottomJustify ? bottomJustifiedFragments() : (textFragments, attachmentFragments)
        return ReaderPageLayout(
            textFragments: fragments.0,
            attachmentFragments: fragments.1,
            chapterTitle: chapterTitle,
            characterOffset: firstCharacterOffset ?? 0,
            previewText: previewParts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            contentSize: contentSize
        )
    }

    private func bottomJustifiedFragments() -> ([ReaderTextLayoutFragment], [ReaderAttachmentLayoutFragment]) {
        let original = (textFragments, attachmentFragments)
        var lines = textFragments.enumerated().map { (index: $0.offset, frame: $0.element.frame, isImage: false) }
        for (index, attachment) in attachmentFragments.enumerated() {
            if case .remoteImage = attachment.source {
                lines.append((index, attachment.frame, true))
            }
        }
        lines.sort { $0.frame.minY < $1.frame.minY }
        guard lines.count > 1, let lastLine = lines.last, !lastLine.isImage else { return original }
        let surplus = contentSize.height - lastLine.frame.maxY
        // TextPage.upLinesPosition considers the next body stride before aligning the last glyph box.
        guard surplus > 0, surplus - bodyLineAdvance < lastLine.frame.height else { return original }
        var texts = textFragments
        var attachments = attachmentFragments
        let denominator = CGFloat(lines.count - 1)
        for (position, line) in lines.enumerated() {
            let offset = surplus * CGFloat(position) / denominator
            if line.isImage {
                let item = attachments[line.index]
                attachments[line.index] = ReaderAttachmentLayoutFragment(
                    sourceRange: item.sourceRange, frame: item.frame.offsetBy(dx: 0, dy: offset),
                    contentMode: item.contentMode, source: item.source)
            } else {
                texts[line.index] = texts[line.index].offsetBy(dx: 0, dy: offset)
            }
        }
        return (texts, attachments)
    }
}

struct CoreTextMeasurementBackend {
    func measureHeight(_ attributedText: NSAttributedString, width: CGFloat) -> CGFloat {
        guard attributedText.length > 0 else { return 0 }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: attributedText.length),
            nil,
            CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            nil
        )
        return ceil(suggested.height)
    }

    func fittingLength(_ attributedText: NSAttributedString, width: CGFloat, height: CGFloat) -> Int {
        guard attributedText.length > 0 else { return 0 }
        let text = attributedText.string as NSString
        guard height >= 1 else {
            return NSMaxRange(text.rangeOfComposedCharacterSequence(at: 0))
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(width, 1), height: max(height, 1)), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: attributedText.length), path, nil)
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        if visibleRange.length > 0 {
            let visibleLength = min(visibleRange.length, attributedText.length)
            let lastCluster = text.rangeOfComposedCharacterSequence(at: visibleLength - 1)
            let completeLength = NSMaxRange(lastCluster) <= visibleLength ? visibleLength : lastCluster.location
            if completeLength > 0 {
                return completeLength
            }
        }
        return binarySearchFittingLength(attributedText, width: width, height: height)
    }

    private func binarySearchFittingLength(_ attributedText: NSAttributedString, width: CGFloat, height: CGFloat) -> Int {
        let text = attributedText.string as NSString
        var low = 1
        var high = attributedText.length
        var best = 0
        while low <= high {
            let mid = (low + high) / 2
            let cluster = text.rangeOfComposedCharacterSequence(at: mid - 1)
            let candidateLength = NSMaxRange(cluster)
            let candidate = attributedText.attributedSubstring(from: NSRange(location: 0, length: candidateLength))
            if measureHeight(candidate, width: width) <= height {
                best = candidateLength
                low = candidateLength + 1
            } else {
                high = cluster.location
            }
        }
        return best > 0 ? best : NSMaxRange(text.rangeOfComposedCharacterSequence(at: 0))
    }
}
