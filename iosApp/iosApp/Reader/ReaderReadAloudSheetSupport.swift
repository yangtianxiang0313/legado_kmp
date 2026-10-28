import shared
import SnapKit
import Then
import UIKit

enum ReaderReadAloudSheetSupport {
    static let maximumSpeechRateSliderValue: Float = 45

    static func clampedSpeechRateSliderValue(_ value: Float) -> Float {
        min(max(value.rounded(), 0), maximumSpeechRateSliderValue)
    }

    static func updatedConfig(
        _ config: ReaderRuntimeConfig,
        followSystemRate: Bool? = nil,
        speechRate: Float? = nil,
        timerMinutes: Int? = nil,
        voiceIdentifier: String?? = nil
    ) -> ReaderRuntimeConfig {
        ReaderRuntimeConfig(
            brightnessDay: config.brightnessDay,
            brightnessNight: config.brightnessNight,
            pageAnimation: config.pageAnimation,
            shareLayout: config.shareLayout,
            readStyleIndex: config.readStyleIndex,
            comicStyleIndex: config.comicStyleIndex,
            autoReadSpeed: config.autoReadSpeed,
            ttsFollowSystemRate: followSystemRate ?? config.ttsFollowSystemRate,
            ttsSpeechRate: speechRate.map { Int32(clampedSpeechRateSliderValue($0)) } ?? config.ttsSpeechRate,
            ttsTimerMinutes: timerMinutes.map { Int32(min(max($0, 0), 180)) } ?? config.ttsTimerMinutes,
            ttsVoiceIdentifier: voiceIdentifier ?? config.ttsVoiceIdentifier,
            textFullJustify: config.textFullJustify,
            textBottomJustify: config.textBottomJustify,
            hideStatusBar: config.hideStatusBar,
            hideNavigationBar: config.hideNavigationBar,
            chineseMode: config.chineseMode,
            tapZoneActions: config.tapZoneActions,
            useZhLayout: config.useZhLayout,
            readBodyToLh: config.readBodyToLh,
            isComic: config.isComic
        )
    }

    static func voiceOptions(
        _ voices: [ReaderReadAloudVoiceOption],
        selectedIdentifier: String?,
        onSelect: @escaping (String?) -> Void
    ) -> [AndroidReaderOptionSheetViewController.Option] {
        let selectedIdentifier = selectedIdentifier?.nilIfEmpty
        return [
            .init(title: L10n.Reader.readAloudVoiceSystemDefault, isSelected: selectedIdentifier == nil) {
                onSelect(nil)
            },
        ] + voices.map { voice in
            .init(title: voice.displayName, isSelected: voice.identifier == selectedIdentifier) {
                onSelect(voice.identifier)
            }
        }
    }

    static func timerOptions(
        selectedMinutes: Int,
        onSelect: @escaping (Int) -> Void
    ) -> [AndroidReaderOptionSheetViewController.Option] {
        [0, 5, 10, 15, 30, 60, 90, 180].map { minutes in
            .init(title: L10n.Reader.readAloudTimerMinutes(minutes), isSelected: minutes == selectedMinutes) {
                onSelect(minutes)
            }
        }
    }

    static func optionSheetHeight(optionCount: Int) -> CGFloat {
        let contentHeight: CGFloat = 96 + CGFloat(optionCount) * 54 + CGFloat(max(optionCount - 1, 0)) * 10
        return min(max(contentHeight, 260), 640)
    }

    static func playbackFeedback(state: ReadAloudState?, canReadCurrentContent: Bool) -> String? {
        switch state?.status {
        case .error:
            if let message = state?.message?.nilIfEmpty {
                return "朗读失败：\(message)"
            }
            return "朗读失败，请重试"
        case .running:
            return "朗读进行中"
        case .paused:
            return "朗读已暂停"
        case .stopped:
            return state?.message == "Read aloud chapter completed" ? "本章朗读已结束" : "朗读已停止"
        default:
            return canReadCurrentContent ? nil : "当前章节没有可朗读内容"
        }
    }

