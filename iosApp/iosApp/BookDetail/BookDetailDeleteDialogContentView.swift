import UIKit

@MainActor
final class BookDetailDeleteDialogContentView: UIView {
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    var isEditingEnabled = true {
        didSet {
            fileControl.isEnabled = isEditingEnabled
            cancelControl.isEnabled = isEditingEnabled
            confirmControl.isEnabled = isEditingEnabled
        }
    }

    // Network books have no checkbox, but must not replace the incoming preference with false.
    var deleteOriginal: Bool { fileControl.isSelected }
    var accessibilityHeading: UIView { titleLabel }

    private let showsFileOption: Bool
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let fileControl = BookDetailDeleteDialogFileControl()
    private let cancelControl = BookshelfLayoutDialogAction(title: "否")
    private let confirmControl = BookshelfLayoutDialogAction(title: "是")

    init(showsFileOption: Bool, deleteOriginal: Bool) {
        self.showsFileOption = showsFileOption
        super.init(frame: .zero)
        // Fixed revision values-zh: draw / sure_del / delete_book_file / no / yes.
        BookshelfLayoutDialogStyle.configure(titleLabel, text: "提醒", color: AndroidReplicaTheme.primaryText)
        BookshelfLayoutDialogStyle.configure(messageLabel, text: "是否确认删除？", color: AndroidReplicaTheme.primaryText)
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "bookDetail.deleteDialog.title"
        messageLabel.accessibilityIdentifier = "bookDetail.deleteDialog.message"
        fileControl.isSelected = deleteOriginal
        fileControl.accessibilityIdentifier = "bookDetail.deleteDialog.deleteOriginal"
        cancelControl.accessibilityIdentifier = "bookDetail.deleteDialog.cancel"
        confirmControl.accessibilityIdentifier = "bookDetail.deleteDialog.confirm"
        fileControl.addTarget(self, action: #selector(toggleFile), for: .touchUpInside)
        cancelControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        confirmControl.addTarget(self, action: #selector(confirm), for: .touchUpInside)
        for child in [titleLabel, messageLabel, cancelControl, confirmControl] { addSubview(child) }
        var elements: [UIView] = [titleLabel, messageLabel]
        if showsFileOption {
            addSubview(fileControl)
            elements.append(fileControl)
        }
        accessibilityElements = elements + [cancelControl, confirmControl]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func applyFonts(traits: UITraitCollection) {
        titleLabel.font = BookshelfLayoutDialogStyle.font(
            size: 20, weight: .medium, style: .headline, traits: traits)
        messageLabel.font = BookshelfLayoutDialogStyle.font(size: 16, traits: traits)
        fileControl.apply(font: BookshelfLayoutDialogStyle.font(size: 14, traits: traits))
        let actionFont = BookshelfLayoutDialogStyle.font(size: 14, weight: .medium, traits: traits)
        cancelControl.apply(font: actionFont)
        confirmControl.apply(font: actionFont)
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, applyFrames: true)
    }

    private func arrange(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let textInset = min(24, max(0, (width - 1) / 2))
        let textWidth = max(1, width - textInset * 2)
        var y: CGFloat = 20
        for label in [titleLabel, messageLabel] {
            let height = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames { label.frame = CGRect(x: textInset, y: y, width: textWidth, height: height) }
            y += height + 16
        }
        if showsFileOption {
            // BookInfoActivity wraps its native CheckBox in 16dp horizontal padding.
            let inset = min(16, max(0, (width - 1) / 2))
            let rowWidth = max(1, width - inset * 2)
            let height = fileControl.sizeThatFits(CGSize(width: rowWidth, height: .greatestFiniteMagnitude)).height
            if applyFrames { fileControl.frame = CGRect(x: inset, y: y, width: rowWidth, height: height) }
            y += height + 12
        }
        return arrangeActions(width: width, top: y, applyFrames: applyFrames) + 8
    }

    private func arrangeActions(width: CGFloat, top: CGFloat, applyFrames: Bool) -> CGFloat {
        let inset = min(8, max(0, (width - 1) / 2))
        let availableWidth = max(1, width - inset * 2)
        let cancelWidth = cancelControl.preferredWidth
        let confirmWidth = confirmControl.preferredWidth
        let gap: CGFloat = 8
        if cancelWidth + confirmWidth + gap <= availableWidth {
            let height = max(
                cancelControl.sizeThatFits(CGSize(width: cancelWidth, height: .greatestFiniteMagnitude)).height,
                confirmControl.sizeThatFits(CGSize(width: confirmWidth, height: .greatestFiniteMagnitude)).height)
            if applyFrames {
                let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
                let confirmX = isRTL ? inset : width - inset - confirmWidth
                let cancelX = isRTL ? confirmX + confirmWidth + gap : confirmX - gap - cancelWidth
                cancelControl.frame = CGRect(x: cancelX, y: top, width: cancelWidth, height: height)
                confirmControl.frame = CGRect(x: confirmX, y: top, width: confirmWidth, height: height)
            }
            return top + height
        }
        // Keep all text and touch targets when either action no longer fits one row.
        let cancelHeight = cancelControl.sizeThatFits(
            CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        ).height
        let confirmHeight = confirmControl.sizeThatFits(
            CGSize(width: availableWidth, height: .greatestFiniteMagnitude)
        ).height
        if applyFrames {
            cancelControl.frame = CGRect(x: inset, y: top, width: availableWidth, height: cancelHeight)
            confirmControl.frame = CGRect(
                x: inset, y: top + cancelHeight + gap, width: availableWidth, height: confirmHeight)
        }
        return top + cancelHeight + gap + confirmHeight
    }

    @objc private func toggleFile() {
        guard isEditingEnabled, showsFileOption else { return }
        fileControl.isSelected.toggle()
    }

    @objc private func cancel() {
        guard isEditingEnabled else { return }
        onCancel?()
    }

    @objc private func confirm() {
        guard isEditingEnabled else { return }
        onConfirm?()
    }
}

private final class BookDetailDeleteDialogFileControl: UIControl {
    private let indicator = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        BookshelfLayoutDialogStyle.configure(label, text: "删除源文件", color: AndroidReplicaTheme.primaryText)
        label.isAccessibilityElement = false
        indicator.isAccessibilityElement = false
        indicator.isUserInteractionEnabled = false
        indicator.contentMode = .scaleAspectFit
        addSubview(indicator)
        addSubview(label)
        isAccessibilityElement = true
        accessibilityLabel = "删除源文件"
        updateSelection()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isSelected: Bool { didSet { updateSelection() } }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.5
            if !isEnabled { isHighlighted = false }
            updateSelection()
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? AndroidReplicaTheme.activeIndicator : .clear }
    }

