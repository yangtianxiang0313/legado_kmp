import CoreText
import UIKit

/// Synchronous, operation-local CoreText layout. Only UTF-16 ranges escape this call.
enum ReaderVisualLineRanges {
    /// `nil` means cancellation; an empty result leaves layout to the caller's fallback.
    /// The caller must not mutate the attributed string or its attribute values during layout.
    static func collect(
        for attributed: NSAttributedString,
        contentSize: CGSize,
        isCancelled: () -> Bool = { false }
    ) -> [NSRange]? {
        guard !isCancelled() else { return nil }
        guard attributed.length > 0 else { return [] }
        guard contentSize.width.isFinite else { return [] }

        return autoreleasepool {
            // Retain the original framesetter factory and paragraph-strategy behavior.
            let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
            let text = attributed.string as NSString
            let width = max(contentSize.width, 1)
            var result: [NSRange] = []
            var offset = 0

            while offset < attributed.length {
                guard !isCancelled() else { return nil }
                let height = batchHeight(for: attributed, at: offset, viewportHeight: contentSize.height)
                var accepted: Batch?

                // A later font, run delegate or paragraph spacing may exceed the estimate.
                // Retries are bounded at one source position; total text/line count is not.
                for scale in [CGFloat(1), 4, 16] {
                    guard !isCancelled() else { return nil }
                    let batch = readBatch(
                        framesetter: framesetter, text: text, offset: offset,
                        width: width, height: height * scale, isCancelled: isCancelled
                    )
                    switch batch {
                    case .cancelled:
                        return nil
                    case .lines:
                        accepted = batch
                    case .unusable:
                        continue
                    }
                    break
                }

                guard case let .lines(ranges, end)? = accepted else {
                    // Discard the prefix rather than publishing an apparently complete,
                    // truncated chapter. This exceptional recovery can retain all its lines.
                    return collectFullLayout(
                        framesetter: framesetter, text: text, width: width,
                        minimumHeight: height * 16, isCancelled: isCancelled
                    )
                }
                guard !isCancelled() else { return nil }
                result.append(contentsOf: ranges)
                offset = end
            }
            return isCancelled() ? nil : result
        }
    }

    private enum Batch {
        case lines([NSRange], end: Int)
        case unusable
        case cancelled
    }

    private static func readBatch(
        framesetter: CTFramesetter,
        text: NSString,
        offset: Int,
        width: CGFloat,
        height: CGFloat,
        isCancelled: () -> Bool
    ) -> Batch {
        guard !isCancelled() else { return .cancelled }
        guard height.isFinite, height > 0 else { return .unusable }

        // No CTFrame, its CFArray, or a CTLine survives this pool/helper invocation.
        return autoreleasepool {
            let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
            // Keep the *whole* attributed string as the backing store. A substring
            // would reset paragraph context (including first-line indentation/bidi).
            // The range includes the entire remainder, so a batch is not a fake EOF.
            let frame = CTFramesetterCreateFrame(
                framesetter, CFRange(location: offset, length: text.length - offset), path, nil
            )
            guard !isCancelled() else { return .cancelled }
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.location == offset, visible.length > 0,
                visible.length <= text.length - offset
            else { return .unusable }
            let visibleEnd = offset + visible.length
            let lines = CTFrameGetLines(frame)
            var ranges: [NSRange] = []
            ranges.reserveCapacity(CFArrayGetCount(lines))
            var end = offset

            for index in 0..<CFArrayGetCount(lines) {
                guard !isCancelled() else { return .cancelled }
                let line = Unmanaged<CTLine>.fromOpaque(CFArrayGetValueAtIndex(lines, index)).takeUnretainedValue()
                let range = CTLineGetStringRange(line)
                // CoreText may include a zero-length terminal line after a newline.
                guard range.length != 0 else { continue }
                guard range.location == end, range.length > 0,
                    range.length <= visibleEnd - end
                else { return .unusable }
                let next = end + range.length
                // Never repair a CoreText boundary by splitting/merging source characters.
                // Retry with more context/space instead, including an intact CRLF pair.
                guard isCharacterBoundary(next, in: text) else { return .unusable }
                ranges.append(NSRange(location: range.location, length: range.length))
                end = next
            }

            guard end == visibleEnd, end > offset else { return .unusable }
            return isCancelled() ? .cancelled : .lines(ranges, end: end)
        }
    }

    private static func batchHeight(
        for attributed: NSAttributedString,
        at offset: Int,
        viewportHeight: CGFloat
    ) -> CGFloat {
        // These numbers choose only the temporary frame height, never line breaks,
        // fonts, paragraph styles, or a maximum number of output lines.
        let font = attributed.attribute(.font, at: offset, effectiveRange: nil) as? UIFont
        var advance = font?.lineHeight ?? 20
        if let style = attributed.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle {
            if style.lineHeightMultiple > 0 { advance *= style.lineHeightMultiple }
            advance = max(advance, style.minimumLineHeight)
            if style.maximumLineHeight > 0 { advance = min(advance, style.maximumLineHeight) }
            advance += max(style.lineSpacing, 0)
        }
        if !advance.isFinite || advance <= 0 { advance = 20 }
        let viewport = viewportHeight.isFinite ? max(viewportHeight, 1) : 1
        return min(max(advance * 256, min(viewport, 4096)), 65_536)
    }

    private static func isCharacterBoundary(_ offset: Int, in text: NSString) -> Bool {
        guard offset > 0, offset < text.length else { return true }
        if text.character(at: offset - 1) == 0x000D, text.character(at: offset) == 0x000A {
            return false
        }
        return text.rangeOfComposedCharacterSequence(at: offset).location == offset
    }

    private static func collectFullLayout(
        framesetter: CTFramesetter,
        text: NSString,
        width: CGFloat,
        minimumHeight: CGFloat,
        isCancelled: () -> Bool
    ) -> [NSRange]? {
        guard !isCancelled() else { return nil }
        // Unconstrained *measurement* is exceptional; the actual CTFrame path
        // below always has a finite, measured height, never CGFLOAT_MAX/infinity.
        let suggested = autoreleasepool {
            CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter, CFRange(location: 0, length: text.length), nil,
                CGSize(width: width, height: .greatestFiniteMagnitude), nil
            )
        }
        guard !isCancelled() else { return nil }
        guard suggested.height.isFinite, suggested.height >= 0 else { return [] }
        var height = max(ceil(suggested.height), minimumHeight) + minimumHeight

        // Measurement and frame fitting can disagree at a baseline/leading boundary.
        // Rebuild at most three times, never spin at a non-advancing source offset.
        for _ in 0..<3 {
            guard !isCancelled() else { return nil }
            switch readBatch(
                framesetter: framesetter, text: text, offset: 0,
                width: width, height: height, isCancelled: isCancelled
            ) {
            case .cancelled:
                return nil
            case let .lines(ranges, end) where end == text.length:
                return isCancelled() ? nil : ranges
            case .lines, .unusable:
                break
            }
            height *= 2
        }
        // No complete usable line partition: preserve the legacy fallback contract,
        // not a partial success or a synthetic/approximate last line.
        return isCancelled() ? nil : []
    }
}
