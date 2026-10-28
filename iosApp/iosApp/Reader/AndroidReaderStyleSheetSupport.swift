import UIKit
import shared

enum AndroidReaderStyleScale {
    static let fontSizeRange: ClosedRange<Float> = 5...50
    static let letterSpacingRange: ClosedRange<Float> = -0.5...0.5
    static let lineProgressRange: ClosedRange<Float> = 0...20
    static let paragraphProgressRange: ClosedRange<Float> = 0...20
    static let verticalPaddingRange: ClosedRange<Float> = 0...40
    static let brightnessRange: ClosedRange<Float> = 1...100

    static func roundFontSize(_ value: Float) -> Float {
        value.rounded().coerced(to: fontSizeRange)
    }

    static func roundLetterSpacing(_ value: Float) -> Float {
        (value * 100).rounded() / 100
    }

    static func roundProgress(_ value: Float) -> Int {
        Int(value.rounded().coerced(to: lineProgressRange))
    }

    static func roundPadding(_ value: Float) -> Float {
        value.rounded().coerced(to: AppUI.ReaderAppearance.minHorizontalPadding...AppUI.ReaderAppearance.maxHorizontalPadding)
    }

    static func roundVerticalPadding(_ value: Float) -> Int32 {
        Int32(value.rounded().coerced(to: verticalPaddingRange))
    }

    static func roundBrightness(_ value: Float) -> Int32 {
        Int32(value.rounded().coerced(to: brightnessRange))
    }

    static func lineProgress(multiplier: Float) -> Int {
        Int((multiplier * 10).rounded().coerced(to: lineProgressRange))
    }

    static func lineSpacingMultiplier(progress: Int) -> Float {
        Float(progress) / 10
    }

    static func fontSizeText(_ value: Float) -> String {
        L10n.ReaderAppearance.fontSizeValue(roundFontSize(value))
    }

    static func letterSpacingText(_ value: Float) -> String {
        L10n.ReaderAppearance.letterSpacingValue(roundLetterSpacing(value))
    }

    static func lineSpacingText(progress: Int) -> String {
        String(format: "%.1f", (Float(progress) - 10) / 10)
    }

    static func paragraphSpacingText(progress: Int) -> String {
        String(format: "%.1f", Float(progress) / 10)
    }

    static func defaultColors(for mode: ReaderBackgroundMode) -> (background: String, text: String) {
        switch mode {
        case .dark:
            return ("#000000", "#D0D0D0")
        case .sepia:
            return ("#DDC090", "#3F2F1D")
        default:
            return ("#EEEEEE", "#3E3D3B")
        }
    }
}

func colorOptionTitle(_ title: String, _ hex: String?) -> String {
    guard let hex, hex.isEmpty == false else { return title }
    return "\(title): \(hex)"
}

extension Float {
    func coerced(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

final class AndroidReaderStylePresetButton: UIButton {
    private let preset: ReaderPreset
    private let isCurrent: Bool
    var presetName: String { preset.name }

    init(preset: ReaderPreset, selected: Bool) {
        self.preset = preset
        isCurrent = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 48).isActive = true
        heightAnchor.constraint(equalToConstant: 48).isActive = true
        setTitle(preset.name.isEmpty ? L10n.ReaderAppearance.presetFallbackName : preset.name, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 10, weight: selected ? .bold : .regular)
        titleLabel?.lineBreakMode = .byTruncatingTail
        setTitleColor(textColor, for: .normal)
        backgroundColor = backgroundColorValue
        layer.cornerRadius = 24
        layer.borderWidth = selected ? 2 : 1
        layer.borderColor = (selected ? UIColor.systemBlue : textColor).cgColor
        clipsToBounds = true
        accessibilityLabel = preset.name
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(palette: ReaderMenuPalette, isNight: Bool) {
        // legado 5f5d314 ReadStyleDialog.StyleAdapter: cur colors, 1dp border, selected bold text.
        let foreground = UIColor(hex: (isNight ? preset.textColorNight : preset.textColor) ?? "") ?? palette.bodyText
        let background = UIColor(hex: (isNight ? preset.bgStrNight : preset.bgStr) ?? "") ?? palette.bottomBackground
        setTitleColor(foreground, for: .normal)
        backgroundColor = background
        // CircleImageView.drawText uses 15sp. Fit legacy/custom long names without ellipses.
        titleLabel?.font = .systemFont(ofSize: 15, weight: isCurrent ? .bold : .regular)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.5
        titleLabel?.baselineAdjustment = .alignCenters
        layer.borderWidth = 1
        layer.borderColor = (isCurrent ? palette.accent : foreground).cgColor
        accessibilityLabel = title(for: .normal)
        if isCurrent { accessibilityTraits.insert(.selected) }
    }

    private var backgroundColorValue: UIColor {
        UIColor(hex: preset.bgStr ?? "") ?? UIColor(hex: "#F6F0DD") ?? AndroidReplicaTheme.menuBackground
    }

    private var textColor: UIColor {
        UIColor(hex: preset.textColor ?? "") ?? .label
    }
}

final class AndroidReaderStyleAddPresetButton: UIButton {
    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 48).isActive = true
        heightAnchor.constraint(equalToConstant: 48).isActive = true
        setImage(UIImage(systemName: "plus"), for: .normal)
        tintColor = AndroidReplicaTheme.primaryText
        backgroundColor = AndroidReplicaTheme.menuBackground
        layer.cornerRadius = 24
        layer.borderWidth = 1
        layer.borderColor = AndroidReplicaTheme.divider.cgColor
        clipsToBounds = true
        accessibilityLabel = L10n.ReaderAppearance.importPresetTitle
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func apply(palette: ReaderMenuPalette, isNight _: Bool) {
        setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 24, weight: .regular), forImageIn: .normal)
        tintColor = palette.bodyText
        backgroundColor = palette.bottomBackground
        layer.borderColor = palette.bodyText.cgColor
    }
}

