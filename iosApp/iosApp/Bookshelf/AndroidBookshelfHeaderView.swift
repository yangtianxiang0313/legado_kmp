import UIKit

struct AndroidBookshelfHeaderGroup: Equatable {
    let id: Int64
    let title: String
}

final class AndroidBookshelfHeaderView: UIView {
    var onSelectGroup: ((Int64) -> Void)?
    var onReselectGroup: ((Int64) -> Void)?
    var onEditGroup: ((Int64) -> Void)? {
        didSet {
            for button in groupButtons { button.onEditGroup = onEditGroup }
        }
    }
    var onSearch: (() -> Void)?
    var onMore: (() -> Void)?
    var moreAnchor: UIView { moreButton }

    private let groupScrollView = UIScrollView()
    private let searchButton = BookshelfHeaderActionButton(type: .custom)
    private let moreButton = BookshelfHeaderActionButton(type: .custom)
    private let indicatorView = UIView()
    private var transition: (from: Int64, to: Int64, fraction: CGFloat)?
    private var groups: [AndroidBookshelfHeaderGroup] = []
    private var groupButtons: [AndroidBookshelfHeaderGroupButton] = []
    private var selectedGroupId: Int64 = -1
    private var groupFont = UIFont.systemFont(ofSize: 14)
    private var selectedGroupFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private var preferredHeight: CGFloat = 56
    private var needsSelectedGroupReveal = true

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        isAccessibilityElement = false
        accessibilityLabel = L10n.Tabs.bookshelf
        shouldGroupAccessibilityChildren = true
        setContentCompressionResistancePriority(.required, for: .vertical)

        groupScrollView.showsHorizontalScrollIndicator = false
        groupScrollView.showsVerticalScrollIndicator = false
        groupScrollView.contentInsetAdjustmentBehavior = .never
        groupScrollView.scrollsToTop = false
        groupScrollView.alwaysBounceVertical = false
        groupScrollView.isDirectionalLockEnabled = true
        groupScrollView.clipsToBounds = true
        groupScrollView.isAccessibilityElement = false
        addSubview(groupScrollView)
        indicatorView.backgroundColor = AndroidReplicaTheme.accent
        indicatorView.isUserInteractionEnabled = false
        indicatorView.isAccessibilityElement = false
        groupScrollView.addSubview(indicatorView)

        // main_bookshelf.xml uses ic_search; overflow retains the AppCompat toolbar default.
        configureActionButton(
            searchButton,
            image: UIImage(named: "ReaderMenuAndroidSearch")?.withRenderingMode(.alwaysTemplate),
            label: L10n.Bookshelf.openSearch,
            identifier: "bookshelf.search", action: #selector(didTapSearch)
        )
        configureActionButton(
            moreButton,
            image: UIImage(named: "ReaderMenuAndroidMore")?.withRenderingMode(.alwaysTemplate),
            label: L10n.Bookshelf.moreActions,
            identifier: "bookshelf.more", action: #selector(didTapMore)
        )

        updateFonts()
        configure(groups: [], selectedGroupId: -1)
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(groups: [AndroidBookshelfHeaderGroup], selectedGroupId: Int64) {
        let displayedGroups =
            groups.isEmpty
            ? [
                AndroidBookshelfHeaderGroup(
                    id: -1, title: NSLocalizedString("bookshelf.all_group", value: "全部", comment: "")
                )
            ]
            : groups
        let displayedSelection =
            displayedGroups.first { $0.id == selectedGroupId }?.id
            ?? displayedGroups[0].id
        let groupsChanged = self.groups != displayedGroups
        guard groupsChanged || self.selectedGroupId != displayedSelection else { return }

        if groupsChanged {
            reconcileGroupButtons(with: displayedGroups)
            self.groups = displayedGroups
        }
        self.selectedGroupId = displayedSelection
        transition = nil
        indicatorView.layer.removeAllAnimations()
        updateGroupButtons()
        needsSelectedGroupReveal = true
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        // Android 5f5d31404 keeps scrollable tabs and toolbar actions on one row.
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let previousViewportSize = groupScrollView.bounds.size
        let previousContentSize = groupScrollView.contentSize
        moreButton.frame = CGRect(
            x: isRTL ? 0 : max(0, bounds.width - 40), y: 0, width: 40, height: bounds.height
        )
        searchButton.frame = CGRect(
            x: isRTL ? 40 : max(0, bounds.width - 88), y: 0, width: 48, height: bounds.height)
        moreButton.contentEdgeInsets = UIEdgeInsets(
            top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
        groupScrollView.frame = CGRect(
            x: isRTL ? 88 : 0, y: 0, width: max(0, bounds.width - 88), height: bounds.height
        )

        var tabX: CGFloat = 0
        for button in groupButtons {
            let width = button.intrinsicContentSize.width
            button.frame = CGRect(x: tabX, y: 0, width: width, height: bounds.height)
            tabX += width
        }
        groupScrollView.contentSize = CGSize(width: tabX, height: bounds.height)
        if isRTL {
            let contentWidth = max(tabX, groupScrollView.bounds.width)
            for button in groupButtons { button.frame.origin.x = contentWidth - button.frame.maxX }
            groupScrollView.contentSize.width = contentWidth
        }
        for button in groupButtons { button.layoutIfNeeded() }
        groupScrollView.bringSubviewToFront(indicatorView)
        indicatorView.frame = indicatorFrame()

        if previousViewportSize != groupScrollView.bounds.size
            || previousContentSize != groupScrollView.contentSize
        {
            needsSelectedGroupReveal = true
        }
        revealSelectedGroupIfNeeded()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) ?? true {
            refreshColors()
        }
        if previousTraitCollection?.preferredContentSizeCategory
            != traitCollection.preferredContentSizeCategory
        {
            updateFonts()
        }
    }

