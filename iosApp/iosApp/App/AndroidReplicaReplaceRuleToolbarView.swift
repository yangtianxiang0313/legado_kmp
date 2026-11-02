import UIKit

/// Legado 5f5d314 activity_replace_rule.xml / view_search.xml; no submit action.
final class AndroidReplicaReplaceRuleToolbarView: NavigationToolbarView {
    private let chrome = AndroidSearchToolbarView(
        placeholder: NSLocalizedString(
            "replace_rule.android_search_placeholder", value: "替换净化-搜索", comment: "Legado replace_purify_search"),
        showsMoreButton: true)
    let groupButton = SourceManagementToolbarActionButton(type: .custom)
    var backButton: UIButton { chrome.backButton }
    var searchField: UITextField { chrome.searchField }
    var moreButton: UIButton { chrome.moreButton }
    var canInteract: (() -> Bool)?
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updateAvailability()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        chrome.canInteract = { [weak self] in self?.canInteract?() != false }
        chrome.isSubmitButtonEnabled = false
        searchField.accessibilityIdentifier = "replaceRule.search"
        searchField.smartQuotesType = .no
        searchField.smartDashesType = .no
        searchField.enablesReturnKeyAutomatically = false
        moreButton.accessibilityIdentifier = "replaceRule.more"
        chrome.setClearButtonAccessibilityIdentifier("replaceRule.clearSearch")
        groupButton.configuration = nil
        groupButton.adjustsImageWhenHighlighted = false
        groupButton.adjustsImageWhenDisabled = false
        groupButton.setImage(
            UIImage(named: "BookDetailAndroidGroups")?.withRenderingMode(.alwaysTemplate), for: .normal)
        groupButton.imageView?.contentMode = .center
        groupButton.accessibilityIdentifier = "replaceRule.group"
        groupButton.accessibilityLabel = L10n.ReplaceRule.filterByGroup
        groupButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.ReplaceRule.filterByGroup))
        groupButton.canInteract = { [weak self] in
            guard let self else { return false }
            return self.presentation.isActive && self.canInteract?() != false
        }
        groupButton.tintColor = nil
        chrome.setTrailingAccessory(groupButton, width: 48)
        chrome.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize { chrome.intrinsicContentSize }
    override func sizeThatFits(_ size: CGSize) -> CGSize { chrome.sizeThatFits(size) }

    func updateLayout(availableSize: CGSize) {
        let previousHeight = chrome.intrinsicContentSize.height
        chrome.updateLayout(availableSize: availableSize)
        if previousHeight != chrome.intrinsicContentSize.height { invalidateIntrinsicContentSize() }
        presentation.update()
    }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
        updateAvailability()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        invalidateIntrinsicContentSize()
    }

    private func updateAvailability() {
        let active = presentation.isActive && canInteract?() != false
        chrome.setPresentationActive(active)
        groupButton.isEnabled = active
        if !active { groupButton.cancelPendingActivation() }
    }

    @objc func updateQueryChrome() { chrome.updateQueryControls() }
}

