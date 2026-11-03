enum RssArticlePresentationStyle: Int {
    case compact = 0
    case largeImage = 1
    case grid = 2

    init(articleStyle: Int32) {
        self = Self(rawValue: Int(articleStyle)) ?? .compact
    }

    var next: Self {
        switch self {
        case .compact: return .largeImage
        case .largeImage: return .grid
        case .grid: return .compact
        }
    }

    var title: String {
        switch self {
        case .compact: return L10n.RSS.articleLayoutCompact
        case .largeImage: return L10n.RSS.articleLayoutLargeImage
        case .grid: return L10n.RSS.articleLayoutGrid
        }
    }

    var symbolName: String {
        switch self {
        case .compact: return "list.bullet"
        case .largeImage: return "rectangle.topthird.inset.filled"
        case .grid: return "square.grid.2x2"
        }
    }
}
