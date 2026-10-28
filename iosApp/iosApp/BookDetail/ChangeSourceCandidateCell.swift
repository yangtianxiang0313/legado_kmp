import UIKit
import shared

/// Candidate content from item_change_source.xml / ChangeBookSourceAdapter.kt at 5f5d31404.
final class ChangeSourceCandidateCell: UITableViewCell {
    static let reuseIdentifier = "ChangeSourceCandidateCell"

    var onScore: ((Int) -> Void)? {
        didSet { updateRatingControls() }
    }

    private let ratingColumn = UIControl()
    private let ratingStack = UIStackView()
    private let goodButton = ChangeSourceRatingButton(type: .custom)
    private let badButton = ChangeSourceRatingButton(type: .custom)
    private let sourceLabel = ReaderTocSingleLineLabel()
    private let authorLabel = ReaderTocSingleLineLabel()
    private let latestLabel = ReaderTocSingleLineLabel()
    private let wordCountLabel = ChangeSourceMetadataLabel()
    private let responseTimeLabel = ChangeSourceMetadataLabel()
    private let headingStack = UIStackView()
    private let textStack = UIStackView()
    private let currentSourceSlot = UIView()
    private let currentSourceImageView = UIImageView()
    private let dividerView = UIView()
    private lazy var dividerHeight = dividerView.heightAnchor.constraint(equalToConstant: 1)
    private lazy var sourceLineHeight = sourceLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
    private lazy var latestLineHeight = latestLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
    private var isCurrentSource = false
    private var score = 0
    private var scoreInteractionEnabled = false
    private var candidateIdentity: [String]?
    private lazy var candidateAccessibilityElement: ChangeSourceCandidateAccessibilityElement = {
        let element = ChangeSourceCandidateAccessibilityElement(accessibilityContainer: self)
        element.accessibilityIdentifier = "changeSource.candidate"
        element.onActivate = { [weak self] in self?.activateCandidateForAccessibility() ?? false }
        return element
    }()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setUpViews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUpViews()
    }

    func configure(
        candidate: BookSourceChangeCandidate,
        isCurrent: Bool,
        score: Int = 0,
        loadWordCount: Bool = false,
        isScoreEnabled: Bool = true
    ) {
        let identity = [candidate.sourceUrl, candidate.bookUrl, candidate.displayName, candidate.author]
        if let candidateIdentity, candidateIdentity != identity { onScore = nil }
        candidateIdentity = identity
        self.score = min(1, max(-1, score))
        scoreInteractionEnabled = isScoreEnabled
        let source = Self.nonempty(candidate.sourceName)
        let author = Self.nonempty(candidate.author)
        let bookName = Self.nonempty(candidate.displayName)
        let latest = Self.nonempty(candidate.latestChapterTitle)
        let wordCount = loadWordCount ? Self.nonempty(candidate.chapterWordCountText) : nil
        let responseTime = loadWordCount && candidate.respondTime >= 0 ? "响应时间：\(candidate.respondTime) ms" : nil

        sourceLabel.text = source
        authorLabel.text = author
        authorLabel.isHidden = author == nil
        latestLabel.text = latest
        // tv_last remains visible even when no latest-chapter text has arrived.
        latestLabel.isHidden = false
        wordCountLabel.text = wordCount
        wordCountLabel.isHidden = wordCount == nil
        responseTimeLabel.text = responseTime
        responseTimeLabel.isHidden = responseTime == nil
        isCurrentSource = isCurrent
        currentSourceImageView.isHidden = !isCurrent

        accessibilityLabel = [
            source.map { "书源：\($0)" },
            author.map { "作者：\($0)" },
            bookName.map { "书名：\($0)" },
            latest.map { "最新章节：\($0)" },
            wordCount.map { "章节字数：\($0)" },
            responseTime,
        ].compactMap { $0 }.joined(separator: "，")
        accessibilityValue = isCurrent ? "当前书源" : "非当前书源"
        accessibilityHint = [
            Self.nonempty(candidate.sourceUrl).map { "书源地址：\($0)" },
            Self.nonempty(candidate.bookUrl).map { "书籍地址：\($0)" },
        ].compactMap { $0 }.joined(separator: "，")
        accessibilityTraits = isCurrent ? [.button, .selected] : .button
        applyAppearance()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        candidateIdentity = nil
        score = 0
        scoreInteractionEnabled = false
        onScore = nil
        isCurrentSource = false
        for label in [sourceLabel, authorLabel, latestLabel, wordCountLabel, responseTimeLabel] {
            label.text = nil
        }
        for label in [authorLabel, wordCountLabel, responseTimeLabel] {
            label.isHidden = true
        }
        currentSourceImageView.isHidden = true
        setSelected(false, animated: false)
        setHighlighted(false, animated: false)
        accessoryType = .none
        editingAccessoryType = .none
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityCustomActions = nil
        accessibilityTraits = .button
        updateRatingControls()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        candidateAccessibilityElement.accessibilityFrameInContainerSpace = CGRect(
            x: contentView.frame.minX + 30, y: contentView.frame.minY,
            width: max(0, contentView.bounds.width - 30), height: contentView.bounds.height)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        // The selected trait identifies the current source, not a transient row selection.
        accessibilityTraits = isCurrentSource ? [.button, .selected] : .button
        candidateAccessibilityElement.accessibilityTraits = accessibilityTraits
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDividerHeight()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    private func setUpViews() {
        accessoryType = .none
        editingAccessoryType = .none
        selectionStyle = .default
        separatorInset = .zero
        directionalLayoutMargins = .zero
        contentView.directionalLayoutMargins = .zero
        preservesSuperviewLayoutMargins = false
        selectedBackgroundView = UIView()
        isAccessibilityElement = false
        contentView.isAccessibilityElement = false
        accessibilityIdentifier = "changeSource.candidate"
        accessibilityTraits = .button

        ratingColumn.isAccessibilityElement = false
        ratingColumn.isExclusiveTouch = true
        ratingStack.axis = .vertical
        ratingStack.distribution = .fillEqually
        ratingStack.alignment = .fill
        ratingStack.spacing = 0
        ratingStack.isAccessibilityElement = false
        goodButton.setImage(ChangeSourcePraiseIcon.good, for: .normal)
        badButton.setImage(ChangeSourcePraiseIcon.bad, for: .normal)
        for (button, title, identifier) in [
            (goodButton, "赞", "changeSource.score.good"),
            (badButton, "踩", "changeSource.score.bad"),
        ] {
            button.isExclusiveTouch = true
            button.adjustsImageWhenHighlighted = false
            button.adjustsImageWhenDisabled = false
            button.imageView?.contentMode = .scaleAspectFit
            button.isAccessibilityElement = true
            button.accessibilityLabel = title
            button.accessibilityIdentifier = identifier
            button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
            ratingStack.addArrangedSubview(button)
        }
        goodButton.addTarget(self, action: #selector(rateGood), for: .touchUpInside)
        badButton.addTarget(self, action: #selector(rateBad), for: .touchUpInside)
        ratingColumn.addSubview(ratingStack)

        for label in [sourceLabel, authorLabel, latestLabel, wordCountLabel, responseTimeLabel] {
            label.adjustsFontForContentSizeCategory = false
            label.isAccessibilityElement = false
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        }
        for label in [sourceLabel, authorLabel, latestLabel] {
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
        }
        for label in [wordCountLabel, responseTimeLabel] {
            label.numberOfLines = 0
            label.lineBreakMode = .byWordWrapping
        }
        sourceLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        authorLabel.textAlignment = .right
        authorLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        authorLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        headingStack.axis = .horizontal
        headingStack.alignment = .top
        headingStack.spacing = 0
        headingStack.addArrangedSubview(sourceLabel)
        headingStack.addArrangedSubview(authorLabel)
        textStack.axis = .vertical
        textStack.alignment = .fill
        textStack.spacing = 0
        for view in [headingStack, latestLabel, wordCountLabel, responseTimeLabel] {
            textStack.addArrangedSubview(view)
        }

        currentSourceImageView.image = ReaderTocAndroidIcon.check.image()
        currentSourceImageView.contentMode = .scaleAspectFit
        currentSourceImageView.isHidden = true
        currentSourceSlot.addSubview(currentSourceImageView)
        for view in [ratingColumn, textStack, currentSourceSlot, dividerView] {
            contentView.addSubview(view)
        }
        for view in [
            ratingColumn, ratingStack, headingStack, textStack, currentSourceSlot, currentSourceImageView, dividerView,
        ] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.isAccessibilityElement = false
        }

        NSLayoutConstraint.activate([
            ratingColumn.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            ratingColumn.widthAnchor.constraint(equalToConstant: 30),
            ratingColumn.topAnchor.constraint(equalTo: contentView.topAnchor),
            ratingColumn.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            ratingStack.leadingAnchor.constraint(equalTo: ratingColumn.leadingAnchor),
            ratingStack.trailingAnchor.constraint(equalTo: ratingColumn.trailingAnchor),
            ratingStack.topAnchor.constraint(equalTo: ratingColumn.topAnchor, constant: 5),
            ratingStack.bottomAnchor.constraint(equalTo: ratingColumn.bottomAnchor, constant: -5),
            textStack.leadingAnchor.constraint(equalTo: ratingColumn.trailingAnchor),
            textStack.trailingAnchor.constraint(equalTo: currentSourceSlot.leadingAnchor),
            textStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
            authorLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160),
            currentSourceSlot.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            currentSourceSlot.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            currentSourceSlot.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 10),
            currentSourceSlot.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -10),
            currentSourceSlot.widthAnchor.constraint(equalToConstant: 40),
            currentSourceSlot.heightAnchor.constraint(equalToConstant: 40),
            currentSourceImageView.leadingAnchor.constraint(equalTo: currentSourceSlot.leadingAnchor, constant: 8),
            currentSourceImageView.trailingAnchor.constraint(equalTo: currentSourceSlot.trailingAnchor, constant: -8),
            currentSourceImageView.topAnchor.constraint(equalTo: currentSourceSlot.topAnchor, constant: 8),
            currentSourceImageView.bottomAnchor.constraint(equalTo: currentSourceSlot.bottomAnchor, constant: -8),
            dividerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            dividerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            dividerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            dividerHeight,
            sourceLineHeight,
            latestLineHeight,
        ])
        for label in [authorLabel, wordCountLabel, responseTimeLabel] {
            label.isHidden = true
        }
        applyAppearance()
    }

    private func applyAppearance() {
        let palette = ChangeSourcePalette(traits: traitCollection)
        backgroundColor = palette.background
        contentView.backgroundColor = .clear
        sourceLabel.textColor = palette.primaryText
        sourceLabel.highlightedTextColor = palette.primaryText
        currentSourceImageView.tintColor = palette.primaryText
        dividerView.backgroundColor = palette.divider
        for label in [authorLabel, latestLabel, wordCountLabel, responseTimeLabel] {
            label.textColor = palette.secondaryText
            label.highlightedTextColor = palette.secondaryText
        }
        // All five TextViews inherit AppCompat's 14sp textAppearanceSmall.
        for label in [sourceLabel, authorLabel, latestLabel, wordCountLabel, responseTimeLabel] {
            label.font = ReaderAndroidDefaultFont.scaledFont(
                size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        }
        sourceLineHeight.constant = sourceLabel.intrinsicContentSize.height
        latestLineHeight.constant = latestLabel.intrinsicContentSize.height
        selectedBackgroundView?.backgroundColor = palette.selectionBackground
        updateRatingControls()
        updateDividerHeight()
    }

    @objc private func rateGood() { rate(1) }
    @objc private func rateBad() { rate(-1) }

    private func rate(_ value: Int) {
        guard candidateIdentity != nil, scoreInteractionEnabled, let onScore else { return }
        let newScore = score == value ? 0 : value
        score = newScore
        updateRatingControls()
        // The callback may synchronously reconfigure or reuse this cell; do not mutate after it.
        onScore(newScore)
    }

    private func activateCandidateForAccessibility() -> Bool {
        guard candidateIdentity != nil, isUserInteractionEnabled else { return false }
        var ancestor = superview
        while let view = ancestor {
            if let tableView = view as? UITableView {
                guard tableView.isUserInteractionEnabled,
                    tableView.isEditing ? tableView.allowsSelectionDuringEditing : tableView.allowsSelection,
                    let indexPath = tableView.indexPath(for: self),
                    let didSelect = tableView.delegate?.tableView(_:didSelectRowAt:)
                else { return false }
                let target: IndexPath
                if let willSelect = tableView.delegate?.tableView(_:willSelectRowAt:) {
                    guard let approved = willSelect(tableView, indexPath) else { return false }
                    target = approved
                } else {
                    target = indexPath
                }
                tableView.selectRow(at: target, animated: false, scrollPosition: .none)
                didSelect(tableView, target)
                return true
            }
            ancestor = view.superview
        }
        return false
    }

    private func updateRatingControls() {
        goodButton.isHidden = score < 0
        badButton.isHidden = score > 0
        goodButton.tintColor = score > 0 ? Self.redActive : Self.redInactive
        badButton.tintColor = score < 0 ? Self.blueActive : Self.blueInactive
        let enabled = candidateIdentity != nil && scoreInteractionEnabled && onScore != nil
        goodButton.isEnabled = enabled
        badButton.isEnabled = enabled
        goodButton.accessibilityTraits = score > 0 ? [.button, .selected] : .button
        badButton.accessibilityTraits = score < 0 ? [.button, .selected] : .button
        if !enabled {
            goodButton.accessibilityTraits.insert(.notEnabled)
            badButton.accessibilityTraits.insert(.notEnabled)
        }
        goodButton.accessibilityValue = score > 0 ? "已赞" : "未赞"
        badButton.accessibilityValue = score < 0 ? "已踩" : "未踩"
        goodButton.accessibilityHint = enabled ? (score > 0 ? "点按取消赞" : "为此书源点赞") : "评分不可用"
        badButton.accessibilityHint = enabled ? (score < 0 ? "点按取消踩" : "为此书源点踩") : "评分不可用"
        let element = candidateAccessibilityElement
        element.accessibilityLabel = accessibilityLabel
        element.accessibilityValue = [
            accessibilityValue, score > 0 ? "已赞" : score < 0 ? "已踩" : "未评分",
        ].compactMap { $0 }.joined(separator: "，")
        element.accessibilityHint = accessibilityHint
        element.accessibilityTraits = isCurrentSource ? [.button, .selected] : .button
        guard candidateIdentity != nil else {
            accessibilityElements = []
            return
        }
        var elements: [Any] = []
        if !goodButton.isHidden { elements.append(goodButton) }
        if !badButton.isHidden { elements.append(badButton) }
        elements.append(element)
        accessibilityElements = elements
    }

    // Legado 5f5d314 colors_material_design.xml: A200 for active, 100 for unscored.
    private static let redActive = UIColor(red: 255 / 255, green: 82 / 255, blue: 82 / 255, alpha: 1)
    private static let redInactive = UIColor(red: 255 / 255, green: 205 / 255, blue: 210 / 255, alpha: 1)
    private static let blueActive = UIColor(red: 68 / 255, green: 138 / 255, blue: 255 / 255, alpha: 1)
    private static let blueInactive = UIColor(red: 187 / 255, green: 222 / 255, blue: 251 / 255, alpha: 1)

    private func updateDividerHeight() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        dividerHeight.constant = 1 / max(scale, 1)
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Check presence without rewriting display or accessibility content.
        return trimmed.isEmpty ? nil : text
    }
}