/// view_select_action_bar.xml / SelectActionBar.kt at Legado 5f5d314.
final class AndroidReplicaReplaceRuleSelectionBar: UIView {
    let allButton = ReplaceRuleChromeActionButton(type: .custom)
    let invertButton = ReplaceRuleChromeActionButton(type: .custom)
    let deleteButton = ReplaceRuleChromeActionButton(type: .custom)
    let moreButton = ReplaceRuleChromeActionButton(type: .custom)
    var canInteract: (() -> Bool)?
    private let selectionIcon = UIImageView()
    private let selectionTitleLabel = UILabel()
    private var selectedCount = 0
    private var totalCount = 0
    private var measuredHeight: CGFloat = 54
    private lazy var presentation = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updateAvailability()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        invertButton.setTitle(L10n.Bookshelf.revertSelection, for: .normal)
        deleteButton.setTitle(L10n.ReplaceRule.deleteAction, for: .normal)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        moreButton.imageView?.contentMode = .center
        moreButton.accessibilityLabel = L10n.Reader.menuMore
        moreButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Reader.menuMore))
        for (index, button) in buttons.enumerated() {
            button.configuration = nil
            button.backgroundColor = .clear
            button.adjustsImageWhenHighlighted = false
            button.adjustsImageWhenDisabled = false
            button.accessibilityIdentifier =
                ["replaceRule.selectAll", "replaceRule.invert", "replaceRule.delete", "replaceRule.batchMore"][index]
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.textAlignment = .center
            button.permitsInteraction = { [weak self] in
                guard let self else { return false }
                return self.presentation.isActive && self.canInteract?() != false
            }
            addSubview(button)
        }
        for button in [invertButton, deleteButton] {
            button.layer.cornerRadius = 3
            button.layer.borderWidth = 1
            button.contentEdgeInsets = UIEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)
            button.accessibilityLabel = button.title(for: .normal)
        }
        selectionIcon.contentMode = .scaleAspectFit
        selectionTitleLabel.numberOfLines = 0
        selectionTitleLabel.lineBreakMode = .byWordWrapping
        selectionTitleLabel.textAlignment = .natural
        for item in [selectionIcon, selectionTitleLabel] {
            item.isAccessibilityElement = false
            item.isUserInteractionEnabled = false
            allButton.addSubview(item)
        }
        accessibilityElements = buttons
        updateTypography()
        update(selectedCount: 0, totalCount: 0)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshColors), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { NotificationCenter.default.removeObserver(self) }

    private var buttons: [ReplaceRuleChromeActionButton] { [allButton, invertButton, deleteButton, moreButton] }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: metrics(width: bounds.width > 0 ? bounds.width : 402).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: metrics(width: size.width).height)
    }

    func update(selectedCount: Int, totalCount: Int) {
        self.selectedCount = max(0, selectedCount)
        self.totalCount = max(0, totalCount)
        let all = self.selectedCount > 0 && self.selectedCount >= self.totalCount
        let title = all ? L10n.ReplaceRule.deselectAll : L10n.ReplaceRule.selectAll
        selectionTitleLabel.text = String(
            format: NSLocalizedString(
                "source_management.selection_count_format", value: "%@（%ld/%ld）",
                comment: "Legado select_all_count / select_cancel_count"),
            locale: Locale.current, title, self.selectedCount, self.totalCount)
        selectionIcon.image = all ? ReplaceRuleEditorIcons.checked : ReplaceRuleEditorIcons.unchecked
        allButton.accessibilityLabel = title
        allButton.accessibilityValue = "\(self.selectedCount)/\(self.totalCount)"
        allButton.accessibilityTraits = all ? [.button, .selected] : .button
        updateAvailability()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
        updateAvailability()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
        refreshColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentation.update()
        let m = metrics(width: bounds.width)
        if measuredHeight != m.height {
            measuredHeight = m.height
            invalidateIntrinsicContentSize()
        }
        // XML explicitly uses physical paddingLeft=16 / paddingRight=8.
        let content = CGRect(x: 16, y: 6, width: max(0, bounds.width - 24), height: max(0, m.height - 12))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            CGRect(x: rtl ? content.maxX - x - width : content.minX + x, y: y + 6, width: width, height: height)
        }
        let checkboxHeight = m.stacked ? m.checkboxHeight : m.rowHeight
        allButton.frame = frame(0, 0, m.checkboxWidth, checkboxHeight)
        if m.verticalActions {
            var y = checkboxHeight + 5
            invertButton.frame = frame(5, y, m.actionWidth, m.actionHeight)
            y += m.actionHeight + 10
            deleteButton.frame = frame(5, y, m.actionWidth, m.actionHeight)
            y += m.actionHeight + 5
            moreButton.frame = frame(max(0, content.width - 36), y, min(36, content.width), 36)
        } else {
            let y = m.stacked ? checkboxHeight : 0
            var x = m.stacked ? max(0, content.width - m.actionsWidth) : m.checkboxWidth
            x += 5
            invertButton.frame = frame(x, y + (m.rowHeight - m.actionHeight) / 2, m.actionWidth, m.actionHeight)
            x += m.actionWidth + 10
            deleteButton.frame = frame(x, y + (m.rowHeight - m.actionHeight) / 2, m.actionWidth, m.actionHeight)
            x += m.actionWidth + 5
            moreButton.frame = frame(x, y + (m.rowHeight - 36) / 2, 36, 36)
        }
        selectionIcon.frame = CGRect(
            x: rtl ? max(0, m.checkboxWidth - 37) : 5, y: (checkboxHeight - 32) / 2, width: 32, height: 32)
        selectionTitleLabel.frame = CGRect(
            x: rtl ? 5 : 37, y: 5, width: max(0, m.checkboxWidth - 42), height: max(0, checkboxHeight - 10))
    }

    private struct Metrics {
        let actionWidth: CGFloat
        let actionHeight: CGFloat
        let checkboxWidth: CGFloat
        let checkboxHeight: CGFloat
        let rowHeight: CGFloat
        let stacked: Bool
        let verticalActions: Bool
        var actionsWidth: CGFloat { 2 * actionWidth + 56 }
        var height: CGFloat {
            if verticalActions { return 12 + checkboxHeight + 2 * (actionHeight + 10) + 36 }
            return 12 + rowHeight + (stacked ? checkboxHeight : 0)
        }
    }

    private func metrics(width: CGFloat) -> Metrics {
        let contentWidth = max(0, width - 24)
        let font = selectionTitleLabel.font ?? .systemFont(ofSize: 14)
        let naturalActionWidth =
            [invertButton, deleteButton].map {
                $0.titleLabel?.sizeThatFits(
                    CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                ).width ?? 0
            }.max() ?? 0
        let preferredActionWidth = max(
            72, ceil(naturalActionWidth) + 10)
        let inlineCheckboxWidth = max(0, contentWidth - 2 * preferredActionWidth - 56)
        func checkboxHeight(_ width: CGFloat) -> CGFloat {
            let height = selectionTitleLabel.sizeThatFits(
                CGSize(width: max(1, width - 42), height: .greatestFiniteMagnitude)
            ).height
            return max(32, ceil(height)) + 10
        }
        let stacked =
            inlineCheckboxWidth < 42 + 2 * font.pointSize
            || checkboxHeight(inlineCheckboxWidth) > max(32, 2 * ceil(font.lineHeight)) + 10
        let pairedTextWidth = max(1, (contentWidth - 56) / 2 - 10)
        let splitsActionWord = [invertButton, deleteButton].contains { button in
            (button.currentTitle ?? "").split(whereSeparator: { $0.isWhitespace }).contains { word in
                ceil((String(word) as NSString).size(withAttributes: [.font: font]).width) > pairedTextWidth
            }
        }
        let verticalActions = stacked && (contentWidth < 2 * 72 + 56 || splitsActionWord)
        let actionWidth: CGFloat
        if verticalActions {
            actionWidth = max(0, contentWidth - 10)
        } else if stacked {
            actionWidth = min(preferredActionWidth, max(72, (contentWidth - 56) / 2))
        } else {
            actionWidth = preferredActionWidth
        }
        let actionTextHeight =
            [invertButton, deleteButton].map {
                $0.titleLabel?.sizeThatFits(
                    CGSize(width: max(1, actionWidth - 10), height: .greatestFiniteMagnitude)
                ).height ?? 0
            }.max() ?? 0
        let actionHeight = ceil(max(font.lineHeight, actionTextHeight)) + 10
        let checkboxWidth = stacked ? contentWidth : inlineCheckboxWidth
        let checkHeight = checkboxHeight(checkboxWidth)
        let rowHeight = max(36, actionHeight + 10, stacked ? 0 : checkHeight)
        return Metrics(
            actionWidth: actionWidth, actionHeight: actionHeight, checkboxWidth: checkboxWidth,
            checkboxHeight: checkHeight, rowHeight: rowHeight, stacked: stacked, verticalActions: verticalActions)
    }

    private func updateTypography() {
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        selectionTitleLabel.font = font
        for button in [invertButton, deleteButton] { button.titleLabel?.font = font }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func updateAvailability() {
        let active = presentation.isActive && canInteract?() != false
        accessibilityElementsHidden = !active
        // SelectActionBar.setMenuClickable enables all three actions only when
        // selectCount > 0; unlike the old iOS bar, invert is not enabled by allCount.
        // Preserve iOS empty-list select-all availability (Android leaves it enabled).
        allButton.isEnabled = active && totalCount > 0
        for button in [invertButton, deleteButton, moreButton] { button.isEnabled = active && selectedCount > 0 }
        for button in buttons where !button.isEnabled { button.cancelPendingInteraction() }
        refreshColors()
    }

    @objc private func refreshColors() {
        let surface = AndroidReplicaTheme.bottomBackground.resolvedColor(with: traitCollection)
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        surface.getRed(&r, green: &g, blue: &b, alpha: nil)
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let light = linear(r) * 0.2126 + linear(g) * 0.7152 + linear(b) * 0.0722 >= 0.5
        let primary = UIColor(white: light ? 0 : 1, alpha: light ? 222 / 255.0 : 1)
        let disabled = UIColor(white: light ? 0 : 1, alpha: light ? 97 / 255.0 : 77 / 255.0)
        let disabledIcon = UIColor(white: light ? 0 : 1, alpha: light ? 36 / 255.0 : 54 / 255.0)
        let accent = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        backgroundColor = surface
        selectionTitleLabel.textColor = primary
        selectionIcon.tintColor =
            selectedCount > 0 && selectedCount >= totalCount
            ? accent : UIColor(white: light ? 0 : 1, alpha: light ? 138 / 255.0 : 179 / 255.0)
        moreButton.tintColor = moreButton.isEnabled ? primary : disabledIcon
        for button in [invertButton, deleteButton] {
            button.setTitleColor(accent, for: .normal)
            button.setTitleColor(disabled, for: .disabled)
            button.layer.borderColor = (button.isEnabled ? accent : disabled).cgColor
        }
    }
}

