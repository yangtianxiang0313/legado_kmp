import UIKit

struct MangaChapterTitle {
    enum Edge: String, Hashable {
        case leading = "MangaChapterTitleLeading"
        case trailing = "MangaChapterTitleTrailing"
    }

    struct ID: Hashable {
        let position: Int
        let edge: Edge
    }

    let position: Int
    let edge: Edge
    let message: String
    var isVolume = false

    var id: ID { ID(position: position, edge: edge) }
}

@MainActor
final class MangaChapterTitleView: UICollectionReusableView {
    static let reuseIdentifier = "MangaChapterTitleView"
    static let normalHeight: CGFloat = 96

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityTraits = .header
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = .white
        label.textAlignment = .center
        label.numberOfLines = 0
        label.lineBreakMode = .byTruncatingTail
        label.isAccessibilityElement = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    func configure(_ title: MangaChapterTitle) {
        label.text = title.message
        accessibilityLabel = title.message
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.text = nil
        accessibilityLabel = nil
    }
}
