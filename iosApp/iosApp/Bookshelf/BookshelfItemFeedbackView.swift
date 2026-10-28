import UIKit

/// The bounded selectableItemBackground foreground used by both Android bookshelf item XMLs.
final class BookshelfItemFeedbackView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = UIColor { traits in
            UIColor(
                white: traits.userInterfaceStyle == .dark ? 1 : 0,
                alpha: traits.userInterfaceStyle == .dark ? 51.0 / 255 : 31.0 / 255)
        }
        isHidden = true
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
}
