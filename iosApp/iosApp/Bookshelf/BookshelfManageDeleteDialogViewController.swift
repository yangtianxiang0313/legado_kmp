import UIKit

@MainActor
final class BookshelfManageDeleteDialogViewController: UIViewController {
    private let showsFileOption: Bool
    private var completion: ((Bool) -> Void)?
    private let panel = UIView()
    private let scroll = UIScrollView()
    private let content = UIView()
    private let titleLabel = AndroidExploreTextLabel()
    private let message = AndroidExploreTextLabel()
    private let fileButton = UIButton(type: .custom)
    private let footer = BookshelfManageDeleteFooter()
    private var active = false
    private var closing = false

    init(showsFileOption: Bool, completion: @escaping (Bool) -> Void) {
        self.showsFileOption = showsFileOption
        self.completion = completion
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityViewIsModal = true
        let backdrop = UIControl()
        backdrop.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        backdrop.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        panel.backgroundColor = AndroidReplicaTheme.background
        panel.layer.cornerRadius = 3
        panel.clipsToBounds = true
        view.addSubview(panel)
        panel.addSubview(scroll)
        scroll.addSubview(content)
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false
        titleLabel.text = "提醒"
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.accessibilityTraits = .header
        message.text = "是否确认删除？"
        message.textColor = AndroidReplicaTheme.primaryText
        for label in [titleLabel, message] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = false
            content.addSubview(label)
        }
        fileButton.contentHorizontalAlignment = .leading
        fileButton.titleLabel?.numberOfLines = 0
        fileButton.setTitle("删除源文件", for: .normal)
        fileButton.setTitleColor(AndroidReplicaTheme.primaryText, for: .normal)
        fileButton.accessibilityIdentifier = "bookshelf.manage.delete.files"
        fileButton.addTarget(self, action: #selector(toggleFile), for: .touchUpInside)
        fileButton.isHidden = !showsFileOption
        fileButton.titleLabel?.adjustsFontForContentSizeCategory = false
        fileButton.titleEdgeInsets = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        content.addSubview(fileButton)
        for (button, action, id) in [
            (footer.cancelButton, #selector(cancel), "cancel"),
            (footer.confirmButton, #selector(confirm), "confirm"),
        ] {
            button.addTarget(self, action: action, for: .touchUpInside)
            button.accessibilityIdentifier = "bookshelf.manage.delete.\(id)"
            button.isEnabled = false
        }
        content.addSubview(footer)
        updateFonts()
        updateFile()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        active = true
        footer.cancelButton.isEnabled = true
        footer.confirmButton.isEnabled = true
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isBeingDismissed || presentingViewController?.isBeingDismissed == true {
            active = false
            completion = nil
            footer.cancelButton.isEnabled = false
            footer.confirmButton.isEnabled = false
        }
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if isViewLoaded { updateFonts() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let width = min(safe.width, view.bounds.width * dialogWidthFraction)
        let contentHeight = arrangeContent(width: width)
        let height = min(safe.height, contentHeight)
        panel.frame = CGRect(x: safe.midX - width / 2, y: safe.midY - height / 2, width: width, height: height)
        scroll.frame = panel.bounds
        content.frame = CGRect(x: 0, y: 0, width: width, height: contentHeight)
        scroll.contentSize = content.bounds.size
        scroll.isScrollEnabled = contentHeight > height
    }
    override func accessibilityPerformEscape() -> Bool {
        cancel()
        return true
    }

    private func updateFonts() {
        titleLabel.font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        message.font = ReaderAndroidDefaultFont.scaledFont(size: 16, textStyle: .body, compatibleWith: traitCollection)
        let fileFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, compatibleWith: traitCollection)
        fileButton.titleLabel?.font = fileFont
        let padding = AndroidExploreTextMetrics.padding(font: fileFont, scale: traitCollection.displayScale)
        fileButton.contentEdgeInsets = UIEdgeInsets(top: 4 + padding.top, left: 0, bottom: 4 + padding.bottom, right: 8)
        let actionFont = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traitCollection)
        for button in [footer.cancelButton, footer.confirmButton] {
            button.apply(font: actionFont)
        }
        view.setNeedsLayout()
    }

    private var dialogWidthFraction: CGFloat {
        let size = view.bounds.size
        let shortSide = min(size.width, size.height)
        let longSide = max(size.width, size.height)
        if shortSide >= 720 && longSide >= 960 { return size.width > size.height ? 0.45 : 0.72 }
        if shortSide >= 480 && longSide >= 640 { return size.width > size.height ? 0.55 : 0.80 }
        return size.width > size.height ? 0.65 : 0.95
    }

    private func arrangeContent(width: CGFloat) -> CGFloat {
        let textWidth = max(1, width - 48)
        let titleHeight = ceil(
            titleLabel.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        titleLabel.frame = CGRect(x: 24, y: 18, width: textWidth, height: titleHeight)
        var y = 18 + titleHeight + 8
        let messageHeight = ceil(
            message.sizeThatFits(CGSize(width: textWidth, height: .greatestFiniteMagnitude)).height)
        message.frame = CGRect(x: 24, y: y, width: textWidth, height: messageHeight)
        y += max(48, messageHeight)
        if showsFileOption {
            let rowWidth = max(1, width - 32)
            let rowHeight = max(
                44, ceil(fileButton.sizeThatFits(CGSize(width: rowWidth, height: .greatestFiniteMagnitude)).height))
            fileButton.frame = CGRect(x: 16, y: y, width: rowWidth, height: rowHeight)
            y += rowHeight
        }
        let footerHeight = footer.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        footer.frame = CGRect(x: 0, y: y, width: width, height: footerHeight)
        return y + footerHeight
    }
    private func updateFile() {
        fileButton.setImage(
            UIImage(named: fileButton.isSelected ? "SearchScopeAndroidCheckOn" : "SearchScopeAndroidCheckOff")?
                .withRenderingMode(.alwaysTemplate), for: .normal
        )
        fileButton.tintColor = fileButton.isSelected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.secondaryText
        fileButton.accessibilityTraits = fileButton.isSelected ? [.button, .selected] : .button
    }
    @objc private func toggleFile() {
        guard active, !closing else { return }
        fileButton.isSelected.toggle()
        updateFile()
    }
    @objc private func cancel() { close(submit: false) }
    @objc private func confirm() { close(submit: true) }
    private func close(submit: Bool) {
        guard active, !closing, !isBeingDismissed else { return }
        closing = true
        footer.cancelButton.isEnabled = false
        footer.confirmButton.isEnabled = false
        let callback = submit ? completion : nil
        let deleteFiles = showsFileOption && fileButton.isSelected
        completion = nil
        dismiss(animated: true) { callback?(deleteFiles) }
    }
}

private final class BookshelfManageDeleteFooter: UIView {
    let cancelButton = BookshelfLayoutDialogAction(title: "否")
    let confirmButton = BookshelfLayoutDialogAction(title: "确定")

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(cancelButton)
        addSubview(confirmButton)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        CGSize(width: size.width, height: arrange(width: size.width, applyFrames: false))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        _ = arrange(width: bounds.width, applyFrames: true)
    }

    private func arrange(width: CGFloat, applyFrames: Bool) -> CGFloat {
        let available = max(1, width - 24)
        let stacked = cancelButton.preferredWidth + confirmButton.preferredWidth > available
        let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
        var y: CGFloat = 4
        for button in [confirmButton, cancelButton] {
            let buttonWidth = stacked ? available : button.preferredWidth
            let height = button.sizeThatFits(CGSize(width: buttonWidth, height: .greatestFiniteMagnitude)).height
            let x = isRTL ? 12 : width - 12 - buttonWidth
            if applyFrames {
                let offset = !stacked && button === cancelButton ? confirmButton.preferredWidth : 0
                button.frame = CGRect(x: x + (isRTL ? offset : -offset), y: y, width: buttonWidth, height: height)
            }
            if stacked { y += height }
        }
        accessibilityElements = stacked ? [confirmButton, cancelButton] : [cancelButton, confirmButton]
        let rowHeight = max(
            cancelButton.sizeThatFits(CGSize(width: cancelButton.preferredWidth, height: .greatestFiniteMagnitude))
                .height,
            confirmButton.sizeThatFits(CGSize(width: confirmButton.preferredWidth, height: .greatestFiniteMagnitude))
                .height)
        return stacked ? y + 4 : rowHeight + 8
    }
}
