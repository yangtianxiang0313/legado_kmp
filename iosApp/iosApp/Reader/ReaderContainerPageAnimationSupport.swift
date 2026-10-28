import UIKit

enum ReaderPageAnimationOperationMenu {
    @MainActor
    static func make(
        selectedValue _: Int = -1,
        globalValue _: Int = 0,
        onClose: (() -> Void)? = nil,
        onSelect: @escaping (Int) -> Void
    ) -> ReaderBookPageAnimationDialogViewController {
        // Android's selector uses plain items, independent of the current/global value.
        ReaderBookPageAnimationDialogViewController(onClose: onClose, onSelect: onSelect)
    }

    static func title(for value: Int) -> String {
        switch value {
        case -1:
            return L10n.ReaderAppearance.pageAnimationDefault
        case 0:
            return L10n.ReaderAppearance.pageAnimationCover
        case 1:
            return L10n.ReaderAppearance.pageAnimationSlide
        case 2:
            return L10n.ReaderAppearance.pageAnimationSimulation
        case 3:
            return L10n.ReaderAppearance.pageAnimationScroll
        case 4:
            return L10n.ReaderAppearance.pageAnimationNone
        default:
            return L10n.ReaderAppearance.pageAnimationCover
        }
    }
}

extension ReaderContainerViewController {
    func currentReaderPageAnimationOverrideValue() -> Int? {
        guard let pageAnim = book?.config.pageAnim?.intValue, pageAnim >= 0 else { return nil }
        return Int(pageAnim)
    }

    func effectiveReaderPageAnimation() -> Int {
        if let pageAnim = currentReaderPageAnimationOverrideValue() {
            return pageAnim
        }
        return Int(runtimeConfig?.reader.pageAnimation ?? 0)
    }

    func readerPageAnimationTitle(for value: Int) -> String {
        ReaderPageAnimationOperationMenu.title(for: value)
    }

    func currentReaderPageAnimationText() -> String {
        guard let pageAnim = currentReaderPageAnimationOverrideValue() else {
            let fallback = readerPageAnimationTitle(for: Int(runtimeConfig?.reader.pageAnimation ?? 0))
            return "\(L10n.ReaderAppearance.pageAnimationDefault) · \(fallback)"
        }
        return readerPageAnimationTitle(for: pageAnim)
    }
}