    static func cardSection(content: UIView) -> UIView {
        UIView().then { container in
            container.backgroundColor = AndroidReplicaTheme.menuBackground
            container.layer.cornerRadius = 8
            container.addSubview(content)
            content.snp.makeConstraints { $0.edges.equalToSuperview().inset(AppUI.Spacing.small) }
        }
    }

    static func flatSection(content: UIView, verticalInset: CGFloat = 5) -> UIView {
        UIView().then { container in
            container.addSubview(content)
            content.snp.makeConstraints {
                $0.edges.equalToSuperview().inset(UIEdgeInsets(top: verticalInset, left: 0, bottom: verticalInset, right: 0))
            }
        }
    }

    static func labeledSection(title: String, content: UIView, spacing: CGFloat = AppUI.Spacing.small) -> UIView {
        let metadata = sectionMetadata(for: title)
        let titleLabel = UILabel().then {
            $0.font = .systemFont(ofSize: 12, weight: .medium)
            $0.textColor = AndroidReplicaTheme.secondaryText
            $0.text = title
            $0.accessibilityIdentifier = metadata?.titleIdentifier
            $0.adjustsFontForContentSizeCategory = true
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.82
        }
        if let metadata {
            content.accessibilityIdentifier = content.accessibilityIdentifier ?? metadata.contentIdentifier
            content.accessibilityLabel = content.accessibilityLabel ?? metadata.contentLabel
            content.accessibilityHint = content.accessibilityHint ?? metadata.contentHint
        }
        if title == L10n.Reader.readAloudTimerPreset {
            configureTimerControls(in: content)
        }
        return UIStackView(arrangedSubviews: [titleLabel, content]).then {
            $0.axis = .vertical
            $0.spacing = spacing
            $0.accessibilityIdentifier = metadata?.sectionIdentifier
        }
    }