extension ReaderStylePreferences {
    func androidCopy(
        fontSizeSp: Float? = nil,
        lineSpacingMultiplier: Float? = nil,
        horizontalPaddingDp: Float? = nil,
        backgroundMode: ReaderBackgroundMode? = nil,
        backgroundColorHex: String?? = nil,
        textColorHex: String?? = nil,
        textBold: Int32? = nil,
        fontName: String?? = nil,
        letterSpacing: Float? = nil,
        paragraphSpacing: Int32? = nil,
        paragraphIndent: Int32? = nil,
        underline: Bool? = nil,
        backgroundAlpha: Int32? = nil,
        backgroundImagePath: String?? = nil,
        darkStatusIcon: Bool? = nil,
        titleMode: Int32? = nil,
        titleSize: Float? = nil,
        titleTopSpacing: Int32? = nil,
        titleBottomSpacing: Int32? = nil,
        paddingTop: Int32? = nil,
        paddingBottom: Int32? = nil,
        paddingLeft: Int32? = nil,
        paddingRight: Int32? = nil,
        headerPaddingTop: Int32? = nil,
        headerPaddingBottom: Int32? = nil,
        headerPaddingLeft: Int32? = nil,
        headerPaddingRight: Int32? = nil,
        footerPaddingTop: Int32? = nil,
        footerPaddingBottom: Int32? = nil,
        footerPaddingLeft: Int32? = nil,
        footerPaddingRight: Int32? = nil,
        showHeaderLine: Bool? = nil,
        showFooterLine: Bool? = nil,
        tipHeaderLeft: Int32? = nil,
        tipHeaderMiddle: Int32? = nil,
        tipHeaderRight: Int32? = nil,
        tipFooterLeft: Int32? = nil,
        tipFooterMiddle: Int32? = nil,
        tipFooterRight: Int32? = nil,
        tipColorHex: String?? = nil,
        tipDividerColorHex: String?? = nil,
        headerMode: Int32? = nil,
        footerMode: Int32? = nil
    ) -> ReaderStylePreferences {
        ReaderStylePreferences(
            fontSizeSp: fontSizeSp ?? self.fontSizeSp,
            lineSpacingMultiplier: lineSpacingMultiplier ?? self.lineSpacingMultiplier,
            horizontalPaddingDp: horizontalPaddingDp ?? self.horizontalPaddingDp,
            backgroundMode: backgroundMode ?? self.backgroundMode,
            backgroundColorHex: backgroundColorHex ?? self.backgroundColorHex,
            textColorHex: textColorHex ?? self.textColorHex,
            fontName: fontName ?? self.fontName,
            textBold: textBold ?? self.textBold,
            letterSpacing: letterSpacing ?? self.letterSpacing,
            paragraphSpacing: paragraphSpacing ?? self.paragraphSpacing,
            paragraphIndent: paragraphIndent ?? self.paragraphIndent,
            underline: underline ?? self.underline,
            backgroundAlpha: backgroundAlpha ?? self.backgroundAlpha,
            backgroundImagePath: backgroundImagePath ?? self.backgroundImagePath,
            darkStatusIcon: darkStatusIcon ?? self.darkStatusIcon,
            titleMode: titleMode ?? self.titleMode,
            titleSize: titleSize ?? self.titleSize,
            titleTopSpacing: titleTopSpacing ?? self.titleTopSpacing,
            titleBottomSpacing: titleBottomSpacing ?? self.titleBottomSpacing,
            paddingTop: paddingTop ?? self.paddingTop,
            paddingBottom: paddingBottom ?? self.paddingBottom,
            paddingLeft: paddingLeft ?? self.paddingLeft,
            paddingRight: paddingRight ?? self.paddingRight,
            headerPaddingTop: headerPaddingTop ?? self.headerPaddingTop,
            headerPaddingBottom: headerPaddingBottom ?? self.headerPaddingBottom,
            headerPaddingLeft: headerPaddingLeft ?? self.headerPaddingLeft,
            headerPaddingRight: headerPaddingRight ?? self.headerPaddingRight,
            footerPaddingTop: footerPaddingTop ?? self.footerPaddingTop,
            footerPaddingBottom: footerPaddingBottom ?? self.footerPaddingBottom,
            footerPaddingLeft: footerPaddingLeft ?? self.footerPaddingLeft,
            footerPaddingRight: footerPaddingRight ?? self.footerPaddingRight,
            showHeaderLine: showHeaderLine ?? self.showHeaderLine,
            showFooterLine: showFooterLine ?? self.showFooterLine,
            tipHeaderLeft: tipHeaderLeft ?? self.tipHeaderLeft,
            tipHeaderMiddle: tipHeaderMiddle ?? self.tipHeaderMiddle,
            tipHeaderRight: tipHeaderRight ?? self.tipHeaderRight,
            tipFooterLeft: tipFooterLeft ?? self.tipFooterLeft,
            tipFooterMiddle: tipFooterMiddle ?? self.tipFooterMiddle,
            tipFooterRight: tipFooterRight ?? self.tipFooterRight,
            tipColorHex: tipColorHex ?? self.tipColorHex,
            tipDividerColorHex: tipDividerColorHex ?? self.tipDividerColorHex,
            headerMode: headerMode ?? self.headerMode,
            footerMode: footerMode ?? self.footerMode
        )
    }
}

