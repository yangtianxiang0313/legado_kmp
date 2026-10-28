import UIKit
import shared

final class AndroidReaderStyleQuickButton: UIButton {
    private let baseTitle: String
    private let imageName: String
    private var legacySizeConstraints: [NSLayoutConstraint] = []
    private var androidTitle: String?
    private var selectedRange: NSRange?
    private var palette: ReaderMenuPalette?
    private var summary = ""
    private var isActive = false

    override var isHighlighted: Bool { didSet { updateAndroidAppearance() } }
    override var isSelected: Bool { didSet { updateAndroidAppearance() } }
    override var isEnabled: Bool { didSet { updateAndroidAppearance() } }

    init(title: String, image: String) {
        baseTitle = title
        imageName = image
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        legacySizeConstraints = [
            widthAnchor.constraint(equalToConstant: 78),
            heightAnchor.constraint(equalToConstant: 58),
        ]
        NSLayoutConstraint.activate(legacySizeConstraints)
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true
        update(summary: "", isActive: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(summary: String, isActive: Bool) {
        self.summary = summary
        self.isActive = isActive
        guard androidTitle == nil else {
            updateAndroidAppearance()
            return
        }
        let foreground = palette?.bodyText ?? AndroidReplicaTheme.primaryText
        let accent = palette?.accent ?? AndroidReplicaTheme.accent
        let background = palette?.bottomBackground ?? AndroidReplicaTheme.menuBackground
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: imageName)
        configuration.title = baseTitle
        configuration.subtitle = summary
        configuration.imagePlacement = .top
        configuration.imagePadding = 3
        configuration.titleAlignment = .center
        configuration.baseForegroundColor = isActive ? accent : foreground
        configuration.baseBackgroundColor = isActive ? accent.withAlphaComponent(0.14) : background
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 4, bottom: 7, trailing: 4)
        self.configuration = configuration
        titleLabel?.numberOfLines = 1
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.78
        titleLabel?.lineBreakMode = .byTruncatingTail
        layer.borderColor = (isActive ? accent : (palette?.bodyText ?? AndroidReplicaTheme.divider)).cgColor
        accessibilityLabel = summary.isEmpty ? baseTitle : "\(baseTitle)，\(summary)"
    }

    func setAndroidTitle(_ title: String, selectedRange: NSRange? = nil) {
        if androidTitle == nil {
            NSLayoutConstraint.deactivate(legacySizeConstraints)
            setContentHuggingPriority(.defaultHigh, for: .horizontal)
            setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        androidTitle = title
        self.selectedRange = selectedRange
        updateAndroidAppearance()
        invalidateIntrinsicContentSize()
    }

    func apply(palette: ReaderMenuPalette) {
        self.palette = palette
        if androidTitle != nil {
            updateAndroidAppearance()
        } else {
            update(summary: summary, isActive: isActive)
        }
    }

    override var intrinsicContentSize: CGSize {
        guard let androidTitle else { return super.intrinsicContentSize }
        let font = androidFont
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        let width = (androidTitle as NSString).size(withAttributes: [.font: font]).width
        return CGSize(width: ceil(width) + 12, height: ceil(font.lineHeight + padding.top + padding.bottom + 8))
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if androidTitle != nil {
            updateAndroidAppearance()
            invalidateIntrinsicContentSize()
        }
    }

    private var androidFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
    }

    private func updateAndroidAppearance() {
        guard let androidTitle else { return }
        let font = androidFont
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        let palette = self.palette ?? ReaderMenuPalette(readerTheme: ReaderThemeController(), traits: traitCollection)
        // Selector puts pressed before selected; converter spans retain their own accent.
        let foreground =
            isEnabled
            ? (isSelected && !isHighlighted ? palette.accent : palette.bodyText)
            : UIColor(white: 158.0 / 255.0, alpha: 1)
        let text = NSMutableAttributedString(
            string: androidTitle,
            attributes: [
                .font: font,
                .foregroundColor: foreground,
                .kern: CGFloat(0),
            ])
        accessibilityValue = nil
        // legado 5f5d314 TextFontWeightConverter/ChineseConverter color only the selected character.
        if let range = selectedRange,
            range.location != NSNotFound, range.location >= 0, range.length > 0,
            range.location <= text.length, range.length <= text.length - range.location
        {
            if isEnabled { text.addAttribute(.foregroundColor, value: palette.accent, range: range) }
            accessibilityValue = (androidTitle as NSString).substring(with: range)
        }
        // dialog_read_book_style.xml: text-only 14sp, 6dp/4dp insets and a 3dp stroke radius.
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(text)
        configuration.baseForegroundColor = foreground
        let pressedColor: UIColor = ReaderPaletteColor.isNightResource(traits: traitCollection) ? .white : .black
        configuration.background.backgroundColor =
            isEnabled && isHighlighted ? pressedColor.withAlphaComponent(48.0 / 255.0) : .clear
        configuration.background.cornerRadius = 3
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 4 + padding.top, leading: 6, bottom: 4 + padding.bottom, trailing: 6)
        self.configuration = configuration
        layer.cornerRadius = 3
        layer.borderWidth = 1
        layer.borderColor = foreground.resolvedColor(with: traitCollection).cgColor
        titleLabel?.numberOfLines = 1
        titleLabel?.adjustsFontForContentSizeCategory = false
        titleLabel?.adjustsFontSizeToFitWidth = false
        titleLabel?.lineBreakMode = .byClipping
        accessibilityLabel = androidTitle
    }
}

