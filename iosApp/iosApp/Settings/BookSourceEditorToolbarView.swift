import UIKit

final class BookSourceEditorToolbarView: NavigationToolbarView {
    let backButton = UIButton(type: .custom)
    let saveButton = UIButton(type: .custom)
    let debugButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)

    private let titleLabel = AndroidExploreTextLabel()
    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private let saveImage = UIImage(named: "EditorAndroidSave")?.withRenderingMode(.alwaysTemplate)
    private var isBusy = false
    private var heightConstraint: NSLayoutConstraint!
    private var navigationLeading: NSLayoutConstraint!
    private var titleLeading: NSLayoutConstraint!
    private var actionsTrailing: NSLayoutConstraint!
    private var actionHeightConstraints: [NSLayoutConstraint] = []
    private var availableSize = CGSize.zero
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updatePresentation()
    }

    var canInteract: Bool { presentation.isActive && isUserInteractionEnabled && !isBusy }

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        configureButton(
            backButton, image: ReaderMenuAndroidIcon.back.image(),
            label: L10n.Reader.backAction, identifier: UIIdentifiers.Common.drillDownBackButton)
        configureButton(
            saveButton, image: saveImage,
            label: L10n.SourceEdit.saveAction, identifier: UIIdentifiers.SourceEdit.saveButton)
        configureButton(
            debugButton, image: UIImage(named: "SourceEditorAndroidDebug")?.withRenderingMode(.alwaysTemplate),
            label: L10n.SourceEdit.debugAction, identifier: "sourceEdit.debugButton")
        configureButton(
            moreButton, image: ReaderMenuAndroidIcon.more.image(),
            label: L10n.Reader.moreActionTitle, identifier: UIIdentifiers.SourceEdit.moreButton)

        titleLabel.text = title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        titleLabel.accessibilityLabel = title
        titleLabel.font =
            ReaderAndroidDefaultFont.font(size: 20, weight: 500) ?? .systemFont(ofSize: 20, weight: .medium)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.textAlignment = .natural
        titleLabel.numberOfLines = 1
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = [.header, .staticText]
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        busyIndicator.color = AndroidReplicaTheme.toolbarText
        busyIndicator.hidesWhenStopped = true
        busyIndicator.isUserInteractionEnabled = false
        busyIndicator.isAccessibilityElement = false
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addSubview(busyIndicator)
        heightConstraint = heightAnchor.constraint(equalToConstant: resourceHeight)
        navigationLeading = backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: backButton.trailingAnchor)
        actionsTrailing = moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor)
        NSLayoutConstraint.activate([
            heightConstraint,
            navigationLeading,
            backButton.widthAnchor.constraint(equalToConstant: 56),
            actionsTrailing,
            moreButton.widthAnchor.constraint(equalToConstant: 40),
            debugButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            debugButton.widthAnchor.constraint(equalToConstant: 48),
            saveButton.trailingAnchor.constraint(equalTo: debugButton.leadingAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 48),
            titleLeading,
            titleLabel.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            titleLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            busyIndicator.centerXAnchor.constraint(equalTo: saveButton.centerXAnchor),
            busyIndicator.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
        for button in [backButton, saveButton, debugButton, moreButton] {
            let height = button.heightAnchor.constraint(equalToConstant: resourceHeight)
            actionHeightConstraints.append(height)
            NSLayoutConstraint.activate([
                button.topAnchor.constraint(equalTo: topAnchor),
                height,
            ])
        }
        accessibilityElements = [backButton, titleLabel, saveButton, debugButton, moreButton]
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshAppearance), name: .androidReplicaThemeDidChange, object: nil)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        let padding = titleLabel.fontPadding
        return CGSize(
            width: UIView.noIntrinsicMetric,
            height: max(
                resourceHeight,
                ceil(titleLabel.font.lineHeight + padding.top + padding.bottom + AndroidToolbarLayout.titleVerticalMargins)))
    }

    private var resourceHeight: CGFloat { AndroidToolbarLayout.minimumHeight(for: availableSize) }

    func updateLayout(availableSize: CGSize) {
        guard availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0, self.availableSize != availableSize
        else { return }
        self.availableSize = availableSize
        updateLayoutMetrics()
    }

    private func updateLayoutMetrics() {
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableSize)
        navigationLeading?.constant = padding
        actionsTrailing?.constant = -padding
        titleLeading?.constant = AndroidToolbarLayout.contentInsetStartWithNavigation(for: availableSize) + 4 - 56
        for constraint in actionHeightConstraints { constraint.constant = resourceHeight }
        heightConstraint?.constant = intrinsicContentSize.height
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
        updateLayoutMetrics()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshAppearance()
    }

    override func layoutSubviews() {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        moreButton.contentEdgeInsets = UIEdgeInsets(
            top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
        super.layoutSubviews()
        presentation.update()
    }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
        updatePresentation()
    }

    func setBusy(_ busy: Bool) {
        isBusy = busy
        for button in [backButton, saveButton, debugButton, moreButton] {
            button.isEnabled = !busy
        }
        saveButton.setImage(busy ? nil : saveImage, for: .normal)
        saveButton.accessibilityValue = busy ? L10n.SourceEdit.saving : nil
        updatePresentation()
    }

    private func updatePresentation() {
        if !presentation.isActive {
            for button in [backButton, saveButton, debugButton, moreButton] {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
        }
        isBusy && presentation.isActive ? busyIndicator.startAnimating() : busyIndicator.stopAnimating()
    }

    @objc private func refreshAppearance() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        for button in [backButton, saveButton, debugButton, moreButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
        }
        busyIndicator.color = AndroidReplicaTheme.toolbarText
        updateLayoutMetrics()
    }

    private func configureButton(_ button: UIButton, image: UIImage?, label: String, identifier: String) {
        button.configuration = nil
        button.automaticallyUpdatesConfiguration = false
        button.backgroundColor = .clear
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.setImage(image, for: .normal)
        button.imageView?.contentMode = .center
        button.contentEdgeInsets = .zero
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
    }
}