enum AndroidReaderStyleColorTarget {
    case background
    case text
    case tip
    case tipDivider
}

extension ReaderRuntimeConfig {
    func androidCopy(
        brightnessDay: Int32? = nil,
        brightnessNight: Int32? = nil,
        pageAnimation: Int32? = nil,
        shareLayout: Bool? = nil,
        chineseMode: Int32? = nil,
        useZhLayout: Bool? = nil,
        readBodyToLh: Bool? = nil
    ) -> ReaderRuntimeConfig {
        ReaderRuntimeConfig(
            brightnessDay: brightnessDay ?? self.brightnessDay,
            brightnessNight: brightnessNight ?? self.brightnessNight,
            pageAnimation: pageAnimation ?? self.pageAnimation,
            shareLayout: shareLayout ?? self.shareLayout,
            readStyleIndex: readStyleIndex,
            comicStyleIndex: comicStyleIndex,
            autoReadSpeed: autoReadSpeed,
            ttsFollowSystemRate: ttsFollowSystemRate,
            ttsSpeechRate: ttsSpeechRate,
            ttsTimerMinutes: ttsTimerMinutes,
            ttsVoiceIdentifier: ttsVoiceIdentifier,
            textFullJustify: textFullJustify,
            textBottomJustify: textBottomJustify,
            hideStatusBar: hideStatusBar,
            hideNavigationBar: hideNavigationBar,
            chineseMode: chineseMode ?? self.chineseMode,
            tapZoneActions: tapZoneActions,
            useZhLayout: useZhLayout ?? self.useZhLayout,
            readBodyToLh: readBodyToLh ?? self.readBodyToLh,
            isComic: isComic
        )
    }
}

enum AndroidReaderStyleTipSlot {
    case headerLeft
    case headerMiddle
    case headerRight
    case footerLeft
    case footerMiddle
    case footerRight
}

