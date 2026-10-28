import UIKit

@MainActor
final class ThemeBackgroundBlurViewController: UIViewController {
    var canSubmit: (() -> Bool)?
    private let identifier: String
    private var onSubmit: ((Int) -> Void)?
    private var active = false
    private var closing = false
    private let outside = UIControl()
    private let panel = UIView()
    private let scroll = UIScrollView()
    private let body = UIStackView()
    private let heading = UILabel()
    private let valueLabel = UILabel()
    private let slider = ThemeBackgroundBlurSlider()
    private let cancelButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)

    init(value: Int, identifier: String, onSubmit: @escaping (Int) -> Void) {
        self.identifier = identifier
        self.onSubmit = onSubmit
        super.init(nibName: nil, bundle: nil)
        slider.minimumValue = 0
        slider.maximumValue = 25
        slider.value = Float(min(25, max(0, value)))
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        view.accessibilityViewIsModal = true
        view.accessibilityIdentifier = identifier
        outside.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        outside.isAccessibilityElement = false
        outside.accessibilityElementsHidden = true
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 3
        panel.clipsToBounds = true
        heading.text = "背景图片模糊"
        heading.numberOfLines = 0
        heading.textColor = AndroidReplicaTheme.primaryText
        heading.accessibilityTraits = .header
        heading.accessibilityIdentifier = identifier + ".title"
        valueLabel.textColor = AndroidReplicaTheme.primaryText
        valueLabel.textAlignment = .center
        valueLabel.numberOfLines = 0
        valueLabel.isAccessibilityElement = false
        valueLabel.accessibilityIdentifier = identifier + ".value"
        slider.minimumValue = 0
        slider.maximumValue = 25
        slider.minimumTrackTintColor = AndroidReplicaTheme.accent
        slider.thumbTintColor = AndroidReplicaTheme.accent
        slider.accessibilityLabel = "背景图片模糊"
        slider.accessibilityIdentifier = identifier + ".slider"
        slider.addTarget(self, action: #selector(valueChanged), for: .valueChanged)
        cancelButton.setTitle("取消", for: .normal)
        cancelButton.accessibilityIdentifier = identifier + ".cancel"
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        saveButton.setTitle("确定", for: .normal)
        saveButton.accessibilityIdentifier = identifier + ".save"
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)
        let actions = UIStackView(arrangedSubviews: [cancelButton, saveButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 8
        body.axis = .vertical
        body.spacing = 12
        for item in [heading, valueLabel, slider, actions] { body.addArrangedSubview(item) }
        view.addSubview(outside)
        view.addSubview(panel)
        panel.addSubview(scroll)
        scroll.addSubview(body)
        for item in [panel, scroll, body] { item.translatesAutoresizingMaskIntoConstraints = false }
        let naturalHeight = panel.heightAnchor.constraint(equalTo: body.heightAnchor, constant: 40)
        naturalHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24),
            panel.widthAnchor.constraint(lessThanOrEqualToConstant: 480),
            panel.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            naturalHeight,
            scroll.topAnchor.constraint(equalTo: panel.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
            body.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            body.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            body.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24),
            body.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            body.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            slider.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            cancelButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            saveButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
        let preferredWidth = panel.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -24)
        preferredWidth.priority = .defaultHigh
        preferredWidth.isActive = true
        applyFonts()
        valueChanged()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !closing else { return }
        active = true
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: slider)
    }

    override func viewWillDisappear(_ animated: Bool) {
        active = false
        if !closing { onSubmit = nil }
        super.viewWillDisappear(animated)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outside.frame = view.bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { applyFonts() }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let key = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        key.discoverabilityTitle = "取消"
        return [key]
    }

    override func accessibilityPerformEscape() -> Bool {
        guard active, !closing else { return false }
        close(submitting: false)
        return true
    }

    private func applyFonts() {
        heading.font = UIFontMetrics(forTextStyle: .headline).scaledFont(for: .systemFont(ofSize: 20, weight: .medium))
        valueLabel.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 17))
        for button in [cancelButton, saveButton] {
            button.tintColor = AndroidReplicaTheme.accent
            button.titleLabel?.font = UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: 14, weight: .medium))
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.textAlignment = .center
        }
    }

    @objc private func valueChanged() {
        let value = Int(slider.value.rounded())
        slider.value = Float(value)
        valueLabel.text = String(value)
        slider.accessibilityValue = String(value)
    }

    @objc private func cancel() { close(submitting: false) }
    @objc private func save() { close(submitting: true) }

    private func close(submitting: Bool) {
        guard active, !closing, !isBeingPresented, !isBeingDismissed,
            let presenter = presentingViewController,
            presenter.presentedViewController === self,
            UIApplication.shared.applicationState == .active,
            view.window?.windowScene?.activationState == .foregroundActive
        else { return }
        if submitting, canSubmit?() == false { return }
        closing = true
        active = false
        slider.isEnabled = false
        cancelButton.isEnabled = false
        saveButton.isEnabled = false
        let value = Int(slider.value.rounded())
        let callback = submitting ? onSubmit : nil
        onSubmit = nil
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self, weak presenter] in
            guard submitting, viewIfLoaded?.window == nil, presentingViewController == nil,
                presenter?.presentedViewController == nil, canSubmit?() != false
            else { return }
            callback?(value)
        }
    }
}

private final class ThemeBackgroundBlurSlider: UISlider {
    override func accessibilityIncrement() {
        value = min(maximumValue, value.rounded() + 1)
        sendActions(for: .valueChanged)
    }

    override func accessibilityDecrement() {
        value = max(minimumValue, value.rounded() - 1)
        sendActions(for: .valueChanged)
    }
}
