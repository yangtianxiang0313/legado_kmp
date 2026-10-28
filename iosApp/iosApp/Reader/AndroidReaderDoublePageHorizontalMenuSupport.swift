import Foundation

enum AndroidReaderDoublePageHorizontalMenuSupport {
    static func title(_ mode: ReaderDoubleHorizontalPageMode) -> String {
        switch mode {
        case .singlePage: return L10n.Reader.doublePageHorizontalSinglePage
        case .doublePage: return L10n.Reader.doublePageHorizontalDoublePage
        case .landscape: return L10n.Reader.doublePageHorizontalLandscape
        case .tabletOrLandscape: return L10n.Reader.doublePageHorizontalTabletOrLandscape
        }
    }

    static func detail(_ mode: ReaderDoubleHorizontalPageMode) -> String {
        switch mode {
        case .singlePage: return L10n.Reader.doublePageHorizontalSinglePageDetail
        case .doublePage: return L10n.Reader.doublePageHorizontalDoublePageDetail
        case .landscape: return L10n.Reader.doublePageHorizontalLandscapeDetail
        case .tabletOrLandscape: return L10n.Reader.doublePageHorizontalTabletOrLandscapeDetail
        }
    }

    static func image(_ mode: ReaderDoubleHorizontalPageMode) -> String {
        switch mode {
        case .singlePage: return "rectangle.portrait"
        case .doublePage: return "rectangle.split.2x1"
        case .landscape: return "rectangle"
        case .tabletOrLandscape: return "ipad.landscape"
        }
    }
}
