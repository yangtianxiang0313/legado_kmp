import UIKit

// Legado 5f5d31404: item_read_record.xml / activity_read_record.xml.
final class ReadRecordTableViewCell: UITableViewCell {
    static let reuseIdentifier = "ReadRecordTableViewCell"
    private let recordView = ReadRecordContentView(isSummary: false)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = AndroidReplicaTheme.background
        contentView.backgroundColor = .clear
        isAccessibilityElement = false
        let selection = UIView()
        selection.backgroundColor = AndroidReplicaTheme.activeIndicator
        selectedBackgroundView = selection
        recordView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(recordView)
        NSLayoutConstraint.activate([
            recordView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            recordView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            recordView.topAnchor.constraint(equalTo: contentView.topAnchor),
            recordView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        accessibilityElements = [recordView]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(
        bookName: String, time: String, lastRead: String, canClear: Bool, onClear: (() -> Void)?
    ) {
        recordView.configure(title: bookName, values: [time, lastRead], canClear: canClear, onClear: onClear)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        recordView.configure(title: "", values: ["", ""], canClear: false, onClear: nil)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let width = targetSize.width > 0 ? targetSize.width : contentView.bounds.width
        return recordView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

final class ReadRecordSummaryView: UIView {
    private let recordView = ReadRecordContentView(isSummary: true)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        accessibilityIdentifier = "readRecord.summary"
        isAccessibilityElement = false
        recordView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(recordView)
        NSLayoutConstraint.activate([
            recordView.leadingAnchor.constraint(equalTo: leadingAnchor),
            recordView.trailingAnchor.constraint(equalTo: trailingAnchor),
            recordView.topAnchor.constraint(equalTo: topAnchor),
            recordView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        accessibilityElements = [recordView]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(totalTime: String, canClear: Bool, onClear: (() -> Void)?) {
        recordView.configure(title: ReadRecordText.totalTime, values: [totalTime], canClear: canClear, onClear: onClear)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: CGSize {
        let height = bounds.width > 0 ? sizeThatFits(bounds.size).height : recordView.intrinsicContentSize.height
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize { recordView.sizeThatFits(size) }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        sizeThatFits(targetSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if recordView.bounds.width != bounds.width { invalidateIntrinsicContentSize() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        invalidateIntrinsicContentSize()
    }
}

private enum ReadRecordText {
    static let totalTime = NSLocalizedString(
        "readRecord.totalTime", value: "总阅读时间", comment: "Android all_read_time")
    static let readingTime = NSLocalizedString(
        "readRecord.readingTime", value: "阅读时长:", comment: "Android reading_time_tag")
    static let lastRead = NSLocalizedString(
        "readRecord.lastRead", value: "最后阅读时间:", comment: "Android last_read_time_tag")
    static let clear = NSLocalizedString("readRecord.clear", value: "清除", comment: "Android clear")
}

private enum ReadRecordTypography {
    static func font(traits: UITraitCollection) -> UIFont {
        ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
    }

    static func padding(font: UIFont, traits: UITraitCollection) -> UIEdgeInsets {
        let natural = AndroidExploreTextMetrics.padding(font: font, scale: traits.displayScale)
        return UIEdgeInsets(top: natural.top + 6, left: 6, bottom: natural.bottom + 6, right: 6)
    }

    static func roundUp(_ value: CGFloat, traits: UITraitCollection) -> CGFloat {
        let scale = max(1, traits.displayScale)
        return ceil(value * scale) / scale
    }
}

private final class ReadRecordTextLabel: UILabel {
    private var rawText = ""

    func setRawText(_ text: String, singleLine: Bool = false) {
        rawText = text
        // SingleLineTransformationMethod affects rendering, never the source or AX text.
        self.text =
            singleLine
            ? text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: "\u{FEFF}")
            : text
        accessibilityLabel = rawText
        invalidateIntrinsicContentSize()
    }

    private var padding: UIEdgeInsets {
        ReadRecordTypography.padding(font: font, traits: traitCollection)
    }

    func measuredSize(width: CGFloat, singleLine: Bool) -> CGSize {
        let padding = padding
        let textWidth = max(1, width - padding.left - padding.right)
        let text = (self.text ?? "") as NSString
        let size =
            singleLine
            ? text.size(withAttributes: [.font: font as UIFont])
            : text.boundingRect(
                with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font as UIFont], context: nil
            ).size
        return CGSize(
            width: ReadRecordTypography.roundUp(size.width + padding.left + padding.right, traits: traitCollection),
            height: ReadRecordTypography.roundUp(
                max(font.lineHeight, size.height) + padding.top + padding.bottom, traits: traitCollection))
    }

    override var intrinsicContentSize: CGSize {
        measuredSize(width: .greatestFiniteMagnitude, singleLine: true)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        measuredSize(width: size.width, singleLine: numberOfLines == 1)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: padding))
    }
}

private final class ReadRecordDetailView: UIView {
    private let tagLabel: ReadRecordTextLabel?
    private let valueLabel = ReadRecordTextLabel()

    init(tag: String?) {
        tagLabel = tag.map { text in
            let label = ReadRecordTextLabel()
            label.setRawText(text)
            return label
        }
        super.init(frame: .zero)
        isAccessibilityElement = false
        let labels = [tagLabel, valueLabel].compactMap { $0 }
        for label in labels {
            label.textColor = AndroidReplicaTheme.secondaryText
            label.adjustsFontForContentSizeCategory = false
            label.adjustsFontSizeToFitWidth = false
            label.clipsToBounds = true
            label.isAccessibilityElement = true
            addSubview(label)
        }
        accessibilityElements = labels
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(value: String) {
        valueLabel.setRawText(value)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    func apply(font: UIFont) {
        tagLabel?.font = font
        valueLabel.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func arrangement(width: CGFloat) -> (tag: CGRect, value: CGRect, height: CGFloat, stacked: Bool) {
        let width = max(0, width)
        let valueHeight = valueLabel.measuredSize(width: width, singleLine: false).height
        guard let tagLabel else {
            return (.zero, CGRect(x: 0, y: 0, width: width, height: valueHeight), valueHeight, false)
        }
        let tagSize = tagLabel.measuredSize(width: width, singleLine: true)
        let minimumValue = min(
            valueLabel.intrinsicContentSize.width, 3 * valueLabel.font.pointSize + 12)
        let stacked = tagSize.width + minimumValue > width
        if stacked {
            let tagHeight = tagLabel.measuredSize(width: width, singleLine: false).height
            return (
                CGRect(x: 0, y: 0, width: width, height: tagHeight),
                CGRect(x: 0, y: tagHeight, width: width, height: valueHeight), tagHeight + valueHeight, true
            )
        }
        let remainingWidth = max(0, width - tagSize.width)
        let remainingHeight = valueLabel.measuredSize(width: remainingWidth, singleLine: false).height
        let height = max(tagSize.height, remainingHeight)
        return (
            CGRect(x: 0, y: 0, width: tagSize.width, height: tagSize.height),
            CGRect(x: tagSize.width, y: 0, width: remainingWidth, height: remainingHeight), height, false
        )
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrangement(width: size.width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let layout = arrangement(width: bounds.width)
        tagLabel?.numberOfLines = layout.stacked ? 0 : 1
        tagLabel?.lineBreakMode = layout.stacked ? .byWordWrapping : .byTruncatingTail
        valueLabel.numberOfLines = 0
        valueLabel.lineBreakMode = .byWordWrapping
        tagLabel?.frame = layout.tag
        valueLabel.frame = layout.value
    }
}

private final class ReadRecordClearButton: UIButton {
    private let text = ReadRecordTextLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configuration = nil
        automaticallyUpdatesConfiguration = false
        adjustsImageWhenHighlighted = false
        isExclusiveTouch = true
        isAccessibilityElement = true
        accessibilityLabel = ReadRecordText.clear
        text.setRawText(ReadRecordText.clear)
        text.numberOfLines = 0
        text.lineBreakMode = .byCharWrapping
        text.textAlignment = .center
        text.textColor = AndroidReplicaTheme.primaryText
        text.isAccessibilityElement = false
        text.isUserInteractionEnabled = false
        text.clipsToBounds = true
        clipsToBounds = true
        addSubview(text)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func apply(font: UIFont) {
        text.font = font
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize { text.intrinsicContentSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: text.measuredSize(width: size.width, singleLine: false).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        text.frame = bounds
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted && isEnabled ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.38
            if !isEnabled {
                cancelTracking(with: nil)
                isHighlighted = false
            }
        }
    }
}

private final class ReadRecordContentView: UIView {
    private let titleLabel = ReadRecordTextLabel()
    private let details: [ReadRecordDetailView]
    private let clearButton = ReadRecordClearButton(frame: .zero)
    private var onClear: (() -> Void)?
    private var measuredWidth: CGFloat = 0

    init(isSummary: Bool) {
        details =
            isSummary
            ? [ReadRecordDetailView(tag: nil)]
            : [ReadRecordDetailView(tag: ReadRecordText.readingTime), ReadRecordDetailView(tag: ReadRecordText.lastRead)]
        super.init(frame: .zero)
        isAccessibilityElement = false
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.adjustsFontForContentSizeCategory = false
        titleLabel.adjustsFontSizeToFitWidth = false
        titleLabel.clipsToBounds = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.isAccessibilityElement = true
        addSubview(titleLabel)
        for detail in details { addSubview(detail) }
        clearButton.accessibilityIdentifier = isSummary ? "readRecord.clearAll" : "readRecord.row.clear"
        clearButton.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clearButton.isEnabled = false
        addSubview(clearButton)
        var elements: [UIView] = [titleLabel]
        elements.append(contentsOf: details)
        elements.append(clearButton)
        accessibilityElements = elements
        if isSummary { titleLabel.setRawText(ReadRecordText.totalTime, singleLine: true) }
        applyTypography()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(title: String, values: [String], canClear: Bool, onClear: (() -> Void)?) {
        clearButton.cancelTracking(with: nil)
        clearButton.isHighlighted = false
        self.onClear = canClear ? onClear : nil
        titleLabel.setRawText(title, singleLine: true)
        for (detail, value) in zip(details, values) { detail.configure(value: value) }
        clearButton.isEnabled = canClear && onClear != nil
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func geometry(width: CGFloat) -> (inset: CGFloat, columnWidth: CGFloat, actionWidth: CGFloat, height: CGFloat) {
        let inset = min(10, max(0, width / 2))
        let available = max(0, width - 2 * inset)
        let actionWidth = min(clearButton.intrinsicContentSize.width, available / 2)
        let columnWidth = max(0, available - actionWidth)
        let titleHeight = titleLabel.measuredSize(width: columnWidth, singleLine: true).height
        let detailsHeight = details.reduce(CGFloat.zero) { height, detail in
            height + detail.sizeThatFits(CGSize(width: columnWidth, height: .greatestFiniteMagnitude)).height
        }
        let actionHeight = clearButton.sizeThatFits(CGSize(width: actionWidth, height: .greatestFiniteMagnitude)).height
        return (inset, columnWidth, actionWidth, max(titleHeight + detailsHeight, actionHeight))
    }

    override var intrinsicContentSize: CGSize {
        let width = bounds.width > 0 ? bounds.width : CGFloat.greatestFiniteMagnitude
        return CGSize(width: UIView.noIntrinsicMetric, height: geometry(width: width).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = size.width > 0 ? size.width : CGFloat.greatestFiniteMagnitude
        return CGSize(width: max(0, size.width), height: geometry(width: width).height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
            superview?.invalidateIntrinsicContentSize()
        }
        let layout = geometry(width: bounds.width)
        var y: CGFloat = 0
        let titleHeight = titleLabel.measuredSize(width: layout.columnWidth, singleLine: true).height
        titleLabel.frame = CGRect(x: layout.inset, y: y, width: layout.columnWidth, height: titleHeight)
        y += titleHeight
        for detail in details {
            let height = detail.sizeThatFits(CGSize(width: layout.columnWidth, height: .greatestFiniteMagnitude)).height
            detail.frame = CGRect(x: layout.inset, y: y, width: layout.columnWidth, height: height)
            y += height
        }
        let actionHeight = clearButton.sizeThatFits(
            CGSize(width: layout.actionWidth, height: .greatestFiniteMagnitude)
        ).height
        clearButton.frame = CGRect(
            x: bounds.width - layout.inset - layout.actionWidth,
            y: max(0, (max(bounds.height, layout.height) - actionHeight) / 2),
            width: layout.actionWidth, height: actionHeight)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyTypography()
    }

    private func applyTypography() {
        let font = ReadRecordTypography.font(traits: traitCollection)
        titleLabel.font = font
        for detail in details { detail.apply(font: font) }
        clearButton.apply(font: font)
        invalidateIntrinsicContentSize()
        superview?.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    @objc private func clearTapped() {
        guard clearButton.isEnabled else { return }
        onClear?()
    }
}