private final class ChangeSourceMetadataLabel: AndroidExploreTextLabel {
    override var intrinsicContentSize: CGSize { roundedSize(super.intrinsicContentSize) }

    override func sizeThatFits(_ size: CGSize) -> CGSize { roundedSize(super.sizeThatFits(size)) }

    private func roundedSize(_ size: CGSize) -> CGSize {
        // A subpixel-short stack row makes UILabel drop the last line after font padding is removed.
        let scale = max(1, traitCollection.displayScale)
        return CGSize(width: size.width, height: ceil(size.height * scale) / scale)
    }
}

private final class ChangeSourceRatingButton: UIButton {
    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        let side = max(0, min(20, min(contentRect.width - 10, contentRect.height - 10)))
        return CGRect(x: contentRect.midX - side / 2, y: contentRect.midY - side / 2, width: side, height: side)
    }
}

private final class ChangeSourceCandidateAccessibilityElement: UIAccessibilityElement {
    var onActivate: (() -> Bool)?
    override func accessibilityActivate() -> Bool { onActivate?() ?? false }
}

// Legado 5f5d314 drawable/ic_praise.xml (GPL-3.0), original 1024-viewport paths.
// The bad icon mirrors vertically, matching item_change_source.xml's rotationX=180.
private enum ChangeSourcePraiseIcon {
    static let good = image(flipped: false)
    static let bad = image(flipped: true)

