import UIKit

final class BookSourceOnlineImportInputView: UIView {
    let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let underline = UIView()
    private var palette = ReaderTocPalette(traits: .current)
    private var inputFont = ReaderAndroidDefaultFont.scaledFont(
        size: 18, textStyle: .body, compatibleWith: .current)

    var showsError = false {
        didSet { refreshUnderline() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = false
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.textContentType = nil
        textView.keyboardType = .default
        textView.returnKeyType = .default
        textView.enablesReturnKeyAutomatically = false
        textView.allowsEditingTextAttributes = false
        textView.dataDetectorTypes = []
        textView.accessibilityLabel = "url"
        textView.accessibilityIdentifier = "sourceManagement.importUrl.input"
        placeholderLabel.text = "url"
        placeholderLabel.isAccessibilityElement = false
        placeholderLabel.isUserInteractionEnabled = false
        placeholderLabel.adjustsFontForContentSizeCategory = false
        underline.isUserInteractionEnabled = false
        underline.isAccessibilityElement = false
        for item in [textView, placeholderLabel, underline] { addSubview(item) }
        accessibilityElements = [textView]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func apply(traits: UITraitCollection) {
        palette = ReaderTocPalette(traits: traits)
        // AppCompat AutoCompleteTextView inherits textAppearanceMediumInverse (18sp).
        let font = ReaderAndroidDefaultFont.scaledFont(size: 18, textStyle: .body, compatibleWith: traits)
        inputFont = font
        // Recolor attributes only after composition commits, without assigning the draft text.
        if textView.markedTextRange == nil {
            if textView.font != font { textView.font = font }
            textView.textColor = palette.primaryText
        }
        textView.tintColor = palette.accent
        textView.keyboardAppearance = traits.userInterfaceStyle == .dark ? .dark : .light
        placeholderLabel.font = font
        placeholderLabel.textColor = palette.secondaryText
        refreshState()
    }

    func refreshState() {
        if textView.markedTextRange == nil {
            if textView.font != inputFont { textView.font = inputFont }
            textView.textColor = palette.primaryText
        }
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
        refreshUnderline()
        setNeedsLayout()
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let width = max(1, size.width)
        let measured = textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let lineHeight = textView.font?.lineHeight ?? 20
        return CGSize(width: size.width, height: max(48, ceil(max(lineHeight + 16, measured.height)) + 8))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - 8))
        placeholderLabel.frame = CGRect(
            x: 4, y: 8, width: max(0, bounds.width - 8), height: ceil(placeholderLabel.font.lineHeight))
        placeholderLabel.textAlignment = textView.textAlignment
        let lineHeight: CGFloat = textView.isFirstResponder || showsError ? 2 : 1
        underline.frame = CGRect(
            x: 0, y: max(0, bounds.height - 8), width: bounds.width, height: lineHeight)
    }

    private func refreshUnderline() {
        underline.backgroundColor = showsError || textView.isFirstResponder ? palette.accent : palette.secondaryText
        setNeedsLayout()
    }
}