/// DetailSeekBar's ImageViews use a borderless selector without dimming their icons.
final class AndroidReaderStyleStepButton: UIButton {
    private let pressedView = UIView()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        adjustsImageWhenHighlighted = false
        adjustsImageWhenDisabled = false
        pressedView.isUserInteractionEnabled = false
        pressedView.isAccessibilityElement = false
        insertSubview(pressedView, at: 0)
        updatePressedAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool { didSet { updatePressedAppearance() } }
    override var isEnabled: Bool { didSet { updatePressedAppearance() } }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updatePressedAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressedView.frame = bounds
        pressedView.layer.cornerRadius = min(bounds.width, bounds.height) / 2
        sendSubviewToBack(pressedView)
    }

    private func updatePressedAppearance() {
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        pressedView.backgroundColor = ReaderPaletteColor.argb(isNight ? 0x33FF_FFFF : 0x1F00_0000)
        pressedView.isHidden = !isHighlighted || !isEnabled
    }
}

final class AndroidReaderStyleHorizontalScrollView: UIScrollView {
    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        delaysContentTouches = false
        canCancelContentTouches = true
        isDirectionalLockEnabled = true
        bounces = false
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UISlider { return false }
        return view is UIControl || super.touchesShouldCancel(in: view)
    }
}

final class AndroidReaderStyleVerticalScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.x) > abs(velocity.y) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}

/// Keep DetailSeekBar's 60/24/track/24/60 columns and single-line padded text boxes.
final class AndroidReaderStyleCompactRowsView: UIView {
    private let rows: [AndroidReaderStyleSliderRow]
    private let valueSamples: [[String]]
    private var rowHeightConstraints: [NSLayoutConstraint] = []
    private var contentSizeCategory: UIContentSizeCategory?
    private var displayScale: CGFloat?

    init(rows: [AndroidReaderStyleSliderRow], valueSamples: [[String]]) {
        self.rows = rows
        self.valueSamples = valueSamples
        super.init(frame: .zero)
        let scrollView = AndroidReaderStyleHorizontalScrollView()
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 0
        for row in rows {
            for label in row.arrangedSubviews.compactMap({ $0 as? UILabel }) {
                label.numberOfLines = 1
                // Non-editable TextView singleLine defaults to END ellipsis.
                label.lineBreakMode = .byTruncatingTail
                label.adjustsFontSizeToFitWidth = false
                label.adjustsFontForContentSizeCategory = false
            }
            let height = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 25)
            height.isActive = true
            rowHeightConstraints.append(height)
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stack)
        let preferredWidth = stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            preferredWidth,
        ])
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func updateTypography() {
        guard
            contentSizeCategory != traitCollection.preferredContentSizeCategory
                || displayScale != traitCollection.displayScale
        else { return }
        contentSizeCategory = traitCollection.preferredContentSizeCategory
        displayScale = traitCollection.displayScale
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        let measurer = UILabel()
        measurer.font = font
        measurer.numberOfLines = 1
        measurer.lineBreakMode = .byTruncatingTail
        for (index, row) in rows.enumerated() {
            let labels = row.arrangedSubviews.compactMap { $0 as? UILabel }
            for label in labels { label.font = font }
            // Reserve every formatted value, so dragging does not change a row's height.
            let samples = labels.compactMap(\.text) + (valueSamples.indices.contains(index) ? valueSamples[index] : [])
            let height =
                samples.map { text -> CGFloat in
                    measurer.text = text.replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: "\u{FEFF}")
                    let textHeight = measurer.sizeThatFits(CGSize(width: 60, height: CGFloat.greatestFiniteMagnitude)).height
                    return ceil(max(font.lineHeight, textHeight) + padding.top + padding.bottom)
                }.max() ?? 25
            rowHeightConstraints[index].constant = max(25, height)
        }
        setNeedsLayout()
    }
}

typealias AndroidReaderStyleShareLayoutIndicator = ReaderAndroidCheckIndicatorView