extension AndroidReaderStyleSheetViewController {
    func openPaddingPicker() {
        guard let state = self.state, presentedViewController == nil else { return }
        let style = state.preferences.readerStyle
        do {
            let settings = try ReaderPaddingSettings(style: style, context: ReaderAppearanceSelectionContext(state))
            let bookIsCurrent = controlBookValidation()
            let controller = ReaderPaddingDialogViewController(
                values: ReaderPaddingValues(style: style),
                onChange: { settings.update($0) },
                onFinish: { try await settings.finish() })
            controller.canInteract = { settings.isCurrent && bookIsCurrent() }
            settings.onContextChange = { [weak controller] in controller?.refreshInteractionAvailability() }
            controller.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            var owner: UIViewController = self
            while let parent = owner.parent { owner = parent }
            if owner is ReaderBottomSheetNavigationController, let presenter = owner.presentingViewController {
                owner.dismiss(animated: true) { [weak presenter] in
                    guard let presenter, presenter.view.window != nil, presenter.presentedViewController == nil else { return }
                    presenter.present(controller, animated: true)
                }
            } else {
                present(controller, animated: true)
            }
        } catch {
            presentError(error)
        }
    }

    func openTipPicker() {
        guard let style = state?.preferences.readerStyle, presentedViewController == nil else { return }
        do {
            let settings = try ReaderTipSettings()
            let controller = AndroidReaderTipConfigSheetViewController(
                values: ReaderTipValues(style: style),
                onChange: { settings.update($0) },
                onFinish: { try await settings.finish() })
            controller.overrideUserInterfaceStyle = overrideUserInterfaceStyle
            // Unlike padding, Android keeps the appearance panel behind the info dialog.
            present(controller, animated: true)
        } catch {
            presentError(error)
        }
    }

    func openMoreStylePicker() {
        guard let style = state?.preferences.readerStyle else { return }
        guard presentedViewController == nil else { return }
        let controller = AndroidReaderAdvancedStyleSheetViewController(
            style: style,
            onUpdate: { [weak self] updatedStyle in
                guard let self else { return }
                self.runSettingTask { try await self.screen.setReaderStyle(style: updatedStyle) }
            }
        )
        presentAppearanceDetail(controller, height: 380)
    }

    func fontWeightTitle(_ value: Int32) -> String {
        value == 1
            ? L10n.ReaderAppearance.fontWeightBold
            : (value == 2 ? L10n.ReaderAppearance.fontWeightLight : L10n.ReaderAppearance.fontWeightNormal)
    }

    func fontTitle(_ name: String?) -> String {
        name == "Georgia"
            ? L10n.ReaderAppearance.fontSerif
            : (name == "Menlo-Regular" ? L10n.ReaderAppearance.fontMonospaced : L10n.ReaderAppearance.fontSystem)
    }

    func chineseModeTitle(_ value: Int) -> String {
        value == 1
            ? L10n.ReaderAppearance.chineseSimplified
            : (value == 2 ? L10n.ReaderAppearance.chineseTraditional : L10n.ReaderAppearance.chineseNone)
    }
}

extension AndroidReaderStyleSheetViewController {
    func openHorizontalPaddingPicker(style: ReaderStylePreferences) {
        let values: [Float] = [12, 16, 20, 24, 28, 32, 36]
        presentOptionSheet(
            title: L10n.ReaderAppearance.paddingBodySection, height: 430,
            options: values.map { value in
                .init(title: L10n.ReaderAppearance.paddingValue(value), isSelected: abs(style.horizontalPaddingDp - value) < 0.5)
                { [weak self] in
                    guard let self else { return }
                    self.runSettingTask {
                        try await self.screen.setReaderStyle(
                            style: style.androidCopy(
                                horizontalPaddingDp: value, paddingLeft: Int32(value), paddingRight: Int32(value)))
                    }
                }
            })
    }