final class ReplaceRuleChromeActionButton: UIButton {
    var permitsInteraction: (() -> Bool)?

    private var available: Bool {
        guard isEnabled, permitsInteraction?() != false,
            window?.windowScene?.activationState == .foregroundActive, let window, !bounds.isEmpty
        else { return false }
        var visible = convert(bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = self
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            if view.clipsToBounds { visible = visible.intersection(view.convert(view.bounds, to: window)) }
            guard !visible.isEmpty, !visible.isNull else { return false }
            ancestor = view.superview
        }
        return true
    }

    func cancelPendingInteraction() {
        cancelTracking(with: nil)
        isHighlighted = false
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundColor =
                isHighlighted && available
                ? UIColor { UIColor(white: $0.userInterfaceStyle == .dark ? 1 : 0, alpha: 48 / 255.0) } : .clear
        }
    }

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard available else { return }
        super.sendAction(action, to: target, for: event)
    }

    override func sendActions(for controlEvents: UIControl.Event) {
        guard available else { return }
        super.sendActions(for: controlEvents)
    }

    override func accessibilityActivate() -> Bool {
        guard available else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}

/// Presentation-only state; never changes rules, filters or selection.
final class ReplaceRuleChromeLifecycle: NSObject {
    private weak var owner: UIViewController?
    private let onAvailabilityChanged: (Bool) -> Void
    private var appeared = false
    private var modalID: UUID?
    private(set) var generation = UUID()

