import UIKit
import shared

// Only frozen UIKit values cross the worker boundary. UIFont/CTFont are immutable;
// no view, window, screen, trait provider, or CoreText layout object is retained here.
struct ReaderPaginationInput: @unchecked Sendable {
    // Kotlin DTO properties are val. Retain the published, read-only chapter graph
    // for this request; neither the producer nor this worker may mutate its Lists.
    // A deep copy on MainActor would itself walk the entire chapter before enqueueing.
    let layout: ReaderChapterLayout
    let bounds: CGRect
    let pageGeometry: ReaderPageGeometry
    let theme: ReaderThemeController

    @MainActor
    static func frozen(
        layout: ReaderChapterLayout,
        bounds: CGRect,
        theme: ReaderThemeController,
        traits: UITraitCollection
    ) -> ReaderPaginationInput {
        func resolved(_ color: UIColor) -> UIColor {
            UIColor(cgColor: color.resolvedColor(with: traits).cgColor)
        }
        var frozenTheme = theme
        frozenTheme.textColor = resolved(theme.textColor)
        frozenTheme.backgroundColor = resolved(theme.backgroundColor)
        frozenTheme.tipColor = resolved(theme.tipColor)
        frozenTheme.tipDividerColor = resolved(theme.tipDividerColor)
        frozenTheme.selectionColor = resolved(theme.selectionColor)
        return ReaderPaginationInput(
            layout: layout,
            bounds: bounds,
            pageGeometry: ReaderPageGeometry.estimated(bounds: bounds, theme: frozenTheme),
            theme: frozenTheme
        )
    }
}
