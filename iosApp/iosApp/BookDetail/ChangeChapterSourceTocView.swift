import UIKit
import shared

/// Inline cl_toc from dialog_chapter_change_source.xml at Legado 5f5d314.
/// The owner pins this view below its existing toolbar, through the page bottom.
@MainActor
final class ChangeChapterSourceTocView: UIView, UITableViewDataSource, UITableViewDelegate {
    var onClose: (() -> Void)?
    var onSelect: ((BookChapter) -> Void)?

    private enum State {
        case hidden
        case loading(canClose: Bool)
        case ready
        case selectionPending
    }

    private let closeButton = UIButton(type: .custom)
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let loadingView = ChangeChapterSourceTocLoadingView()
    private var state: State = .hidden
    private var chapters: [BookChapter] = []
    private var suggestedIndex: Int?
    private var presentationRevision = 0
    private var pendingSuggestedRow: Int?
    private var scheduledScrollRevision: Int?

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayout()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayout()
    }

    /// true: loading a new TOC; false: writing content, retaining the visible TOC.
    func showLoading(canClose: Bool) {
        cancelSuggestedScroll()
        if canClose {
            clearChapters()
        }
        state = .loading(canClose: canClose)
        loadingView.accessibilityLabel = canClose ? "正在加载目录" : "正在替换正文"
        updatePresentation()
        setNeedsLayout()
    }

    func show(chapters: [BookChapter], suggestedIndex: Int) {
        cancelSuggestedScroll()
        self.chapters = chapters
        self.suggestedIndex = suggestedIndex
        // Android passes the suggested list position, not a lookup by BookChapter.index.
        pendingSuggestedRow = chapters.indices.contains(suggestedIndex) ? max(suggestedIndex - 5, 0) : nil
        state = .ready
        tableView.reloadData()
        tableView.setContentOffset(.zero, animated: false)
        updatePresentation()
        setNeedsLayout()
    }

    /// The owner also calls reset after cancellation or successful content saving.
    func reset() {
        cancelSuggestedScroll()
        state = .hidden
        updatePresentation()
        clearChapters()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ChangeSourceElevation.updatePath(for: closeButton)
        let insets = UIEdgeInsets(top: 0, left: 0, bottom: safeAreaInsets.bottom, right: 0)
        if tableView.contentInset != insets {
            tableView.contentInset = insets
            tableView.scrollIndicatorInsets = insets
        }
        scheduleSuggestedScroll()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { setNeedsLayout() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyAppearance()
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            // Recalculate automatic heights without relocating the user's current row.
            tableView.reloadData()
        }
    }

    func refreshPalette() {
        applyAppearance()
        for case let cell as ChangeChapterSourceTocCell in tableView.visibleCells {
            cell.refreshPalette()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        requestClose()
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        chapters.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ChangeChapterSourceTocCell.reuseIdentifier, for: indexPath
            ) as? ChangeChapterSourceTocCell
        else {
            return UITableViewCell()
        }
        let chapter = chapters[indexPath.row]
        cell.configure(chapter: chapter, isSuggested: Int(chapter.index) == suggestedIndex)
        return cell
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        canSelect ? indexPath : nil
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        cancelSuggestedScroll()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: false)
        guard canSelect, indexPath.section == 0, chapters.indices.contains(indexPath.row),
            let cell = tableView.cellForRow(at: indexPath) as? ChangeChapterSourceTocCell,
            let onSelect
        else { return }
        let chapter = chapters[indexPath.row]
        guard cell.representedChapterIndex == Int(chapter.index) else { return }

        // Lock before handing off, including owners that start their work asynchronously.
        cancelSuggestedScroll()
        state = .selectionPending
        updatePresentation()
        onSelect(chapter)
    }

    private var canSelect: Bool {
        guard !isHidden, case .ready = state else { return false }
        return true
    }

    private var canClose: Bool {
        guard !isHidden else { return false }
        switch state {
        case .hidden: return false
        case .loading(let canClose): return canClose
        case .ready, .selectionPending: return true
        }
    }

    private func configureLayout() {
        isOpaque = true
        clipsToBounds = true
        isAccessibilityElement = false
        accessibilityIdentifier = "changeSource.chapterToc"
        closeButton.configuration = nil
        ChangeSourceElevation.apply(to: closeButton)
        // Android fitCenter scales the 64dp drawable into the full-height 36dp close strip.
        closeButton.setImage(ReaderTocAndroidIcon.down.image(size: 36), for: .normal)
        closeButton.contentHorizontalAlignment = .center
        closeButton.contentVerticalAlignment = .center
        closeButton.imageView?.contentMode = .center
        closeButton.accessibilityLabel = "关闭目录"
        closeButton.accessibilityIdentifier = "changeSource.chapterToc.close"
        closeButton.addInteraction(UIToolTipInteraction(defaultToolTip: "关闭目录"))
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(
            ChangeChapterSourceTocCell.self, forCellReuseIdentifier: ChangeChapterSourceTocCell.reuseIdentifier)
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 48
        tableView.separatorStyle = .none
        tableView.sectionHeaderTopPadding = 0
        tableView.sectionHeaderHeight = 0
        tableView.sectionFooterHeight = 0
        tableView.estimatedSectionHeaderHeight = 0
        tableView.estimatedSectionFooterHeight = 0
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.accessibilityIdentifier = "changeSource.chapterToc.table"
        loadingView.accessibilityIdentifier = "changeSource.chapterToc.loading"

        for view in [tableView, closeButton, loadingView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            closeButton.heightAnchor.constraint(equalToConstant: 36),
            tableView.topAnchor.constraint(equalTo: closeButton.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: bottomAnchor),
            loadingView.centerXAnchor.constraint(equalTo: tableView.centerXAnchor),
            loadingView.centerYAnchor.constraint(equalTo: tableView.centerYAnchor),
            loadingView.widthAnchor.constraint(equalToConstant: 48),
            loadingView.heightAnchor.constraint(equalToConstant: 48),
        ])
        applyAppearance()
        updatePresentation()
    }

    private func updatePresentation() {
        if case .hidden = state {
            isHidden = true
        } else {
            isHidden = false
        }
        closeButton.isEnabled = canClose
        tableView.allowsSelection = canSelect
        tableView.isUserInteractionEnabled = canSelect
        tableView.accessibilityElementsHidden = !canSelect
        let isLoading: Bool
        if case .loading = state { isLoading = true } else { isLoading = false }
        loadingView.setLoading(isLoading)
    }

    private func applyAppearance() {
        let palette = ChangeSourcePalette(traits: traitCollection)
        backgroundColor = palette.background
        tableView.backgroundColor = palette.background
        closeButton.backgroundColor = palette.background
        closeButton.tintColor = palette.primaryText
        loadingView.apply(accent: palette.accent)
    }

    private func clearChapters() {
        chapters.removeAll()
        suggestedIndex = nil
        tableView.reloadData()
        tableView.setContentOffset(.zero, animated: false)
    }

    private func cancelSuggestedScroll() {
        presentationRevision &+= 1
        pendingSuggestedRow = nil
        scheduledScrollRevision = nil
    }

    private func scheduleSuggestedScroll() {
        guard canSelect, window != nil, pendingSuggestedRow != nil,
            scheduledScrollRevision == nil, tableView.bounds.width > 0, tableView.bounds.height > 0
        else { return }
        let revision = presentationRevision
        scheduledScrollRevision = revision
        // Wait for the parent's layout and the table's self-sizing pass, once per show.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationRevision == revision else { return }
            defer { self.scheduledScrollRevision = nil }
            self.layoutIfNeeded()
            self.tableView.layoutIfNeeded()
            guard self.canSelect, self.window != nil, let row = self.pendingSuggestedRow,
                self.tableView.bounds.width > 0, self.tableView.bounds.height > 0,
                self.chapters.indices.contains(row), self.tableView.numberOfRows(inSection: 0) == self.chapters.count
            else { return }
            self.pendingSuggestedRow = nil
            let indexPath = IndexPath(row: row, section: 0)
            // RecyclerView.scrollToPosition preserves an already-visible target's position.
            let position: UITableView.ScrollPosition =
                self.tableView.indexPathsForVisibleRows?.contains(indexPath) == true ? .none : .top
            self.tableView.scrollToRow(at: indexPath, at: position, animated: false)
        }
    }

    @objc private func closeTapped() {
        _ = requestClose()
    }

    private func requestClose() -> Bool {
        guard canClose else { return false }
        reset()
        onClose?()
        return true
    }
}

