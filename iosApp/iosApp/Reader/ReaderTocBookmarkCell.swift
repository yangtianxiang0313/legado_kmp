import UIKit
import shared

/// TOC item_bookmark.xml and ui/book/toc/BookmarkAdapter.kt at Legado 5f5d314.
final class ReaderTocBookmarkCell: UITableViewCell {
    static let reuseIdentifier = "ReaderTocBookmarkCell"

    private let chapterLabel = ReaderTocSingleLineLabel()
    private let bookTextLabel = ReaderTocSingleLineLabel()
    private let noteLabel = ReaderTocSingleLineLabel()
    private let textStack = UIStackView()
    private let dividerView = UIView()
    private var bookTextRow: UIView!
    private var noteRow: UIView!
    private var dividerHeight: NSLayoutConstraint!
    private var canActivate: (() -> Bool)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureViews()
    }

    func configure(with bookmark: Bookmark, palette: ReaderTocPalette) {
        backgroundColor = palette.background
        contentView.backgroundColor = .clear
        chapterLabel.text = bookmark.chapterName
        bookTextLabel.text = bookmark.bookText
        noteLabel.text = bookmark.content
        bookTextRow.isHidden = bookmark.bookText.isEmpty
        noteRow.isHidden = bookmark.content.isEmpty

        // These TextViews have no explicit textColor. AppCompat Small resolves
        // textColorTertiary to secondary_text_default_material, for all three.
        for label in [chapterLabel, bookTextLabel, noteLabel] {
            label.textColor = palette.secondaryText
        }
        dividerView.backgroundColor = palette.divider
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        selectedBackgroundView?.backgroundColor =
            isNight
            ? UIColor.white.withAlphaComponent(51 / 255)
            : UIColor.black.withAlphaComponent(31 / 255)

        var spokenText = [bookmark.chapterName]
        if !bookmark.bookText.isEmpty { spokenText.append(bookmark.bookText) }
        if !bookmark.content.isEmpty { spokenText.append(bookmark.content) }
        accessibilityLabel = spokenText.joined(separator: ", ")
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = .button
    }

    func setCanActivate(_ canActivate: (() -> Bool)?) {
        self.canActivate = canActivate
    }

    override func accessibilityActivate() -> Bool {
        guard canActivate?() == true else { return false }
        return ReaderTableAccessibility.activate(self)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        canActivate = nil
        for label in [chapterLabel, bookTextLabel, noteLabel] {
            label.text = nil
        }
        bookTextRow.isHidden = true
        noteRow.isHidden = true
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityCustomActions = nil
        accessibilityTraits = .button
        accessoryType = .none
        editingAccessoryType = .none
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDividerHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
        updateDividerHeight()
    }

    private func configureViews() {
        accessoryType = .none
        editingAccessoryType = .none
        indentationLevel = 0
        separatorInset = .zero
        directionalLayoutMargins = .zero
        contentView.directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = false
        selectedBackgroundView = UIView()
        isAccessibilityElement = true
        accessibilityTraits = .button

        for label in [chapterLabel, bookTextLabel, noteLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            // Sizes are scaled explicitly below; UIKit must not substitute the file-backed font.
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        bookTextRow = paddedRow(for: bookTextLabel)
        noteRow = paddedRow(for: noteLabel)
        bookTextRow.isHidden = true
        noteRow.isHidden = true
        textStack.axis = .vertical
        textStack.spacing = 0
        textStack.addArrangedSubview(paddedRow(for: chapterLabel))
        textStack.addArrangedSubview(bookTextRow)
        textStack.addArrangedSubview(noteRow)

        for item in [textStack, dividerView] {
            item.translatesAutoresizingMaskIntoConstraints = false
            item.isAccessibilityElement = false
            contentView.addSubview(item)
        }
        dividerHeight = dividerView.heightAnchor.constraint(equalToConstant: 1)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            textStack.bottomAnchor.constraint(equalTo: dividerView.topAnchor, constant: -8),
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerHeight,
        ])
        applyFonts()
        updateDividerHeight()
    }

    private func paddedRow(for label: UILabel) -> UIView {
        let row = UIView()
        row.isAccessibilityElement = false
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        let bottom = label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4)
        // UIStackView adds a required zero height when an optional row is gone.
        bottom.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: row.topAnchor, constant: 4),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            bottom,
        ])
        return row
    }

    private func applyFonts() {
        // item_bookmark inherits regular sans-serif; only the two optional rows override 14sp to 12sp.
        chapterLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        for label in [bookTextLabel, noteLabel] {
            label.font = ReaderAndroidDefaultFont.scaledFont(
                size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        }
    }

    private func updateDividerHeight() {
        // VerticalDivider uses ic_divider.xml, whose intrinsic height is 1px.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        dividerHeight?.constant = 1 / max(scale, 1)
    }
}
