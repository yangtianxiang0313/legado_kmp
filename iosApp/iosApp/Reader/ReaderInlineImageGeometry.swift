import CoreText
import UIKit

enum ReaderInlineImageGeometry {
    static func columnFrame(at index: Int, text: NSAttributedString, contentSize: CGSize, lineHeight: CGFloat) -> CGRect? {
        autoreleasepool {
            let frame = ReaderTextSelectionGeometry.makeFrame(for: text, size: CGSize(width: contentSize.width, height: lineHeight))
            guard let line = (CTFrameGetLines(frame) as? [CTLine])?.first else { return nil }
            var origin = CGPoint.zero
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &origin)
            let xOrigin = origin.x + CTFrameGetPath(frame).boundingBoxOfPath.minX
            var edges: [CGFloat] = []
            CTLineEnumerateCaretOffsets(line) { offset, character, _, _ in
                if character == index, offset.isFinite { edges.append(CGFloat(offset) + xOrigin) }
            }
            guard let left = edges.min(), let right = edges.max(), right > left else { return nil }
            return CGRect(x: left, y: 0, width: right - left, height: lineHeight)
        }
    }

    // Android ImageColumn keeps the character column's width, not its height constraint.
    static func drawingRect(imageSize: CGSize, in column: CGRect) -> CGRect? {
        guard imageSize.width.isFinite, imageSize.height.isFinite, imageSize.width > 0, imageSize.height > 0,
            column.minX.isFinite, column.midY.isFinite, column.width.isFinite, column.width > 0
        else { return nil }
        let height = column.width / imageSize.width * imageSize.height
        guard height.isFinite, height > 0 else { return nil }
        return CGRect(x: column.minX, y: column.midY - height / 2, width: column.width, height: height)
    }
}
