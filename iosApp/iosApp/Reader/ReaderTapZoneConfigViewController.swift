import UIKit
import shared

final class ReaderTapZoneConfigViewController: ReaderSettingsBoundViewController {
    private let headerBar = UIStackView()
    private let titleLabel = AndroidExploreTextLabel()
    private let closeButton = UIButton(type: .system)
    private let contentStack = UIStackView()
    private let gridStack = UIStackView()
    private let gridScrollView = ReaderTapZoneGridScrollView()
    private var gridMinimumHeight: NSLayoutConstraint?
    private var headerHeight: NSLayoutConstraint?
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private lazy var settings = ReaderTapZoneSettings(screen: screen)
    private var zoneButtons: [ReaderTapZoneSlot: ReaderTapZoneControl] = [:]
    private let translucent = UIColor(white: 52 / 255, alpha: 153 / 255)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.ReaderAppearance.tapZonePageTitle
        view.backgroundColor = translucent
        view.accessibilityIdentifier = UIIdentifiers.ReaderTapZoneConfig.root
        stateView.setTestingIdentifier(UIIdentifiers.ReaderTapZoneConfig.state)
        configureViews()
        settings.onChange = { [weak self] actions in
            self?.reloadZoneButtons(actions)
        }
        settings.onError = { [weak self] error in
            guard let self, self.viewIfLoaded?.window != nil, !self.isBeingDismissed else { return }
            self.topmostPresentedViewController.showTransientMessage(error.userFacingMessage)
        }
        bootstrapReaderSettings()
    }

    override func apply(_ state: ReaderAppearanceState) {
        super.apply(state)
        settings.receive(state.runtimeConfig.reader.tapZoneActions)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        applyFonts()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let titleWidth = max(1, headerBar.bounds.width - 56)
        let measuredTitleHeight = ceil(
            titleLabel.sizeThatFits(
                CGSize(width: titleWidth, height: CGFloat.greatestFiniteMagnitude)
            ).height)
        let measuredHeaderHeight = max(24, measuredTitleHeight) + 12
        if let headerHeight, abs(headerHeight.constant - measuredHeaderHeight) > 0.5 {
            headerHeight.constant = measuredHeaderHeight
        }
        if titleLabel.bounds.width > 0, titleLabel.preferredMaxLayoutWidth != titleLabel.bounds.width {
            titleLabel.preferredMaxLayoutWidth = titleLabel.bounds.width
            titleLabel.invalidateIntrinsicContentSize()
        }
        let cellWidth = max(1, (gridScrollView.bounds.width - 12) / 3)
        let textHeight =
            zoneButtons.values.map {
                $0.sizeThatFits(CGSize(width: cellWidth, height: CGFloat.greatestFiniteMagnitude)).height
            }.max() ?? 0
        let minimumHeight = textHeight * 3 + 12
        if let gridMinimumHeight, abs(gridMinimumHeight.constant - minimumHeight) > 0.5 {
            gridMinimumHeight.constant = minimumHeight
        }
    }

    private func configureViews() {
        configureHeader()
        configureGrid()
        contentStack.axis = .vertical
        contentStack.spacing = 6
        contentStack.addArrangedSubview(headerBar)
        contentStack.addArrangedSubview(gridStack)
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        gridStack.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.translatesAutoresizingMaskIntoConstraints = false
        gridScrollView.contentInsetAdjustmentBehavior = .never
        gridScrollView.alwaysBounceVertical = false
        gridScrollView.showsHorizontalScrollIndicator = false
        gridScrollView.canCancelContentTouches = true
        gridScrollView.delaysContentTouches = false
        gridScrollView.scrollsToTop = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        stateView.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.accessibilityLabel = L10n.Common.loadingTitle
        view.addSubview(gridScrollView)
        gridScrollView.addSubview(contentStack)
        gridScrollView.addSubview(loadingIndicator)
        gridScrollView.addSubview(stateView)

        // Android root padding 3dp + each child's 3dp margin; adjacent margins add to 6dp.
        NSLayoutConstraint.activate([
            gridScrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            gridScrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            gridScrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            gridScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            contentStack.topAnchor.constraint(equalTo: gridScrollView.contentLayoutGuide.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: gridScrollView.contentLayoutGuide.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: gridScrollView.contentLayoutGuide.trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: gridScrollView.contentLayoutGuide.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: gridScrollView.frameLayoutGuide.widthAnchor),
            contentStack.heightAnchor.constraint(greaterThanOrEqualTo: gridScrollView.frameLayoutGuide.heightAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: gridStack.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: gridStack.centerYAnchor),
            stateView.topAnchor.constraint(equalTo: gridStack.topAnchor),
            stateView.leadingAnchor.constraint(equalTo: gridStack.leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: gridStack.trailingAnchor),
            stateView.bottomAnchor.constraint(equalTo: gridStack.bottomAnchor),
        ])
        // Keep the XML's wrap-content header and equal grid; short windows scroll both.
        headerHeight = headerBar.heightAnchor.constraint(equalToConstant: 36)
        headerHeight?.isActive = true
        let fillViewport = contentStack.heightAnchor.constraint(equalTo: gridScrollView.frameLayoutGuide.heightAnchor)
        fillViewport.priority = .defaultLow
        fillViewport.isActive = true
        gridMinimumHeight = gridStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        gridMinimumHeight?.isActive = true
        applyFonts()
        reloadZoneButtons(nil)
    }

    private func configureHeader() {
        headerBar.axis = .horizontal
        headerBar.alignment = .center
        headerBar.spacing = 0
        headerBar.isLayoutMarginsRelativeArrangement = true
        headerBar.insetsLayoutMarginsFromSafeArea = false
        headerBar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)
        headerBar.backgroundColor = translucent
        headerBar.layer.cornerRadius = 3
        headerBar.layer.masksToBounds = true

        titleLabel.text = L10n.ReaderAppearance.tapZoneTitle
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.textAlignment = .natural
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.accessibilityLabel = titleLabel.text
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "\(UIIdentifiers.ReaderTapZoneConfig.root).title"
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14)),
            for: .normal)
        closeButton.tintColor = .white
        closeButton.accessibilityLabel = L10n.ReaderAppearance.tapZoneClose
        closeButton.accessibilityIdentifier = UIIdentifiers.ReaderTapZoneConfig.closeButton
        closeButton.addAction(
            UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            }, for: .touchUpInside)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        headerBar.addArrangedSubview(titleLabel)
        headerBar.addArrangedSubview(closeButton)

        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    private func configureGrid() {
        gridStack.axis = .vertical
        gridStack.spacing = 6
        gridStack.distribution = .fillEqually
        gridStack.accessibilityIdentifier = UIIdentifiers.ReaderTapZoneConfig.grid
        for row in ReaderTapZoneSlot.rows {
            let rowStack = UIStackView()
            rowStack.axis = .horizontal
            rowStack.spacing = 6
            rowStack.distribution = .fillEqually
            for zone in row {
                let button = makeZoneButton(zone)
                zoneButtons[zone] = button
                rowStack.addArrangedSubview(button)
            }
            gridStack.addArrangedSubview(rowStack)
        }
    }

    private func makeZoneButton(_ zone: ReaderTapZoneSlot) -> ReaderTapZoneControl {
        let button = ReaderTapZoneControl()
        button.accessibilityIdentifier = zone.identifier
        button.backgroundColor = translucent
        button.layer.cornerRadius = 3
        button.clipsToBounds = true
        button.addAction(
            UIAction { [weak self] _ in
                self?.openActionPicker(for: zone)
            }, for: .touchUpInside)
        return button
    }

    private func applyFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        titleLabel.font = font
        titleLabel.invalidateIntrinsicContentSize()
        titleLabel.setNeedsDisplay()
        for button in zoneButtons.values {
            button.apply(font: font)
        }
        view.setNeedsLayout()
    }

    private func reloadZoneButtons(_ actions: ReaderTapZoneActions?) {
        if actions == nil {
            loadingIndicator.startAnimating()
        } else {
            loadingIndicator.stopAnimating()
        }
        gridStack.accessibilityElementsHidden = actions == nil
        for zone in ReaderTapZoneSlot.allCases {
            guard let button = zoneButtons[zone] else { continue }
            let actionTitle = actions.map { values in
                let rawAction = values.value(for: zone)
                return ReaderTapZoneAction(rawValue: rawAction)?.title
                    ?? L10n.ReaderAppearance.unknownTapAction(String(rawAction))
            }
            button.setActionTitle(actionTitle)
            button.isEnabled = actions != nil
        }
        view.setNeedsLayout()
    }

    private func openActionPicker(for zone: ReaderTapZoneSlot) {
        guard settings.actions != nil, viewIfLoaded?.window != nil, !isBeingDismissed else {
            return
        }
        guard presentedViewController == nil else {
            showTransientMessage(L10n.Reader.operationBusy)
            return
        }
        let choices = ReaderTapZoneAction.allCases
        let controller = ReaderTapZoneActionSelectorViewController(
            title: L10n.ReaderAppearance.tapZonePicker,
            items: choices.map(\.title),
            identifier: "\(UIIdentifiers.ReaderTapZoneConfig.root).selector"
        ) { [weak self] index in
            guard let self, choices.indices.contains(index) else { return }
            if self.settings.select(choices[index], for: zone) {
                self.showTransientMessage(L10n.ReaderAppearance.tapZoneMenuRequired)
            }
        }
        controller.overrideUserInterfaceStyle = overrideUserInterfaceStyle
        present(controller, animated: true)
    }
}