    static func inlineTextButton(title: String, handler: @escaping () -> Void) -> UIButton {
        let metadata = inlineButtonMetadata(for: title)
        return UIButton(type: .system).then {
            var configuration = UIButton.Configuration.plain()
            configuration.title = title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)
            configuration.titleLineBreakMode = .byTruncatingTail
            configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                    for: .systemFont(ofSize: 12, weight: .medium)
                )
                return outgoing
            }
            $0.configuration = configuration
            $0.titleLabel?.adjustsFontForContentSizeCategory = true
            $0.titleLabel?.adjustsFontSizeToFitWidth = true
            $0.titleLabel?.minimumScaleFactor = 0.8
            $0.accessibilityIdentifier = metadata?.identifier
            $0.accessibilityLabel = metadata?.label ?? title
            $0.accessibilityHint = metadata?.hint
            $0.addAction(UIAction { _ in handler() }, for: .touchUpInside)
        }
    }

    static func toggleRow(title: String, toggle: UISwitch) -> UIView {
        let metadata = toggleMetadata(for: title)
        let titleLabel = UILabel().then {
            $0.text = title
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.accessibilityIdentifier = metadata?.titleIdentifier
            $0.adjustsFontForContentSizeCategory = true
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.82
        }
        if let metadata {
            toggle.accessibilityIdentifier = toggle.accessibilityIdentifier ?? metadata.toggleIdentifier
            toggle.accessibilityLabel = metadata.label
            toggle.accessibilityHint = metadata.hint
        }
        return UIStackView(arrangedSubviews: [titleLabel, UIView(), toggle]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = AppUI.Spacing.small
            $0.accessibilityIdentifier = metadata?.rowIdentifier
        }
    }

    static func sliderRow(title: String, slider: UISlider, valueLabel: UILabel) -> UIView {
        let metadata = sliderMetadata(for: title)
        let titleLabel = UILabel().then {
            $0.text = title
            $0.font = .preferredFont(forTextStyle: .subheadline)
            $0.accessibilityIdentifier = metadata?.titleIdentifier
            $0.adjustsFontForContentSizeCategory = true
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.82
        }
        if let metadata {
            slider.accessibilityIdentifier = slider.accessibilityIdentifier ?? metadata.sliderIdentifier
            slider.accessibilityLabel = metadata.label
            slider.accessibilityHint = metadata.hint
            valueLabel.accessibilityIdentifier = metadata.valueIdentifier
            valueLabel.accessibilityLabel = metadata.valueLabel
        }
        valueLabel.textAlignment = .right
        valueLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.78
        let labels = UIStackView(arrangedSubviews: [titleLabel, UIView(), valueLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = AppUI.Spacing.small
        }
        return UIStackView(arrangedSubviews: [labels, slider]).then {
            $0.axis = .vertical
            $0.spacing = AppUI.Spacing.small
            $0.accessibilityIdentifier = metadata?.rowIdentifier
        }
    }

    private struct SectionMetadata {
        let sectionIdentifier: String
        let titleIdentifier: String
        let contentIdentifier: String?
        let contentLabel: String
        let contentHint: String?
    }

    private struct InlineButtonMetadata {
        let identifier: String
        let label: String
        let hint: String
    }

    private struct ToggleMetadata {
        let rowIdentifier: String
        let titleIdentifier: String
        let toggleIdentifier: String
        let label: String
        let hint: String
    }

    private struct SliderMetadata {
        let rowIdentifier: String
        let titleIdentifier: String
        let sliderIdentifier: String
        let valueIdentifier: String
        let label: String
        let valueLabel: String
        let hint: String
    }

    private static func sectionMetadata(for title: String) -> SectionMetadata? {
        switch title {
        case L10n.Reader.readAloudVoiceTitle:
            return SectionMetadata(
                sectionIdentifier: UIIdentifiers.Reader.readAloudVoiceSection,
                titleIdentifier: "\(UIIdentifiers.Reader.readAloudVoiceSection).title",
                contentIdentifier: UIIdentifiers.Reader.readAloudVoiceButton,
                contentLabel: L10n.Reader.readAloudVoiceTitle,
                contentHint: L10n.Reader.readAloudVoicePickerHint
            )
        case L10n.Reader.readAloudFollowSystem:
            return SectionMetadata(
                sectionIdentifier: UIIdentifiers.Reader.readAloudFollowSystemSection,
                titleIdentifier: "\(UIIdentifiers.Reader.readAloudFollowSystemSection).title",
                contentIdentifier: nil,
                contentLabel: L10n.Reader.readAloudFollowSystem,
                contentHint: L10n.Reader.readAloudFollowSystemHint
            )
        case L10n.Reader.readAloudTimerPreset:
            return SectionMetadata(
                sectionIdentifier: UIIdentifiers.Reader.readAloudTimerSection,
                titleIdentifier: "\(UIIdentifiers.Reader.readAloudTimerSection).title",
                contentIdentifier: "\(UIIdentifiers.Reader.readAloudTimerSection).row",
                contentLabel: L10n.Reader.readAloudTimerPreset,
                contentHint: L10n.Reader.readAloudTimerPresetHint
            )
        default:
            return nil
        }
    }

    private static func inlineButtonMetadata(for title: String) -> InlineButtonMetadata? {
        switch title {
        case L10n.Reader.menuPrevious:
            return InlineButtonMetadata(
                identifier: UIIdentifiers.Reader.readAloudPreviousChapterButton,
                label: L10n.Reader.menuPrevious,
                hint: L10n.Reader.readAloudPreviousChapterHint
            )
        case L10n.Reader.menuNext:
            return InlineButtonMetadata(
                identifier: UIIdentifiers.Reader.readAloudNextChapterButton,
                label: L10n.Reader.menuNext,
                hint: L10n.Reader.readAloudNextChapterHint
            )
        case L10n.Reader.readAloudTimerOff:
            return InlineButtonMetadata(
                identifier: UIIdentifiers.Reader.readAloudTimerPresetButton,
                label: L10n.Reader.readAloudTimerPreset,
                hint: L10n.Reader.readAloudTimerPresetHint
            )
        default:
            return nil
        }
    }

    private static func toggleMetadata(for title: String) -> ToggleMetadata? {
        guard title == L10n.Reader.readAloudFollowSystem else { return nil }
        return ToggleMetadata(
            rowIdentifier: "\(UIIdentifiers.Reader.readAloudFollowSystemSection).row",
            titleIdentifier: "\(UIIdentifiers.Reader.readAloudFollowSystemSection).row.title",
            toggleIdentifier: UIIdentifiers.Reader.readAloudFollowSystemSwitch,
            label: L10n.Reader.readAloudFollowSystem,
            hint: L10n.Reader.readAloudFollowSystemHint
        )
    }

    private static func sliderMetadata(for title: String) -> SliderMetadata? {
        switch title {
        case L10n.Reader.readAloudManualRate:
            return SliderMetadata(
                rowIdentifier: UIIdentifiers.Reader.readAloudRateSection,
                titleIdentifier: "\(UIIdentifiers.Reader.readAloudRateSection).title",
                sliderIdentifier: UIIdentifiers.Reader.readAloudRateSlider,
                valueIdentifier: UIIdentifiers.Reader.readAloudRateValueLabel,
                label: L10n.Reader.readAloudManualRate,
                valueLabel: L10n.Reader.readAloudManualRate,
                hint: L10n.Reader.readAloudRateSliderHint
            )
        case L10n.Reader.readAloudPitchTitle:
            return SliderMetadata(
                rowIdentifier: UIIdentifiers.Reader.readAloudPitchSection,
                titleIdentifier: "\(UIIdentifiers.Reader.readAloudPitchSection).title",
                sliderIdentifier: UIIdentifiers.Reader.readAloudPitchSlider,
                valueIdentifier: UIIdentifiers.Reader.readAloudPitchValueLabel,
                label: L10n.Reader.readAloudPitchTitle,
                valueLabel: L10n.Reader.readAloudPitchTitle,
                hint: L10n.Reader.readAloudPitchSliderHint
            )
        default:
            return nil
        }
    }

    private static func configureTimerControls(in view: UIView) {
        descendantViews(of: view).forEach { descendant in
            if let slider = descendant as? UISlider {
                slider.accessibilityIdentifier = slider.accessibilityIdentifier ?? UIIdentifiers.Reader.readAloudTimerSlider
                slider.accessibilityLabel = L10n.Reader.readAloudTimerDrag
                slider.accessibilityHint = L10n.Reader.readAloudTimerSliderHint
            } else if let button = descendant as? UIButton,
                      button.accessibilityIdentifier == nil,
                      button.configuration?.title?.isEmpty != false {
                button.accessibilityIdentifier = UIIdentifiers.Reader.readAloudTimerIconButton
                button.accessibilityLabel = L10n.Reader.readAloudTimerPreset
                button.accessibilityHint = L10n.Reader.readAloudTimerPresetHint
            }
        }
    }

    private static func descendantViews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { descendantViews(of: $0) }
    }
}

struct ReaderReadAloudSheetAvailability: Equatable {
    let chapterIndex: Int
    let chapterCount: Int
    private let blockIndexes: [Int]

    init(chapterIndex: Int, chapterCount: Int, blocks: [ReaderContentBlock]) {
        self.chapterIndex = chapterIndex
        self.chapterCount = chapterCount
        blockIndexes = blocks.map { Int($0.blockIndex) }.sorted()
    }

    var canReadCurrentContent: Bool { blockIndexes.isEmpty == false }
    var canPreviousChapter: Bool { chapterIndex > 0 }
    var canNextChapter: Bool { chapterIndex < chapterCount - 1 }

    func paragraphBounds(state: ReadAloudState?) -> (previous: Bool, next: Bool) {
        guard state?.status == .running || state?.status == .paused,
              let progress = state?.progress,
              Int(progress.chapterIndex) == chapterIndex,
              let position = blockIndexes.firstIndex(of: Int(progress.blockIndex))
        else { return (false, false) }
        return (position > 0, position < blockIndexes.count - 1)
    }
}
