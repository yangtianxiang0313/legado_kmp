import UIKit

final class AndroidCacheBookCell: UITableViewCell {
    struct Model {
        let bookURL: String
        let name: String
        let author: String
        let cacheText: String
        let message: String?
        let isLocal: Bool
        let isRunning: Bool
        let isStopping: Bool
        let canDownload: Bool
        let canExport: Bool
        let isExporting: Bool
        // Normalized 0...1; invalid values do not represent an export state.
        let exportProgress: Float?
    }

    static let reuseIdentifier = "AndroidCacheBookCell"

    var onDownload: (() -> Void)?
    var onExport: (() -> Void)?
    var exportAnchor: UIView { exportButton }

    private var model: Model?
    private let nameLabel = AndroidCacheTextLabel()
    private let authorLabel = AndroidCacheTextLabel()
    private let cacheLabel = AndroidCacheTextLabel()
    private let messageLabel = AndroidCacheTextLabel()
    private let identityStack = UIStackView()
    private let headerStack = UIStackView()
    private let contentStack = UIStackView()
    private let downloadButton = AndroidCachePaddedButton(isIcon: true)
    private let exportButton = AndroidCachePaddedButton(isIcon: false)
    private let exportProgressView = UIProgressView(progressViewStyle: .default)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        accessoryType = .none
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = AndroidReplicaTheme.background
        isAccessibilityElement = false
        contentView.isAccessibilityElement = false