/// RotateLoading's accent-colored paired arcs and offset shadow in a 48pt slot.
@MainActor
private final class ChangeChapterSourceTocLoadingView: UIView {
    private let rotatingLayer = CALayer()
    private let shadowRotatingLayer = CALayer()
    private let arcs = [CAShapeLayer(), CAShapeLayer()]
    private let shadowArcs = [CAShapeLayer(), CAShapeLayer()]
    private var isLoading = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLayers()
    }

    func setLoading(_ loading: Bool) {
        isLoading = loading
        isHidden = !loading
        updateAnimations()
    }

    func apply(accent: UIColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for arc in arcs { arc.strokeColor = accent.cgColor }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rotatingLayer.frame = bounds
        shadowRotatingLayer.frame = bounds.offsetBy(dx: 2, dy: 2)
        for (index, arc) in arcs.enumerated() {
            arc.frame = rotatingLayer.bounds
            let start = CGFloat(10 + index * 180) * .pi / 180
            arc.path =
                UIBezierPath(
                    arcCenter: CGPoint(x: bounds.midX, y: bounds.midY),
                    radius: max(min(bounds.width, bounds.height) / 2 - 12, 0),
                    startAngle: start, endAngle: start + 160 * .pi / 180, clockwise: true
                ).cgPath
            shadowArcs[index].frame = shadowRotatingLayer.bounds
            shadowArcs[index].path = arc.path
        }
        CATransaction.commit()
    }

    private func configureLayers() {
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        layer.addSublayer(shadowRotatingLayer)
        layer.addSublayer(rotatingLayer)
        for arc in shadowArcs + arcs {
            arc.fillColor = UIColor.clear.cgColor
            arc.lineWidth = 6
            arc.lineCap = .round
        }
        for arc in shadowArcs { shadowRotatingLayer.addSublayer(arc) }
        for arc in arcs { rotatingLayer.addSublayer(arc) }
        for arc in shadowArcs { arc.strokeColor = UIColor.black.withAlphaComponent(26 / 255).cgColor }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAnimations),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        isHidden = true
    }

    @objc private func updateAnimations() {
        guard isLoading, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            rotatingLayer.removeAllAnimations()
            shadowRotatingLayer.removeAllAnimations()
            for arc in shadowArcs + arcs { arc.removeAllAnimations() }
            return
        }
        guard rotatingLayer.animation(forKey: "rotation") == nil else { return }
        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = 2 * Double.pi
        rotation.duration = 0.6
        rotation.repeatCount = .infinity
        rotatingLayer.add(rotation, forKey: "rotation")
        shadowRotatingLayer.add(rotation, forKey: "rotation")

        let sweep = CAKeyframeAnimation(keyPath: "strokeEnd")
        sweep.values = [10.0 / 160, 1, 10.0 / 160]
        sweep.keyTimes = [0, NSNumber(value: 2.0 / 3), 1]
        sweep.duration = 1.875
        sweep.repeatCount = .infinity
        for arc in shadowArcs + arcs { arc.add(sweep, forKey: "sweep") }
    }
}
