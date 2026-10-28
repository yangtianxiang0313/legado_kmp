import UIKit

/// activity_book_source.xml keeps the list between the search toolbar and selection bar.
@MainActor
enum SourceManagementPageLayout {
    static func install(
        in view: UIView, toolbarBackground: UIView, bottomBackground: UIView,
        toolbar: SourceManagementToolbarView, status: UILabel, table: UITableView,
        placeholder: UILabel, selectionBar: SourceManagementSelectionBar
    ) -> NSLayoutConstraint {
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 68
        table.sectionHeaderTopPadding = 0
        table.contentInsetAdjustmentBehavior = .never
        table.insetsContentViewsToSafeArea = false
        // VerticalDivider / ic_divider.xml draws a full-width 1px line, without a text inset.
        table.separatorInset = .zero
        table.separatorInsetReference = .fromCellEdges
        table.cellLayoutMarginsFollowReadableWidth = false
        table.layoutMargins = .zero
        table.keyboardDismissMode = .onDrag
        placeholder.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: view.traitCollection)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.isUserInteractionEnabled = false
        placeholder.accessibilityIdentifier = "sourceManagement.listState"
        for item in [toolbarBackground, bottomBackground, toolbar, status, table, placeholder, selectionBar] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        let statusHeight = status.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            statusHeight,
            toolbarBackground.topAnchor.constraint(equalTo: view.topAnchor),
            toolbarBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbarBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbarBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            bottomBackground.topAnchor.constraint(equalTo: selectionBar.topAnchor),
            bottomBackground.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBackground.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBackground.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            status.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.topAnchor.constraint(equalTo: status.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: selectionBar.topAnchor),
            selectionBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            placeholder.centerXAnchor.constraint(equalTo: table.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: table.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: table.leadingAnchor, constant: 24),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: table.trailingAnchor, constant: -24),
            placeholder.topAnchor.constraint(greaterThanOrEqualTo: table.topAnchor, constant: 8),
            placeholder.bottomAnchor.constraint(lessThanOrEqualTo: table.bottomAnchor, constant: -8),
        ])
        return statusHeight
    }
}

/// A delayed empty snapshot must not overwrite an initial load failure or a newer loading state.
struct SourceManagementListState {
    private var hasLoaded = false
    private var failure: String?

    mutating func didLoad() {
        hasLoaded = true
        failure = nil
    }

    mutating func didFail(_ message: String) { failure = message }

    func placeholder(deliveredCount: Int, hasSources: Bool, query: String) -> String? {
        guard deliveredCount == 0 else { return nil }
        if let failure, !hasSources { return failure }
        guard hasLoaded else { return L10n.SourceManagement.loading }
        // A submitted filter with no results is not an invitation to import another source.
        return hasSources || !query.isEmpty ? L10n.SourceManagement.noMatch : L10n.SourceManagement.empty
    }
}