        identityStack.axis = .vertical
        identityStack.spacing = 0
        identityStack.isAccessibilityElement = true
        identityStack.accessibilityTraits = .staticText
        identityStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        identityStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for label in [nameLabel, authorLabel, cacheLabel, messageLabel] {
            label.textColor = AndroidReplicaTheme.primaryText
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        for label in [nameLabel, authorLabel, cacheLabel] {
            label.isAccessibilityElement = false
            identityStack.addArrangedSubview(label)
        }
        cacheLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.numberOfLines = 0
        messageLabel.lineBreakMode = .byWordWrapping

        exportButton.setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        downloadButton.tintColor = AndroidReplicaTheme.primaryText
        for button in [downloadButton, exportButton] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        headerStack.axis = .horizontal
        headerStack.alignment = .center
        headerStack.spacing = 0
        for view in [identityStack, downloadButton, exportButton] {
            headerStack.addArrangedSubview(view)
        }
        let downloadWidth = downloadButton.widthAnchor.constraint(equalToConstant: 36)
        downloadWidth.priority = .init(999)
        downloadWidth.isActive = true
        downloadButton.heightAnchor.constraint(equalToConstant: 36).isActive = true

        exportProgressView.progressTintColor = AndroidReplicaTheme.accent
        exportProgressView.trackTintColor = AndroidReplicaTheme.divider
        exportProgressView.isAccessibilityElement = true
        contentStack.axis = .vertical
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        for view in [headerStack, messageLabel, exportProgressView] {
            contentStack.addArrangedSubview(view)
        }
        contentView.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: contentView.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(
                equalTo: contentView.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            contentStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            contentStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
        ])
        downloadButton.addTarget(self, action: #selector(downloadTapped), for: .touchUpInside)
        exportButton.addTarget(self, action: #selector(exportTapped), for: .touchUpInside)
        updateFonts()
        clearPresentation()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(_ model: Model) {
        if self.model?.bookURL != model.bookURL {
            onDownload = nil
            onExport = nil
            clearPresentation()
        }
        self.model = model
        messageLabel.isHidden = true
        messageLabel.isAccessibilityElement = false
        exportProgressView.isHidden = true
        for button in [downloadButton, exportButton] {
            for tooltip in button.interactions.compactMap({ $0 as? UIToolTipInteraction }) {
                button.removeInteraction(tooltip)
            }
        }

        let cacheText = model.isLocal ? L10n.CacheManagement.localBook : model.cacheText
        let authorText = "作者：\(model.author)"
        let identity = "\(model.name)，\(authorText)"
        // item_download uses singleLine, including Android's newline transformation.
        nameLabel.text = singleLine(model.name)
        authorLabel.text = singleLine(authorText)
        cacheLabel.text = singleLine(cacheText)
        identityStack.accessibilityLabel = "\(identity)，\(cacheText)"

        let showsStop = model.isRunning || model.isStopping
        let downloadAction = showsStop ? "停止" : "开始"
        let downloadLabel = "\(downloadAction)，\(identity)"
        downloadButton.setImage(
            UIImage(named: showsStop ? "ChangeSourceAndroidStop" : "SearchToolbarAndroidPlay")?
                .withRenderingMode(.alwaysTemplate), for: .normal)
        downloadButton.isHidden = model.isLocal
        downloadButton.isEnabled =
            !model.isLocal && !model.isStopping
            && (model.isRunning || model.canDownload)
        downloadButton.accessibilityIdentifier = "cacheManagement.download.\(model.bookURL)"
        downloadButton.accessibilityLabel = downloadLabel
        downloadButton.accessibilityValue = model.isStopping ? "正在停止" : (model.isRunning ? "正在下载" : nil)
        downloadButton.addInteraction(UIToolTipInteraction(defaultToolTip: downloadLabel))

        let progress = validProgress(model.exportProgress)
        let exportLabel = "导出，\(identity)"
        exportButton.setTitle("导出", for: .normal)
        exportButton.isEnabled = model.canExport && !model.isExporting && progress == nil
        exportButton.accessibilityIdentifier = "cacheManagement.export.\(model.bookURL)"
        exportButton.accessibilityLabel = exportLabel
        exportButton.accessibilityValue = model.isExporting || progress != nil ? L10n.CacheManagement.exporting : nil
        exportButton.addInteraction(UIToolTipInteraction(defaultToolTip: exportLabel))

        var elements: [Any] = [identityStack]
        if !model.isLocal { elements.append(downloadButton) }
        elements.append(exportButton)
        if let message = model.message,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            messageLabel.text = message
            messageLabel.isHidden = false
            messageLabel.isAccessibilityElement = true
            elements.append(messageLabel)
        } else if let progress {
            exportProgressView.setProgress(progress, animated: false)
            exportProgressView.isHidden = false
            exportProgressView.accessibilityLabel = "\(L10n.CacheManagement.exporting)，\(identity)"
            exportProgressView.accessibilityValue = "\(Int((progress * 100).rounded()))%"
            elements.append(exportProgressView)
        }
        accessibilityElements = elements
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        model = nil
        onDownload = nil
        onExport = nil
        clearPresentation()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory
            || previousTraitCollection?.displayScale != traitCollection.displayScale
        {
            updateFonts()
        }
    }

    private func updateFonts() {
        let font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .footnote, compatibleWith: traitCollection)
        for label in [nameLabel, authorLabel, cacheLabel, messageLabel] {
            label.font = font
            label.invalidateIntrinsicContentSize()
        }
        exportButton.applyFont(font)
    }

    private func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
    }

    private func validProgress(_ progress: Float?) -> Float? {
        guard let progress, progress.isFinite, (0...1).contains(progress) else { return nil }
        return progress
    }

    private func clearPresentation() {
        setHighlighted(false, animated: false)
        setSelected(false, animated: false)
        selectionStyle = .none
        isAccessibilityElement = false
        accessibilityElements = nil
        for view in [
            self, contentView, identityStack, nameLabel, authorLabel, cacheLabel,
            messageLabel, downloadButton, exportButton, exportProgressView,
        ] {
            view.accessibilityLabel = nil
            view.accessibilityValue = nil
            view.accessibilityHint = nil
            view.accessibilityIdentifier = nil
            view.accessibilityCustomActions = nil
            for tooltip in view.interactions.compactMap({ $0 as? UIToolTipInteraction }) {
                view.removeInteraction(tooltip)
            }
        }
        for label in [nameLabel, authorLabel, cacheLabel, messageLabel] { label.text = nil }
        identityStack.accessibilityTraits = .staticText
        messageLabel.isHidden = true
        messageLabel.isAccessibilityElement = false
        exportProgressView.isHidden = true
        exportProgressView.setProgress(0, animated: false)
        exportProgressView.layer.removeAllAnimations()
        for button in [downloadButton, exportButton] {
            button.cancelTracking(with: nil)
            button.isHighlighted = false
            button.isSelected = false
            button.isEnabled = false
            button.accessibilityTraits = [.button, .notEnabled]
            button.setImage(nil, for: .normal)
            button.setTitle(nil, for: .normal)
        }
        downloadButton.isHidden = true
    }

    @objc private func downloadTapped() {
        guard let model, !model.isLocal, !model.isStopping,
            model.isRunning || model.canDownload
        else { return }
        onDownload?()
    }

    @objc private func exportTapped() {
        guard let model, model.canExport, !model.isExporting, validProgress(model.exportProgress) == nil else { return }
        onExport?()
    }
}

