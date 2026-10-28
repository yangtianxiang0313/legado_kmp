import UIKit

final class ReaderMenuTitleAdditionView: UIView {
    var onChapterSource: (() -> Void)?
    var onSource: (() -> Void)?

    private let chapterButton = ReaderMenuSummaryButton(type: .custom)
    private let urlButton = ReaderMenuSummaryButton(type: .custom)
    private let sourceButton = ReaderMenuSourceButton(type: .custom)
    private let chapterStack = UIStackView()
    private let sourceContainer = UIView()
    private let contentStack = UIStackView()
    private var chapterHeightConstraints: [NSLayoutConstraint] = []
    private var sourceWidthConstraint: NSLayoutConstraint?
    private var isLocal = false

    var sourceMenuAnchor: UIView? {
        guard !isLocal, ReaderMenuToolbarInteraction.isAvailable(sourceButton) else { return nil }
        return sourceButton
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTypography()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
    }

    override func layoutSubviews() {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // XML uses physical left/right constraints, but TextViews retain locale direction.
        for button in [chapterButton, urlButton, sourceButton] {
            button.semanticContentAttribute = isRTL ? .forceRightToLeft : .forceLeftToRight
        }
        for button in [chapterButton, urlButton] {
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.textAlignment = isRTL ? .right : .left
        }
        super.layoutSubviews()
    }

    func update(
        chapter: String,
        source: String,
        url: String?,
        isLocal: Bool,
        showsAddition: Bool
    ) {
        self.isLocal = isLocal
        let chapterURL = isLocal ? nil : url
        let hasChapter = !chapter.isEmpty || chapterURL != nil
        let sourceName = source.isEmpty ? L10n.Reader.sourceInfoTitle : source

        chapterButton.setTitle(Self.singleLine(chapter), for: .normal)
        chapterButton.accessibilityLabel = chapter
        chapterButton.isHidden = !hasChapter
        urlButton.setTitle(chapterURL.map(Self.singleLine), for: .normal)
        urlButton.accessibilityLabel = chapterURL
        urlButton.isHidden = isLocal || !hasChapter
        sourceButton.setTitle(sourceName, for: .normal)
        sourceButton.accessibilityLabel =
            sourceName == L10n.Reader.sourceInfoTitle
            ? sourceName
            : "\(L10n.Reader.sourceInfoTitle): \(sourceName)"
        sourceContainer.isHidden = isLocal || !hasChapter
        updateSourceWidth()
        let chapterTraits: UIAccessibilityTraits = isLocal ? .staticText : .button
        chapterButton.accessibilityTraits = chapterTraits
        urlButton.accessibilityTraits = chapterTraits
        accessibilityElements =
            [chapterButton, urlButton].filter { !$0.isHidden }
            + (sourceContainer.isHidden ? [] : [sourceButton])
        // Android pins the source slot to the URL row; it must not create its own row.
        isHidden = !showsAddition || !hasChapter
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func apply(
        background: UIColor,
        text: UIColor,
        sourceBackground: UIColor,
        sourceText: UIColor
    ) {
        backgroundColor = background
        chapterButton.setTitleColor(text, for: .normal)
        urlButton.setTitleColor(text, for: .normal)
        sourceButton.sourceBackgroundColor = sourceBackground
        sourceButton.setTitleColor(sourceText, for: .normal)
    }

    private func configureView() {
        isAccessibilityElement = false
        clipsToBounds = true
        updateTypography()

        for button in [chapterButton, urlButton, sourceButton] {
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.titleLabel?.adjustsFontSizeToFitWidth = false
            button.titleLabel?.lineBreakMode = .byClipping
            button.accessibilityTraits = .button
            button.clipsToBounds = true
        }

        for button in [chapterButton, urlButton] {
            button.contentHorizontalAlignment = .left
            // view_read_menu.xml:34-35/46-47 sets horizontal padding only.
            button.contentEdgeInsets = UIEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
            button.titleLabel?.textAlignment = .left
            button.titleLabel?.numberOfLines = 1
            // Android's non-editable singleLine TextView defaults to END ellipsis.
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let height = button.heightAnchor.constraint(equalToConstant: button.naturalLineHeight)
            height.priority = UILayoutPriority(999)
            height.isActive = true
            chapterHeightConstraints.append(height)
            button.addAction(
                UIAction { [weak self, weak button] _ in
                    guard let self, let button, !self.isLocal,
                        ReaderMenuToolbarInteraction.isAvailable(button)
                    else { return }
                    self.onChapterSource?()
                }, for: .touchUpInside)
        }
        chapterButton.accessibilityIdentifier = UIIdentifiers.Reader.chapterTitleLabel
        urlButton.accessibilityIdentifier = UIIdentifiers.Reader.chapterInfoAction

        sourceButton.translatesAutoresizingMaskIntoConstraints = false
        sourceButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        sourceButton.wrapsTitle = true
        sourceButton.titleLabel?.numberOfLines = 0
        sourceButton.titleLabel?.lineBreakMode = .byWordWrapping
        sourceButton.titleLabel?.textAlignment = .center
        sourceButton.layer.cornerRadius = 2
        sourceButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sourceButton.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        sourceButton.setContentCompressionResistancePriority(.fittingSizeLevel, for: .vertical)
        sourceButton.accessibilityIdentifier = UIIdentifiers.Reader.sourceButton
        sourceButton.addAction(
            UIAction { [weak self] _ in
                guard let self, self.sourceMenuAnchor != nil else { return }
                self.onSource?()
            }, for: .touchUpInside)

        chapterStack.axis = .vertical
        chapterStack.alignment = .fill
        chapterStack.distribution = .fill
        chapterStack.spacing = 0
        chapterStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        chapterStack.addArrangedSubview(chapterButton)
        chapterStack.addArrangedSubview(urlButton)

        sourceContainer.addSubview(sourceButton)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .horizontal
        contentStack.alignment = .fill
        contentStack.distribution = .fill
        contentStack.spacing = 0
        contentStack.semanticContentAttribute = .forceLeftToRight
        contentStack.addArrangedSubview(chapterStack)
        contentStack.addArrangedSubview(sourceContainer)
        addSubview(contentStack)

        // Optional edges let UIStackView collapse the addition or the local-book source slot.
        let contentBottom = contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        contentBottom.priority = UILayoutPriority(999)
        let sourceTrailing = sourceButton.trailingAnchor.constraint(
            equalTo: sourceContainer.trailingAnchor, constant: -1)
        sourceTrailing.priority = UILayoutPriority(999)
        let sourceWidth = sourceButton.widthAnchor.constraint(equalToConstant: 0)
        sourceWidth.priority = UILayoutPriority(999)
        sourceWidthConstraint = sourceWidth
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentBottom,
            sourceButton.topAnchor.constraint(equalTo: sourceContainer.topAnchor, constant: 1),
            sourceButton.leadingAnchor.constraint(equalTo: sourceContainer.leadingAnchor, constant: 1),
            sourceTrailing,
            sourceButton.bottomAnchor.constraint(equalTo: sourceContainer.bottomAnchor, constant: -1),
            sourceWidth,
            sourceButton.widthAnchor.constraint(lessThanOrEqualToConstant: 120),
        ])

