import UIKit
import shared

/// item_search_list.xml, SearchContentAdapter.kt and SearchResult.kt at Legado 5f5d31404.
final class ReaderContentSearchResultCell: UITableViewCell {
    static let reuseIdentifier = "ReaderContentSearchResultCell"

    private let resultLabel = AndroidExploreTextLabel()
    private let dividerView = UIView()
    private lazy var dividerHeight = dividerView.heightAnchor.constraint(equalToConstant: 1)
    private var displayedText: String?
    private var titleRange: NSRange?
    private var queryRange: NSRange?
    private var isCurrentChapter = false
    private var isActionable = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .default, reuseIdentifier: reuseIdentifier)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func configure(with result: ContentSearchResult, isCurrentChapter: Bool) {
        let hasQuery = !result.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let prefix = hasQuery ? result.chapterTitle + "\n" : ""
        let prefixLength = (prefix as NSString).length
        displayedText = prefix + result.matchText
        titleRange = hasQuery ? NSRange(location: 0, length: (result.chapterTitle as NSString).length) : nil
        queryRange = nil
        if hasQuery,
            let match = Self.matchRange(in: result.matchText, query: result.query)
        {
            queryRange = NSRange(location: prefixLength + match.location, length: match.length)
        }
        self.isCurrentChapter = hasQuery && isCurrentChapter
        isActionable = hasQuery
        applyAppearance()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func configureEmpty(message: String) {
        displayedText = message
        titleRange = nil
        queryRange = nil
        isCurrentChapter = false
        isActionable = false
        setSelected(false, animated: false)
        setHighlighted(false, animated: false)
        applyAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        displayedText = nil
        titleRange = nil
        queryRange = nil
        isCurrentChapter = false
        isActionable = false
        resultLabel.attributedText = nil
        resultLabel.text = nil
        setSelected(false, animated: false)
        setHighlighted(false, animated: false)
        applyAppearance()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyAppearance()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    override func accessibilityActivate() -> Bool {
        guard isActionable else { return false }
        return super.accessibilityActivate()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        if isCurrentChapter { accessibilityTraits.insert(.selected) }
    }

    private func setUpViews() {
        indentationLevel = 0
        separatorInset = .zero
        directionalLayoutMargins = .zero
        contentView.directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = false
        contentView.preservesSuperviewLayoutMargins = false
        selectedBackgroundView = UIView()
        isAccessibilityElement = true
        contentView.isAccessibilityElement = false

        resultLabel.numberOfLines = 0
        resultLabel.lineBreakMode = .byWordWrapping
        resultLabel.textAlignment = .natural
        // Reopen the bundled Android font on trait changes; UIKit must not substitute its face.
        resultLabel.adjustsFontForContentSizeCategory = false
        resultLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        resultLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        for view in [resultLabel, dividerView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            resultLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            resultLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            resultLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            resultLabel.bottomAnchor.constraint(equalTo: dividerView.topAnchor, constant: -12),
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerHeight,
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance), name: .androidReplicaThemeDidChange, object: nil)
        applyAppearance()
    }

    @objc private func applyAppearance() {
        let primary = AndroidReplicaTheme.primaryText.resolvedColor(with: traitCollection)
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: isCurrentChapter ? 700 : 400,
            compatibleWith: traitCollection)
        let isEInk = UserDefaults.standard.string(forKey: "theme_mode") == "E_INK"
        backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        contentView.backgroundColor = .clear
        selectedBackgroundView?.backgroundColor = AndroidReplicaTheme.activeIndicator
        dividerView.backgroundColor = AndroidReplicaTheme.divider.resolvedColor(with: traitCollection)
        resultLabel.font = font
        resultLabel.textColor = primary
        if let displayedText {
            let text = NSMutableAttributedString(
                string: displayedText,
                attributes: [.font: font, .foregroundColor: primary, .kern: 0]
            )
            for range in [titleRange, queryRange].compactMap({ $0 }) {
                if isEInk {
                    text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
                } else {
                    text.addAttribute(.foregroundColor, value: accent, range: range)
                }
            }
            resultLabel.attributedText = text
        } else {
            resultLabel.attributedText = nil
            resultLabel.text = nil
        }

        accessoryType = .none
        accessoryView = nil
        editingAccessoryType = .none
        editingAccessoryView = nil
        selectionStyle = isActionable ? .default : .none
        isUserInteractionEnabled = isActionable
        accessibilityLabel = displayedText
        accessibilityValue = isCurrentChapter ? L10n.Reader.chapterStateCurrent : nil
        accessibilityHint = nil
        accessibilityCustomActions = nil
        accessibilityTraits = isActionable ? .button : .staticText
        if isCurrentChapter { accessibilityTraits.insert(.selected) }
        updateDividerHeight()
    }

    private func updateDividerHeight() {
        // VerticalDivider -> ic_divider.xml: 1px, bg_divider_line
        // (day #8FE0E0E0, night #363636), with no horizontal inset.
        let scale = window?.screen.scale ?? traitCollection.displayScale
        dividerHeight.constant = 1 / max(scale, 1)
    }

    private static func matchRange(in text: String, query: String) -> NSRange? {
        let source = text as NSString
        guard !query.isEmpty else { return nil }
        // SearchResult.getHtmlCompat uses resultText.indexOf(query), independently of the jump offset.
        let match = source.range(of: query, options: .literal)
        return isValidUTF16Range(match, in: source) ? match : nil
    }

    private static func isValidUTF16Range(_ range: NSRange, in text: NSString) -> Bool {
        guard range.location != NSNotFound,
            range.location >= 0,
            range.length > 0,
            range.location <= text.length,
            range.length <= text.length - range.location
        else {
            return false
        }
        // A match may be within a composed emoji, but must not split a surrogate pair.
        for offset in [range.location, range.location + range.length] {
            if offset > 0, offset < text.length,
                (0xD800...0xDBFF).contains(text.character(at: offset - 1)),
                (0xDC00...0xDFFF).contains(text.character(at: offset))
            {
                return false
            }
        }
        return true
    }
}
