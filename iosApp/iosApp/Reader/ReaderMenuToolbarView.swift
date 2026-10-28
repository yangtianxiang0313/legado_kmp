import UIKit

final class ReaderMenuToolbarView: UIView {
    private enum Metrics {
        static let navigationWidth: CGFloat = 56
        static let titleMargin: CGFloat = 4
        static let actionWidth: CGFloat = 48
        static let overflowWidth: CGFloat = 40
    }

    var onBack: (() -> Void)?
    var onBookInfo: (() -> Void)?
    var onChangeSource: (() -> Void)?
    var onChangeSourceLongPress: (() -> Bool)?
    var onRefresh: (() -> Void)?
    var onRefreshLongPress: (() -> Bool)?
    var onBookAction: (() -> Void)?
    var onMore: (() -> Void)?

    private let backButton = ReaderMenuActionButton(type: .system)
    private let titleButton = UIButton(type: .custom)
    private let changeSourceButton = ReaderMenuActionButton(type: .system)
    private let refreshButton = ReaderMenuActionButton(type: .system)
    private let bookActionButton = ReaderMenuActionButton(type: .system)
    private let moreButton = ReaderMenuActionButton(type: .system)
    private var changeSourceWidthConstraint: NSLayoutConstraint?
    private var refreshWidthConstraint: NSLayoutConstraint?
    private var navigationLeadingConstraint: NSLayoutConstraint?
    private var overflowTrailingConstraint: NSLayoutConstraint?
    private var actionHeightConstraints: [NSLayoutConstraint] = []
    private var availableLayoutSize = CGSize.zero
    private var titleFontPadding = UIEdgeInsets.zero
    private var paddedTitleHeight: CGFloat = 0

    var titleAccessibilityElement: UIView { titleButton }
    var overflowAnchorView: UIView { moreButton }

    var refreshMenuAnchor: UIView? {
        ReaderMenuToolbarInteraction.isAvailable(refreshButton) ? refreshButton : nil
    }

    var changeSourceMenuAnchor: UIView? {
        ReaderMenuToolbarInteraction.isAvailable(changeSourceButton) ? changeSourceButton : nil
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateTypography()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTypography()
    }

    func updateBookTitle(_ title: String) {
        // Toolbar.setTitle uses a single-line TextView transformation, not a first-line crop.
        let display = title.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        titleButton.setTitle(display, for: .normal)
        titleButton.accessibilityLabel = title
        superview?.setNeedsLayout()
    }

    func setRefreshEnabled(_ enabled: Bool) {
        refreshButton.isEnabled = enabled
    }

    func updateLayout(availableSize: CGSize) -> CGFloat {
        if availableSize.width.isFinite, availableSize.height.isFinite,
            availableSize.width > 0, availableSize.height > 0
        {
            availableLayoutSize = availableSize
        }
        updateDirectionalInsets()
        let padding = AndroidToolbarLayout.horizontalPadding(for: availableLayoutSize)
        navigationLeadingConstraint?.constant = padding
        overflowTrailingConstraint?.constant = -padding
        // These AppCompat dimensions are minimums; the XML toolbar is wrap_content.
        let minimumHeight = AndroidToolbarLayout.minimumHeight(for: availableLayoutSize)
        for constraint in actionHeightConstraints where constraint.constant != minimumHeight {
            constraint.constant = minimumHeight
        }
        let titleHeight =
            titleButton.currentTitle?.isEmpty == false
            ? paddedTitleHeight + AndroidToolbarLayout.titleVerticalMargins : 0
        return max(minimumHeight, titleHeight)
    }

    func apply(textColor: UIColor) {
        titleButton.setTitleColor(textColor, for: .normal)
        for button in [backButton, changeSourceButton, refreshButton, bookActionButton, moreButton] {
            button.tintColor = textColor
        }
    }

    func updateBookLocalState(isLocal: Bool) {
        // Android's entire online action group is visible regardless of source-name availability.
        changeSourceButton.isHidden = isLocal
        refreshButton.isHidden = isLocal
        changeSourceWidthConstraint?.constant = isLocal ? 0 : Metrics.actionWidth
        refreshWidthConstraint?.constant = isLocal ? 0 : Metrics.actionWidth
        bookActionButton.setImage((isLocal ? ReaderMenuAndroidIcon.charset : .download).image(), for: .normal)
        bookActionButton.accessibilityIdentifier =
            isLocal ? "reader.menu.charset" : UIIdentifiers.Reader.downloadButton
        bookActionButton.accessibilityLabel =
            isLocal ? L10n.Reader.setCharsetTitle : L10n.Reader.offlineCache
    }