    func openHeaderFooterPaddingPicker(style: ReaderStylePreferences, isHeader: Bool) {
        let title = isHeader ? L10n.ReaderAppearance.paddingHeaderSection : L10n.ReaderAppearance.paddingFooterSection
        let top = isHeader ? style.headerPaddingTop : style.footerPaddingTop
        let bottom = isHeader ? style.headerPaddingBottom : style.footerPaddingBottom
        let left = isHeader ? style.headerPaddingLeft : style.footerPaddingLeft
        let right = isHeader ? style.headerPaddingRight : style.footerPaddingRight
        let options: [AndroidReaderOptionSheetViewController.Option] = [
            .init(title: "\(L10n.ReaderAppearance.paddingTop): \(L10n.ReaderAppearance.pointValue(top))", isSelected: false) {
                [weak self] in
                self?.openEdgePaddingPicker(title: L10n.ReaderAppearance.paddingTop, current: top) { value in
                    isHeader ? style.androidCopy(headerPaddingTop: value) : style.androidCopy(footerPaddingTop: value)
                }
            },
            .init(title: "\(L10n.ReaderAppearance.paddingBottom): \(L10n.ReaderAppearance.pointValue(bottom))", isSelected: false)
            { [weak self] in
                self?.openEdgePaddingPicker(title: L10n.ReaderAppearance.paddingBottom, current: bottom) { value in
                    isHeader ? style.androidCopy(headerPaddingBottom: value) : style.androidCopy(footerPaddingBottom: value)
                }
            },
            .init(title: "\(L10n.ReaderAppearance.paddingLeft): \(L10n.ReaderAppearance.pointValue(left))", isSelected: false) {
                [weak self] in
                self?.openEdgePaddingPicker(title: L10n.ReaderAppearance.paddingLeft, current: left) { value in
                    isHeader ? style.androidCopy(headerPaddingLeft: value) : style.androidCopy(footerPaddingLeft: value)
                }
            },
            .init(title: "\(L10n.ReaderAppearance.paddingRight): \(L10n.ReaderAppearance.pointValue(right))", isSelected: false) {
                [weak self] in
                self?.openEdgePaddingPicker(title: L10n.ReaderAppearance.paddingRight, current: right) { value in
                    isHeader ? style.androidCopy(headerPaddingRight: value) : style.androidCopy(footerPaddingRight: value)
                }
            },
        ]
        presentOptionSheet(title: title, height: 360, options: options)
    }

    func openTipSlotPicker(title: String, selected: Int32, style: ReaderStylePreferences, slot: AndroidReaderStyleTipSlot) {
        let options: [(Int32, String)] = [
            (0, L10n.ReaderAppearance.tipSlotNone),
            (1, L10n.ReaderAppearance.tipSlotChapterTitle),
            (2, L10n.ReaderAppearance.tipSlotTime),
            (3, L10n.ReaderAppearance.tipSlotBattery),
            (4, L10n.ReaderAppearance.tipSlotPage),
            (5, L10n.ReaderAppearance.tipSlotTotalProgress),
            (6, L10n.ReaderAppearance.tipSlotPageAndTotal),
            (7, L10n.ReaderAppearance.tipSlotBookName),
            (8, L10n.ReaderAppearance.tipSlotTimeBattery),
            (9, L10n.ReaderAppearance.tipSlotTimeBatteryPercentage),
            (10, L10n.ReaderAppearance.tipSlotBatteryPercentage),
            (11, L10n.ReaderAppearance.tipSlotTotalProgressAlt),
        ]
        presentOptionSheet(
            title: title, height: 620,
            options: options.map { value, title in
                .init(title: title, isSelected: selected == value) { [weak self] in
                    guard let self else { return }
                    let updated = style.androidCopy(settingTipSlot: slot, to: value)
                    self.runSettingTask { try await self.screen.setReaderStyle(style: updated) }
                }
            })
    }

    func openHeaderModePicker(style: ReaderStylePreferences) {
        let options: [(Int32, String)] = [
            (0, L10n.ReaderAppearance.headerModeAuto),
            (1, L10n.ReaderAppearance.headerModeShow),
            (2, L10n.ReaderAppearance.headerModeHidden),
        ]
        presentOptionSheet(
            title: L10n.ReaderAppearance.headerModePicker, height: 280,
            options: options.map { value, title in
                .init(title: title, isSelected: style.headerMode == value) { [weak self] in
                    guard let self else { return }
                    self.runSettingTask { try await self.screen.setReaderStyle(style: style.androidCopy(headerMode: value)) }
                }
            })
    }

    func openFooterModePicker(style: ReaderStylePreferences) {
        let options: [(Int32, String)] = [
            (0, L10n.ReaderAppearance.footerModeShow),
            (1, L10n.ReaderAppearance.footerModeHidden),
        ]
        presentOptionSheet(
            title: L10n.ReaderAppearance.footerModePicker, height: 230,
            options: options.map { value, title in
                .init(title: title, isSelected: style.footerMode == value) { [weak self] in
                    guard let self else { return }
                    self.runSettingTask { try await self.screen.setReaderStyle(style: style.androidCopy(footerMode: value)) }
                }
            })
    }

