import UIKit

/// dialog_toc_regex.xml: fixed toolbar and bottom actions, weighted scrollable list.
@MainActor
final class ReaderTxtTocRuleDialogBodyView: UIView {
    var onApply: (() -> Void)?
    var onCancel: (() -> Void)?
    var onManage: (() -> Void)?

    let tableView = UITableView(frame: .zero, style: .plain)
    let titleLabel = UILabel()
    private let outsideControl = UIControl()
    private let dialogView = UIView()
    private let toolbarScrollView = ReaderTxtTocRuleControlScrollView()
    private let toolbar = UIView()
    private let manageButton = UIButton(type: .system)
    private let footerScrollView = ReaderTxtTocRuleControlScrollView()
    private let footer = UIView()
    private let cancelButton = UIButton(type: .system)
    private let applyButton = UIButton(type: .system)
    private let statusView = UIView()
    private let statusLabel = UILabel()
    private let busyIndicator = UIActivityIndicatorView(style: .medium)
    private var hasStatus = false
    private var statusIsEmptyList = false
    private var shouldRevealStatus = false
    private var wasBusy = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureViews()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func setState(enabled: Bool, canCancel: Bool, canApply: Bool, canManage: Bool, busy: Bool, message: String?, isEmpty: Bool) {
        if busy, !wasBusy { shouldRevealStatus = true }
        wasBusy = busy
        tableView.allowsSelection = enabled
        // Scrolling remains available while loading/applying, including a very long regex.
        outsideControl.isEnabled = canCancel
        cancelButton.isEnabled = canCancel
        applyButton.isEnabled = canApply
        manageButton.isEnabled = canManage
        manageButton.alpha = canManage ? 1 : 0.38
        statusIsEmptyList = isEmpty
        if let message, !message.isEmpty {
            statusLabel.text = message
        } else if busy {
            statusLabel.text = L10n.Common.loadingTitle
        } else if isEmpty {
            statusLabel.text = L10n.Settings.txtTocRuleListEmptyTitle
        } else {
            statusLabel.text = nil
        }
        hasStatus = statusLabel.text != nil
        if busy { busyIndicator.startAnimating() } else { busyIndicator.stopAnimating() }
        setNeedsLayout()
    }

    func revealStatus() {
        shouldRevealStatus = true
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
    }

