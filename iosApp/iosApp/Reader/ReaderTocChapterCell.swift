import UIKit
import shared

/// item_chapter_list.xml and ChapterListAdapter.kt at Legado 5f5d314.
final class ReaderTocChapterCell: UITableViewCell {
    static let reuseIdentifier = "ReaderTocChapterCell"

    private let titleLabel = ReaderTocSingleLineLabel()
    private let wordCountLabel = ReaderTocSingleLineLabel()
    private let tagLabel = ReaderTocSingleLineLabel()
    private let metadataStack = UIStackView()
    private let textStack = UIStackView()
    private let rowStack = UIStackView()
    private let lockSlot = UIView()
    private let lockImageView = UIImageView()
    private let statusSlot = UIView()
    private let statusImageView = UIImageView()
    private let dividerView = UIView()
    private lazy var lockWidth = lockSlot.widthAnchor.constraint(equalToConstant: 0)
    private lazy var dividerHeight = dividerView.heightAnchor.constraint(equalToConstant: 1)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func configure(
        item: ReaderChapterListItem, palette: ReaderTocPalette, showWordCount: Bool = true,
        onShowFullTitle: (() -> Bool)? = nil
    ) {
        let wordCount = showWordCount && !item.chapter.isVolume ? Self.metadata(item.chapter.wordCount) : nil
        let tag = item.chapter.isVolume ? nil : Self.metadata(item.chapter.tag)
        let isLocked = item.chapter.isVip && !item.chapter.isPay
        let isCached = item.chapter.isVolume || item.isCached

        backgroundColor = palette.background
        contentView.backgroundColor = item.chapter.isVolume ? palette.volumeBackground : .clear
        titleLabel.text = item.displayTitle
        titleLabel.textColor = item.isCurrent ? palette.accent : palette.primaryText
        wordCountLabel.textColor = palette.secondaryText
        tagLabel.textColor = palette.secondaryText
        wordCountLabel.text = wordCount
        tagLabel.text = tag
        wordCountLabel.isHidden = wordCount == nil
        tagLabel.isHidden = tag == nil
        metadataStack.isHidden = wordCountLabel.isHidden && tagLabel.isHidden

        lockWidth.constant = isLocked ? 24 : 0
        lockImageView.isHidden = !isLocked
        lockImageView.tintColor = palette.secondaryText
        statusImageView.tintColor = palette.secondaryText
        statusImageView.image =
            item.isCurrent
            ? ReaderTocAndroidIcon.check.image(size: 16)
            : (isCached ? nil : ReaderTocAndroidIcon.cloud.image(size: 16))
        dividerView.backgroundColor = palette.divider
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        selectedBackgroundView?.backgroundColor =
            isNight
            ? UIColor.white.withAlphaComponent(51 / 255)
            : UIColor.black.withAlphaComponent(31 / 255)

        // Keep the full strings and independent states even when labels truncate
        // or the check icon takes precedence over the cache icon.
        accessibilityLabel = [item.displayTitle, wordCount, tag]
            .compactMap { $0 }.joined(separator: ", ")
        accessibilityValue = [
            item.isCurrent
                ? L10n.Reader.chapterStateCurrent
                : NSLocalizedString(
                    "reader.toc.state_not_current", value: "非当前章节", comment: "TOC accessibility state"),
            isCached ? L10n.Reader.chapterStateCached : L10n.Reader.chapterStatePendingCache,
            isLocked
                ? NSLocalizedString(
                    "reader.toc.state_locked", value: "已锁定", comment: "TOC accessibility state")
                : NSLocalizedString(
                    "reader.toc.state_unlocked", value: "未锁定", comment: "TOC accessibility state"),
        ].joined(separator: ", ")
        var traits: UIAccessibilityTraits = [.button]
        if item.isCurrent { traits.insert(.selected) }
        if item.chapter.isVolume { traits.insert(.header) }
        accessibilityTraits = traits
        accessibilityCustomActions = onShowFullTitle.map { handler in
            [
                UIAccessibilityCustomAction(
                    name: NSLocalizedString(
                        "reader.toc.show_full_title", value: "显示完整标题", comment: "TOC long-press action"),
                    actionHandler: { _ in handler() })
            ]
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDividerHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFonts()
        updateDividerHeight()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for label in [titleLabel, wordCountLabel, tagLabel] { label.text = nil }
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityCustomActions = nil
        accessibilityTraits = .button
        lockWidth.constant = 0
        lockImageView.isHidden = true
        statusImageView.image = nil
    }

    private func setUpViews() {
        accessoryType = .none
        separatorInset = .zero
        directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = false
        selectedBackgroundView = UIView()
        isAccessibilityElement = true

        for label in [titleLabel, wordCountLabel, tagLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            // Sizes are scaled explicitly below; UIKit must not substitute the file-backed font.
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        updateFonts()
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordCountLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        tagLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordCountLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        metadataStack.axis = .horizontal
        metadataStack.alignment = .firstBaseline
        // item_chapter_list:45 is padding on the word count, including when no tag exists.
        wordCountLabel.endPadding = 18
        metadataStack.spacing = 0
        metadataStack.addArrangedSubview(wordCountLabel)
        metadataStack.addArrangedSubview(tagLabel)
        textStack.axis = .vertical
        textStack.spacing = 0
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(metadataStack)

        lockSlot.clipsToBounds = true
        lockImageView.image = ReaderTocAndroidIcon.lock.image(size: 16)
        lockImageView.contentMode = .scaleAspectFit
        statusImageView.contentMode = .scaleAspectFit
        lockSlot.addSubview(lockImageView)
        statusSlot.addSubview(statusImageView)
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 0
        rowStack.addArrangedSubview(lockSlot)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(statusSlot)
        contentView.addSubview(rowStack)
        contentView.addSubview(dividerView)

        for view in [rowStack, lockSlot, lockImageView, statusSlot, statusImageView, dividerView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
        }
        NSLayoutConstraint.activate([
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rowStack.bottomAnchor.constraint(equalTo: dividerView.topAnchor, constant: -12),
            lockWidth,
            lockSlot.heightAnchor.constraint(equalToConstant: 24),
            // XML paddingEnd=8 leaves a 16pt square at the start of the 24pt lock slot.
            lockImageView.leadingAnchor.constraint(equalTo: lockSlot.leadingAnchor),
            lockImageView.centerYAnchor.constraint(equalTo: lockSlot.centerYAnchor),
            lockImageView.widthAnchor.constraint(equalToConstant: 16),
            lockImageView.heightAnchor.constraint(equalToConstant: 16),
            statusSlot.widthAnchor.constraint(equalToConstant: 24),
            statusSlot.heightAnchor.constraint(equalToConstant: 24),
            statusImageView.centerXAnchor.constraint(equalTo: statusSlot.centerXAnchor),
            statusImageView.centerYAnchor.constraint(equalTo: statusSlot.centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 16),
            statusImageView.heightAnchor.constraint(equalToConstant: 16),
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerHeight,
        ])
        updateDividerHeight()
    }

    private func updateFonts() {
        // Unstyled AppCompat TextView -> Widget.TextView -> textAppearanceSmall (14sp).
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
        for label in [wordCountLabel, tagLabel] {
            label.font = ReaderAndroidDefaultFont.scaledFont(
                size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        }
    }

    private func updateDividerHeight() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        dividerHeight.constant = 1 / max(scale, 1)
    }

    private static func metadata(_ text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }
        return text
    }
}

/// Shared by the chapter and bookmark cells to preserve Android's single-line TextView box.
final class ReaderTocSingleLineLabel: UILabel {
    var endPadding: CGFloat = 0 {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override var font: UIFont! {
        didSet {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    override var text: String? {
        get { super.text }
        set {
            // SingleLineTransformationMethod:27-28; keep the source in cell accessibility.
            super.text = newValue?.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "\u{FEFF}")
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }

    private var fontPadding: UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
    }

    override var intrinsicContentSize: CGSize {
        measuredSize(super.intrinsicContentSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        return measuredSize(
            super.sizeThatFits(
                CGSize(
                    width: max(0, size.width - endPadding),
                    height: max(0, size.height - padding.top - padding.bottom))))
    }

    private func measuredSize(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        let scale = max(traitCollection.displayScale, 1)
        return CGSize(
            width: ceil((max(0, size.width) + endPadding) * scale) / scale,
            // Empty titles retain one line; round the complete includeFontPadding box up.
            height: ceil((max(font.lineHeight, size.height) + padding.top + padding.bottom) * scale) / scale)
    }

    override func drawText(in rect: CGRect) {
        var textRect = rect.inset(by: fontPadding)
        if effectiveUserInterfaceLayoutDirection == .rightToLeft { textRect.origin.x += endPadding }
        textRect.size.width = max(0, textRect.width - endPadding)
        super.drawText(in: textRect)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.displayScale != traitCollection.displayScale {
            invalidateIntrinsicContentSize()
            setNeedsDisplay()
        }
    }
}