    private static func image(flipped: Bool) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { renderer in
            let context = renderer.cgContext
            if flipped {
                context.translateBy(x: 0, y: 20)
                context.scaleBy(x: 1, y: -1)
            }
            context.scaleBy(x: 20 / 1024, y: 20 / 1024)
            context.setFillColor(UIColor.black.cgColor)
            context.addPath(path)
            context.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }

    private static let path: CGPath = {
        let path = CGMutablePath()
        func move(_ x: CGFloat, _ y: CGFloat) { path.move(to: CGPoint(x: x, y: y)) }
        func line(_ x: CGFloat, _ y: CGFloat) {
            let start = path.currentPoint
            path.addLine(to: CGPoint(x: start.x + x, y: start.y + y))
        }
        func curve(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ x: CGFloat, _ y: CGFloat) {
            let start = path.currentPoint
            path.addCurve(
                to: CGPoint(x: start.x + x, y: start.y + y),
                control1: CGPoint(x: start.x + x1, y: start.y + y1),
                control2: CGPoint(x: start.x + x2, y: start.y + y2))
        }

        move(939.4, 423.4)
        curve(-23, -37.3, -62.9, -60.8, -107, -63.2)
        curve(-2.8, -0.4, -5.5, -0.6, -8.3, -0.6)
        line(-152.2, -0.1)
        curve(6.6, -29, 10, -58.7, 10, -88.7)
        curve(0, -28.2, -3.2, -57.1, -9.6, -86)
        curve(-0.4, -2, -1.1, -4, -1.9, -5.9)
        curve(-15.8, -57.3, -67.4, -96.8, -127.3, -96.8)
        curve(-72.8, 0, -132.1, 59.3, -132.1, 132.1)
        curve(0, 3.3, 0.1, 6.7, 0.4, 10)
        curve(-2.2, 57.2, -32.1, 109.9, -80.3, 141.4)
        curve(-14.4, 9.4, -18.5, 28.8, -9.1, 43.2)
        curve(9.4, 14.4, 28.8, 18.5, 43.2, 9.1)
        curve(65.8, -42.9, 106.4, -115.3, 108.7, -193.7)
        curve(0, -1.3, 0, -2.7, -0.1, -4)
        curve(-0.2, -2, -0.3, -4, -0.3, -6)
        curve(0, -38.4, 31.2, -69.6, 69.6, -69.6)
        curve(32.6, 0, 60.5, 22.2, 67.8, 54)
        curve(0.4, 1.5, 0.8, 3, 1.4, 4.5)
        curve(4.7, 22.8, 7.1, 45.6, 7.1, 67.7)
        curve(0, 37.5, -6.2, 74.4, -18.5, 109.6)
        curve(-3.3, 9.5, -1.8, 20.1, 4, 28.3)
        curve(5.9, 8.2, 15.3, 13.1, 25.4, 13.2)
        line(193.2, 0.1)
        curve(1.4, 0.3, 2.9, 0.4, 4.3, 0.5)
        curve(24.1, 1, 45.9, 13.6, 58.6, 34.1)
        curve(7.8, 12.3, 11.4, 26.8, 10.4, 41.9)
        curve(-0.1, 0.9, -0.1, 1.9, -0.1, 2.9)
        curve(0, 0.9, 0, 1.7, 0.1, 2.5)
        curve(0, 0.3, 0, 0.7, -0.1, 1)
        curve(-0.1, 0.4, -0.2, 0.8, -0.3, 1.2)
        line(-75, 330.4)
        curve(-0.9, 1.3, -1.7, 2.6, -2.4, 4)
        curve(-5.9, 11.8, -14.7, 21.5, -25.3, 28.2)
        curve(-10.7, 6.8, -23.1, 10.6, -35.8, 11.1)
        curve(-0.9, -0.1, -513.8, -0.2, -513.8, -0.2)
        curve(-0.5, 0, -0.9, 0, -1.4, 0)
        curve(0, 0, -111, 0.2, -112.7, 0.5)
        curve(-1.9, 0, -3.4, -1.5, -3.4, -3.4)
        line(0.3, -416.3)
        curve(0, -1.9, 1.5, -3.4, 3, -3.5)
        line(1.2, 0.1)
        curve(1.2, 0.1, 2.7, 0.3, 3.5, 0.2)
        line(83.8, -0.2)
        line(0, 339.4)
        curve(0, 17.3, 14, 31.2, 31.2, 31.2)
        curve(17.2, 0, 31.2, -14, 31.2, -31.2)
        path.addLine(to: CGPoint(x: 281, y: 435.4))
        curve(0, -1.8, 0, -8.6, 0, -10.4)
        curve(0, -17.3, -14, -30.9, -31.2, -30.9)
        curve(-1.5, 0, -117.5, 0.3, -119.4, 0.3)
        curve(-36.3, 0, -65.9, 29.6, -65.9, 65.9)
        line(-0.3, 416.3)
        curve(0, 36.3, 29.6, 65.9, 65.9, 65.9)
        curve(2.5, 0, 111.4, -0.5, 111.4, -0.5)
        curve(0.5, 0, 0.9, 0, 1.4, 0)
        curve(0, 0, 511.5, 0.3, 512.5, 0.3)
        curve(25.5, 0, 50.3, -7.2, 71.6, -20.7)
        curve(19.6, -12.3, 35.8, -29.9, 46.8, -51)
        curve(3.7, -5.6, 6.4, -11.9, 8.3, -18.6)
        curve(0.1, -0.4, 0.2, -0.8, 0.3, -1.2)
        line(74.9, -330.3)
        curve(1.6, -6.2, 2.3, -12.6, 2, -19)
        path.addCurve(
            to: CGPoint(x: 939.4, y: 423.4),
            control1: CGPoint(x: 960.9, y: 473.4), control2: CGPoint(x: 953.9, y: 446.3))
        path.closeSubpath()

        move(450, 518.7)
        curve(-17.3, 0, -31.2, 14, -31.2, 31.2)
        line(0, 30.5)
        curve(0, 17.3, 14, 31.2, 31.2, 31.2)
        curve(17.3, 0, 31.2, -14, 31.2, -31.2)
        line(0, -30.5)
        path.addCurve(
            to: CGPoint(x: 450, y: 518.7),
            control1: CGPoint(x: 481.3, y: 532.6), control2: CGPoint(x: 467.3, y: 518.7))
        path.closeSubpath()

        move(693.8, 518.7)
        curve(-17.3, 0, -31.2, 14, -31.2, 31.2)
        line(0, 30.5)
        curve(0, 17.3, 14, 31.2, 31.2, 31.2)
        curve(17.3, 0, 31.2, -14, 31.2, -31.2)
        line(0, -30.5)
        path.addCurve(
            to: CGPoint(x: 693.8, y: 518.7),
            control1: CGPoint(x: 725, y: 532.6), control2: CGPoint(x: 711.1, y: 518.7))
        path.closeSubpath()

        move(648.9, 660.1)
        curve(-14.3, -9.4, -33.6, -5.4, -43.2, 8.8)
        curve(-0.1, 0.2, -13.6, 19.8, -34.2, 19.8)
        curve(-20, 0, -32.4, -18.1, -33.3, -19.4)
        curve(-9.2, -14.4, -28.3, -18.8, -42.8, -9.8)
        curve(-14.7, 9.1, -19.2, 28.4, -10.1, 43)
        curve(11.2, 18, 42, 48.6, 86.2, 48.6)
        curve(44, 0, 75.1, -30.3, 86.6, -48.2)
        path.addCurve(
            to: CGPoint(x: 648.9, y: 660.1),
            control1: CGPoint(x: 667.4, y: 688.5), control2: CGPoint(x: 663.2, y: 669.5))
        path.closeSubpath()
        return path
    }()
}