// TextView's includeFontPadding applies once around the whole message, not to every line.
enum AndroidCacheTextMetrics {
    static func ceilToPixel(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(1, scale)
        return ceil(value * scale) / scale
    }

    static func padding(font: UIFont, scale: CGFloat) -> UIEdgeInsets {
        AndroidExploreTextMetrics.padding(font: font, scale: scale)
    }
}

final class AndroidCacheTextLabel: UILabel {
    private var fontPadding: UIEdgeInsets {
        AndroidCacheTextMetrics.padding(font: font, scale: traitCollection.displayScale)
    }

    override var intrinsicContentSize: CGSize {
        paddedSize(super.intrinsicContentSize)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        return paddedSize(
            super.sizeThatFits(
                CGSize(width: size.width, height: max(0, size.height - padding.top - padding.bottom))))
    }

    override func layoutSubviews() {
        if numberOfLines != 1, bounds.width > 0, preferredMaxLayoutWidth != bounds.width {
            preferredMaxLayoutWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        super.layoutSubviews()
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: fontPadding))
    }

    private func paddedSize(_ size: CGSize) -> CGSize {
        let padding = fontPadding
        // Round the measured multiline block before adding font padding, then round again.
        let height = AndroidCacheTextMetrics.ceilToPixel(
            max(font.lineHeight, size.height), scale: traitCollection.displayScale)
        return CGSize(
            width: size.width,
            height: AndroidCacheTextMetrics.ceilToPixel(
                height + padding.top + padding.bottom, scale: traitCollection.displayScale))
    }
}

private final class AndroidCachePaddedButton: UIButton {
    private let isIcon: Bool
    private var textFont = UIFont.systemFont(ofSize: 14)

    init(isIcon: Bool) {
        self.isIcon = isIcon
        super.init(frame: .zero)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        imageView?.contentMode = .scaleAspectFit
        adjustsImageWhenDisabled = false
        isAccessibilityElement = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        if isIcon { return CGSize(width: 36, height: 36) }
        let size = ((currentTitle ?? "") as NSString).size(withAttributes: [.font: textFont])
        let padding = AndroidCacheTextMetrics.padding(font: textFont, scale: traitCollection.displayScale)
        return CGSize(
            width: AndroidCacheTextMetrics.ceilToPixel(size.width, scale: traitCollection.displayScale) + 20,
            height: AndroidCacheTextMetrics.ceilToPixel(
                max(textFont.lineHeight, size.height) + padding.top + padding.bottom,
                scale: traitCollection.displayScale) + 20)
    }

    func applyFont(_ font: UIFont) {
        textFont = font
        titleLabel?.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override func imageRect(forContentRect contentRect: CGRect) -> CGRect {
        guard isIcon else { return super.imageRect(forContentRect: contentRect) }
        return contentRect.insetBy(dx: 6, dy: 6)
    }

    override func titleRect(forContentRect contentRect: CGRect) -> CGRect {
        guard !isIcon else { return super.titleRect(forContentRect: contentRect) }
        // Never consult titleLabel here: UIButton can lazily create it through this override.
        let padding = AndroidCacheTextMetrics.padding(font: textFont, scale: traitCollection.displayScale)
        return contentRect.inset(
            by: UIEdgeInsets(top: 10 + padding.top, left: 10, bottom: 10 + padding.bottom, right: 10))
    }

    override var isHighlighted: Bool { didSet { updateAppearance() } }
    override var isEnabled: Bool { didSet { updateAppearance() } }

    private func updateAppearance() {
        alpha = isEnabled ? 1 : 0.38
        backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear
        accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
    }
}