enum AndroidReaderStyleControlColors {
    static func checkedText(on accent: UIColor, traits: UITraitCollection) -> UIColor {
        let color = accent.resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if !color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            guard color.getWhite(&white, alpha: &alpha) else { return .white }
            red = white
            green = white
            blue = white
        }
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : CGFloat(pow(Double((channel + 0.055) / 1.055), 2.4))
        }
        // ThemeRadioNoButton -> ColorUtils.isColorLight, including its 0.5 threshold.
        let luminance = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
        return luminance >= 0.5 ? .black : .white
    }
}

final class AndroidReaderStyleBackgroundButton: UIButton {
    let mode: ReaderBackgroundMode
    private let titleText: String
    private let backgroundHex: String
    private let textHex: String

    init(mode: ReaderBackgroundMode, title: String, backgroundHex: String, textHex: String) {
        self.mode = mode
        titleText = title
        self.backgroundHex = backgroundHex
        self.textHex = textHex
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 46).isActive = true
        layer.cornerRadius = 8
        layer.borderWidth = 1
        clipsToBounds = true
        update(selected: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(selected: Bool) {
        var configuration = UIButton.Configuration.filled()
        configuration.title = titleText
        configuration.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        configuration.imagePlacement = .leading
        configuration.imagePadding = 6
        configuration.titleAlignment = .center
        configuration.baseForegroundColor = selected ? AndroidReplicaTheme.accent : (UIColor(hex: textHex) ?? AndroidReplicaTheme.primaryText)
        configuration.baseBackgroundColor = UIColor(hex: backgroundHex) ?? AndroidReplicaTheme.menuBackground
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        self.configuration = configuration
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.82
        titleLabel?.lineBreakMode = .byTruncatingTail
        layer.borderColor = (selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.divider).cgColor
        accessibilityLabel = titleText
    }
}

final class AndroidReaderStyleValueRow: UIControl {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevronView = UIImageView(image: UIImage(systemName: "chevron.right"))

    override var isHighlighted: Bool {
        didSet {
            backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator.withAlphaComponent(0.35) : AndroidReplicaTheme.menuBackground
        }
    }

    init(title: String, systemImage: String? = nil) {
        super.init(frame: .zero)
        backgroundColor = AndroidReplicaTheme.menuBackground
        layer.cornerRadius = 8
        layer.borderWidth = 1 / UIScreen.main.scale
        layer.borderColor = AndroidReplicaTheme.divider.cgColor
        isAccessibilityElement = true
        accessibilityTraits = .button

        let iconView = UIImageView(image: systemImage.flatMap(UIImage.init(systemName:)))
        iconView.tintColor = AndroidReplicaTheme.accent
        iconView.contentMode = .scaleAspectFit
        iconView.isHidden = systemImage == nil

        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82
        titleLabel.lineBreakMode = .byTruncatingTail

        valueLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.textColor = AndroidReplicaTheme.accent
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 1
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.78
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevronView.tintColor = AndroidReplicaTheme.secondaryText
        chevronView.contentMode = .scaleAspectFit
        chevronView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [iconView, titleLabel, valueLabel, chevronView])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            iconView.widthAnchor.constraint(equalToConstant: systemImage == nil ? 0 : 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            chevronView.widthAnchor.constraint(equalToConstant: 10),
            chevronView.heightAnchor.constraint(equalToConstant: 16),
        ])
        update(value: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: String?) {
        let currentValue = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        valueLabel.text = currentValue
        accessibilityLabel = [titleLabel.text, currentValue]
            .compactMap { $0 }
            .joined(separator: "，")
    }
}

extension AndroidReaderStyleSheetViewController {
    func makeSwitchSection(title: String, toggle: UISwitch) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        let section = UIStackView(arrangedSubviews: [titleLabel, UIView(), toggle])
        section.axis = .horizontal
        section.alignment = .center
        section.spacing = 12
        return section
    }

    func makeSection(title: String, arrangedSubviews: [UIView]) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AndroidReplicaTheme.secondaryText
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82
        let stack = UIStackView(arrangedSubviews: [titleLabel])
        stack.axis = .vertical
        stack.spacing = 8
        arrangedSubviews.forEach(stack.addArrangedSubview)
        return stack
    }

    func makeActionButton(title: String, image: String, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        configuration.image = UIImage(systemName: image)
        configuration.imagePlacement = .top
        configuration.imagePadding = 4
        configuration.titleAlignment = .center
        configuration.baseForegroundColor = AndroidReplicaTheme.primaryText
        configuration.background.backgroundColor = AndroidReplicaTheme.menuBackground.withAlphaComponent(0.55)
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 6, bottom: 8, trailing: 6)
        let button = UIButton(configuration: configuration)
        button.titleLabel?.font = .systemFont(ofSize: 12, weight: .medium)
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.82
        button.layer.cornerRadius = 6
        button.clipsToBounds = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        return button
    }
}
