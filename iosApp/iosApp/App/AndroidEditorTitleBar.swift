import UIKit

/// Legado TitleBar / AppCompat Toolbar slots shared by the two full-screen editors.
final class AndroidEditorTitleBar: NavigationToolbarView {
    let backButton = UIButton(type: .custom)
    let saveButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)
    let titleButton = UIButton(type: .custom)
    private let showsBack: Bool
    private let showsMore: Bool
    private let busyIndicator = UIActivityIndicatorView(style: .medium)

    init(title: String, showsBack: Bool = true, showsMore: Bool = false) {
        self.showsBack = showsBack
        self.showsMore = showsMore
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
        titleButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        busyIndicator.hidesWhenStopped = true
        busyIndicator.isUserInteractionEnabled = false
        busyIndicator.translatesAutoresizingMaskIntoConstraints = false
        saveButton.addSubview(busyIndicator)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 56),
            backButton.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: showsBack ? 56 : 0),
            backButton.heightAnchor.constraint(equalToConstant: 56),
            titleButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: showsBack ? 20 : 16),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleButton.heightAnchor.constraint(equalToConstant: 48),
            titleButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 0),
            titleButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -4),
            saveButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            saveButton.widthAnchor.constraint(equalToConstant: 48),
            saveButton.heightAnchor.constraint(equalToConstant: 48),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: showsMore ? 40 : 0),
            moreButton.heightAnchor.constraint(equalToConstant: 48),
            moreButton.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor),
            moreButton.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            busyIndicator.centerXAnchor.constraint(equalTo: saveButton.centerXAnchor),
            busyIndicator.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])
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