@MainActor
final class BookSourceOnlineImportURLHistory {
    private let defaults: UserDefaults
    private let key = "io.legado.kmp.sourceImport.urlHistory.v1"
    private static let maximumEntries = 50
    private static let maximumEntryBytes = 8_192
    private var values: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
    }

    func reload() {
        var seen = Set<String>()
        values = (defaults.stringArray(forKey: key) ?? []).compactMap { value in
            guard let url = Self.historyValue(value), seen.insert(url).inserted else { return nil }
            return url
        }
        values = Array(values.prefix(Self.maximumEntries))
    }

    func matching(_ input: String) -> [String] {
        guard input.utf8.count <= Self.maximumEntryBytes else { return [] }
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.first != "{", query.first != "[" else { return [] }
        return query.isEmpty ? values : values.filter { $0.range(of: query, options: .caseInsensitive) != nil }
    }

    func record(_ input: String) {
        guard let value = Self.historyValue(input) else { return }
        reload()
        // Android records on confirmation, including failed requests, without moving duplicates.
        guard !values.contains(value) else { return }
        values.insert(value, at: 0)
        values = Array(values.prefix(Self.maximumEntries))
        defaults.set(values, forKey: key)
    }

    func remove(_ value: String) {
        reload()
        values.removeAll { $0 == value }
        defaults.set(values, forKey: key)
    }

    private static func historyValue(_ input: String) -> String? {
        guard input.utf8.count <= maximumEntryBytes else { return nil }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("http://") || value.lowercased().hasPrefix("https://") else { return nil }
        var address = value
        // Keep a URL's option object intact; never extract URLs from a source JSON payload.
        if let separator = value.range(of: ",\\s*(?=\\{)", options: .regularExpression) {
            address = String(value[..<separator.lowerBound])
            let options = String(value[separator.upperBound...])
            guard let object = try? JSONSerialization.jsonObject(with: Data(options.utf8)),
                object is [String: Any]
            else { return nil }
        }
        let invalid = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "\"{}<>"))
        guard address.rangeOfCharacter(from: invalid) == nil,
            let components = URLComponents(string: address),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty, components.url != nil
        else { return nil }
        return value
    }
}

final class BookSourceOnlineImportHistoryView: UIView, UITableViewDataSource {
    var onSelect: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    private let tableView = BookSourceOnlineImportHistoryTableView(frame: .zero, style: .plain)
    private let divider = UIView()
    private var values: [String] = []
    private var palette = ReaderTocPalette(traits: .current)
    private var rowFont = ReaderAndroidDefaultFont.scaledFont(
        size: 14, textStyle: .subheadline, compatibleWith: .current)

    var firstRowHeight: CGFloat {
        let padding = AndroidExploreTextMetrics.padding(font: rowFont, scale: traitCollection.displayScale)
        // item_1line_text_and_del: 6dp padding around a TextView and a 24dp icon.
        return ceil(max(24, rowFont.lineHeight + padding.top + padding.bottom)) + 12
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        tableView.dataSource = self
        tableView.register(BookSourceOnlineImportHistoryCell.self, forCellReuseIdentifier: "urlHistory")
        tableView.separatorStyle = .none
        tableView.estimatedRowHeight = 0
        tableView.sectionHeaderTopPadding = 0
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.alwaysBounceVertical = false
        tableView.showsHorizontalScrollIndicator = false
        tableView.scrollsToTop = false
        tableView.delaysContentTouches = false
        tableView.keyboardDismissMode = .none
        tableView.accessibilityIdentifier = "sourceManagement.importUrl.history"
        divider.isUserInteractionEnabled = false
        divider.isAccessibilityElement = false
        addSubview(tableView)
        addSubview(divider)
        accessibilityElements = [tableView]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func apply(traits: UITraitCollection) {
        palette = ReaderTocPalette(traits: traits)
        rowFont = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .subheadline, compatibleWith: traits)
        tableView.backgroundColor = palette.background
        tableView.indicatorStyle = traits.userInterfaceStyle == .dark ? .white : .black
        tableView.rowHeight = firstRowHeight
        divider.backgroundColor = palette.divider
        for case let cell as BookSourceOnlineImportHistoryCell in tableView.visibleCells {
            guard let indexPath = tableView.indexPath(for: cell), values.indices.contains(indexPath.row) else { continue }
            cell.configure(value: values[indexPath.row], index: indexPath.row, font: rowFont, palette: palette)
        }
        setNeedsLayout()
    }

    func update(values: [String], resetScroll: Bool = true) {
        isHidden = values.isEmpty
        guard self.values != values else { return }
        self.values = values
        tableView.reloadData()
        if resetScroll { tableView.setContentOffset(.zero, animated: false) }
        setNeedsLayout()
    }

