import UIKit

final class ReaderPageViewController: UIViewController {
    private let renderView = ReaderRenderView()
    private let pageLayout: ReaderPageLayout
    private let theme: ReaderThemeController
    private let chrome: ReaderChromeSnapshot
    private let bookURL: String
    private let highlightedBlockIndex: Int?
    private let selectionRange: NSRange?

    init(
        pageLayout: ReaderPageLayout,
        theme: ReaderThemeController,
        chrome: ReaderChromeSnapshot,
        bookURL: String,
        highlightedBlockIndex: Int?,
        selectionRange: NSRange?
    ) {
        self.pageLayout = pageLayout
        self.theme = theme
        self.chrome = chrome
        self.bookURL = bookURL
        self.highlightedBlockIndex = highlightedBlockIndex
        self.selectionRange = selectionRange
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = renderView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        renderView.bookURL = bookURL
        renderView.pageLayout = pageLayout
        renderView.theme = theme
        renderView.chrome = chrome
        renderView.highlightedBlockIndex = highlightedBlockIndex
        renderView.selectionRange = selectionRange
        renderView.isAccessibilityElement = false
        renderView.accessibilityLabel = nil
        renderView.accessibilityValue = nil
        renderView.accessibilityIdentifier = nil
    }
}
