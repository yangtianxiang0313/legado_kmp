import UIKit
import shared

/// ReadStyleDialog at legado 5f5d314: dialog_read_book_style.xml and item_read_style.xml.
final class AndroidReaderStyleSheetBodyView: UIView {
    static let contentHeight: CGFloat = 334

    let fontSizeRow = AndroidReaderStyleSliderRow(title: "字号", identifier: UIIdentifiers.ReaderAppearance.fontSizeSlider)
    let letterSpacingRow = AndroidReaderStyleSliderRow(title: "字距", identifier: UIIdentifiers.ReaderAppearance.letterSpacingSlider)
    let lineSpacingRow = AndroidReaderStyleSliderRow(title: "行距", identifier: UIIdentifiers.ReaderAppearance.lineSpacingSlider)
    let paragraphSpacingRow = AndroidReaderStyleSliderRow(title: "段距", identifier: UIIdentifiers.ReaderAppearance.paragraphSpacingSlider)
    let fontWeightButton = AndroidReaderStyleQuickButton(title: "中/粗/细", image: "bold")
    let fontButton = AndroidReaderStyleQuickButton(title: "字体", image: "textformat")
    let indentButton = AndroidReaderStyleQuickButton(title: "缩进", image: "increase.indent")
    let chineseButton = AndroidReaderStyleQuickButton(title: "简/繁", image: "character.book.closed")
    let paddingButton = AndroidReaderStyleQuickButton(title: "边距", image: "arrow.left.and.right")
    let tipButton = AndroidReaderStyleQuickButton(title: "信息", image: "info.circle")
    let shareLayoutButton = UIButton(type: .custom)

    var onPageAnimationSelected: ((ReaderPageAnimationOption) -> Void)?
    var onPresetSelected: ((Int) -> Void)?
    var onPresetEdit: ((Int) -> Void)?
    var onAddPreset: (() -> Void)?
    var onContentHeightChange: ((CGFloat) -> Void)? {
        didSet { invalidateContentLayout() }
    }

    private let scrollView = AndroidReaderStyleVerticalScrollView()
    private let stackView = UIStackView()
    private let quickScrollView = AndroidReaderStyleHorizontalScrollView()
    private let animationScrollView = AndroidReaderStyleHorizontalScrollView()
    private let animationTitleLabel = AndroidExploreTextLabel()
    private let backgroundTitleLabel = AndroidExploreTextLabel()
    private let shareLayoutTitleLabel = AndroidExploreTextLabel()
    private let shareLayoutIndicator = AndroidReaderStyleShareLayoutIndicator()
    private let backgroundHeader = UIStackView()
    private let presetStrip = ReaderStylePresetStripView()
    private var state: ReaderAppearanceState?
    private var styleOverride: ReaderStylePreferences?
    private var palette: ReaderMenuPalette?
    private var presets: [ReaderPreset] = []
    private var selectedPresetIndex = -1
    private let firstDivider = UIView()
    private let secondDivider = UIView()
    private var animationButtons: [UIButton] = []
    private var animationWidthConstraints: [NSLayoutConstraint] = []
    private var quickHeightConstraint: NSLayoutConstraint?
    private var animationHeightConstraint: NSLayoutConstraint?
    private var shareWidthConstraint: NSLayoutConstraint?
    private var shareHeightConstraint: NSLayoutConstraint?
    private var sliderRowsView: AndroidReaderStyleCompactRowsView?
    private var selectedAnimation: ReaderPageAnimationOption = .cover
    private var lastReportedContentHeight: CGFloat?
    private var sliderContext: ReaderAppearanceSelectionContext?
    private var sliderVariant: ReaderVisualVariant?

    var canInteract: (() -> Bool)? {
        didSet { for row in sliderRows { row.canInteract = canInteract } }
    }

    private var sliderRows: [AndroidReaderStyleSliderRow] {
        [fontSizeRow, letterSpacingRow, lineSpacingRow, paragraphSpacingRow]
    }

    func setSliderInteractionEnabled(_ enabled: Bool) {
        for row in sliderRows { row.setInteractionEnabled(enabled) }
    }

    func cancelPendingSliderTracking() {
        for row in sliderRows { row.cancelPendingTracking() }
    }

