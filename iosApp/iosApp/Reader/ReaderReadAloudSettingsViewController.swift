import shared
import UIKit

final class ReaderReadAloudSettingsViewController: ReaderSettingsBoundViewController {
    static let preferredSheetHeight: CGFloat = 500

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private var ignoreAudioFocusOverride: Bool?
    private var pauseWhilePhoneCallsOverride: Bool?
    private var streamReadAloudAudioOverride: Bool?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.Reader.readAloudSettings
        view.backgroundColor = AndroidReplicaTheme.background
        preferredContentSize = CGSize(width: 0, height: Self.preferredSheetHeight)
        configureViews()
        bootstrapReaderSettings()
    }

    override func apply(_ state: ReaderAppearanceState) {
        rebuildRows(runtimeConfig: state.runtimeConfig)
    }

    private func configureViews() {
        view.accessibilityIdentifier = UIIdentifiers.ReaderReadAloudSettings.root
        scrollView.accessibilityIdentifier = UIIdentifiers.ReaderReadAloudSettings.table
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        stackView.axis = .vertical
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        view.addSubview(stateView)
        stateView.setTestingIdentifier(UIIdentifiers.ReaderReadAloudSettings.state)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -18),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),

            stateView.topAnchor.constraint(equalTo: view.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func rebuildRows(runtimeConfig: AppRuntimeConfig) {
        stackView.arrangedSubviews.forEach { view in
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let ignoreAudioFocus = ignoreAudioFocusOverride ?? runtimeConfig.ignoreAudioFocus
        let pauseWhilePhoneCalls = pauseWhilePhoneCallsOverride ?? runtimeConfig.pauseReadAloudWhilePhoneCalls
        let streamReadAloudAudio = streamReadAloudAudioOverride ?? runtimeConfig.streamReadAloudAudio

        stackView.addArrangedSubview(categoryHeader())
        stackView.addArrangedSubview(toggleRow(
            title: L10n.Reader.readAloudIgnoreAudioFocusTitle,
                detail: "允许与其他应用混音；系统音频中断仍会暂停朗读",
                isOn: ignoreAudioFocus,
            isEnabled: true,
            rowIdentifier: UIIdentifiers.ReaderReadAloudSettings.ignoreAudioFocusRow,
            switchIdentifier: UIIdentifiers.ReaderReadAloudSettings.ignoreAudioFocusSwitch
        ) { [weak self] isOn in
            self?.ignoreAudioFocusOverride = isOn
            self?.refreshFromCurrentState()
            self?.runSettingTask { [weak self] in
                guard let self else { return }
                try await self.screen.setIgnoreAudioFocus(enabled: isOn)
            }
        })
        stackView.addArrangedSubview(toggleRow(
            title: L10n.Reader.readAloudPausePhoneCallsTitle,
                detail: "仅在忽略音频焦点时额外监听通话并暂停，不读取或保存号码",
                isOn: pauseWhilePhoneCalls,
            isEnabled: ignoreAudioFocus,
            rowIdentifier: UIIdentifiers.ReaderReadAloudSettings.pausePhoneCallsRow,
            switchIdentifier: UIIdentifiers.ReaderReadAloudSettings.pausePhoneCallsSwitch
        ) { [weak self] isOn in
            self?.pauseWhilePhoneCallsOverride = isOn
            self?.refreshFromCurrentState()
            self?.runSettingTask { [weak self] in
                guard let self else { return }
                try await self.screen.setPauseReadAloudWhilePhoneCalls(enabled: isOn)
            }
        })
        stackView.addArrangedSubview(toggleRow(
            title: L10n.Reader.readAloudStreamAudioTitle,
            detail: L10n.Reader.readAloudStreamAudioSummary,
            isOn: streamReadAloudAudio,
            isEnabled: true,
            rowIdentifier: UIIdentifiers.ReaderReadAloudSettings.streamAudioRow,
            switchIdentifier: UIIdentifiers.ReaderReadAloudSettings.streamAudioSwitch
        ) { [weak self] isOn in
            self?.streamReadAloudAudioOverride = isOn
            self?.refreshFromCurrentState()
            self?.runSettingTask { [weak self] in
                guard let self else { return }
                try await self.screen.setStreamReadAloudAudio(enabled: isOn)
            }
        })
        stackView.addArrangedSubview(actionRow(
            title: L10n.Reader.readAloudSpeakEngineTitle,
            detail: runtimeConfig.ttsEngine?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? "TTS" : L10n.Reader.readAloudSystemTts,
            value: nil,
            rowIdentifier: UIIdentifiers.ReaderReadAloudSettings.speakEngineRow
        ) { [weak self] in
            self?.presentSpeakEnginePicker()
        })
        stackView.addArrangedSubview(actionRow(
            title: L10n.Reader.readAloudSystemTtsConfigTitle,
            detail: L10n.Reader.readAloudSystemTtsConfigSummary,
            value: nil,
            rowIdentifier: UIIdentifiers.ReaderReadAloudSettings.systemTtsConfigRow
        ) { [weak self] in
            self?.openSystemTtsSettings()
        })
    }

    private func categoryHeader() -> UIView {
        let label = UILabel()
        label.text = L10n.Reader.readAloudSettings
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = AndroidReplicaTheme.secondaryText
        label.accessibilityIdentifier = UIIdentifiers.ReaderReadAloudSettings.category
        label.accessibilityTraits.insert(.header)

        let container = UIView()
        container.layoutMargins = UIEdgeInsets(top: 0, left: 20, bottom: 6, right: 20)
        container.addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.layoutMarginsGuide.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.layoutMarginsGuide.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.layoutMarginsGuide.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: container.layoutMarginsGuide.bottomAnchor),
        ])
        return container
    }

    private func toggleRow(
        title: String,
        detail: String,
        isOn: Bool,
        isEnabled: Bool,
        rowIdentifier: String,
        switchIdentifier: String,
        onChange: @escaping (Bool) -> Void
    ) -> UIView {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.isEnabled = isEnabled
        toggle.onTintColor = AndroidReplicaTheme.accent
        toggle.accessibilityIdentifier = switchIdentifier
        toggle.accessibilityLabel = title
        toggle.accessibilityHint = detail
        toggle.accessibilityValue = isOn ? L10n.Settings.enabled : L10n.Settings.disabled

        let row = baseRow(title: title, detail: detail, value: nil, accessoryView: toggle, identifier: rowIdentifier)
        row.alpha = isEnabled ? 1 : 0.46
        row.isUserInteractionEnabled = isEnabled
        row.accessibilityTraits = isEnabled ? .button : .notEnabled

        let applyChange: (Bool) -> Void = { value in
            toggle.accessibilityValue = value ? L10n.Settings.enabled : L10n.Settings.disabled
            onChange(value)
        }
        toggle.addAction(UIAction { _ in applyChange(toggle.isOn) }, for: .valueChanged)
        row.addAction(UIAction { _ in
            guard toggle.isEnabled else { return }
            toggle.setOn(!toggle.isOn, animated: true)
            applyChange(toggle.isOn)
        }, for: .touchUpInside)
        return row
    }

    private func actionRow(
        title: String,
        detail: String,
        value: String?,
        rowIdentifier: String,
        action: @escaping () -> Void
    ) -> UIView {
        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = AndroidReplicaTheme.secondaryText
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = baseRow(title: title, detail: detail, value: value, accessoryView: chevron, identifier: rowIdentifier)
        row.accessibilityTraits = .button
        row.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return row
    }

    private func baseRow(
        title: String,
        detail: String,
        value: String?,
        accessoryView: UIView,
        identifier: String
    ) -> UIControl {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 1

        let detailLabel = UILabel()
        detailLabel.text = detail
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.numberOfLines = 0

        let labelStack = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 3
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIControl()
        row.accessibilityIdentifier = identifier
        row.accessibilityLabel = [title, detail].joined(separator: ", ")
        row.accessibilityValue = value
        row.backgroundColor = AndroidReplicaTheme.menuBackground

        let rowStack = UIStackView(arrangedSubviews: [labelStack])
        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 14
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(rowStack)

        if let value {
            let valueLabel = UILabel()
            valueLabel.text = value
            valueLabel.font = .preferredFont(forTextStyle: .subheadline)
            valueLabel.textColor = AndroidReplicaTheme.secondaryText
            valueLabel.numberOfLines = 1
            valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            rowStack.addArrangedSubview(valueLabel)
        }
        rowStack.addArrangedSubview(accessoryView)

        let divider = UIView()
        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(divider)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            rowStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            rowStack.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -20),
            rowStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),

            divider.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 20),
            divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        return row
    }

    private func presentSpeakEnginePicker() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let facade = try BootstrapApiKt.sharedBackupCapabilitiesFacade()
                let engines: [HttpTTS] = try await SharedAsync.value { completion in
                    facade.loadSpeechEngines(completionHandler: completion)
                }
                let selected = state?.runtimeConfig.ttsEngine?.replacingOccurrences(of: "httpTts:", with: "")
                var options: [AndroidReaderOptionSheetViewController.Option] = [
                    .init(title: L10n.Reader.readAloudSystemTts, subtitle: "TTS", isSelected: selected?.isEmpty != false) { [weak self] in
                        self?.selectSpeechEngine(nil)
                    },
                ]
                options += engines.map { engine in
                    let identifier = String(engine.id)
                    return .init(title: engine.name.isEmpty ? "HTTP TTS \(identifier)" : engine.name,
                                 subtitle: "HTTP TTS", isSelected: selected == identifier) { [weak self] in
                        self?.selectSpeechEngine(identifier)
                    }
                }
                let controller = AndroidReaderOptionSheetViewController(
                    titleText: L10n.Reader.readAloudSpeakEngineTitle, options: options
                )
                present(controller.wrappedInReaderBottomSheet(fixedHeight: min(CGFloat(100 + options.count * 64), 560)), animated: true)
            } catch {
                let alert = UIAlertController(title: "加载朗读引擎失败", message: error.userFacingMessage, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func selectSpeechEngine(_ identifier: String?) {
        runSettingTask { [weak self] in
            guard let self else { return }
            try await screen.setTtsEngine(engine: identifier)
        }
    }

    private func openSystemTtsSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString),
              UIApplication.shared.canOpenURL(url)
        else { return }
        UIApplication.shared.open(url)
    }

    private func refreshFromCurrentState() {
        guard let state else { return }
        apply(state)
    }
}

extension SettingsFacade {
    func setIgnoreAudioFocusAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setIgnoreAudioFocus(enabled: enabled, completionHandler: completion)
        }
    }

    func setPauseReadAloudWhilePhoneCallsAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setPauseReadAloudWhilePhoneCalls(enabled: enabled, completionHandler: completion)
        }
    }

    func setStreamReadAloudAudioAsync(enabled: Bool) async throws {
        try await SharedAsync.void { completion in
            setStreamReadAloudAudio(enabled: enabled, completionHandler: completion)
        }
    }

    func setTtsEngineAsync(engine: String?) async throws {
        try await SharedAsync.void { completion in
            setTtsEngine(engine: engine, completionHandler: completion)
        }
    }
}
