import shared
import SnapKit
import Then
import UIKit

final class ReaderReadAloudSheetViewController: UIViewController {
    private var state: ReadAloudState?
    private var availability: ReaderReadAloudSheetAvailability
    private var readerConfig: ReaderRuntimeConfig
    private let voiceOptions: [ReaderReadAloudVoiceOption]
    private let onTogglePlayPause: () -> Void
    private let onPreviousParagraph: () -> Void
    private let onNextParagraph: () -> Void
    private let onPreviousChapter: () -> Void
    private let onNextChapter: () -> Void
    private let onStop: () -> Void
    private let onOpenChapterList: () -> Void
    private let onOpenMainMenu: () -> Void
    private let onOpenSettings: () -> Void
    private let onUpdateVoice: (String?) -> Void
    private let onSetBackgroundPlayback: (Bool) -> Void
    private let onUpdateSpeechRate: (Bool, Float) -> Void
    private let onUpdatePitch: (Float) -> Void
    private let onUpdateTimer: (Int) -> Void
    private let currentPitch: Float
    private var navigationFeedbackPending = false
    private let scrollView = UIScrollView().then {
        $0.alwaysBounceVertical = true
    }

    private let stackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = 10
        $0.alignment = .fill
    }

    private let playPauseButton = UIButton(type: .system)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let stopButton = UIButton(type: .system)
    private let backgroundButton = UIButton(type: .system)
    private let followSystemSwitch = UISwitch()
    private let rateSlider = UISlider()
    private let pitchSlider = UISlider()
    private let timerSlider = UISlider()
    private let rateValueLabel = UILabel()
    private let pitchValueLabel = UILabel()
    private let timerValueLabel = UILabel()
    private let feedbackLabel = UILabel()
    private let voiceButton = UIButton(type: .system)
    private lazy var previousChapterButton = makeInlineTextButton(title: L10n.Reader.menuPrevious) { [weak self] in
        self?.performChapterNavigation(previous: true)
    }

    private lazy var nextChapterButton = makeInlineTextButton(title: L10n.Reader.menuNext) { [weak self] in
        self?.performChapterNavigation(previous: false)
    }

    private lazy var timerPresetButton = makeInlineTextButton(title: L10n.Reader.readAloudTimerMinutes(0)) { [weak self] in
        self?.presentTimerPresetPicker()
    }

    init(
        state: ReadAloudState?,
        readerConfig: ReaderRuntimeConfig,
        voiceOptions: [ReaderReadAloudVoiceOption],
        onTogglePlayPause: @escaping () -> Void,
        onPreviousParagraph: @escaping () -> Void,
        onNextParagraph: @escaping () -> Void,
        onPreviousChapter: @escaping () -> Void,
        onNextChapter: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onOpenChapterList: @escaping () -> Void,
        onOpenMainMenu: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void,
        onUpdateVoice: @escaping (String?) -> Void,
        onSetBackgroundPlayback: @escaping (Bool) -> Void,
        onUpdateSpeechRate: @escaping (Bool, Float) -> Void,
        onUpdatePitch: @escaping (Float) -> Void,
        onUpdateTimer: @escaping (Int) -> Void,
        currentPitch: Float = 1.0,
        availability: ReaderReadAloudSheetAvailability
    ) {
        self.state = state
        self.availability = availability
        self.readerConfig = readerConfig
        self.voiceOptions = voiceOptions
        self.onTogglePlayPause = onTogglePlayPause
        self.onPreviousParagraph = onPreviousParagraph
        self.onNextParagraph = onNextParagraph
        self.onPreviousChapter = onPreviousChapter
        self.onNextChapter = onNextChapter
        self.onStop = onStop
        self.onOpenChapterList = onOpenChapterList
        self.onOpenMainMenu = onOpenMainMenu
        self.onOpenSettings = onOpenSettings
        self.onUpdateVoice = onUpdateVoice
        self.onSetBackgroundPlayback = onSetBackgroundPlayback
        self.onUpdateSpeechRate = onUpdateSpeechRate
        self.onUpdatePitch = onUpdatePitch
        self.onUpdateTimer = onUpdateTimer
        self.currentPitch = currentPitch
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: ReadAloudState?) {
        let previous = self.state
        self.state = state
        guard isViewLoaded else { return }
        let statusChanged = previous?.status != state?.status
        let errorChanged = state?.status == .error && previous?.message != state?.message
        let paragraphChanged = previous?.progress.chapterIndex != state?.progress.chapterIndex
            || previous?.progress.blockIndex != state?.progress.blockIndex
        let backgroundChanged = previous?.isBackgroundPlaybackEnabled != state?.isBackgroundPlaybackEnabled
        if statusChanged || paragraphChanged {
            refreshPlaybackControls()
        }
        if backgroundChanged {
            refreshBackgroundButton()
        }
        // Range/rate/timer updates must not replace configuration feedback or reset sliders.
        if statusChanged || errorChanged || (navigationFeedbackPending && paragraphChanged) {
            setFeedback(playbackFeedbackText())
        } else if backgroundChanged {
            setFeedback(state?.isBackgroundPlaybackEnabled == true ? "已允许后台播放" : "已关闭后台播放")
        }
    }

    func update(availability: ReaderReadAloudSheetAvailability) {
        let previous = self.availability
        guard previous != availability else { return }
        self.availability = availability
        guard isViewLoaded else { return }
        refreshPlaybackControls()
        refreshChapterControls()
        if navigationFeedbackPending && previous.chapterIndex != availability.chapterIndex {
            setFeedback("已切换章节")
        } else if previous.canReadCurrentContent != availability.canReadCurrentContent,
                  state?.status != .running, state?.status != .paused {
            setFeedback(playbackFeedbackText())
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Reader.menuReadAloud
        view.backgroundColor = AndroidReplicaTheme.background
        preferredContentSize = CGSize(width: 0, height: 620)
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        scrollView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }
        stackView.snp.makeConstraints { make in
            make.edges.equalTo(scrollView.contentLayoutGuide).inset(AppUI.Spacing.large)
            make.width.equalTo(scrollView.frameLayoutGuide).offset(-AppUI.Spacing.large * 2)
        }

        configureButton(
            playPauseButton,
            title: currentPlayPauseVisualTitle(),
            accessibilityLabel: currentPlayPauseTitle(),
            systemImage: playPauseSystemImage(),
            identifier: UIIdentifiers.Reader.readAloudPlayPauseButton,
            isProminent: true
        ) { [weak self] in
            self?.performPlayPause()
        }
        configureButton(
            previousButton,
            title: L10n.Reader.readAloudPrevParagraphShort,
            accessibilityLabel: L10n.Reader.readAloudPrevParagraph,
            systemImage: "backward.end.fill",
            identifier: UIIdentifiers.Reader.readAloudPreviousParagraphButton
        ) { [weak self] in
            self?.performParagraphSkip(previous: true)
        }
        configureButton(
            nextButton,
            title: L10n.Reader.readAloudNextParagraphShort,
            accessibilityLabel: L10n.Reader.readAloudNextParagraph,
            systemImage: "forward.end.fill",
            identifier: UIIdentifiers.Reader.readAloudNextParagraphButton
        ) { [weak self] in
            self?.performParagraphSkip(previous: false)
        }
        configureButton(
            stopButton,
            title: L10n.Reader.readAloudStopShort,
            accessibilityLabel: L10n.Reader.readAloudStop,
            systemImage: "stop.fill",
            identifier: UIIdentifiers.Reader.readAloudStopButton
        ) { [weak self] in
            self?.performStop()
        }
        configureButton(backgroundButton, title: L10n.Reader.readAloudBackground, systemImage: "arrow.down.circle", identifier: UIIdentifiers.Reader.readAloudBackgroundButton) { [weak self] in
            guard let self else { return }
            self.onSetBackgroundPlayback(self.state?.isBackgroundPlaybackEnabled != true)
        }

        let paragraphControlRow = UIStackView.readerCompactRow(
            [previousButton, playPauseButton, stopButton, nextButton],
            spacing: AppUI.Spacing.small
        ).then {
            $0.alignment = .fill
        }
        let chapterRow = UIStackView(arrangedSubviews: [previousChapterButton, paragraphControlRow, nextChapterButton]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = AppUI.Spacing.medium
        }
        previousChapterButton.setContentHuggingPriority(.required, for: .horizontal)
        nextChapterButton.setContentHuggingPriority(.required, for: .horizontal)
        previousChapterButton.snp.makeConstraints { make in
            make.width.equalTo(58)
        }
        nextChapterButton.snp.makeConstraints { make in
            make.width.equalTo(58)
        }
        paragraphControlRow.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let timerIconButton = ReaderCompactActionButton(title: "", systemImage: "timer") { [weak self] in
            self?.presentTimerPresetPicker()
        }
        timerIconButton.snp.makeConstraints { make in
            make.width.equalTo(52)
        }
        let timerRow = UIStackView(arrangedSubviews: [
            timerIconButton,
            timerSlider,
            timerPresetButton,
        ]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = AppUI.Spacing.small
        }
        timerPresetButton.setContentHuggingPriority(.required, for: .horizontal)
        timerSlider.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let speechRateSection = UIStackView(arrangedSubviews: [
            ReaderReadAloudSheetSupport.labeledSection(title: L10n.Reader.readAloudFollowSystem, content: makeToggleRow()),
            ReaderReadAloudSheetSupport.sliderRow(title: L10n.Reader.readAloudManualRate, slider: rateSlider, valueLabel: rateValueLabel),
        ]).then {
            $0.axis = .vertical
            $0.spacing = AppUI.Spacing.small
        }
        let voiceAndPitchSection = UIStackView(arrangedSubviews: [
            makeVoiceRow(),
            ReaderReadAloudSheetSupport.sliderRow(title: L10n.Reader.readAloudPitchTitle, slider: pitchSlider, valueLabel: pitchValueLabel),
        ]).then {
            $0.axis = .vertical
            $0.spacing = AppUI.Spacing.small
        }
        let tocButton = ReaderCompactActionButton(title: L10n.Reader.menuToc, systemImage: "list.bullet") { [weak self] in
            self?.dismiss(animated: true) {
                self?.onOpenChapterList()
            }
        }
        tocButton.accessibilityIdentifier = UIIdentifiers.Reader.readAloudTocButton
        let mainMenuButton = ReaderCompactActionButton(title: L10n.Reader.mainMenuTitle, systemImage: "menucard") { [weak self] in
            self?.dismiss(animated: true) {
                self?.onOpenMainMenu()
            }
        }
        mainMenuButton.accessibilityIdentifier = UIIdentifiers.Reader.readAloudMainMenuButton
        let settingsButton = ReaderCompactActionButton(title: L10n.Reader.readAloudSettings, systemImage: "gearshape") { [weak self] in
            self?.dismiss(animated: true) {
                self?.onOpenSettings()
            }
        }
        settingsButton.accessibilityIdentifier = UIIdentifiers.Reader.readAloudSettingsButton
        let quickActions = UIStackView.readerCompactRow([
            tocButton,
            mainMenuButton,
            backgroundButton,
            settingsButton,
        ])
        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.textColor = AndroidReplicaTheme.secondaryText
        feedbackLabel.textAlignment = .center
        feedbackLabel.numberOfLines = 2
        [
            makeFlatSection(content: chapterRow),
            makeFlatSection(content: ReaderReadAloudSheetSupport.labeledSection(title: L10n.Reader.readAloudTimerPreset, content: timerRow)),
            makeCardSection(content: speechRateSection),
            makeFlatSection(content: quickActions, verticalInset: 2),
            feedbackLabel,
            makeCardSection(content: voiceAndPitchSection),
        ].forEach(stackView.addArrangedSubview)

        configureControls()
        setFeedback(playbackFeedbackText())
    }

    private func configureControls() {
        followSystemSwitch.isOn = readerConfig.ttsFollowSystemRate
        followSystemSwitch.accessibilityIdentifier = UIIdentifiers.Reader.readAloudFollowSystemSwitch
        followSystemSwitch.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            let rateValue = Self.clampedSpeechRateSliderValue(self.rateSlider.value)
            self.rateSlider.value = rateValue
            let timerMinutes = min(max(Int(self.timerSlider.value.rounded()), 0), 180)
            self.timerSlider.value = Float(timerMinutes)
            self.onUpdateSpeechRate(self.followSystemSwitch.isOn, rateValue)
            self.readerConfig = ReaderReadAloudSheetSupport.updatedConfig(
                self.readerConfig,
                followSystemRate: self.followSystemSwitch.isOn,
                speechRate: rateValue,
                timerMinutes: timerMinutes
            )
            self.refreshRateState()
            self.setFeedback(self.followSystemSwitch.isOn ? "已跟随系统语速" : "已保存手动语速")
        }), for: .valueChanged)

        rateSlider.minimumValue = 0
        rateSlider.maximumValue = ReaderReadAloudSheetSupport.maximumSpeechRateSliderValue
        rateSlider.value = Self.clampedSpeechRateSliderValue(Float(readerConfig.ttsSpeechRate))
        rateSlider.accessibilityIdentifier = UIIdentifiers.Reader.readAloudRateSlider
        rateSlider.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            let value = Self.clampedSpeechRateSliderValue(self.rateSlider.value)
            self.rateSlider.value = value
            self.readerConfig = ReaderReadAloudSheetSupport.updatedConfig(self.readerConfig, speechRate: value)
            self.onUpdateSpeechRate(self.followSystemSwitch.isOn, value)
            self.rateValueLabel.text = self.rateValueText()
            self.setFeedback("语速已保存")
        }), for: .valueChanged)

        pitchSlider.minimumValue = 0.5
        pitchSlider.maximumValue = 2.0
        pitchSlider.value = min(max(currentPitch, pitchSlider.minimumValue), pitchSlider.maximumValue)
        pitchValueLabel.text = pitchValueText()
        pitchSlider.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            let value = min(max(self.pitchSlider.value, self.pitchSlider.minimumValue), self.pitchSlider.maximumValue)
            self.pitchSlider.value = value
            self.onUpdatePitch(value)
            self.pitchValueLabel.text = self.pitchValueText()
            self.setFeedback("音调已保存")
        }), for: .valueChanged)

        timerSlider.minimumValue = 0
        timerSlider.maximumValue = 180
        timerSlider.value = min(max(Float(readerConfig.ttsTimerMinutes), 0), 180)
        timerSlider.accessibilityIdentifier = UIIdentifiers.Reader.readAloudTimerSlider
        timerSlider.addAction(UIAction(handler: { [weak self] _ in
            guard let self else { return }
            let minutes = min(max(Int(self.timerSlider.value.rounded()), 0), 180)
            self.timerSlider.value = Float(minutes)
            self.readerConfig = ReaderReadAloudSheetSupport.updatedConfig(self.readerConfig, timerMinutes: minutes)
            self.onUpdateTimer(minutes)
            self.updateTimerValue(minutes)
            self.setFeedback(minutes == 0 ? "已关闭定时停止" : "定时停止已保存")
        }), for: .valueChanged)

        refreshRateState()
        refreshBackgroundButton()
        refreshVoiceButton()
        refreshPlaybackControls()
        refreshChapterControls()
    }

    private func makeCardSection(content: UIView) -> UIView {
        ReaderReadAloudSheetSupport.cardSection(content: content)
    }

    private func makeFlatSection(content: UIView, verticalInset: CGFloat = 5) -> UIView {
        ReaderReadAloudSheetSupport.flatSection(content: content, verticalInset: verticalInset)
    }

    private func configureButton(
        _ button: UIButton,
        title: String,
        accessibilityLabel: String? = nil,
        systemImage: String,
        identifier: String,
        isProminent: Bool = false,
        action: @escaping () -> Void
    ) {
        var configuration: UIButton.Configuration = isProminent ? .filled() : .plain()
        configuration.title = title
        configuration.image = UIImage(systemName: systemImage)
        configuration.imagePlacement = .top
        configuration.imagePadding = 5
        configuration.cornerStyle = .medium
        configuration.baseForegroundColor = isProminent ? AndroidReplicaTheme.accent : .label
        configuration.baseBackgroundColor = isProminent ? AndroidReplicaTheme.accent.withAlphaComponent(0.14) : nil
        configuration.titleLineBreakMode = .byTruncatingTail
        configuration.contentInsets = NSDirectionalEdgeInsets(top: isProminent ? 10 : 8, leading: 6, bottom: isProminent ? 10 : 8, trailing: 6)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
                for: .systemFont(ofSize: isProminent ? 12 : 11, weight: .medium)
            )
            return outgoing
        }
        button.configuration = configuration
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = accessibilityLabel ?? title
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.8
        button.titleLabel?.numberOfLines = 2
        button.titleLabel?.textAlignment = .center
        button.addAction(UIAction(handler: { _ in action() }), for: .touchUpInside)
    }

    private func makeInlineTextButton(title: String, handler: @escaping () -> Void) -> UIButton {
        ReaderReadAloudSheetSupport.inlineTextButton(title: title, handler: handler)
    }

    private static func clampedSpeechRateSliderValue(_ value: Float) -> Float {
        ReaderReadAloudSheetSupport.clampedSpeechRateSliderValue(value)
    }

    private func performPlayPause() {
        guard availability.canReadCurrentContent || state?.status == .running else {
            setFeedback("当前章节没有可朗读内容")
            return
        }
        onTogglePlayPause()
    }

    private func performStop() {
        guard state?.status == .running || state?.status == .paused else {
            setFeedback("朗读尚未开始")
            return
        }
        onStop()
    }

    private func performParagraphSkip(previous: Bool) {
        guard state?.status == .running || state?.status == .paused else {
            setFeedback("朗读尚未开始")
            return
        }
        guard availability.canReadCurrentContent else {
            setFeedback("当前章节没有可朗读内容")
            return
        }
        let bounds = availability.paragraphBounds(state: state)
        if previous, bounds.previous == false {
            setFeedback("已经是本章第一段")
            return
        }
        if previous == false, bounds.next == false {
            setFeedback("已经是本章最后一段")
            return
        }
        setFeedback(previous ? "正在切换到上一段" : "正在切换到下一段")
        navigationFeedbackPending = true
        previous ? onPreviousParagraph() : onNextParagraph()
    }

    private func performChapterNavigation(previous: Bool) {
        if previous, availability.canPreviousChapter == false {
            setFeedback("已经是第一章")
            return
        }
        if previous == false, availability.canNextChapter == false {
            setFeedback("已经是最后一章")
            return
        }
        setFeedback(previous ? "正在切换上一章" : "正在切换下一章")
        navigationFeedbackPending = true
        previous ? onPreviousChapter() : onNextChapter()
    }

    private func makeVoiceRow() -> UIView {
        voiceButton.configuration = .bordered()
        voiceButton.configuration?.cornerStyle = .medium
        voiceButton.configuration?.titleLineBreakMode = .byTruncatingTail
        voiceButton.accessibilityIdentifier = UIIdentifiers.Reader.readAloudVoiceButton
        voiceButton.titleLabel?.adjustsFontForContentSizeCategory = true
        voiceButton.titleLabel?.adjustsFontSizeToFitWidth = true
        voiceButton.titleLabel?.minimumScaleFactor = 0.78
        voiceButton.addAction(UIAction { [weak self] _ in
            self?.presentVoicePicker()
        }, for: .touchUpInside)
        return ReaderReadAloudSheetSupport.labeledSection(title: L10n.Reader.readAloudVoiceTitle, content: voiceButton)
    }

    private func makeToggleRow() -> UIView {
        ReaderReadAloudSheetSupport.toggleRow(title: L10n.Reader.readAloudFollowSystem, toggle: followSystemSwitch)
    }

    private func currentPlayPauseTitle() -> String {
        switch state?.status {
        case .running:
            return L10n.Reader.readAloudPause
        case .paused:
            return L10n.Reader.readAloudResume
        default:
            return "开始朗读"
        }
    }

    private func currentPlayPauseVisualTitle() -> String {
        switch state?.status {
        case .running:
            return L10n.Reader.readAloudPauseShort
        case .paused:
            return L10n.Reader.readAloudResumeShort
        default:
            return L10n.Reader.readAloudStartShort
        }
    }

    private func playPauseSystemImage() -> String {
        switch state?.status {
        case .running:
            return "pause.fill"
        default:
            return "play.fill"
        }
    }

    private func refreshRateState() {
        rateSlider.isEnabled = !followSystemSwitch.isOn
        rateSlider.alpha = rateSlider.isEnabled ? 1 : 0.45
        rateValueLabel.text = rateValueText()
        updateTimerValue(Int(timerSlider.value.rounded()))
    }

    private func rateValueText() -> String {
        if followSystemSwitch.isOn {
            return L10n.Reader.readAloudFollowSystem
        }
        return String(format: "%.1fx", (rateSlider.value + 5) / 10)
    }

    private func pitchValueText() -> String {
        return String(format: "%.1fx", pitchSlider.value)
    }

    private func refreshBackgroundButton() {
        let enabled = state?.isBackgroundPlaybackEnabled == true
        backgroundButton.configuration?.title = enabled ? L10n.Reader.readAloudBackgroundPlaying : L10n.Reader.readAloudBackground
        backgroundButton.configuration?.image = UIImage(systemName: enabled ? "arrow.down.circle.fill" : "arrow.down.circle")
        backgroundButton.accessibilityLabel = backgroundButton.configuration?.title
    }

    private func refreshPlaybackControls() {
        let isActive = state?.status == .running || state?.status == .paused
        playPauseButton.isEnabled = availability.canReadCurrentContent || state?.status == .running
        playPauseButton.alpha = playPauseButton.isEnabled ? 1 : 0.42
        playPauseButton.configuration?.title = currentPlayPauseVisualTitle()
        playPauseButton.configuration?.image = UIImage(systemName: playPauseSystemImage())
        playPauseButton.accessibilityLabel = currentPlayPauseTitle()
        setParagraphControlsActive(isActive)
    }

    private func setParagraphControlsActive(_ isActive: Bool) {
        let bounds = availability.paragraphBounds(state: state)
        previousButton.isEnabled = isActive && bounds.previous
        nextButton.isEnabled = isActive && bounds.next
        stopButton.isEnabled = isActive
        for button in [previousButton, nextButton, stopButton] {
            button.alpha = button.isEnabled ? 1 : 0.42
        }
    }

    private func refreshChapterControls() {
        previousChapterButton.isEnabled = availability.canPreviousChapter
        nextChapterButton.isEnabled = availability.canNextChapter
        previousChapterButton.alpha = previousChapterButton.isEnabled ? 1 : 0.42
        nextChapterButton.alpha = nextChapterButton.isEnabled ? 1 : 0.42
        previousChapterButton.accessibilityHint = previousChapterButton.isEnabled ? nil : "已经是第一章"
        nextChapterButton.accessibilityHint = nextChapterButton.isEnabled ? nil : "已经是最后一章"
    }

    func showNavigationFailure(_ message: String) {
        setFeedback(message)
    }

    private func setFeedback(_ text: String?) {
        navigationFeedbackPending = false
        feedbackLabel.text = text
        feedbackLabel.isHidden = text?.isEmpty != false
    }

    private func playbackFeedbackText() -> String? {
        ReaderReadAloudSheetSupport.playbackFeedback(state: state, canReadCurrentContent: availability.canReadCurrentContent)
    }

    private func updateTimerValue(_ minutes: Int) {
        timerValueLabel.text = L10n.Reader.readAloudTimerMinutes(minutes)
        timerPresetButton.configuration?.title = L10n.Reader.readAloudTimerMinutes(minutes)
        timerPresetButton.accessibilityValue = L10n.Reader.readAloudTimerMinutes(minutes)
    }

    private func refreshVoiceButton() {
        let selectedTitle = voiceOptions.first(where: { $0.identifier == readerConfig.ttsVoiceIdentifier })?.displayName
            ?? L10n.Reader.readAloudVoiceSystemDefault
        voiceButton.configuration?.title = selectedTitle
    }

    private func presentVoicePicker() {
        guard presentedViewController == nil else { setFeedback("请先关闭当前弹窗"); return }
        let options = ReaderReadAloudSheetSupport.voiceOptions(
            voiceOptions,
            selectedIdentifier: readerConfig.ttsVoiceIdentifier
        ) { [weak self] identifier in
            self?.selectVoice(identifier)
        }
        let controller = AndroidReaderOptionSheetViewController(
            titleText: L10n.Reader.readAloudVoiceTitle,
            options: options
        )
        present(controller.wrappedInReaderBottomSheet(fixedHeight: ReaderReadAloudSheetSupport.optionSheetHeight(optionCount: options.count)), animated: true)
    }

    private func presentTimerPresetPicker() {
        guard presentedViewController == nil else { setFeedback("请先关闭当前弹窗"); return }
        let options = ReaderReadAloudSheetSupport.timerOptions(selectedMinutes: Int(timerSlider.value.rounded())) { [weak self] minutes in
            self?.selectTimerPreset(minutes)
        }
        let controller = AndroidReaderOptionSheetViewController(
            titleText: L10n.Reader.readAloudTimerPreset,
            options: options
        )
        present(controller.wrappedInReaderBottomSheet(fixedHeight: ReaderReadAloudSheetSupport.optionSheetHeight(optionCount: options.count)), animated: true)
    }

    private func selectVoice(_ identifier: String?) {
        readerConfig = ReaderReadAloudSheetSupport.updatedConfig(readerConfig, voiceIdentifier: .some(identifier))
        onUpdateVoice(identifier)
        refreshVoiceButton()
        setFeedback(identifier == nil ? "已切换为系统默认音色" : "音色已切换")
    }

    private func selectTimerPreset(_ minutes: Int) {
        let normalizedMinutes = min(max(minutes, 0), 180)
        timerSlider.setValue(Float(normalizedMinutes), animated: true)
        readerConfig = ReaderReadAloudSheetSupport.updatedConfig(readerConfig, timerMinutes: normalizedMinutes)
        onUpdateTimer(normalizedMinutes)
        updateTimerValue(normalizedMinutes)
        setFeedback(normalizedMinutes == 0 ? "已关闭定时停止" : "定时停止已保存")
    }
}