    private var quickButtons: [AndroidReaderStyleQuickButton] {
        [fontWeightButton, fontButton, indentButton, chineseButton, paddingButton, tipButton]
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        for (button, title) in zip(quickButtons, ["中/粗/细", "字体", "缩进", "简/繁", "边距", "信息"]) {
            button.setAndroidTitle(title)
        }
        configureSliders()
        configureLayout()
        updateTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        updateBackgroundHeaderLayout()
        super.layoutSubviews()
        scrollView.layoutIfNeeded()
        guard scrollView.bounds.width > 0 else { return }
        let height = ceil(scrollView.contentSize.height)
        guard height > 0, height != lastReportedContentHeight else { return }
        lastReportedContentHeight = height
        onContentHeightChange?(height)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            updateTypography()
            invalidateContentLayout()
        }
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previousTraitCollection?.displayScale != traitCollection.displayScale,
            let palette
        {
            apply(palette: palette)
        }
    }

    private func configureLayout() {
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.accessibilityIdentifier = UIIdentifiers.ReaderAppearance.scrollView
        stackView.axis = .vertical
        stackView.spacing = 0
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])

        let quickRow = makeQuickRow()
        quickHeightConstraint = quickRow.heightAnchor.constraint(equalToConstant: 28)
        quickHeightConstraint?.isActive = true
        let quickHost = addInsetRow(quickRow, height: 0, minimumHeight: true)
        stackView.setCustomSpacing(8, after: quickHost)
        let sliderRows = AndroidReaderStyleCompactRowsView(
            rows: [fontSizeRow, letterSpacingRow, lineSpacingRow, paragraphSpacingRow],
            valueSamples: [
                (5...50).compactMap { fontSizeRow.valueFormatter?(Float($0)) },
                (-50...50).compactMap { letterSpacingRow.valueFormatter?(Float($0) / 100) },
                (0...20).compactMap { lineSpacingRow.valueFormatter?(Float($0)) },
                (0...20).compactMap { paragraphSpacingRow.valueFormatter?(Float($0)) },
            ])
        sliderRowsView = sliderRows
        addInsetRow(sliderRows, height: 100, minimumHeight: true)
        addDivider(firstDivider)
        animationTitleLabel.text = L10n.ReaderAppearance.pageAnimationTitle
        configureSectionLabel(animationTitleLabel)
        let animationTitleHost = addInsetRow(animationTitleLabel, height: 0, minimumHeight: true)
        stackView.setCustomSpacing(4, after: animationTitleHost)
        let animationRow = makeAnimationRow()
        animationHeightConstraint = animationRow.heightAnchor.constraint(equalToConstant: 40)
        animationHeightConstraint?.isActive = true
        addInsetRow(animationRow, height: 0, minimumHeight: true, horizontalInset: 11)
        addDivider(secondDivider)
        let backgroundHost = addInsetRow(makeBackgroundHeader(), height: 20, minimumHeight: true)
        stackView.setCustomSpacing(8, after: backgroundHost)
        presetStrip.onSelect = { [weak self] name in self?.onPresetSelected?(name) }
        presetStrip.onEdit = { [weak self] name in self?.onPresetEdit?(name) }
        presetStrip.onAdd = { [weak self] in self?.onAddPreset?() }
        stackView.addArrangedSubview(presetStrip)
    }

    private func configureSliders() {
        fontSizeRow.useAndroidCompactLayout(step: 1)
        letterSpacingRow.useAndroidCompactLayout(step: 0.01)
        lineSpacingRow.useAndroidCompactLayout(step: 1)
        paragraphSpacingRow.useAndroidCompactLayout(step: 1)
        fontSizeRow.valueFormatter = { String(Int(AndroidReaderStyleScale.roundFontSize($0))) }
        letterSpacingRow.valueFormatter = {
            let value = AndroidReaderStyleScale.roundLetterSpacing($0)
            return String(value == 0 ? Float(0) : value)
        }
        lineSpacingRow.valueFormatter = {
            AndroidReaderStyleScale.lineSpacingText(progress: AndroidReaderStyleScale.roundProgress($0))
        }
        paragraphSpacingRow.valueFormatter = {
            AndroidReaderStyleScale.paragraphSpacingText(progress: AndroidReaderStyleScale.roundProgress($0))
        }
    }

    private func makeQuickRow() -> UIView {
        let row = UIStackView(arrangedSubviews: quickButtons)
        row.axis = .horizontal
        row.alignment = .fill
        row.distribution = .equalSpacing
        // Android uses weighted Space views, without a minimum gap between controls.
        row.spacing = 0
        row.translatesAutoresizingMaskIntoConstraints = false
        for button in quickButtons { button.setContentCompressionResistancePriority(.required, for: .horizontal) }
        quickScrollView.addSubview(row)
        let preferredWidth = row.widthAnchor.constraint(equalTo: quickScrollView.frameLayoutGuide.widthAnchor)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.topAnchor),
            row.leadingAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.trailingAnchor),
            row.bottomAnchor.constraint(equalTo: quickScrollView.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: quickScrollView.frameLayoutGuide.heightAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualTo: quickScrollView.frameLayoutGuide.widthAnchor),
            preferredWidth,
        ])
        return quickScrollView
    }

    private func makeAnimationRow() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = 8
        row.accessibilityIdentifier = UIIdentifiers.ReaderAppearance.pageAnimationButton
        row.translatesAutoresizingMaskIntoConstraints = false
        for option in ReaderPageAnimationOption.allCases {
            let button = UIButton(type: .custom)
            // SingleLineTransformationMethod affects display only; AX retains the resource text.
            let displayTitle = option.title.replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: "\u{FEFF}")
            button.setTitle(displayTitle, for: .normal)
            button.accessibilityLabel = option.title
            button.titleLabel?.numberOfLines = 1
            button.titleLabel?.adjustsFontSizeToFitWidth = false
            button.titleLabel?.adjustsFontForContentSizeCategory = false
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.layer.cornerRadius = 2
            button.layer.borderWidth = 2
            button.accessibilityIdentifier = "readerAppearance.pageAnimation.\(option.rawValue)"
            button.addAction(
                UIAction { [weak self] _ in
                    guard let self, option != self.selectedAnimation else { return }
                    self.onPageAnimationSelected?(option)
                }, for: .touchUpInside)
            row.addArrangedSubview(button)
            animationButtons.append(button)
            let width = button.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
            width.isActive = true
            animationWidthConstraints.append(width)
        }
        animationScrollView.addSubview(row)
        // RadioGroup: 11dp outer margins, then each radio's 4dp margin and 5dp padding.
        let preferredWidth = row.widthAnchor.constraint(equalTo: animationScrollView.frameLayoutGuide.widthAnchor, constant: -8)
        preferredWidth.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: animationScrollView.contentLayoutGuide.topAnchor, constant: 4),
            row.leadingAnchor.constraint(equalTo: animationScrollView.contentLayoutGuide.leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: animationScrollView.contentLayoutGuide.trailingAnchor, constant: -4),
            row.bottomAnchor.constraint(equalTo: animationScrollView.contentLayoutGuide.bottomAnchor, constant: -4),
            row.heightAnchor.constraint(equalTo: animationScrollView.frameLayoutGuide.heightAnchor, constant: -8),
            row.widthAnchor.constraint(greaterThanOrEqualTo: animationScrollView.frameLayoutGuide.widthAnchor, constant: -8),
            preferredWidth,
        ])
        return animationScrollView
    }

    private func makeBackgroundHeader() -> UIView {
        backgroundTitleLabel.text = "文字颜色和背景（长按自定义）"
        configureSectionLabel(backgroundTitleLabel)
        backgroundTitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        backgroundTitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shareLayoutTitleLabel.text = "共用布局"
        shareLayoutTitleLabel.numberOfLines = 0
        shareLayoutTitleLabel.lineBreakMode = .byCharWrapping
        shareLayoutTitleLabel.adjustsFontSizeToFitWidth = false
        shareLayoutTitleLabel.adjustsFontForContentSizeCategory = false
        shareLayoutTitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
        let content = UIStackView(arrangedSubviews: [shareLayoutTitleLabel, shareLayoutIndicator])
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = 6
        content.isUserInteractionEnabled = false
        content.isAccessibilityElement = false
        content.translatesAutoresizingMaskIntoConstraints = false
        shareLayoutButton.addSubview(content)
        shareLayoutButton.isAccessibilityElement = true
        shareLayoutButton.accessibilityIdentifier = UIIdentifiers.ReaderAppearance.shareLayoutSwitch
        shareLayoutButton.accessibilityLabel = "共用布局"
        shareLayoutButton.accessibilityHint = L10n.ReaderAppearance.shareLayoutDetail
        shareLayoutButton.translatesAutoresizingMaskIntoConstraints = false
        shareWidthConstraint = shareLayoutButton.widthAnchor.constraint(equalToConstant: 82)
        shareHeightConstraint = shareLayoutButton.heightAnchor.constraint(equalToConstant: 20)
        shareWidthConstraint?.isActive = true
        shareHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            shareLayoutIndicator.widthAnchor.constraint(equalToConstant: 20),
            shareLayoutIndicator.heightAnchor.constraint(equalToConstant: 20),
            content.leadingAnchor.constraint(equalTo: shareLayoutButton.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: shareLayoutButton.trailingAnchor),
            content.centerYAnchor.constraint(equalTo: shareLayoutButton.centerYAnchor),
            content.topAnchor.constraint(greaterThanOrEqualTo: shareLayoutButton.topAnchor),
            content.bottomAnchor.constraint(lessThanOrEqualTo: shareLayoutButton.bottomAnchor),
        ])
        backgroundHeader.addArrangedSubview(backgroundTitleLabel)
        backgroundHeader.addArrangedSubview(shareLayoutButton)
        backgroundHeader.axis = .horizontal
        backgroundHeader.alignment = .center
        backgroundHeader.spacing = 0
        return backgroundHeader
    }

    private func configureSectionLabel(_ label: UILabel) {
        label.alpha = 0.75
        label.adjustsFontForContentSizeCategory = false
        label.adjustsFontSizeToFitWidth = false
        label.numberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    private func updateTypography() {
        let sectionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        for label in [animationTitleLabel, backgroundTitleLabel] { label.font = sectionFont }
        let controlFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        let fontPadding = AndroidExploreTextMetrics.padding(font: controlFont, scale: traitCollection.displayScale)
        shareLayoutTitleLabel.font = controlFont
        for (button, width) in zip(animationButtons, animationWidthConstraints) {
            button.titleLabel?.font = controlFont
            button.contentEdgeInsets = UIEdgeInsets(
                top: 5 + fontPadding.top, left: 5, bottom: 5 + fontPadding.bottom, right: 5)
            let title = button.title(for: .normal) ?? ""
            width.constant = ceil((title as NSString).size(withAttributes: [.font: controlFont]).width) + 10
        }
        quickHeightConstraint?.constant = quickButtons.map(\.intrinsicContentSize.height).max() ?? 0
        // AppCompat's 14sp radio has no independent minimum height with button=@null and this selector.
        animationHeightConstraint?.constant = ceil(controlFont.lineHeight + fontPadding.top + fontPadding.bottom + 10) + 8
        sliderRowsView?.updateTypography()
        updateBackgroundHeaderLayout()
    }

    private func updateBackgroundHeaderLayout() {
        let width = max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right - 32)
        guard width > 0 else { return }
        let shareFont = shareLayoutTitleLabel.font ?? .systemFont(ofSize: 14)
        let titleWidth = ceil(
            ((shareLayoutTitleLabel.text ?? "") as NSString).size(withAttributes: [.font: shareFont]).width)
        let buttonWidth = min(width, titleWidth + 26)
        shareWidthConstraint?.constant = buttonWidth
        let titleHeight = shareLayoutTitleLabel.sizeThatFits(
            CGSize(width: max(1, buttonWidth - 26), height: .greatestFiniteMagnitude)
        ).height
        // dialog_read_book_style: wrap_content text beside a fixed 20dp checkbox.
        shareHeightConstraint?.constant = max(20, ceil(titleHeight))
        // Android keeps this row horizontal: only the weighted background title wraps.
        backgroundTitleLabel.preferredMaxLayoutWidth = max(0, width - buttonWidth)
    }

    private func invalidateContentLayout() {
        lastReportedContentHeight = nil
        stackView.setNeedsLayout()
        scrollView.setNeedsLayout()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @discardableResult
    private func addInsetRow(
        _ row: UIView, height: CGFloat, minimumHeight: Bool = false, horizontalInset: CGFloat = 16
    ) -> UIView {
        let host = UIView()
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            minimumHeight
                ? host.heightAnchor.constraint(greaterThanOrEqualToConstant: height)
                : host.heightAnchor.constraint(equalToConstant: height),
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: horizontalInset),
            row.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -horizontalInset),
            row.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        stackView.addArrangedSubview(host)
        return host
    }

    private func addDivider(_ divider: UIView) {
        let host = UIView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(divider)
        NSLayoutConstraint.activate([
            host.heightAnchor.constraint(equalToConstant: 16.8),
            divider.topAnchor.constraint(equalTo: host.topAnchor, constant: 8),
            divider.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 16),
            divider.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
            divider.heightAnchor.constraint(equalToConstant: 0.8),
        ])
        stackView.addArrangedSubview(host)
    }

    func apply(
        state: ReaderAppearanceState, presets: [ReaderPreset], palette: ReaderMenuPalette,
        styleOverride: ReaderStylePreferences? = nil, effectivePageAnimation: Int? = nil
    ) {
        let variant = ReaderThemeVisualStyle.variant(
            preferences: state.preferences, userInterfaceStyle: traitCollection.userInterfaceStyle)
        if sliderContext.map({ !$0.matches(state) }) == true || sliderVariant.map({ $0 != variant }) == true {
            cancelPendingSliderTracking()
        }
        sliderContext = ReaderAppearanceSelectionContext(state)
        sliderVariant = variant
        self.state = state
        self.styleOverride = styleOverride
        // Keep pending edits ahead of a scheme resolved from the persisted snapshot.
        let style =
            styleOverride
            ?? ReaderThemeVisualStyle.style(
                preferences: state.preferences, userInterfaceStyle: traitCollection.userInterfaceStyle)
        let runtime = state.runtimeConfig.reader
        set(fontSizeRow, value: style.fontSizeSp)
        set(letterSpacingRow, value: style.letterSpacing)
        set(lineSpacingRow, value: Float(AndroidReaderStyleScale.lineProgress(multiplier: style.lineSpacingMultiplier)))
        set(paragraphSpacingRow, value: Float(style.paragraphSpacing))
        let weightRange: NSRange? =
            (0...2).contains(style.textBold)
            ? NSRange(location: Int(style.textBold) * 2, length: 1) : nil
        fontWeightButton.setAndroidTitle("中/粗/细", selectedRange: weightRange)
        fontButton.setAndroidTitle("字体")
        indentButton.setAndroidTitle("缩进")
        let chineseRange: NSRange? =
            runtime.chineseMode == 1
            ? NSRange(location: 0, length: 1)
            : (runtime.chineseMode == 2 ? NSRange(location: 2, length: 1) : nil)
        chineseButton.setAndroidTitle("简/繁", selectedRange: chineseRange)
        paddingButton.setAndroidTitle("边距")
        tipButton.setAndroidTitle("信息")
        selectedAnimation = ReaderPageAnimationOption(rawValue: effectivePageAnimation ?? Int(runtime.pageAnimation)) ?? .cover
        shareLayoutButton.isSelected = runtime.shareLayout
        shareLayoutButton.accessibilityValue = runtime.shareLayout ? L10n.Settings.enabled : L10n.Settings.disabled
        shareLayoutButton.accessibilityTraits = runtime.shareLayout ? [.button, .selected] : .button
        self.presets = presets.enumerated().map { index, preset in
            index == Int(state.preferences.readerPresetIndex) ? state.preferences.readerPreset ?? preset : preset
        }
        selectedPresetIndex = Int(state.preferences.readerPresetIndex)
        apply(palette: palette)
        updateTypography()
        setNeedsLayout()
    }

    private func set(_ row: AndroidReaderStyleSliderRow, value: Float) {
        row.set(value: value, text: row.valueFormatter?(value) ?? String(value))
    }

    func apply(palette: ReaderMenuPalette) {
        self.palette = palette
        backgroundColor = palette.bottomBackground
        for button in quickButtons { button.apply(palette: palette) }
        for row in [fontSizeRow, letterSpacingRow, lineSpacingRow, paragraphSpacingRow] { row.apply(palette: palette) }
        animationTitleLabel.textColor = palette.bodyText
        backgroundTitleLabel.textColor = palette.bodyText
        let variant =
            state.map {
                ReaderThemeVisualStyle.variant(
                    preferences: $0.preferences, userInterfaceStyle: traitCollection.userInterfaceStyle)
            } ?? (traitCollection.userInterfaceStyle == .dark ? ReaderVisualVariant.night : .day)
        let isNight = ReaderPaletteColor.isNightResource(traits: traitCollection)
        let dividerColor = UIColor(hex: isNight ? "#4D4D4D" : "#ACACAC") ?? palette.bodyText
        for divider in [firstDivider, secondDivider] { divider.backgroundColor = dividerColor.withAlphaComponent(99.0 / 255.0) }
        let checkedTextColor = AndroidReaderStyleControlColors.checkedText(on: palette.accent, traits: traitCollection)
        for (index, button) in animationButtons.enumerated() {
            let selected = index == selectedAnimation.rawValue
            button.isSelected = selected
            button.backgroundColor = selected ? palette.accent : .clear
            let textColor = selected ? checkedTextColor : palette.bodyText
            button.setTitleColor(textColor, for: .normal)
            button.setTitleColor(textColor, for: .selected)
            button.setTitleColor(textColor, for: [.selected, .highlighted])
            button.layer.borderColor = (selected ? palette.accent : palette.bodyText).resolvedColor(with: traitCollection).cgColor
            button.accessibilityTraits = selected ? [.button, .selected] : .button
        }
        let checked = shareLayoutButton.isSelected
        shareLayoutTitleLabel.textColor = palette.bodyText
        shareLayoutIndicator.apply(checked: checked, accent: palette.accent, isNight: isNight)
        shareLayoutButton.accessibilityTraits = checked ? [.button, .selected] : .button
        presetStrip.configure(presets: presets, selectedIndex: selectedPresetIndex, palette: palette, variant: variant)
    }
}
