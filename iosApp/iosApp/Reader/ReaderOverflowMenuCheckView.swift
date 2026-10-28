import UIKit

/// AppCompat 1.7.1 original vectors, already bundled by the search-scope selector.
/// The 32pt canvas includes its original 18pt box and transparent check cutout.
final class ReaderOverflowMenuCheckView: UIImageView {
    let isChecked: Bool

    init(isChecked: Bool) {
        self.isChecked = isChecked
        let name = isChecked ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff"
        super.init(image: UIImage(named: name)?.withRenderingMode(.alwaysTemplate))
        contentMode = .scaleAspectFit
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
}
