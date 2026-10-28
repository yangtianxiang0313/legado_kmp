import UIKit

/// activity_search_content.xml: toolbar, result list, 36dp summary and a mini stop FAB.
final class ReaderContentSearchPageView: UIView {
    // TitleBar's 24dp inset is a minimum beside the menu, not extra trailing padding.
    // The visible overflow already occupies 40pt; view_search stays expanded by default.
    let toolbar = AndroidSearchToolbarView(
        placeholder: L10n.Search.title, showsMoreButton: true)
    let tableView = UITableView(frame: .zero, style: .plain)
    let progressView = AndroidSearchLoadingView()
    let stopButton = AndroidSearchActionButton()
    let summaryButton = UIButton(type: .custom)
    let topButton = UIButton(type: .custom)
    let bottomButton = UIButton(type: .custom)
    var onFastScrollStateChange: ((Bool) -> Void)?
    var isFastScrolling: Bool { fastScroller.isScrubbing }

    private lazy var fastScroller = ReaderListFastScroller(tableView: tableView)
    private let statusBackground = UIView()
    private let footerBackground = UIView()
    private let footer = UIView()
    private let summaryLabel = ReaderTocSingleLineLabel()
    private lazy var footerHeight = footer.heightAnchor.constraint(equalToConstant: 36)
    private var summaryIsError = false
    private var listActionsEnabled = true
    private var isInWindow = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        statusBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 68
        tableView.keyboardDismissMode = .onDrag
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.showsVerticalScrollIndicator = false
        tableView.bounces = false
        tableView.accessibilityIdentifier = "reader_search_results"
        fastScroller.accessibilityIdentifier = "reader_search_fast_scroll"
        fastScroller.isEnabled = false
        fastScroller.onScrubbingChanged = { [weak self] active in
            guard let self else { return }
            self.updateFastScrollAvailability()
            self.onFastScrollStateChange?(active)
        }
        toolbar.backButton.accessibilityLabel = L10n.Reader.exitSearch
        toolbar.backButton.accessibilityIdentifier = "reader_search_close"
        toolbar.searchField.accessibilityIdentifier = "reader_search_bar"
        toolbar.searchField.accessibilityLabel = L10n.Reader.searchInBook
        toolbar.moreButton.accessibilityIdentifier = "reader_search_more"
        progressView.isHidden = true
        progressView.accessibilityIdentifier = "reader_search_progress"
        stopButton.setAction(.stop)
        stopButton.isHidden = true
        stopButton.accessibilityIdentifier = "reader_search_stop"
        summaryButton.configuration = nil
        summaryButton.backgroundColor = .clear
        summaryButton.clipsToBounds = true
        summaryButton.accessibilityIdentifier = "reader_search_summary"
        summaryButton.accessibilityHint = L10n.Reader.searchInBook
        summaryButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Reader.searchInBook))
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.numberOfLines = 1
        summaryLabel.clipsToBounds = true
        summaryLabel.isAccessibilityElement = false
        summaryButton.addSubview(summaryLabel)
        configure(
            topButton, image: ReaderTocAndroidIcon.top.image(), title: L10n.Reader.scrollToTop,
            identifier: "reader_search_top")
        configure(
            bottomButton, image: ReaderTocAndroidIcon.bottom.image(), title: L10n.Reader.scrollToBottom,
            identifier: "reader_search_bottom")
        for item in [statusBackground, toolbar, progressView, tableView, fastScroller, footerBackground, footer, stopButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }
        for item in [summaryButton, topButton, bottomButton] {
            footer.addSubview(item)
        }
        let fastScrollerBottom = fastScroller.bottomAnchor.constraint(
            equalTo: tableView.bottomAnchor, constant: -8)
        // Let the inset yield when the keyboard leaves less than 16pt for the list.
        fastScrollerBottom.priority = .defaultHigh
        NSLayoutConstraint.activate([
            statusBackground.topAnchor.constraint(equalTo: topAnchor),
            statusBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            statusBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            statusBackground.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),
            tableView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: ReaderListFastScrollerGeometry.columnWidth),
            fastScroller.trailingAnchor.constraint(equalTo: tableView.trailingAnchor),
            fastScroller.topAnchor.constraint(equalTo: tableView.topAnchor, constant: 8),
            fastScroller.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            fastScrollerBottom,
            footer.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            footerHeight,
            footer.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
            footerBackground.topAnchor.constraint(equalTo: footer.topAnchor),
            footerBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            footerBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            stopButton.widthAnchor.constraint(equalToConstant: 40),
            stopButton.heightAnchor.constraint(equalToConstant: 40),
            stopButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stopButton.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAppearance), name: .androidReplicaThemeDidChange, object: nil)
        updateAppearance()
        setSummary("搜索结果: 0")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var isHidden: Bool {
        didSet { updateFastScrollAvailability() }
    }

    override var isUserInteractionEnabled: Bool {
        didSet { updateFastScrollAvailability() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            isInWindow = false
            updateFastScrollAvailability()
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        isInWindow = window != nil
        updateFastScrollAvailability()
    }

    override func layoutSubviews() {
        toolbar.updateLayout(availableSize: bounds.size)
        // The shared single-line label measures the complete includeFontPadding box.
        let height = max(36, summaryLabel.intrinsicContentSize.height)
        if footerHeight.constant != height { footerHeight.constant = height }
        super.layoutSubviews()
        layoutFooter()
    }

    func cancelFastScrolling() {
        fastScroller.cancelScrubbing()
    }

    func setListActionsEnabled(_ enabled: Bool) {
        listActionsEnabled = enabled
        tableView.allowsSelection = enabled
        // The scroller is a sibling: disabling result touches must not cancel its thumb.
        tableView.isUserInteractionEnabled = enabled
        updateFastScrollAvailability()
    }

    func setSummary(_ text: String, isError: Bool = false) {
        summaryIsError = isError
        summaryLabel.text = text
        summaryLabel.textColor = isError ? AndroidReplicaTheme.accent : ReaderSearchChromePalette.foreground
        summaryButton.accessibilityLabel = text
        setNeedsLayout()
    }

    func setSearching(_ searching: Bool) {
        progressView.isHidden = !searching
        stopButton.isHidden = !searching
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    private func configure(_ button: UIButton, image: UIImage?, title: String, identifier: String) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.adjustsImageWhenHighlighted = false
        button.adjustsImageWhenDisabled = false
        button.imageView?.contentMode = .center
        button.setImage(image, for: .normal)
        button.accessibilityLabel = title
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: title))
    }

    private func updateFastScrollAvailability() {
        fastScroller.isEnabled =
            isInWindow && !isHidden && isUserInteractionEnabled
            && (listActionsEnabled || fastScroller.isScrubbing)
    }

    private func layoutFooter() {
        // Match LinearLayout weights without letting a long label's intrinsic width
        // move the 36pt icons. Only squeeze spacing on exceptionally narrow widths.
        let width = max(0, footer.bounds.width)
        let height = max(0, footer.bounds.height)
        let padding = min(10, max(0, (width - 72) / 2))
        let iconWidth = min(36, max(0, (width - 2 * padding) / 2))
        let remaining = max(0, width - 2 * padding - 2 * iconWidth)
        let gap = min(20, remaining)
        let summaryWidth = remaining - gap
        let isRTL = footer.effectiveUserInterfaceLayoutDirection == .rightToLeft
        func frame(leading: CGFloat, width: CGFloat) -> CGRect {
            CGRect(
                x: isRTL ? footer.bounds.width - leading - width : leading,
                y: 0, width: width, height: height)
        }
        summaryButton.frame = frame(leading: padding, width: summaryWidth)
        topButton.frame = frame(leading: padding + summaryWidth + gap, width: iconWidth)
        bottomButton.frame = frame(leading: padding + summaryWidth + gap + iconWidth, width: iconWidth)
        let textInset = min(10, summaryWidth / 2)
        summaryLabel.frame = summaryButton.bounds.insetBy(dx: textInset, dy: 0)
    }

    @objc private func updateAppearance() {
        backgroundColor = AndroidReplicaTheme.background.resolvedColor(with: traitCollection)
        statusBackground.backgroundColor = AndroidReplicaTheme.toolbarBackground.resolvedColor(with: traitCollection)
        tableView.backgroundColor = backgroundColor
        footer.backgroundColor = AndroidReplicaTheme.bottomBackground.resolvedColor(with: traitCollection)
        footerBackground.backgroundColor = footer.backgroundColor
        summaryLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 12, textStyle: .caption1, compatibleWith: traitCollection)
        summaryLabel.textColor = summaryIsError ? AndroidReplicaTheme.accent : ReaderSearchChromePalette.foreground
        for button in [topButton, bottomButton] { button.tintColor = ReaderSearchChromePalette.foreground }
        fastScroller.apply(accent: AndroidReplicaTheme.accent)
        setNeedsLayout()
    }

}