    private func configureView() {
        configureButton(backButton, icon: .back, label: L10n.Reader.backAction) { [weak self] in
            self?.onBack?()
        }
        configureButton(changeSourceButton, icon: .changeSource, label: L10n.Reader.changeSource) { [weak self] in
            self?.onChangeSource?()
        }
        configureButton(refreshButton, icon: .refresh, label: L10n.Reader.menuRefresh) { [weak self] in
            self?.onRefresh?()
        }
        configureButton(bookActionButton, icon: .download, label: L10n.Reader.offlineCache) { [weak self] in
            self?.onBookAction?()
        }
        configureButton(moreButton, icon: .more, label: L10n.Reader.menuMore) { [weak self] in
            self?.onMore?()
        }
        changeSourceButton.accessibilityIdentifier = UIIdentifiers.Reader.changeSourceButton
        refreshButton.accessibilityIdentifier = UIIdentifiers.Reader.refreshButton
        moreButton.accessibilityIdentifier = UIIdentifiers.Reader.moreButton
        changeSourceButton.configureSecondaryAction(name: "换源选项") { [weak self] in
            self?.onChangeSourceLongPress?() ?? false
        }
        refreshButton.configureSecondaryAction(name: "刷新选项") { [weak self] in
            self?.onRefreshLongPress?() ?? false
        }

        titleButton.contentHorizontalAlignment = .leading
        titleButton.contentVerticalAlignment = .center
        titleButton.titleLabel?.numberOfLines = 1
        titleButton.titleLabel?.adjustsFontForContentSizeCategory = false
        titleButton.titleLabel?.adjustsFontSizeToFitWidth = false
        titleButton.titleLabel?.lineBreakMode = .byTruncatingTail
        titleButton.clipsToBounds = true
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleButton.addAction(UIAction { [weak self] _ in self?.onBookInfo?() }, for: .touchUpInside)
        updateTypography()
        for item in [backButton, titleButton, changeSourceButton, refreshButton, bookActionButton, moreButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            addSubview(item)
        }

        let navigationLeading = backButton.leadingAnchor.constraint(equalTo: leadingAnchor)
        let overflowTrailing = moreButton.trailingAnchor.constraint(equalTo: trailingAnchor)
        navigationLeadingConstraint = navigationLeading
        overflowTrailingConstraint = overflowTrailing
        var constraints: [NSLayoutConstraint] = [
            navigationLeading,
            backButton.topAnchor.constraint(equalTo: topAnchor),
            backButton.widthAnchor.constraint(equalToConstant: Metrics.navigationWidth),

            changeSourceButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: bookActionButton.leadingAnchor),
            bookActionButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor),
            overflowTrailing,

            titleButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            titleButton.trailingAnchor.constraint(equalTo: changeSourceButton.leadingAnchor),
            titleButton.topAnchor.constraint(equalTo: topAnchor),
            titleButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        for button in [backButton, changeSourceButton, refreshButton, bookActionButton, moreButton] {
            if button !== backButton { constraints.append(button.topAnchor.constraint(equalTo: topAnchor)) }
            let height = button.heightAnchor.constraint(
                equalToConstant: AndroidToolbarLayout.minimumHeight(for: availableLayoutSize))
            actionHeightConstraints.append(height)
            constraints.append(height)
        }
        let changeSourceWidth = changeSourceButton.widthAnchor.constraint(equalToConstant: Metrics.actionWidth)
        let refreshWidth = refreshButton.widthAnchor.constraint(equalToConstant: Metrics.actionWidth)
        changeSourceWidthConstraint = changeSourceWidth
        refreshWidthConstraint = refreshWidth
        constraints.append(contentsOf: [
            changeSourceWidth, refreshWidth,
            bookActionButton.widthAnchor.constraint(equalToConstant: Metrics.actionWidth),
            moreButton.widthAnchor.constraint(equalToConstant: Metrics.overflowWidth),
        ])
        NSLayoutConstraint.activate(constraints)
        updateBookLocalState(isLocal: false)
    }

    private func updateTypography() {
        // ToolbarTitle overrides AppCompat's fixed 20dp with 20sp; App fontScale still applies.
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        titleButton.titleLabel?.font = font
        let scale = max(window?.screen.scale ?? traitCollection.displayScale, 1)
        titleFontPadding = AndroidExploreTextMetrics.padding(font: font, scale: scale)
        paddedTitleHeight = ceil((font.lineHeight + titleFontPadding.top + titleFontPadding.bottom) * scale) / scale
        updateDirectionalInsets()
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        superview?.setNeedsLayout()
    }

    private func updateDirectionalInsets() {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        // AppCompat titleMarginStart/End and overflow padding mirror with the toolbar.
        let titleStart =
            AndroidToolbarLayout.contentInsetStartWithNavigation(for: availableLayoutSize)
            + Metrics.titleMargin - Metrics.navigationWidth
        titleButton.contentEdgeInsets = UIEdgeInsets(
            top: titleFontPadding.top + AndroidToolbarLayout.titleVerticalMargins / 2,
            left: isRTL ? Metrics.titleMargin : titleStart,
            bottom: titleFontPadding.bottom + AndroidToolbarLayout.titleVerticalMargins / 2,
            right: isRTL ? titleStart : Metrics.titleMargin)
        titleButton.titleLabel?.textAlignment = isRTL ? .right : .left
        moreButton.contentEdgeInsets = UIEdgeInsets(
            top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
    }

    private func configureButton(
        _ button: ReaderMenuActionButton, icon: ReaderMenuAndroidIcon, label: String,
        onTap: @escaping () -> Void
    ) {
        button.setImage(icon.image(), for: .normal)
        button.setPreferredSymbolConfiguration(
            UIImage.SymbolConfiguration(pointSize: 20, weight: .regular), forImageIn: .normal)
        button.accessibilityLabel = label
        button.onTap = onTap
    }
}

enum ReaderMenuToolbarInteraction {
    static func isAvailable(_ control: UIControl) -> Bool {
        guard control.isEnabled, let window = control.window, !control.bounds.isEmpty else {
            return false
        }
        var visibleFrame = control.convert(control.bounds, to: window).intersection(window.bounds)
        guard !visibleFrame.isEmpty else { return false }
        var ancestor: UIView? = control
        while let view = ancestor {
            guard !view.isHidden, view.alpha > 0.01, view.isUserInteractionEnabled else { return false }
            if view.clipsToBounds {
                visibleFrame = visibleFrame.intersection(view.convert(view.bounds, to: window))
                guard !visibleFrame.isEmpty else { return false }
            }
            ancestor = view.superview
        }
        return true
    }
}
