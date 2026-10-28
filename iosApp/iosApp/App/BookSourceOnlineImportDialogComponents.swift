import UIKit

final class BookSourceOnlineImportInputView: UIView {
    let textView = UITextView()
    private let placeholderLabel = UILabel()
    private let underline = UIView()
    private var palette = ReaderTocPalette(traits: .current)
    private var inputFont = UIFont.systemFont(ofSize: 16)

    var showsError = false {
        didSet { refreshUnderline() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
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
        placeholderLabel.adjustsFontForContentSizeCategory = true
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
        let font = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 16), compatibleWith: traits)
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
    private var rowFont = UIFont.systemFont(ofSize: 16)

    var firstRowHeight: CGFloat { max(48, ceil(rowFont.lineHeight) + 20) }

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
        rowFont = UIFontMetrics(forTextStyle: .body).scaledFont(
            for: .systemFont(ofSize: 16), compatibleWith: traits)
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
    private let chooseControl = UIButton(type: .system)
    private let deleteControl = UIButton(type: .system)
    private var value = ""

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        isAccessibilityElement = false
        chooseControl.contentHorizontalAlignment = .leading
        chooseControl.titleLabel?.numberOfLines = 1
        chooseControl.titleLabel?.lineBreakMode = .byTruncatingMiddle
        chooseControl.titleLabel?.adjustsFontForContentSizeCategory = true
        chooseControl.addTarget(self, action: #selector(choose), for: .touchUpInside)
        deleteControl.setImage(UIImage(systemName: "xmark"), for: .normal)
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
        self.value = value
        backgroundColor = palette.background
        chooseControl.setTitle(value, for: .normal)
        chooseControl.setTitleColor(palette.primaryText, for: .normal)
        chooseControl.titleLabel?.font = font
        chooseControl.accessibilityLabel = value
        chooseControl.accessibilityIdentifier = "sourceManagement.importUrl.history.fill.\(index)"
        deleteControl.tintColor = palette.secondaryText
        deleteControl.accessibilityValue = value
        deleteControl.accessibilityIdentifier = "sourceManagement.importUrl.history.delete.\(index)"
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let deleteWidth = min(44, bounds.width)
        let rtl = effectiveUserInterfaceLayoutDirection == .rightToLeft
        deleteControl.frame = CGRect(
            x: rtl ? 0 : bounds.width - deleteWidth, y: 0, width: deleteWidth, height: bounds.height)
        chooseControl.frame = CGRect(
            x: rtl ? deleteWidth : 4, y: 0, width: max(0, bounds.width - deleteWidth - 4), height: bounds.height)
    }

    @objc private func choose() { onSelect?(value) }
    @objc private func remove() { onDelete?(value) }
}

final class BookSourceOnlineImportActionControl: UIControl {
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var accent = UIColor.clear

    init(title: String, identifier: String) {
        super.init(frame: .zero)
        label.text = title
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
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
            if !isEnabled { isHighlighted = false }
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? accent.withAlphaComponent(0.12) : .clear }
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

    override func accessibilityActivate() -> Bool {
        guard isEnabled else { return false }
        sendActions(for: .touchUpInside)
        return true
    }

    func apply(traits: UITraitCollection) {
        accent = ReaderTocPalette(traits: traits).accent
        label.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14, weight: .medium), compatibleWith: traits)
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