    func refreshColors() {
        // Color changes must not reconfigure tabs, reveal the selection or reset the indicator transition.
        backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        indicatorView.backgroundColor = AndroidReplicaTheme.accent.resolvedColor(with: traitCollection)
        searchButton.refreshColors()
        moreButton.refreshColors()
        for button in groupButtons { button.refreshColors() }
    }

    func setTransition(from: Int64, to: Int64, fraction: CGFloat, animated: Bool) {
        guard fraction.isFinite, groups.contains(where: { $0.id == from }),
            groups.contains(where: { $0.id == to })
        else { return }
        layoutIfNeeded()
        let previousFrame = indicatorView.layer.presentation()?.frame ?? indicatorView.frame
        indicatorView.layer.removeAllAnimations()
        transition = (from, to, min(1, max(0, fraction)))
        let target = indicatorFrame()
        indicatorView.frame = target
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let movement = CABasicAnimation(keyPath: "position")
        movement.fromValue = NSValue(cgPoint: CGPoint(x: previousFrame.midX, y: previousFrame.midY))
        movement.toValue = NSValue(cgPoint: CGPoint(x: target.midX, y: target.midY))
        let size = CABasicAnimation(keyPath: "bounds")
        size.fromValue = NSValue(cgRect: CGRect(origin: .zero, size: previousFrame.size))
        size.toValue = NSValue(cgRect: CGRect(origin: .zero, size: target.size))
        let animation = CAAnimationGroup()
        animation.animations = [movement, size]
        animation.duration = 0.3
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        indicatorView.layer.add(animation, forKey: "bookshelf.tab.indicator")
    }

    func resetTransition() {
        transition = nil
        indicatorView.layer.removeAllAnimations()
        setNeedsLayout()
    }

    private func indicatorFrame() -> CGRect {
        func frame(for id: Int64) -> CGRect {
            guard let button = groupButtons.first(where: { $0.groupId == id }) else { return .zero }
            return button.indicatorFrame
        }
        guard let transition else { return frame(for: selectedGroupId) }
        let start = frame(for: transition.from)
        let end = frame(for: transition.to)
        let left = start.minX + (end.minX - start.minX) * transition.fraction
        let right = start.maxX + (end.maxX - start.maxX) * transition.fraction
        return CGRect(x: left, y: start.minY, width: max(0, right - left), height: start.height)
    }

