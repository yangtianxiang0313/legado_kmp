import UIKit

/// BaseReadBookActivity.showPageAnimConfig -> selector at 5f5d314.
@MainActor
final class ReaderBookPageAnimationDialogViewController: ReaderBookChoiceDialogViewController {
    init(onClose: (() -> Void)? = nil, onSelect: @escaping (Int) -> Void) {
        let values = Array(-1...4)
        super.init(
            title: L10n.ReaderAppearance.pageAnimationTitle,
            choices: values.map {
                Choice(title: ReaderPageAnimationOperationMenu.title(for: $0), accessibilityValue: String($0))
            },
            identifierPrefix: "reader.bookPageAnimation",
            onClose: onClose,
            onSelect: { index in onSelect(values[index]) }
        )
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }
}
