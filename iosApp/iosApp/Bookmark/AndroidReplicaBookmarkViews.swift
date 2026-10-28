import UIKit
import shared

/// TitleBar / AppCompat Toolbar slots, without a promoted export action.
final class AllBookmarkToolbarView: NavigationToolbarView {
    static let title = NSLocalizedString("all_bookmark.android.title", value: "所有书签", comment: "Legado all_bookmark")
    let backButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        backButton.setImage(ReaderMenuAndroidIcon.back.image(), for: .normal)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        backButton.accessibilityLabel = L10n.Reader.backAction
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        moreButton.accessibilityLabel = L10n.Bookshelf.moreActions
        moreButton.accessibilityIdentifier = "all_bookmark_more_button"
        for button in [backButton, moreButton] {
            button.configuration = nil
            button.automaticallyUpdatesConfiguration = false
            button.tintColor = AndroidReplicaTheme.toolbarText
            button.imageView?.contentMode = .center
            button.addInteraction(UIToolTipInteraction(defaultToolTip: button.accessibilityLabel ?? ""))
        }
        titleLabel.text = Self.title
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for item in [backButton, titleLabel, moreButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 56),
            backButton.heightAnchor.constraint(equalToConstant: 56),
            titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 40),
            moreButton.heightAnchor.constraint(equalToConstant: 48),
        ])
        applyFont()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func layoutSubviews() {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        moreButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
        super.layoutSubviews()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFont()
    }

    private func applyFont() {
        titleLabel.font = UIFontMetrics(forTextStyle: .headline).scaledFont(
            for: .systemFont(ofSize: 20, weight: .medium), maximumPointSize: 32, compatibleWith: traitCollection)
    }
}

/// item_bookmark.xml: 8dp outer padding, 4dp per single-line TextView.
final class AndroidReplicaAllBookmarkCell: UITableViewCell {
    static let reuseIdentifier = "AndroidReplicaAllBookmarkCell"
    private let chapterLabel = UILabel()
    private let bookTextLabel = UILabel()
    private let noteLabel = UILabel()
    private let textStack = UIStackView()
    private lazy var bookTextRow = paddedRow(for: bookTextLabel)
    private lazy var noteRow = paddedRow(for: noteLabel)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureViews()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(with bookmark: Bookmark) {
        chapterLabel.text = singleLineText(bookmark.chapterName)
        bookTextLabel.text = singleLineText(bookmark.bookText)
        noteLabel.text = singleLineText(bookmark.content)
        bookTextRow.isHidden = bookmark.bookText.isEmpty
        noteRow.isHidden = bookmark.content.isEmpty
        accessibilityLabel = [bookmark.chapterName, bookmark.bookText, bookmark.content]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for label in [chapterLabel, bookTextLabel, noteLabel] { label.text = nil }
        bookTextRow.isHidden = true
        noteRow.isHidden = true
        accessibilityLabel = nil
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
    }

    private func configureViews() {
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        accessoryType = .none
        editingAccessoryType = .none
        directionalLayoutMargins = .zero
        contentView.directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = false
        selectedBackgroundView = UIView()
        selectedBackgroundView?.backgroundColor = AndroidReplicaTheme.activeIndicator
        isAccessibilityElement = true
        accessibilityTraits = .button
        for label in [chapterLabel, bookTextLabel, noteLabel] {
            // AppCompat's default TextAppearance.Small uses secondary text.
            label.textColor = AndroidReplicaTheme.secondaryText
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = true
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        textStack.axis = .vertical
        textStack.spacing = 0
        for row in [paddedRow(for: chapterLabel), bookTextRow, noteRow] {
            textStack.addArrangedSubview(row)
        }
        textStack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(textStack)
        NSLayoutConstraint.activate([
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            textStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8),
            textStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            textStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
        ])
        applyFonts()
    }

    private func paddedRow(for label: UILabel) -> UIView {
        let row = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        let bottom = label.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -4)
        // A gone row receives UIStackView's required zero-height constraint.
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
        chapterLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14), compatibleWith: traitCollection)
        for label in [bookTextLabel, noteLabel] {
            label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: 12), compatibleWith: traitCollection)
        }
    }

    private func singleLineText(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "")
        // TextView still measures one line when chapterName is empty.
        return line.isEmpty ? " " : line
    }
}

/// BookmarkDecoration: accent 16sp, 16dp inset and a 32dp sticky header.
final class AndroidReplicaBookmarkSectionHeader: UIView {
    static let height: CGFloat = 32
    private let label = UILabel()

    init(title: String) {
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.background
        clipsToBounds = true
        label.text = title
        label.textColor = AndroidReplicaTheme.accent
        applyFont()
        label.numberOfLines = 1
        label.lineBreakMode = .byClipping
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = true
        label.accessibilityTraits = .header
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFont()
    }

    private func applyFont() {
        label.font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 16), compatibleWith: traitCollection)
    }
}