    func height(maximum: CGFloat) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        return min(CGFloat(values.count) * firstRowHeight, max(firstRowHeight, min(180, maximum)))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tableView.frame = bounds
        tableView.isScrollEnabled = CGFloat(values.count) * firstRowHeight > bounds.height
        divider.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1 / max(1, traitCollection.displayScale))
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { values.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(
                withIdentifier: "urlHistory", for: indexPath) as? BookSourceOnlineImportHistoryCell
        else { return UITableViewCell() }
        cell.configure(value: values[indexPath.row], index: indexPath.row, font: rowFont, palette: palette)
        cell.onSelect = { [weak self] value in self?.onSelect?(value) }
        cell.onDelete = { [weak self] value in self?.onDelete?(value) }
        return cell
    }
}

private final class BookSourceOnlineImportHistoryTableView: UITableView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is UIButton { return true }
        return super.touchesShouldCancel(in: view)
    }
}

private final class BookSourceOnlineImportHistoryCell: UITableViewCell {
    var onSelect: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    private let chooseControl = BookSourceOnlineImportPressButton(frame: .zero)
    private let deleteControl = BookSourceOnlineImportPressButton(frame: .zero)
    private var value = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        isAccessibilityElement = false
        chooseControl.contentHorizontalAlignment = .leading
        chooseControl.titleLabel?.numberOfLines = 1
        chooseControl.titleLabel?.lineBreakMode = .byTruncatingTail
        chooseControl.titleLabel?.adjustsFontForContentSizeCategory = false
        chooseControl.addTarget(self, action: #selector(choose), for: .touchUpInside)
        deleteControl.setImage(
            UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)),
            for: .normal)
        deleteControl.accessibilityLabel = L10n.Common.delete
        deleteControl.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Common.delete))
        deleteControl.addTarget(self, action: #selector(remove), for: .touchUpInside)
        contentView.addSubview(chooseControl)
        contentView.addSubview(deleteControl)
        accessibilityElements = [chooseControl, deleteControl]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    func configure(value: String, index: Int, font: UIFont, palette: ReaderTocPalette) {
        clearPressedFeedback()
        self.value = value
        backgroundColor = palette.background
        chooseControl.setTitle(value, for: .normal)
        chooseControl.setTitleColor(palette.primaryText, for: .normal)
        chooseControl.titleLabel?.font = font
        chooseControl.accessibilityLabel = value
        chooseControl.accessibilityIdentifier = "sourceManagement.importUrl.history.fill.\(index)"
        deleteControl.tintColor = palette.primaryText
        deleteControl.accessibilityValue = value
        deleteControl.accessibilityIdentifier = "sourceManagement.importUrl.history.delete.\(index)"
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let inset = min(6, bounds.width / 2)
        let deleteWidth = min(24, max(0, bounds.width - inset * 2))
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        deleteControl.frame = CGRect(
            x: rtl ? inset : bounds.width - inset - deleteWidth,
            y: max(0, (bounds.height - 24) / 2), width: deleteWidth, height: min(24, bounds.height))
        chooseControl.frame = CGRect(
            x: rtl ? inset + deleteWidth : 0, y: 0,
            width: max(0, bounds.width - deleteWidth - inset), height: bounds.height)
        let padding = AndroidExploreTextMetrics.padding(
            font: chooseControl.titleLabel?.font ?? .systemFont(ofSize: 14), scale: traitCollection.displayScale)
        chooseControl.contentEdgeInsets = UIEdgeInsets(
            top: 6 + padding.top, left: rtl ? 0 : inset, bottom: 6 + padding.bottom, right: rtl ? inset : 0)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        clearPressedFeedback()
        value = ""
        onSelect = nil
        onDelete = nil
    }

    private func clearPressedFeedback() {
        chooseControl.cancelPendingActivation()
        deleteControl.cancelPendingActivation()
    }

    @objc private func choose() { onSelect?(value) }
    @objc private func remove() { onDelete?(value) }
}

class BookSourceOnlineImportPressButton: ReaderMenuPressButton {
    // AppCompat ripple_material_light/dark: #1F000000 / #33FFFFFF.
    private let pressedFeedback = BookshelfItemFeedbackView()
    private var feedbackObservations: [NSKeyValueObservation] = []