    func apply(font: UIFont) {
        label.font = font
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let stacked = usesStackedLayout(width: size.width)
        let textWidth = max(1, size.width - (stacked ? 0 : 32))
        let textHeight = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        return CGSize(width: size.width, height: max(48, textHeight + (stacked ? 44 : 8)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let stacked = usesStackedLayout(width: bounds.width)
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        let markWidth = min(32, bounds.width)
        let textWidth = max(1, bounds.width - (stacked ? 0 : 32))
        let textHeight = ceil(label.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        indicator.frame = CGRect(
            x: isRTL ? bounds.width - markWidth : 0,
            y: stacked ? 4 : (bounds.height - 32) / 2, width: markWidth, height: 32)
        label.frame = CGRect(
            x: stacked || isRTL ? 0 : 32,
            y: stacked ? 40 : (bounds.height - textHeight) / 2, width: textWidth, height: textHeight)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    private func usesStackedLayout(width: CGFloat) -> Bool {
        width < 32 + ceil(label.font?.pointSize ?? 14)
    }

    private func updateSelection() {
        indicator.image = UIImage(named: isSelected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
            .withRenderingMode(.alwaysTemplate)
        indicator.tintColor = isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        var traits: UIAccessibilityTraits = .button
        if isSelected { traits.insert(.selected) }
        if !isEnabled { traits.insert(.notEnabled) }
        accessibilityTraits = traits
        accessibilityValue = isSelected ? "已选中" : "未选中"
    }
}