    private func configureActionButton(
        _ button: UIButton, image: UIImage?, label: String, identifier: String, action: Selector
    ) {
        button.configuration = nil
        button.automaticallyUpdatesConfiguration = false
        button.backgroundColor = .clear
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.setImage(image, for: .normal)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.isExclusiveTouch = true
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func reconcileGroupButtons(with groups: [AndroidBookshelfHeaderGroup]) {
        var reusableButtons = groupButtons
        groupButtons = groups.map { group in
            if let index = reusableButtons.firstIndex(where: { $0.groupId == group.id }) {
                return reusableButtons.remove(at: index)
            }
            let button = AndroidBookshelfHeaderGroupButton(type: .custom)
            button.addTarget(self, action: #selector(didTapGroup(_:)), for: .touchUpInside)
            groupScrollView.addSubview(button)
            return button
        }
        for button in reusableButtons { button.removeFromSuperview() }
        groupScrollView.accessibilityElements = groupButtons
    }

    private func updateFonts() {
        let metrics = UIFontMetrics(forTextStyle: .subheadline)
        groupFont = metrics.scaledFont(
            for: .systemFont(ofSize: 14, weight: .medium), compatibleWith: traitCollection
        )
        selectedGroupFont = metrics.scaledFont(
            for: .systemFont(ofSize: 14, weight: .medium), compatibleWith: traitCollection
        )
        updateGroupButtons()
        needsSelectedGroupReveal = true
        setNeedsLayout()
    }

    private func updateGroupButtons() {
        for (group, button) in zip(groups, groupButtons) {
            button.onEditGroup = onEditGroup
            button.configure(
                group: group, selected: group.id == selectedGroupId,
                font: groupFont, selectedFont: selectedGroupFont
            )
        }
        let height = groupButtons.reduce(CGFloat(56)) { max($0, $1.intrinsicContentSize.height) }
        if preferredHeight != height {
            preferredHeight = height
            invalidateIntrinsicContentSize()
        }
    }

    private func revealSelectedGroupIfNeeded() {
        guard needsSelectedGroupReveal, groupScrollView.bounds.width > 0,
            let button = groupButtons.first(where: { $0.groupId == selectedGroupId })
        else { return }
        needsSelectedGroupReveal = false

        let viewportWidth = groupScrollView.bounds.width
        let maximumOffset = max(0, groupScrollView.contentSize.width - viewportWidth)
        var offset = min(maximumOffset, max(0, groupScrollView.contentOffset.x))
        if button.frame.width > viewportWidth || button.frame.minX < offset {
            offset = button.frame.minX
        } else if button.frame.maxX > offset + viewportWidth {
            offset = button.frame.maxX - viewportWidth
        }
        offset = min(maximumOffset, max(0, offset))
        if groupScrollView.contentOffset != CGPoint(x: offset, y: 0) {
            groupScrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        }
    }

    @objc private func didTapGroup(_ sender: AndroidBookshelfHeaderGroupButton) {
        guard !sender.suppressesSelection else { return }
        let groupId = sender.groupId
        let isReselection = groupId == selectedGroupId
        if isReselection {
            onReselectGroup?(groupId)
        } else {
            onSelectGroup?(groupId)
        }
    }

    @objc private func didTapSearch() {
        onSearch?()
    }

    @objc private func didTapMore() {
        onMore?()
    }
}

/// AppCompat toolbar actions retain press feedback even though view_tab_layout_min disables tab ripples.
final class BookshelfHeaderActionButton: UIButton {
    private let feedbackView = UIView()

    override var isHighlighted: Bool {
        didSet { updateFeedback() }
    }

    override var isEnabled: Bool {
        didSet { updateFeedback() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        adjustsImageWhenHighlighted = false
        feedbackView.isUserInteractionEnabled = false
        feedbackView.isAccessibilityElement = false
        insertSubview(feedbackView, at: 0)
        updateFeedback()
        refreshColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let diameter = max(bounds.width, bounds.height)
        feedbackView.frame = CGRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
            width: diameter, height: diameter)
        feedbackView.layer.cornerRadius = diameter / 2
    }

    func refreshColors() {
        tintColor = AndroidReplicaTheme.toolbarText.resolvedColor(with: traitCollection)
        let usesDarkText = BookshelfRootView.statusBarStyle(for: traitCollection) == .darkContent
        // AppCompat ripple_material_light / ripple_material_dark follow the toolbar, not night mode.
        feedbackView.backgroundColor = UIColor(
            white: usesDarkText ? 0 : 1, alpha: usesDarkText ? 31.0 / 255 : 51.0 / 255)
    }

    private func updateFeedback() {
        feedbackView.isHidden = !isHighlighted || !isEnabled
    }
}

private final class AndroidBookshelfHeaderGroupButton: UIButton {
    var onEditGroup: ((Int64) -> Void)? {
        didSet {
            editLongPress.isEnabled = onEditGroup != nil
            accessibilityCustomActions =
                onEditGroup == nil
                ? nil
                : [
                    UIAccessibilityCustomAction(
                        name: "编辑分组", target: self, selector: #selector(editFromAccessibility(_:)))
                ]
        }
    }

    private let groupLabel = UILabel()
    private var normalFont = UIFont.systemFont(ofSize: 14)
    private var selectedFont = UIFont.systemFont(ofSize: 14, weight: .medium)
    private var measuredTitleWidth: CGFloat = 0
    private var measuredTitleHeight: CGFloat = 0
    private var isGroupSelected = false
    private(set) var groupId: Int64 = -1
    private(set) var suppressesSelection = false
    private lazy var editLongPress = UILongPressGestureRecognizer(
        target: self, action: #selector(didLongPress(_:)))

    private var tabWidth: CGFloat {
        // Android's 10-point minimum yields to the 44-point accessible hit target.
        min(100, max(44, ceil(measuredTitleWidth) + 24))
    }

    override var intrinsicContentSize: CGSize {
        CGSize(
            width: tabWidth,
            height: max(44, ceil(measuredTitleHeight) + 24)
        )
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        backgroundColor = .clear
        isExclusiveTouch = true
        isAccessibilityElement = true
        editLongPress.cancelsTouchesInView = true
        editLongPress.isEnabled = false
        addGestureRecognizer(editLongPress)

        groupLabel.numberOfLines = 2
        groupLabel.lineBreakMode = .byTruncatingTail
        groupLabel.textAlignment = .center
        groupLabel.isUserInteractionEnabled = false
        groupLabel.isAccessibilityElement = false
        addSubview(groupLabel)

        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(
        group: AndroidBookshelfHeaderGroup, selected: Bool, font: UIFont, selectedFont: UIFont
    ) {
        groupId = group.id
        groupLabel.text = group.title.uppercased(with: .current)
        normalFont = font
        self.selectedFont = selectedFont
        let title = (groupLabel.text ?? "") as NSString
        measuredTitleWidth = max(
            title.size(withAttributes: [.font: font]).width,
            title.size(withAttributes: [.font: selectedFont]).width
        )
        // Measure both states at the stable tab width, not the previous layout's bounds.
        let textSize = CGSize(width: tabWidth - 24, height: CGFloat.greatestFiniteMagnitude)
        measuredTitleHeight = 0
        for baseFont in [font, selectedFont] {
            groupLabel.font = effectiveFont(for: baseFont, textWidth: textSize.width)
            measuredTitleHeight = max(measuredTitleHeight, groupLabel.sizeThatFits(textSize).height)
        }
        accessibilityLabel = group.title
        accessibilityIdentifier = "bookshelf.group.\(group.id)"
        setGroupSelected(selected)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func setGroupSelected(_ selected: Bool) {
        // Keep selection in the Android label/indicator, not UIButton's native selected chrome.
        isGroupSelected = selected
        updateAppearance()
    }

    func refreshColors() {
        // Material 1.13's legacy selector uses toolbar primary/secondary text, not accent.
        // view_tab_layout_min makes tab background and ripple transparent, including while pressed.
        let text = AndroidReplicaTheme.toolbarText.resolvedColor(with: traitCollection)
        let usesDarkText = BookshelfRootView.statusBarStyle(for: traitCollection) == .darkContent
        groupLabel.textColor =
            isGroupSelected
            ? text
            : text.withAlphaComponent(usesDarkText ? 138.0 / 255 : 179.0 / 255)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        suppressesSelection = false
        return super.beginTracking(touch, with: event)
    }

    override func accessibilityActivate() -> Bool {
        suppressesSelection = false
        return super.accessibilityActivate()
    }

    @objc private func didLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let onEditGroup else { return }
        suppressesSelection = true
        cancelTracking(with: nil)
        isHighlighted = false
        onEditGroup(groupId)
    }

    @objc private func editFromAccessibility(_: UIAccessibilityCustomAction) -> Bool {
        guard let onEditGroup else { return false }
        onEditGroup(groupId)
        return true
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let textWidth = max(0, bounds.width - 24)
        let font = isGroupSelected ? selectedFont : normalFont
        groupLabel.font = effectiveFont(for: font, textWidth: textWidth)
        groupLabel.frame = CGRect(
            x: 12, y: 0, width: textWidth, height: bounds.height
        )
    }

    private func effectiveFont(for font: UIFont, textWidth: CGFloat) -> UIFont {
        let wraps = measuredTitleWidth > textWidth || groupLabel.text?.contains(where: { $0.isNewline }) == true
        // Material TabLayout keeps maxLines=2 and uses design_tab_text_size_2line (12sp) after wrapping.
        return wraps ? UIFont(descriptor: font.fontDescriptor, size: font.pointSize * 12 / 14) : font
    }

    var indicatorFrame: CGRect {
        let width = min(bounds.width, max(24, min(ceil(measuredTitleWidth), groupLabel.bounds.width)))
        return CGRect(x: frame.midX - width / 2, y: frame.maxY - 2, width: width, height: 2)
    }

    private func updateAppearance() {
        groupLabel.font = effectiveFont(
            for: isGroupSelected ? selectedFont : normalFont, textWidth: tabWidth - 24)
        refreshColors()
        accessibilityTraits = isGroupSelected ? [.button, .selected] : .button
        setNeedsLayout()
    }
}