    @objc private func applyAppearance() {
        dialogView.backgroundColor = AndroidReplicaTheme.background
        tableView.backgroundColor = AndroidReplicaTheme.background
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbarScrollView.backgroundColor = AndroidReplicaTheme.toolbarBackground
        let foreground = ReaderSearchChromePalette.foreground(on: AndroidReplicaTheme.toolbarBackground, traits: traitCollection)
        titleLabel.textColor = foreground
        manageButton.tintColor = foreground
        busyIndicator.color = AndroidReplicaTheme.secondaryText
        statusLabel.textColor = AndroidReplicaTheme.primaryText
        cancelButton.setTitleColor(AndroidReplicaTheme.secondaryText, for: .normal)
        cancelButton.setTitleColor(AndroidReplicaTheme.secondaryText.withAlphaComponent(0.38), for: .disabled)
        applyButton.setTitleColor(AndroidReplicaTheme.accent, for: .normal)
        applyButton.setTitleColor(AndroidReplicaTheme.secondaryText.withAlphaComponent(0.38), for: .disabled)
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        let font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traitCollection)
        cancelButton.titleLabel?.font = font
        applyButton.titleLabel?.font = font
        statusLabel.font = font
        tableView.separatorColor = ReaderTocPalette(traits: traitCollection).divider
        tableView.reloadData()
        setNeedsLayout()
    }

    private func configureViews() {
        backgroundColor = UIColor.black.withAlphaComponent(0.6)
        accessibilityViewIsModal = true
        accessibilityIdentifier = "reader.txtToc.dialog"
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        dialogView.layer.cornerRadius = 2
        dialogView.clipsToBounds = true
        dialogView.accessibilityViewIsModal = true

        titleLabel.text = L10n.Reader.txtTocRuleTitle
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byCharWrapping
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "reader.txtToc.title"
        manageButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        manageButton.imageView?.contentMode = .center
        manageButton.accessibilityLabel = NSLocalizedString(
            "reader.txt_toc_rule.manage", value: "管理TXT目录规则", comment: "Existing TXT TOC management entry")
        manageButton.accessibilityIdentifier = "reader.txtToc.manage"
        manageButton.isPointerInteractionEnabled = true
        manageButton.showsLargeContentViewer = true
        manageButton.largeContentTitle = manageButton.accessibilityLabel
        manageButton.addInteraction(UILargeContentViewerInteraction())
        manageButton.addTarget(self, action: #selector(manage), for: .touchUpInside)
        configureAction(cancelButton, title: L10n.Common.cancel, identifier: "reader.txtToc.cancel", action: #selector(cancel))
        configureAction(applyButton, title: L10n.Common.ok, identifier: "reader.txtToc.apply", action: #selector(apply))

        for scrollView in [toolbarScrollView, footerScrollView] {
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.showsHorizontalScrollIndicator = false
            scrollView.alwaysBounceVertical = false
            scrollView.alwaysBounceHorizontal = false
            scrollView.delaysContentTouches = false
            scrollView.canCancelContentTouches = true
            scrollView.scrollsToTop = false
        }
        tableView.register(ReaderTxtTocRuleDialogCell.self, forCellReuseIdentifier: ReaderTxtTocRuleDialogCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 104
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.separatorInset = .zero
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.alwaysBounceVertical = false
        tableView.scrollsToTop = false
        tableView.accessibilityIdentifier = "reader.txtToc.list"
        statusLabel.numberOfLines = 0
        statusLabel.lineBreakMode = .byCharWrapping
        statusLabel.textAlignment = .center
        statusLabel.accessibilityIdentifier = "reader.txtToc.status"
        busyIndicator.hidesWhenStopped = true
        busyIndicator.isAccessibilityElement = false
        busyIndicator.accessibilityIdentifier = "reader.txtToc.busy"
        statusView.addSubview(statusLabel)
        statusView.addSubview(busyIndicator)
        addSubview(outsideControl)
        addSubview(dialogView)
        dialogView.addSubview(toolbarScrollView)
        toolbarScrollView.addSubview(toolbar)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(manageButton)
        dialogView.addSubview(tableView)
        dialogView.addSubview(footerScrollView)
        footerScrollView.addSubview(footer)
        footer.addSubview(cancelButton)
        footer.addSubview(applyButton)
        toolbar.accessibilityElements = [titleLabel, manageButton]
        footer.accessibilityElements = [cancelButton, applyButton]
        dialogView.accessibilityElements = [toolbarScrollView, tableView, footerScrollView]
        NotificationCenter.default.addObserver(
            self, selector: #selector(applyAppearance), name: .androidReplicaThemeDidChange, object: nil)
    }

    private func configureAction(_ button: UIButton, title: String, identifier: String, action: Selector) {
        button.setTitle(title, for: .normal)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.lineBreakMode = .byCharWrapping
        button.titleLabel?.textAlignment = .center
        button.accessibilityIdentifier = identifier
        button.addTarget(self, action: action, for: .touchUpInside)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        outsideControl.frame = bounds
        let safe = safeAreaLayoutGuide.layoutFrame
        guard safe.width > 0, safe.height > 0 else { return }
        let width = min(safe.width, bounds.width * 0.9)
        let height = min(safe.height, bounds.height * 0.8)
        dialogView.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        let titleWidth = max(1, width - 16 - 48 - 8)
        let titleHeight = ceil(titleLabel.sizeThatFits(CGSize(width: titleWidth, height: .greatestFiniteMagnitude)).height)
        let toolbarHeight = max(56, titleHeight + 16)
        // In a short window / AX type, chrome scrolls in its own slot instead of hiding the list.
        let toolbarViewport = min(toolbarHeight, height * 0.25)
        toolbarScrollView.frame = CGRect(x: 0, y: 0, width: width, height: toolbarViewport)
        toolbar.frame = CGRect(x: 0, y: 0, width: width, height: toolbarHeight)
        toolbarScrollView.contentSize = toolbar.bounds.size
        toolbarScrollView.isScrollEnabled = toolbarHeight > toolbarViewport
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        titleLabel.frame = CGRect(x: isRTL ? 56 : 16, y: (toolbarHeight - titleHeight) / 2, width: titleWidth, height: titleHeight)
        manageButton.frame = CGRect(x: isRTL ? 0 : width - 48, y: 0, width: 48, height: toolbarHeight)

        let actionWidth = max(1, min(width / 2 - 16, max(preferredActionWidth(cancelButton), preferredActionWidth(applyButton))))
        let footerHeight = max(actionHeight(cancelButton, width: actionWidth), actionHeight(applyButton, width: actionWidth))
        let footerViewport = min(footerHeight, height * 0.25)
        footerScrollView.frame = CGRect(x: 0, y: height - footerViewport, width: width, height: footerViewport)
        footer.frame = CGRect(x: 0, y: 0, width: width, height: footerHeight)
        footerScrollView.contentSize = footer.bounds.size
        footerScrollView.isScrollEnabled = footerHeight > footerViewport
        // Android's bottom row uses physical right margins, 16dp after each padded action.
        applyButton.frame = CGRect(x: width - 16 - actionWidth, y: 0, width: actionWidth, height: footerHeight)
        cancelButton.frame = CGRect(x: width - 32 - 2 * actionWidth, y: 0, width: actionWidth, height: footerHeight)
        tableView.frame = CGRect(x: 0, y: toolbarViewport, width: width, height: max(0, height - toolbarViewport - footerViewport))
        layoutStatus()
        clampOffset(toolbarScrollView)
        clampOffset(footerScrollView)
    }

    private func preferredActionWidth(_ button: UIButton) -> CGFloat {
        max(48, ceil(button.titleLabel?.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width ?? 0) + 24)
    }

    private func actionHeight(_ button: UIButton, width: CGFloat) -> CGFloat {
        max(48, ceil(button.titleLabel?.sizeThatFits(CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)).height ?? 0) + 24)
    }

    private func layoutStatus() {
        guard hasStatus else {
            if tableView.tableHeaderView != nil { tableView.tableHeaderView = nil }
            return
        }
        let width = tableView.bounds.width
        let textWidth = max(1, width - 32)
        let textHeight = ceil(statusLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        let spinnerHeight: CGFloat = busyIndicator.isAnimating ? 32 : 0
        let contentHeight = spinnerHeight + textHeight
        let height = max(statusIsEmptyList ? tableView.bounds.height : 0, contentHeight + 32)
        let size = CGSize(width: width, height: height)
        let needsAssignment = tableView.tableHeaderView !== statusView || statusView.bounds.size != size
        statusView.frame = CGRect(origin: statusView.frame.origin, size: size)
        let top = (height - contentHeight) / 2
        busyIndicator.frame = CGRect(x: width / 2 - 10, y: top, width: 20, height: 20)
        statusLabel.frame = CGRect(x: 16, y: top + spinnerHeight, width: textWidth, height: textHeight)
        if needsAssignment { tableView.tableHeaderView = statusView }
        if shouldRevealStatus {
            shouldRevealStatus = false
            tableView.setContentOffset(.zero, animated: false)
        }
    }

    private func clampOffset(_ scrollView: UIScrollView) {
        let maximum = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        let y = min(maximum, max(0, scrollView.contentOffset.y))
        if scrollView.contentOffset.y != y { scrollView.contentOffset = CGPoint(x: 0, y: y) }
    }

    @objc private func cancel() { if cancelButton.isEnabled { onCancel?() } }
    @objc private func apply() { if applyButton.isEnabled { onApply?() } }
    @objc private func manage() { if manageButton.isEnabled { onManage?() } }
}

private final class ReaderTxtTocRuleControlScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