    init(owner: UIViewController, onAvailabilityChanged: @escaping (Bool) -> Void) {
        self.owner = owner
        self.onAvailabilityChanged = onAvailabilityChanged
        super.init()
        for name in [
            UIApplication.didBecomeActiveNotification, UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification, UIScene.didActivateNotification,
            UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
        ] {
            NotificationCenter.default.addObserver(self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    var canUsePage: Bool {
        guard appeared, modalID == nil, let owner, let view = owner.viewIfLoaded,
            let window = view.window, window.isKeyWindow,
            UIApplication.shared.applicationState == .active,
            window.windowScene?.activationState == .foregroundActive,
            owner.navigationController?.topViewController === owner,
            owner.presentedViewController == nil, !owner.isMovingFromParent, !owner.isBeingDismissed,
            owner.transitionCoordinator == nil, owner.navigationController?.transitionCoordinator == nil
        else { return false }
        var visible = view.convert(view.bounds, to: window).intersection(window.bounds)
        var ancestor: UIView? = view
        while let current = ancestor {
            guard !current.isHidden, current.alpha > 0.01, current.isUserInteractionEnabled else { return false }
            if current.clipsToBounds { visible = visible.intersection(current.convert(current.bounds, to: window)) }
            guard !visible.isEmpty, !visible.isNull else { return false }
            ancestor = current.superview
        }
        return true
    }

    var canUseChrome: Bool { canUsePage }

    func setAppeared(_ appeared: Bool) {
        self.appeared = appeared
        if !appeared { generation = UUID() }
        refresh()
        if appeared { refreshAfterTransition() }
    }

    func refresh() { onAvailabilityChanged(canUseChrome) }

    @objc private func activationChanged(_ notification: Notification) {
        if let scene = notification.object as? UIScene, scene !== owner?.viewIfLoaded?.window?.windowScene { return }
        if notification.name != UIApplication.didBecomeActiveNotification && notification.name != UIScene.didActivateNotification {
            generation = UUID()
        }
        refresh()
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    // Non-fullscreen sheets do not necessarily call viewWillDisappear.
    func observePresentation(of controller: UIViewController) -> UUID? {
        guard modalID == nil else { return nil }
        let id = UUID()
        modalID = id
        generation = UUID()
        refresh()
        let observer = ReplaceRulePresentationObserver(frame: .zero)
        observer.isUserInteractionEnabled = false
        observer.isAccessibilityElement = false
        observer.onDetach = { [weak self, weak controller] in
            let resume = { [weak self, weak controller] in
                guard let self, self.modalID == id, controller?.viewIfLoaded?.window == nil else { return }
                self.modalID = nil
                self.refreshAfterTransition()
            }
            if let transition = controller?.transitionCoordinator {
                if !transition.animate(alongsideTransition: nil, completion: { _ in resume() }) { resume() }
            } else {
                resume()
            }
        }
        controller.view.addSubview(observer)
        return id
    }

    func resolvePresentationRequest(of controller: UIViewController, request: UUID) {
        // UIKit can reject a request without attaching its view or calling completion.
        guard modalID == request, controller.presentingViewController == nil,
            !controller.isBeingPresented, controller.viewIfLoaded?.window == nil
        else { return }
        modalID = nil
        refreshAfterTransition()
    }

    private func refreshAfterTransition() {
        let resume = { [weak self] in
            // UIKit may retain transitionCoordinator during its completion callback.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
        if let transition = owner?.transitionCoordinator ?? owner?.navigationController?.transitionCoordinator {
            if !transition.animate(alongsideTransition: nil, completion: { _ in resume() }) { resume() }
        } else {
            resume()
        }
    }
}

private final class ReplaceRulePresentationObserver: UIView {
    var onDetach: (() -> Void)?
    private var wasAttached = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            wasAttached = true
        } else if wasAttached {
            wasAttached = false
            let callback = onDetach
            DispatchQueue.main.async { callback?() }
        }
    }
}
