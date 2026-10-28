import UIKit
import shared

/// Keeps the chapter/excerpt/note hierarchy of Android item_bookmark.xml, with PDF page validity alongside it.
@MainActor
final class PdfBookmarkCell: UITableViewCell {
    static let reuseIdentifier = "pdf.bookmarks.item"

    private let chapterLabel = UILabel()
    private let excerptLabel = UILabel()
    private let noteLabel = UILabel()
    private let locationLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        let stack = UIStackView(arrangedSubviews: [chapterLabel, excerptLabel, noteLabel, locationLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        for label in [chapterLabel, excerptLabel, noteLabel, locationLabel] {
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        chapterLabel.font = .preferredFont(forTextStyle: .subheadline)
        chapterLabel.numberOfLines = 0
        excerptLabel.font = .preferredFont(forTextStyle: .caption1)
        noteLabel.font = .preferredFont(forTextStyle: .caption1)
        locationLabel.font = .preferredFont(forTextStyle: .caption2)
        locationLabel.numberOfLines = 0
        isAccessibilityElement = true
        backgroundColor = AndroidReplicaTheme.background
        chapterLabel.textColor = AndroidReplicaTheme.primaryText
        for label in [excerptLabel, noteLabel, locationLabel] { label.textColor = AndroidReplicaTheme.secondaryText }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("Use init(style:reuseIdentifier:)") }

    func configure(bookmark: Bookmark, currentPage: Int, pageCount: Int, date: String) {
        let page = Int(bookmark.chapterIndex)
        let pageInRange = (0..<max(pageCount, 0)).contains(page)
        let valid = pageInRange && bookmark.chapterPos == 0
        let pageTitle = pageInRange ? "第 \(page + 1) 页" : "页码不可用（\(Int64(bookmark.chapterIndex) + 1)）"
        chapterLabel.text = bookmark.chapterName.isEmpty ? pageTitle : bookmark.chapterName
        excerptLabel.text = bookmark.bookText
        excerptLabel.isHidden = bookmark.bookText.isEmpty
        noteLabel.text = bookmark.content
        noteLabel.isHidden = bookmark.content.isEmpty
        let current = valid && page == currentPage
        locationLabel.text = [pageTitle, !valid ? "定位不可用" : nil, current ? "当前页" : nil, date].compactMap { $0 }.joined(
            separator: " · ")
        let lines = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? 0 : 3
        excerptLabel.numberOfLines = lines
        noteLabel.numberOfLines = lines
        accessoryType = current ? .checkmark : .none
        tintColor = AndroidReplicaTheme.accent
        selectionStyle = valid ? .default : .none
        accessibilityTraits = valid ? .button : .staticText
        if current { accessibilityTraits.insert(.selected) }
        accessibilityLabel = [chapterLabel.text, bookmark.bookText, bookmark.content]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        accessibilityValue = locationLabel.text
        accessibilityHint = valid ? nil : "此书签页码或定位与当前 PDF 不一致，仍可编辑或删除"
        accessibilityIdentifier = "pdf.bookmarks.item.\(bookmark.time)"
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        accessibilityCustomActions = nil
        accessoryType = .none
        for label in [chapterLabel, excerptLabel, noteLabel, locationLabel] { label.text = nil }
    }
}