private final class ReaderTapZoneGridScrollView: UIScrollView {
    override func touchesShouldCancel(in _: UIView) -> Bool { true }
}

private final class ReaderTapZoneControl: UIControl {
    private let label = AndroidExploreTextLabel()
    init() {
        super.init(frame: .zero)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.lineBreakMode = .byWordWrapping
        label.textColor = .white
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isEnabled: Bool {
        didSet {
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let textSize = label.sizeThatFits(CGSize(width: max(1, size.width), height: .greatestFiniteMagnitude))
        return CGSize(width: size.width, height: max(44, ceil(textSize.height)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, window != nil else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func setActionTitle(_ title: String?) {
        label.text = title
        accessibilityLabel = title
        setNeedsLayout()
    }

    func apply(font: UIFont) {
        label.font = font
        label.invalidateIntrinsicContentSize()
        label.setNeedsDisplay()
        setNeedsLayout()
    }
}

enum ReaderTapZoneSlot: CaseIterable {
    case topLeft
    case topCenter
    case topRight
    case middleLeft
    case middleCenter
    case middleRight
    case bottomLeft
    case bottomCenter
    case bottomRight

    static let rows: [[ReaderTapZoneSlot]] = [
        [.topLeft, .topCenter, .topRight],
        [.middleLeft, .middleCenter, .middleRight],
        [.bottomLeft, .bottomCenter, .bottomRight],
    ]

    var title: String {
        switch self {
        case .topLeft:
            return L10n.ReaderAppearance.tapZoneTopLeft
        case .topCenter:
            return L10n.ReaderAppearance.tapZoneTopCenter
        case .topRight:
            return L10n.ReaderAppearance.tapZoneTopRight
        case .middleLeft:
            return L10n.ReaderAppearance.tapZoneMiddleLeft
        case .middleCenter:
            return L10n.ReaderAppearance.tapZoneMiddleCenter
        case .middleRight:
            return L10n.ReaderAppearance.tapZoneMiddleRight
        case .bottomLeft:
            return L10n.ReaderAppearance.tapZoneBottomLeft
        case .bottomCenter:
            return L10n.ReaderAppearance.tapZoneBottomCenter
        case .bottomRight:
            return L10n.ReaderAppearance.tapZoneBottomRight
        }
    }

    var identifier: String {
        switch self {
        case .topLeft:
            return UIIdentifiers.ReaderAppearance.tapZoneTopLeft
        case .topCenter:
            return UIIdentifiers.ReaderAppearance.tapZoneTopCenter
        case .topRight:
            return UIIdentifiers.ReaderAppearance.tapZoneTopRight
        case .middleLeft:
            return UIIdentifiers.ReaderAppearance.tapZoneMiddleLeft
        case .middleCenter:
            return UIIdentifiers.ReaderAppearance.tapZoneMiddleCenter
        case .middleRight:
            return UIIdentifiers.ReaderAppearance.tapZoneMiddleRight
        case .bottomLeft:
            return UIIdentifiers.ReaderAppearance.tapZoneBottomLeft
        case .bottomCenter:
            return UIIdentifiers.ReaderAppearance.tapZoneBottomCenter
        case .bottomRight:
            return UIIdentifiers.ReaderAppearance.tapZoneBottomRight
        }
    }
}

enum ReaderTapZoneAction: Int32, CaseIterable {
    case disabled = -1
    case menu = 0
    case nextPage = 1
    case previousPage = 2
    case nextChapter = 3
    case previousChapter = 4
    case previousParagraph = 5
    case nextParagraph = 6
    case addBookmark = 7
    case editContent = 8
    case replaceRule = 9
    case chapterList = 10
    case searchContent = 11
    case syncProgress = 12
    case readAloud = 13

    var title: String {
        switch self {
        case .disabled:
            return L10n.ReaderAppearance.tapActionDisabled
        case .menu:
            return L10n.ReaderAppearance.tapActionMenu
        case .nextPage:
            return L10n.ReaderAppearance.tapActionNextPage
        case .previousPage:
            return L10n.ReaderAppearance.tapActionPreviousPage
        case .nextChapter:
            return L10n.ReaderAppearance.tapActionNextChapter
        case .previousChapter:
            return L10n.ReaderAppearance.tapActionPreviousChapter
        case .previousParagraph:
            return L10n.ReaderAppearance.tapActionPreviousParagraph
        case .nextParagraph:
            return L10n.ReaderAppearance.tapActionNextParagraph
        case .addBookmark:
            return L10n.ReaderAppearance.tapActionAddBookmark
        case .editContent:
            return L10n.ReaderAppearance.tapActionEditContent
        case .replaceRule:
            return L10n.ReaderAppearance.tapActionReplaceRule
        case .chapterList:
            return L10n.ReaderAppearance.tapActionChapterList
        case .searchContent:
            return L10n.ReaderAppearance.tapActionSearchContent
        case .syncProgress:
            return L10n.ReaderAppearance.tapActionSyncProgress
        case .readAloud:
            return L10n.ReaderAppearance.tapActionReadAloud
        }
    }
}

extension ReaderTapZoneActions {
    static var legadoDefaultActions: ReaderTapZoneActions {
        ReaderTapZoneActions(
            topLeft: 2,
            topCenter: 2,
            topRight: 1,
            middleLeft: 2,
            middleCenter: 0,
            middleRight: 1,
            bottomLeft: 2,
            bottomCenter: 1,
            bottomRight: 1
        )
    }

    var androidMenuSafeActions: ReaderTapZoneActions {
        hasReachableMenuEntry
            ? self : updating(ReaderTapZoneSlot.middleCenter, action: ReaderTapZoneAction.menu.rawValue)
    }

    var hasReachableMenuEntry: Bool {
        allValues.contains(ReaderTapZoneAction.menu.rawValue)
    }

    func value(for zone: ReaderTapZoneSlot) -> Int32 {
        switch zone {
        case .topLeft:
            return topLeft
        case .topCenter:
            return topCenter
        case .topRight:
            return topRight
        case .middleLeft:
            return middleLeft
        case .middleCenter:
            return middleCenter
        case .middleRight:
            return middleRight
        case .bottomLeft:
            return bottomLeft
        case .bottomCenter:
            return bottomCenter
        case .bottomRight:
            return bottomRight
        }
    }

    func updating(_ zone: ReaderTapZoneSlot, action: Int32) -> ReaderTapZoneActions {
        ReaderTapZoneActions(
            topLeft: zone == .topLeft ? action : topLeft,
            topCenter: zone == .topCenter ? action : topCenter,
            topRight: zone == .topRight ? action : topRight,
            middleLeft: zone == .middleLeft ? action : middleLeft,
            middleCenter: zone == .middleCenter ? action : middleCenter,
            middleRight: zone == .middleRight ? action : middleRight,
            bottomLeft: zone == .bottomLeft ? action : bottomLeft,
            bottomCenter: zone == .bottomCenter ? action : bottomCenter,
            bottomRight: zone == .bottomRight ? action : bottomRight
        )
    }

    private var allValues: [Int32] {
        [topLeft, topCenter, topRight, middleLeft, middleCenter, middleRight, bottomLeft, bottomCenter, bottomRight]
    }
}