    func openTitleSizePicker(style: ReaderStylePreferences) {
        let values: [Float] = [0, 1, 2, 4, 6, 8, 10, 12]
        presentOptionSheet(
            title: L10n.ReaderAppearance.titleSizeTitle, height: 500,
            options: values.map { value in
                .init(title: L10n.ReaderAppearance.floatPointValue(value), isSelected: abs(style.titleSize - value) < 0.5) {
                    [weak self] in
                    guard let self else { return }
                    self.runSettingTask { try await self.screen.setReaderStyle(style: style.androidCopy(titleSize: value)) }
                }
            })
    }

    func openTitleModePicker(style: ReaderStylePreferences) {
        let options: [(Int32, String)] = [
            (0, L10n.ReaderAppearance.titleModeDefault),
            (1, L10n.ReaderAppearance.titleModeCenter),
            (2, L10n.ReaderAppearance.titleModeHidden),
        ]
        presentOptionSheet(
            title: L10n.ReaderAppearance.titleModePicker, height: 280,
            options: options.map { value, title in
                .init(title: title, isSelected: style.titleMode == value) { [weak self] in
                    guard let self else { return }
                    self.runSettingTask { try await self.screen.setReaderStyle(style: style.androidCopy(titleMode: value)) }
                }
            })
    }

    func resetCurrentPreset() {
        guard let presetName = state?.preferences.readerPresetName else { return }
        runSettingTask {
            try await self.screen.setReaderPreset(name: presetName)
            await MainActor.run { self.showTransientMessage(L10n.ReaderAppearance.resetPresetDone) }
        }
    }

    func titleModeTitle(_ value: Int32) -> String {
        value == 1
            ? L10n.ReaderAppearance.titleModeCenter
            : (value == 2 ? L10n.ReaderAppearance.titleModeHidden : L10n.ReaderAppearance.titleModeDefault)
    }

    func headerModeTitle(_ value: Int32) -> String {
        value == 1
            ? L10n.ReaderAppearance.headerModeShow
            : (value == 2 ? L10n.ReaderAppearance.headerModeHidden : L10n.ReaderAppearance.headerModeAuto)
    }

    func footerModeTitle(_ value: Int32) -> String {
        value == 1 ? L10n.ReaderAppearance.footerModeHidden : L10n.ReaderAppearance.footerModeShow
    }
}

extension AndroidReaderStyleSheetViewController {
    func openEdgePaddingPicker(title: String, current: Int32, buildStyle: @escaping (Int32) -> ReaderStylePreferences) {
        let values: [Int32] = [0, 4, 6, 8, 12, 16, 24, 32, 40]
        presentOptionSheet(
            title: title, height: 460,
            options: values.map { value in
                .init(title: L10n.ReaderAppearance.pointValue(value), isSelected: current == value) { [weak self] in
                    guard let self else { return }
                    self.runSettingTask { try await self.screen.setReaderStyle(style: buildStyle(value)) }
                }
            })
    }
}

extension ReaderStylePreferences {
    func androidCopy(settingTipSlot slot: AndroidReaderStyleTipSlot, to value: Int32) -> ReaderStylePreferences {
        let none: Int32 = 0
        var headerLeft = tipHeaderLeft
        var headerMiddle = tipHeaderMiddle
        var headerRight = tipHeaderRight
        var footerLeft = tipFooterLeft
        var footerMiddle = tipFooterMiddle
        var footerRight = tipFooterRight

        if value != none {
            if headerLeft == value { headerLeft = none }
            if headerMiddle == value { headerMiddle = none }
            if headerRight == value { headerRight = none }
            if footerLeft == value { footerLeft = none }
            if footerMiddle == value { footerMiddle = none }
            if footerRight == value { footerRight = none }
        }

        switch slot {
        case .headerLeft:
            headerLeft = value
        case .headerMiddle:
            headerMiddle = value
        case .headerRight:
            headerRight = value
        case .footerLeft:
            footerLeft = value
        case .footerMiddle:
            footerMiddle = value
        case .footerRight:
            footerRight = value
        }

        return androidCopy(
            tipHeaderLeft: headerLeft,
            tipHeaderMiddle: headerMiddle,
            tipHeaderRight: headerRight,
            tipFooterLeft: footerLeft,
            tipFooterMiddle: footerMiddle,
            tipFooterRight: footerRight
        )
    }
}
