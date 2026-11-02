import UIKit

/// Legado TitleBar / AppCompat Toolbar slots shared by the two full-screen editors.
final class AndroidEditorTitleBar: NavigationToolbarView {
    let backButton = UIButton(type: .custom)
    let saveButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    let titleButton = UIButton(type: .custom)
    private let showsBack: Bool
    private let showsMore: Bool
    private let wrapsTitle: Bool
    private var barHeight: NSLayoutConstraint!
    private var titleHeight: NSLayoutConstraint!
    private var inlineTitleConstraints: [NSLayoutConstraint] = []
    private var stackedTitleConstraints: [NSLayoutConstraint] = []
    private var inlineIconConstraints: [NSLayoutConstraint] = []
    private var stackedIconConstraints: [NSLayoutConstraint] = []
    private var usesStackedTitle = false
    private let busyIndicator = UIActivityIndicatorView(style: .medium)

    init(title: String, showsBack: Bool = true, showsMore: Bool = false, wrapsTitle: Bool = false) {
        self.showsBack = showsBack
        self.showsMore = showsMore
        self.wrapsTitle = wrapsTitle
        super.init(frame: .zero)
        backButton.setImage(ReaderMenuAndroidIcon.back.image(), for: .normal)
        saveButton.setImage(UIImage(named: "EditorAndroidSave")?.withRenderingMode(.alwaysTemplate), for: .normal)
        moreButton.setImage(ReaderMenuAndroidIcon.more.image(), for: .normal)
        backButton.accessibilityLabel = L10n.Reader.backAction
        saveButton.accessibilityLabel = L10n.Common.save
        moreButton.accessibilityLabel = L10n.Reader.moreActionTitle
        for button in [backButton, saveButton, moreButton, titleButton] {
            button.configuration = nil
            button.automaticallyUpdatesConfiguration = false
            button.backgroundColor = .clear
            button.imageView?.contentMode = .center
            button.titleLabel?.lineBreakMode = .byTruncatingTail
            button.contentEdgeInsets = .zero
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }
        for button in [backButton, saveButton, moreButton] {
            button.addInteraction(UIToolTipInteraction(defaultToolTip: button.accessibilityLabel ?? ""))
        }
        backButton.isHidden = !showsBack
        moreButton.isHidden = !showsMore
        titleButton.setAttributedTitle(
            NSAttributedString(string: title, attributes: [.kern: CGFloat(0)]), for: .normal)
        titleButton.contentHorizontalAlignment = .leading
        titleButton.isUserInteractionEnabled = false
        titleButton.accessibilityLabel = title
        titleButton.accessibilityTraits = [.header, .staticText]
        titleButton.titleLabel?.adjustsFontForContentSizeCategory = true
        if wrapsTitle {
            titleButton.titleLabel?.numberOfLines = 0
            titleButton.titleLabel?.lineBreakMode = .byWordWrapping
        }
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        busyIndicator.hidesWhenStopped = true
        busyIndicator.isUserInteractionEnabled = false
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addSubview(busyIndicator)

        barHeight = heightAnchor.constraint(equalToConstant: 56)
        titleHeight = titleButton.heightAnchor.constraint(equalToConstant: 48)
        inlineTitleConstraints = [
            titleButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: showsBack ? 20 : 16),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
        ]
        stackedTitleConstraints = [
            titleButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            titleButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            titleButton.topAnchor.constraint(equalTo: topAnchor, constant: 56),
        ]
        inlineIconConstraints = [backButton, saveButton, moreButton].map { $0.centerYAnchor.constraint(equalTo: centerYAnchor) }
        stackedIconConstraints = [backButton, saveButton, moreButton].map { $0.centerYAnchor.constraint(equalTo: topAnchor, constant: 28) }
        NSLayoutConstraint.activate(
            [
                barHeight,
                backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
                backButton.widthAnchor.constraint(equalToConstant: showsBack ? 56 : 0),
                backButton.heightAnchor.constraint(equalToConstant: 56),
                titleHeight,
                titleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
                saveButton.widthAnchor.constraint(equalToConstant: 48),
                saveButton.heightAnchor.constraint(equalToConstant: 48),
                moreButton.widthAnchor.constraint(equalToConstant: showsMore ? 40 : 0),
                moreButton.heightAnchor.constraint(equalToConstant: 48),
                moreButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor),
                moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
                busyIndicator.centerXAnchor.constraint(equalTo: saveButton.centerXAnchor),
                busyIndicator.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            ] + inlineTitleConstraints + inlineIconConstraints)
        applyTitleFont()
        applyPalette()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false {
            applyPalette()
        }
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            applyTitleFont()
        }
    }

    override func layoutSubviews() {
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let insets = UIEdgeInsets(top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)
        if moreButton.configuration == nil, moreButton.contentEdgeInsets != insets {
            moreButton.contentEdgeInsets = insets
        }
        super.layoutSubviews()
        if wrapsTitle, let label = titleButton.titleLabel, bounds.width > 0 {
            let availableWidth = max(0, safeAreaLayoutGuide.layoutFrame.width)
            let inlineWidth = max(0, availableWidth - (showsBack ? 76 : 16) - 48 - (showsMore ? 40 : 0) - 4)
            let longestWord =
                (titleButton.attributedTitle(for: .normal)?.string ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .map { (String($0) as NSString).size(withAttributes: [.font: label.font as Any]).width }
                .max() ?? 0
            let stacked = longestWord > inlineWidth + 0.5
            if usesStackedTitle != stacked {
                NSLayoutConstraint.deactivate(
                    usesStackedTitle ? stackedTitleConstraints + stackedIconConstraints : inlineTitleConstraints + inlineIconConstraints)
                usesStackedTitle = stacked
                NSLayoutConstraint.activate(
                    stacked ? stackedTitleConstraints + stackedIconConstraints : inlineTitleConstraints + inlineIconConstraints)
            }
            let titleWidth = stacked ? max(0, availableWidth - 32) : inlineWidth
            let height = max(
                48,
                ceil(
                    label.sizeThatFits(
                        CGSize(
                            width: titleWidth, height: .greatestFiniteMagnitude)
                    ).height))
            let heightOfBar = stacked ? 56 + height + 8 : max(56, height + 8)
            if abs(titleHeight.constant - height) > 0.5 || abs(barHeight.constant - heightOfBar) > 0.5 {
                titleHeight.constant = height
                barHeight.constant = heightOfBar
            }
        }
    }

    func setBusy(_ busy: Bool) {
        backButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        moreButton.isEnabled = !busy
        saveButton.imageView?.isHidden = busy
        busy ? busyIndicator.startAnimating() : busyIndicator.stopAnimating()
    }

    private func applyPalette() {
        for button in [backButton, saveButton, moreButton, titleButton] {
            button.tintColor = AndroidReplicaTheme.toolbarText
            if button.configuration == nil {
                button.setTitleColor(AndroidReplicaTheme.toolbarText, for: .normal)
            }
        }
        busyIndicator.color = AndroidReplicaTheme.toolbarText
    }

    private func applyTitleFont() {
        let size = min(32, UIFontMetrics(forTextStyle: .headline).scaledValue(for: 20, compatibleWith: traitCollection))
        titleButton.titleLabel?.font =
            ReaderAndroidDefaultFont.font(size: size, weight: 500)
            ?? .systemFont(ofSize: size, weight: .medium)
    }
}
