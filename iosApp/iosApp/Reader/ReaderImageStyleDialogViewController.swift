import UIKit

/// ReadBookActivity.menu_image_style -> selector at 5f5d314.
@MainActor
final class ReaderImageStyleDialogViewController: ReaderBookChoiceDialogViewController {
    init(onClose: (() -> Void)? = nil, onSelect: @escaping (String) -> Void) {
        let values = ["DEFAULT", "FULL", "TEXT", "SINGLE"]
        super.init(
            title: L10n.Reader.imageStyleTitle,
            choices: values.map { Choice(title: $0, accessibilityValue: $0) },
            identifierPrefix: "reader.imageStyle",
            onClose: onClose,
            onSelect: { index in onSelect(values[index]) }
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }
}
