import UIKit

final class BookSourceEditorTabsView: UIControl {
    var selectedTab: SourceEditorTab = .base {
        didSet {
            if selectedTab != oldValue { updateSelection() }
        }
    }

    override var isEnabled: Bool {
        didSet {
            for item in tabItems { item.button.isEnabled = isEnabled }
            updateSelection(revealSelected: false)
        }
    }

    private let scrollView = BookSourceEditorTabsScrollView()
    private let divider = UIView()
    private var tabItems: [(tab: SourceEditorTab, container: UIView, button: UIButton, indicator: UIView)] = []
    private var needsSelectionReveal = true
    private var previousViewportSize = CGSize.zero
    private lazy var presentation: AndroidSearchPresentationState = AndroidSearchPresentationState(view: self) { [weak self] in
        self?.updatePresentation()
    }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = AndroidReplicaTheme.background
        accessibilityIdentifier = UIIdentifiers.SourceEdit.tabControl
        isAccessibilityElement = false
        shouldGroupAccessibilityChildren = true

        divider.backgroundColor = AndroidReplicaTheme.divider
        divider.isUserInteractionEnabled = false
        addSubview(divider)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = false
        scrollView.bounces = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.canCancelContentTouches = true
        addSubview(scrollView)

        let tabs: [(SourceEditorTab, String, String)] = [
            (.base, SourceEditorTab.base.title, UIIdentifiers.SourceEdit.baseTab),
            (.search, L10n.SourceEdit.searchTab, UIIdentifiers.SourceEdit.searchTab),
            (.explore, L10n.SourceEdit.exploreTab, UIIdentifiers.SourceEdit.exploreTab),
            (.info, L10n.SourceEdit.infoTab, UIIdentifiers.SourceEdit.infoTab),
            (.toc, L10n.SourceEdit.tocTab, UIIdentifiers.SourceEdit.tocTab),
            (.content, L10n.SourceEdit.contentTab, UIIdentifiers.SourceEdit.contentTab),
        ]
        for (tab, title, identifier) in tabs {
            addTab(tab, title: title, identifier: identifier)
        }
        updateFonts()
        updateSelection()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshPalette), name: .androidReplicaThemeDidChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: max(36, ceil(tabFont.lineHeight) + 12))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        presentation.update()
        if previousViewportSize != bounds.size {
            previousViewportSize = bounds.size
            needsSelectionReveal = true
        }
        scrollView.frame = bounds
        divider.frame = CGRect(x: 0, y: max(0, bounds.height - 1), width: bounds.width, height: 1)
        guard !tabItems.isEmpty else { return }
        let textWidth = tabItems.map { ceil($0.button.titleLabel?.intrinsicContentSize.width ?? 0) }.max() ?? 0
        let tabWidth = max(44, max(textWidth + 24, bounds.width / CGFloat(tabItems.count)))
        let contentWidth = tabWidth * CGFloat(tabItems.count)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        for (index, item) in tabItems.enumerated() {
            let visualIndex = isRTL ? tabItems.count - index - 1 : index
            item.container.frame = CGRect(
                x: CGFloat(visualIndex) * tabWidth, y: 0, width: tabWidth, height: bounds.height)
            item.button.frame = item.container.bounds
            item.indicator.frame = CGRect(x: 0, y: max(0, bounds.height - 2), width: tabWidth, height: 2)
        }
        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        scrollView.isScrollEnabled = contentWidth > bounds.width
        let maximumOffset = max(0, contentWidth - bounds.width)
        var offset = min(max(0, scrollView.contentOffset.x), maximumOffset)
        if needsSelectionReveal, bounds.width > 0, bounds.height > 0,
            let item = tabItems.first(where: { $0.tab == selectedTab })
        {
            let rect = item.container.frame
            if rect.minX < offset {
                offset = rect.minX
            } else if rect.maxX > offset + bounds.width {
                offset = rect.maxX - bounds.width
            }
            offset = min(max(0, offset), maximumOffset)
            needsSelectionReveal = false
        }
        if scrollView.contentOffset != CGPoint(x: offset, y: 0) {
            scrollView.setContentOffset(CGPoint(x: offset, y: 0), animated: false)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshPalette()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            updateFonts()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        presentation.refreshHierarchy()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        presentation.refreshHierarchy()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setPresentationActive(_ active: Bool) {
        presentation.setPresentationActive(active)
        updatePresentation()
    }

    private func updatePresentation() {
        guard !presentation.isActive else { return }
        for item in tabItems {
            item.button.cancelTracking(with: nil)
            item.button.isHighlighted = false
        }
    }

    @objc private func refreshPalette() {
        backgroundColor = AndroidReplicaTheme.background
        divider.backgroundColor = AndroidReplicaTheme.divider
        for item in tabItems {
            item.button.setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
            item.button.setTitleColor(AndroidReplicaTheme.primaryText, for: .selected)
            item.button.setTitleColor(AndroidReplicaTheme.secondaryText.withAlphaComponent(0.38), for: .disabled)
            item.button.setTitleColor(
                AndroidReplicaTheme.primaryText.withAlphaComponent(0.38), for: [.selected, .disabled])
            item.indicator.backgroundColor = AndroidReplicaTheme.accent
        }
    }

    private var tabFont: UIFont {
        ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
    }

    private func updateFonts() {
        let font = tabFont
        for item in tabItems { item.button.titleLabel?.font = font }
        invalidateIntrinsicContentSize()
        needsSelectionReveal = true
        setNeedsLayout()
    }

    private func addTab(_ tab: SourceEditorTab, title: String, identifier: String) {
        let container = UIView()
        let button = UIButton(type: .custom)
        button.configuration = nil
        button.automaticallyUpdatesConfiguration = false
        button.backgroundColor = .clear
        button.setTitle(title, for: .normal)
        button.setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
        button.setTitleColor(AndroidReplicaTheme.primaryText, for: .selected)
        button.setTitleColor(AndroidReplicaTheme.secondaryText.withAlphaComponent(0.38), for: .disabled)
        button.setTitleColor(AndroidReplicaTheme.primaryText.withAlphaComponent(0.38), for: [.selected, .disabled])
        button.titleLabel?.numberOfLines = 1
        button.titleLabel?.adjustsFontSizeToFitWidth = false
        button.titleLabel?.lineBreakMode = .byClipping
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.addAction(
            UIAction { [weak self, weak button] _ in
                guard let self, let button, self.isEnabled, button.isEnabled,
                    self.isUserInteractionEnabled, self.presentation.isActive,
                    !self.scrollView.isDragging, !self.scrollView.isDecelerating, self.selectedTab != tab
                else { return }
                self.selectedTab = tab
                self.sendActions(for: .valueChanged)
            }, for: .touchUpInside)

        let indicator = UIView()
        indicator.backgroundColor = AndroidReplicaTheme.accent
        indicator.isUserInteractionEnabled = false
        container.addSubview(button)
        container.addSubview(indicator)
        scrollView.addSubview(container)
        tabItems.append((tab, container, button, indicator))
    }

    private func updateSelection(revealSelected: Bool = true) {
        for item in tabItems {
            let selected = item.tab == selectedTab
            item.button.isSelected = selected
            var traits: UIAccessibilityTraits = selected ? [.button, .selected] : .button
            if !isEnabled { traits.insert(.notEnabled) }
            item.button.accessibilityTraits = traits
            item.indicator.isHidden = !selected
            item.indicator.alpha = isEnabled ? 1 : 0.38
        }
        if revealSelected { needsSelectionReveal = true }
        setNeedsLayout()
    }
}

private final class BookSourceEditorTabsScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