        apply(
            background: .secondarySystemBackground, text: .label, sourceBackground: .systemBlue,
            sourceText: .white)
        update(chapter: "", source: "", url: nil, isLocal: false, showsAddition: false)
    }

    private func updateTypography() {
        for button in [chapterButton, urlButton, sourceButton] {
            button.applyFont(compatibleWith: traitCollection)
        }
        for (button, height) in zip([chapterButton, urlButton], chapterHeightConstraints) {
            height.constant = button.naturalLineHeight
        }
        updateSourceWidth()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func updateSourceWidth() {
        sourceWidthConstraint?.constant = min(sourceButton.preferredWidth, 120)
    }

    private static func singleLine(_ text: String) -> String {
        // SingleLineTransformationMethod changes display only; accessibility retains the raw text.
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }
}

private class ReaderMenuSummaryButton: UIButton {
    var wrapsTitle = false

    // UIButton can query titleRect while lazily creating titleLabel; never read the label there.
    private var summaryFont = ReaderAndroidDefaultFont.scaledFont(
        size: 14, textStyle: .body, compatibleWith: UITraitCollection())

    private var pixelScale: CGFloat { max(window?.screen.scale ?? traitCollection.displayScale, 1) }

    private var fontPadding: UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: summaryFont, scale: pixelScale)
    }

    var naturalLineHeight: CGFloat {
        let padding = fontPadding
        return pixelCeil(summaryFont.lineHeight + padding.top + padding.bottom)
    }

    var preferredWidth: CGFloat {
        let titleWidth = ((currentTitle ?? "") as NSString).size(withAttributes: [.font: summaryFont]).width
        return pixelCeil(titleWidth + contentEdgeInsets.left + contentEdgeInsets.right)
    }

    func applyFont(compatibleWith traits: UITraitCollection) {
        summaryFont = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        titleLabel?.font = summaryFont
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let insets = contentEdgeInsets
        let width = max(0, min(preferredWidth, size.width))
        let padding = fontPadding
        let height = titleSize(width: max(0, width - insets.left - insets.right)).height
        return CGSize(
            width: width,
            height: pixelCeil(
                max(summaryFont.lineHeight, height) + padding.top + padding.bottom + insets.top + insets.bottom))
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        let rect = contentRect.inset(by: fontPadding)
        let width = max(0, rect.width)
        let height = min(
            max(0, rect.height), pixelCeil(max(summaryFont.lineHeight, titleSize(width: width).height)))
        return CGRect(x: rect.minX, y: rect.minY + max(0, (rect.height - height) / 2), width: width, height: height)
    }

    private func titleSize(width: CGFloat) -> CGSize {
        let text = (currentTitle ?? "") as NSString
        if !wrapsTitle {
            return text.size(withAttributes: [.font: summaryFont])
        }
        return text.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: summaryFont], context: nil
        ).size
    }

    private func pixelCeil(_ value: CGFloat) -> CGFloat {
        ceil(value * pixelScale) / pixelScale
    }
}

private final class ReaderMenuSourceButton: ReaderMenuSummaryButton {
    var sourceBackgroundColor: UIColor = .clear {
        didSet { updateBackgroundColor() }
    }

    override var isHighlighted: Bool {
        didSet { updateBackgroundColor() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateBackgroundColor()
    }

    private func updateBackgroundColor() {
        guard isHighlighted else {
            backgroundColor = sourceBackgroundColor
            return
        }
        let color = sourceBackgroundColor.resolvedColor(with: traitCollection)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else {
            backgroundColor = color
            return
        }
        // AccentBgTextView uses ColorUtils.darkenColor: HSV value multiplied by 0.9.
        backgroundColor = UIColor(
            hue: hue, saturation: saturation, brightness: brightness * 0.9, alpha: alpha)
    }
}