    var pressedFeedbackInsets = UIEdgeInsets.zero {
        didSet { setNeedsLayout() }
    }

    var pressedFeedbackCornerRadius: CGFloat = 0 {
        didSet { pressedFeedback.layer.cornerRadius = pressedFeedbackCornerRadius }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        showsBorderlessFeedback = false
        clipsToBounds = true
        insertSubview(pressedFeedback, at: 0)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var isHighlighted: Bool {
        didSet { updatePressedFeedback() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        pressedFeedback.frame = CGRect(
            x: min(pressedFeedbackInsets.left, bounds.width / 2),
            y: min(pressedFeedbackInsets.top, bounds.height / 2),
            width: max(0, bounds.width - pressedFeedbackInsets.left - pressedFeedbackInsets.right),
            height: max(0, bounds.height - pressedFeedbackInsets.top - pressedFeedbackInsets.bottom))
        updatePressedFeedback()
    }

    private func updatePressedFeedback() {
        // Keep the existing press engine; only replace its borderless appearance with a bounded mask.
        pressedFeedback.isHidden = !isHighlighted || !ReaderMenuToolbarInteraction.isAvailable(self)
        guard !pressedFeedback.isHidden else {
            feedbackObservations.removeAll()
            return
        }
        guard feedbackObservations.isEmpty else { return }
        var ancestor = superview
        while let view = ancestor {
            let changed: () -> Void = { [weak self] in
                guard let self, !ReaderMenuToolbarInteraction.isAvailable(self) else { return }
                self.cancelPendingActivation()
            }
            feedbackObservations.append(view.observe(\.isUserInteractionEnabled, options: [.new]) { _, _ in changed() })
            feedbackObservations.append(view.observe(\.isHidden, options: [.new]) { _, _ in changed() })
            feedbackObservations.append(view.observe(\.alpha, options: [.new]) { _, _ in changed() })
            ancestor = view.superview
        }
    }
}

final class BookSourceOnlineImportActionControl: BookSourceOnlineImportPressButton {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var accent = UIColor.clear

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        // btn_borderless_material masks to btn_default_mtrl_shape: 4dp/6dp insets, 2dp corners.
        pressedFeedbackInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        pressedFeedbackCornerRadius = 2
        label.text = title
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        label.isAccessibilityElement = false
        label.isUserInteractionEnabled = false
        spinner.hidesWhenStopped = true
        spinner.isAccessibilityElement = false
        spinner.isUserInteractionEnabled = false
        addSubview(label)
        addSubview(spinner)
        isAccessibilityElement = true
        accessibilityLabel = title
        accessibilityIdentifier = identifier
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    var preferredWidth: CGFloat {
        let text = label.sizeThatFits(
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        return max(64, ceil(text.width) + 16)
    }

    override var isEnabled: Bool {
        didSet {
            label.alpha = isEnabled ? 1 : 0.5
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let height = label.sizeThatFits(
            CGSize(width: max(1, size.width - 16), height: .greatestFiniteMagnitude)
        ).height
        return CGSize(width: size.width, height: max(48, ceil(height) + 16))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    func apply(traits: UITraitCollection) {
        accent = ReaderTocPalette(traits: traits).accent
        label.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .subheadline, weight: 500, compatibleWith: traits)
        label.textColor = accent
        spinner.color = accent
        setNeedsLayout()
    }

    func setBusy(_ busy: Bool) {
        label.isHidden = busy
        accessibilityValue =
            busy
            ? NSLocalizedString(
                "sourceManagement.importUrl.preparing", value: "正在解析", comment: "Preparing source import preview")
            : nil
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}

final class BookSourceOnlineImportScrollView: UIScrollView {
    override func touchesShouldCancel(in view: UIView) -> Bool {
        if view is BookSourceOnlineImportActionControl || view is UIButton { return true }
        return super.touchesShouldCancel(in: view)
    }
}
