import UIKit

/// activity_cache_book.xml / book_cache.xml at Legado 5f5d314:
/// a minimum 56pt title bar with a group subtitle and fixed action slots.
final class CacheManagementToolbarView: UIView {
    let backButton = UIButton(type: .custom)
    let downloadButton = UIButton(type: .custom)
    let groupButton = UIButton(type: .custom)
    let moreButton = UIButton(type: .custom)

    private let titleLabel = AndroidCacheTextLabel()
    private let subtitleLabel = AndroidCacheTextLabel()
    private var heightConstraint: NSLayoutConstraint?
    private let downloadToolTip = UIToolTipInteraction(defaultToolTip: "下载")
    private let playImage = CacheManagementToolbarView.icon(named: "SearchToolbarAndroidPlay")
    private let stopImage = CacheManagementToolbarView.icon(named: "ChangeSourceAndroidStop")

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        heightConstraint = heightAnchor.constraint(equalToConstant: 56)
        heightConstraint?.isActive = true

        configure(backButton, asset: "ReaderMenuAndroidBack", label: "返回", identifier: "back")
        configure(downloadButton, asset: nil, label: "下载", identifier: "download")
        configure(groupButton, asset: "BookDetailAndroidGroups", label: "分组", identifier: "group")
        configure(moreButton, asset: "ReaderMenuAndroidMore", label: "更多", identifier: "more")
        moreButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        downloadButton.addInteraction(downloadToolTip)

        for label in [titleLabel, subtitleLabel] {
            label.textColor = AndroidReplicaTheme.toolbarText
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.clipsToBounds = true
            label.isAccessibilityElement = true
            addSubview(label)
        }
        titleLabel.text = "离线缓存"
        titleLabel.accessibilityTraits = .header
        applyFonts()
        update(subtitle: "", isRunning: false, enabled: true)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: toolbarHeight)
    }

    /// The caller supplies the group text unchanged and attaches all button targets.
    func update(subtitle: String, isRunning: Bool, enabled: Bool, canDownload: Bool = true, isStopping: Bool = false) {
        subtitleLabel.text = subtitle.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "\u{FEFF}")
        subtitleLabel.accessibilityLabel = subtitle
        subtitleLabel.isHidden = subtitle.isEmpty

        let downloadTitle = isRunning ? "停止" : "下载"
        downloadButton.setImage(isRunning ? stopImage : playImage, for: .normal)
        downloadButton.accessibilityLabel = downloadTitle
        downloadButton.accessibilityValue = isStopping ? "正在停止" : (isRunning ? "正在下载" : nil)
        downloadToolTip.defaultToolTip = downloadTitle

        backButton.isEnabled = true
        backButton.alpha = 1
        for button in [downloadButton, groupButton, moreButton] {
            button.isEnabled = enabled
            button.alpha = enabled ? 1 : 0.38
        }
        downloadButton.isEnabled = enabled && canDownload && !isStopping
        downloadButton.alpha = downloadButton.isEnabled ? 1 : 0.38

        var elements: [UIView] = [backButton, titleLabel]
        if !subtitle.isEmpty { elements.append(subtitleLabel) }
        elements.append(contentsOf: [downloadButton, groupButton, moreButton])
        accessibilityElements = elements
        updateHeight()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = CGRect(
            x: bounds.minX + safeAreaInsets.left,
            y: bounds.minY,
            width: max(0, bounds.width - safeAreaInsets.left - safeAreaInsets.right),
            height: bounds.height)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft

        // Coordinates below run from semantic leading to trailing; mirror once for RTL.
        func rect(leading: CGFloat, width: CGFloat, y: CGFloat = 0, height: CGFloat = 56) -> CGRect {
            CGRect(
                x: isRTL ? content.maxX - leading - width : content.minX + leading,
                y: content.minY + y,
                width: width,
                height: height)
        }

        backButton.frame = rect(leading: 0, width: 56, y: (content.height - 56) / 2)
        // AppCompat actions are 48dp; overflow is a 24dp icon with 6dp/10dp padding.
        let actionsLeading = content.width - 136
        let actionTop = (content.height - 48) / 2
        downloadButton.frame = rect(leading: actionsLeading, width: 48, y: actionTop, height: 48)
        groupButton.frame = rect(leading: actionsLeading + 48, width: 48, y: actionTop, height: 48)
        moreButton.frame = rect(leading: actionsLeading + 96, width: 40, y: actionTop, height: 48)
        moreButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: isRTL ? 10 : 6, bottom: 0, right: isRTL ? 6 : 10)

        // Only text yields space. Button hit regions and 24pt icons never shrink.
        // Toolbar's 72dp navigation inset is followed by its 4dp title margin.
        let textLeading = min(76, max(56, actionsLeading))
        let textWidth = max(0, actionsLeading - 4 - textLeading)
        let titleHeight = titleLabel.intrinsicContentSize.height
        let subtitleHeight: CGFloat = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.height
        let textTop = (content.height - titleHeight - subtitleHeight) / 2
        titleLabel.textAlignment = isRTL ? .right : .left
        subtitleLabel.textAlignment = titleLabel.textAlignment
        titleLabel.frame = rect(leading: textLeading, width: textWidth, y: textTop, height: titleHeight)
        subtitleLabel.frame = rect(
            leading: textLeading, width: textWidth, y: textTop + titleHeight, height: subtitleHeight)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyFonts()
    }

    private func applyFonts() {
        // ToolbarTitle overrides the title to 20sp; AppCompat's subtitle remains 16dp.
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        subtitleLabel.font = ReaderAndroidDefaultFont.font(size: 16) ?? .systemFont(ofSize: 16)
        updateHeight()
    }

    private var toolbarHeight: CGFloat {
        let subtitleHeight = subtitleLabel.isHidden ? 0 : subtitleLabel.intrinsicContentSize.height
        return max(
            56,
            AndroidCacheTextMetrics.ceilToPixel(
                titleLabel.intrinsicContentSize.height + subtitleHeight + 8, scale: traitCollection.displayScale))
    }

    private func updateHeight() {
        heightConstraint?.constant = toolbarHeight
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func configure(_ button: UIButton, asset: String?, label: String, identifier: String) {
        button.configuration = nil
        button.automaticallyUpdatesConfiguration = false
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.imageView?.contentMode = .center
        button.adjustsImageWhenDisabled = false
        button.accessibilityLabel = label
        button.accessibilityIdentifier = "cacheManagement.\(identifier)"
        if let asset { button.setImage(Self.icon(named: asset), for: .normal) }
        if button !== downloadButton {
            button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        }
        addSubview(button)
    }

    private static func icon(named name: String) -> UIImage? {
        guard let source = UIImage(named: name) else { return nil }
        let size = CGSize(width: 24, height: 24)
        let image: UIImage
        if source.size == size {
            image = source
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.opaque = false
            image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                source.withRenderingMode(.alwaysOriginal).draw(in: CGRect(origin: .zero, size: size))
            }
        }
        let template = image.withRenderingMode(.alwaysTemplate)
        return name == "ReaderMenuAndroidBack"
            ? template.imageFlippedForRightToLeftLayoutDirection() : template
    }
}
