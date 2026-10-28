import UIKit
import shared

/// ChangeChapterTocAdapter.kt / item_chapter_list.xml at Legado 5f5d314.
@MainActor
final class ChangeChapterSourceTocCell: UITableViewCell {
    static let reuseIdentifier = "ChangeChapterSourceTocCell"

    private(set) var representedChapterIndex: Int?

    private let titleLabel = ReaderTocSingleLineLabel()
    private let tagLabel = ReaderTocSingleLineLabel()
    private let textStack = UIStackView()
    private let rowStack = UIStackView()
    private let checkSlot = UIView()
    private let checkImageView = UIImageView()
    private var isSuggested = false
    private var isVolume = false

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    func configure(chapter: BookChapter, isSuggested: Bool) {
        representedChapterIndex = Int(chapter.index)
        self.isSuggested = isSuggested
        isVolume = chapter.isVolume
        let tag = !chapter.isVolume && chapter.tag?.isEmpty == false ? chapter.tag : nil

        titleLabel.text = chapter.title
        tagLabel.text = tag
        tagLabel.isHidden = tag == nil
        checkImageView.isHidden = !isSuggested
        accessibilityIdentifier = "changeSource.chapterToc.chapterCell.\(chapter.index)"
        accessibilityLabel = [chapter.title, tag].compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = isSuggested ? "当前建议章节" : nil
        updateAccessibilityTraits()
        applyAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        representedChapterIndex = nil
        isSuggested = false
        isVolume = false
        titleLabel.text = nil
        tagLabel.text = nil
        tagLabel.isHidden = true
        checkImageView.isHidden = true
        setSelected(false, animated: false)
        setHighlighted(false, animated: false)
        accessibilityIdentifier = nil
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityCustomActions = nil
        updateAccessibilityTraits()
        applyAppearance()
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        // Suggested chapter identity is independent of transient table selection.
        updateAccessibilityTraits()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func configureLayout() {
        accessoryType = .none
        editingAccessoryType = .none
        selectionStyle = .default
        separatorInset = .zero
        directionalLayoutMargins = .zero
        contentView.directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = false
        selectedBackgroundView = UIView()
        isAccessibilityElement = true

        for label in [titleLabel, tagLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        tagLabel.isHidden = true
        textStack.axis = .vertical
        textStack.spacing = 0
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(tagLabel)

        checkImageView.image = ReaderTocAndroidIcon.check.image(size: 16)
        checkImageView.contentMode = .scaleAspectFit
        checkImageView.isHidden = true
        checkSlot.addSubview(checkImageView)
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 0
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(checkSlot)
        contentView.addSubview(rowStack)

        for view in [textStack, rowStack, checkSlot, checkImageView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
        }
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            // iv_checked is invisible, not gone, for non-suggested rows.
            checkSlot.widthAnchor.constraint(equalToConstant: 24),
            checkSlot.heightAnchor.constraint(equalToConstant: 24),
            checkImageView.centerXAnchor.constraint(equalTo: checkSlot.centerXAnchor),
            checkImageView.centerYAnchor.constraint(equalTo: checkSlot.centerYAnchor),
            checkImageView.widthAnchor.constraint(equalToConstant: 16),
            checkImageView.heightAnchor.constraint(equalToConstant: 16),
        ])
        updateAccessibilityTraits()
        applyAppearance()
    }

    private func updateAccessibilityTraits() {
        var traits: UIAccessibilityTraits = .button
        if isSuggested { traits.insert(.selected) }
        if isVolume { traits.insert(.header) }
        accessibilityTraits = traits
    }

    func refreshPalette() { applyAppearance() }

    private func applyAppearance() {
        let palette = ChangeSourcePalette(traits: traitCollection)
        backgroundColor = palette.background
        contentView.backgroundColor = isVolume ? palette.volumeBackground : .clear
        selectedBackgroundView?.backgroundColor = palette.selectionBackground
        titleLabel.textColor = isSuggested ? palette.accent : palette.primaryText
        titleLabel.highlightedTextColor = titleLabel.textColor
        tagLabel.textColor = palette.secondaryText
        tagLabel.highlightedTextColor = palette.secondaryText
        checkImageView.tintColor = palette.secondaryText
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
        tagLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
    }
}
