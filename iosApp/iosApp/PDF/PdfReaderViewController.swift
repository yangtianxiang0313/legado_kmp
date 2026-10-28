import PDFKit
import UIKit
import shared

@MainActor
final class PdfReaderViewController: UIViewController, NavigationCustomToolbarProviding {
    private let bookURL: String
    private let initialPage: Int?
    private let topBar = NavigationToolbarView()
    private let titleLabel = UILabel()
    private let pdfView = PDFView()
    private lazy var location = PdfReaderLocationCoordinator(view: pdfView, bookURL: bookURL)
    private let pageLabel = UILabel()
    private let slider = UISlider()
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let spinner = UIActivityIndicatorView(style: .large)
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var loadTask: Task<Void, Never>?
    private var bookmarkTask: Task<Void, Never>?
    private var bookmarkClient: PdfBookmarkClient?
    private var progress: PdfReaderProgressStore?
    private var ready = false
    private var isVisible = false
    private var didRestore = false
    private var isLeaving = false
    private var fileURL: URL?
    private var loadRevision = UUID()
    private var jumpHistory: [PdfReadingLocation] = []
    private var lastSearchQuery = ""
    private var hasSearchHighlight = false

    init(bookURL: String, initialChapterIndex: Int? = nil) {
        self.bookURL = bookURL
        initialPage = initialChapterIndex
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure() }

    deinit { loadTask?.cancel(); bookmarkTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scaleChanged), name: .PDFViewScaleChanged, object: pdfView)
        location.onError = { [weak self] message in
            guard self?.isVisible == true else { return }
            self?.showTransientMessage("阅读位置保存失败：\(message)")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appBackgrounded), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(appActivated), name: UIApplication.didBecomeActiveNotification, object: nil)
        loadDocument()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        isVisible = true
        location.setActive(true)
        beginSessionIfReady()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        location.setActive(false)
        progress?.end()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            loadRevision = UUID()
            loadTask?.cancel()
            bookmarkTask?.cancel()
            bookmarkTask = nil
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        location.observeScrolling()
        guard ready, !didRestore, let document = pdfView.document, let fileURL,
            pdfView.bounds.width > 0, pdfView.bounds.height > 0
        else { return }
        didRestore = true
        location.bind(
            fileURL: fileURL, pageIndex: min(max(initialPage ?? restoredPage, 0), document.pageCount - 1),
            useSavedAnchor: initialPage == nil)
        pageChanged()
        beginSessionIfReady()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        let anchor = location.capture()
        location.setActive(false)
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self, !self.isLeaving else { return }
            if let anchor { self.location.apply(anchor) }
            self.location.setActive(self.isVisible && UIApplication.shared.applicationState == .active)
            self.pageChanged()
        }
    }

    private var restoredPage = 0

    private var canUseReader: Bool {
        ready && didRestore && !isLeaving && canPerformNavigationAction
            && view.window.map { AppLockManager.shared.isUnlocked(in: $0) } == true
    }

    private func configureViews() {
        view.backgroundColor = AndroidReplicaTheme.background
        topBar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        titleLabel.font = .systemFont(ofSize: 18, weight: .medium)
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        titleLabel.text = "PDF"
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let back = button("chevron.left", label: "返回", action: #selector(goBack))
        let toc = button("list.bullet", label: "目录", action: #selector(showPages))
        let search = button("magnifyingglass", label: "搜索正文", action: #selector(showSearch))
        search.accessibilityIdentifier = "pdf.search"
        let mode = button("ellipsis", label: "更多", action: nil)
        mode.accessibilityIdentifier = "pdf.more"
        mode.showsMenuAsPrimaryAction = true
        mode.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] completion in
                Task { @MainActor in completion(self?.menuElements() ?? []) }
            }
        ])
        let header = UIStackView(arrangedSubviews: [back, titleLabel, search, toc, mode])
        header.alignment = .center
        header.spacing = 4
        pdfView.backgroundColor = AndroidReplicaTheme.background
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.accessibilityIdentifier = "pdf.document"
        previousButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
        previousButton.accessibilityLabel = "上一页"
        previousButton.addTarget(self, action: #selector(previousPage), for: .touchUpInside)
        nextButton.setImage(UIImage(systemName: "chevron.right"), for: .normal)
        nextButton.accessibilityLabel = "下一页"
        nextButton.addTarget(self, action: #selector(nextPage), for: .touchUpInside)
        slider.accessibilityLabel = "PDF 页码"
        slider.accessibilityIdentifier = "pdf.pageSlider"
        slider.addTarget(
            self, action: #selector(sliderChanged),
            for: [.valueChanged, .touchUpInside, .touchUpOutside, .touchCancel, .primaryActionTriggered])
        pageLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        pageLabel.textAlignment = .center
        pageLabel.textColor = AndroidReplicaTheme.primaryText
        pageLabel.accessibilityIdentifier = "pdf.pageIndicator"
        let footer = UIStackView(arrangedSubviews: [previousButton, slider, pageLabel, nextButton])
        footer.alignment = .center
        footer.spacing = 8
        footer.isLayoutMarginsRelativeArrangement = true
        footer.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        for item in [back, search, toc, mode, previousButton, nextButton] {
            item.widthAnchor.constraint(equalToConstant: 44).isActive = true
            item.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        pageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        errorLabel.numberOfLines = 0
        errorLabel.textAlignment = .center
        errorLabel.textColor = AndroidReplicaTheme.primaryText
        retryButton.setTitle("重试", for: .normal)
        retryButton.addTarget(self, action: #selector(retry), for: .touchUpInside)
        retryButton.isHidden = true
        spinner.hidesWhenStopped = true
        for item in [topBar, pdfView, footer, spinner, errorLabel, retryButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        header.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(header)
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 56),
            header.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 4),
            header.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -4),
            header.topAnchor.constraint(equalTo: topBar.topAnchor), header.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            footer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 48),
            pdfView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            pdfView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pdfView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            spinner.centerXAnchor.constraint(equalTo: pdfView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
            errorLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            errorLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
            errorLabel.centerYAnchor.constraint(equalTo: pdfView.centerYAnchor),
            retryButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 12),
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func button(_ symbol: String, label: String, action: Selector?) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.tintColor = AndroidReplicaTheme.toolbarText
        button.accessibilityLabel = label
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
        return button
    }

    private func loadDocument() {
        guard loadTask == nil else { return }
        spinner.startAnimating()
        errorLabel.text = nil
        retryButton.isHidden = true
        let revision = UUID()
        loadRevision = revision
        loadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.loadTask = nil; self.spinner.stopAnimating() }
            do {
                let facade = try PdfReaderDocumentFacade.companion.create()
                let resolved: PdfReaderDocument = try await SharedAsync.value {
                    facade.resolve(bookUrl: self.bookURL, completionHandler: $0)
                }
                try Task.checkCancellation()
                guard self.loadRevision == revision, !self.isLeaving else { throw CancellationError() }
                let url = URL(fileURLWithPath: resolved.filePath)
                let document = await Task.detached(priority: .userInitiated) { PDFDocument(url: url) }.value
                try Task.checkCancellation()
                guard let document, !document.isLocked, document.pageCount > 0 else {
                    throw NSError(domain: "io.legado.pdf", code: 1, userInfo: [NSLocalizedDescriptionKey: "PDF 已加密、损坏或没有可阅读的页面"])
                }
                self.progress = try PdfReaderProgressStore(bookURL: self.bookURL)
                self.bookmarkClient = PdfBookmarkClient(bookURL: self.bookURL, pageCount: document.pageCount)
                self.progress?.onError = { [weak self] message in
                    guard self?.isVisible == true else { return }
                    self?.showTransientMessage("阅读进度保存失败：\(message)")
                }
                self.restoredPage = Int(resolved.book.durChapterIndex)
                self.fileURL = url
                self.titleLabel.text = resolved.book.name
                self.pdfView.document = document
                self.slider.minimumValue = 0
                self.slider.maximumValue = Float(max(document.pageCount - 1, 1))
                self.slider.isEnabled = document.pageCount > 1
                self.ready = true
                self.view.setNeedsLayout()
                self.beginSessionIfReady()
            } catch is CancellationError {} catch {
                self.errorLabel.text = error.userFacingMessage
                self.retryButton.isHidden = false
            }
        }
    }

    private func beginSessionIfReady() {
        guard ready, didRestore, isVisible, UIApplication.shared.applicationState == .active,
            let window = viewIfLoaded?.window, window.windowScene?.activationState == .foregroundActive,
            AppLockManager.shared.isUnlocked(in: window)
        else { return }
        progress?.begin()
    }

    private func go(to index: Int, remember: Bool = false) {
        guard canUseReader, let document = pdfView.document, let page = document.page(at: index) else { return }
        if remember { rememberJump() }
        pdfView.go(to: page)
        pageChanged()
        location.checkpoint()
    }

    @objc private func pageChanged() {
        guard ready, didRestore, !location.isRestoring, let document = pdfView.document, let page = pdfView.currentPage else {
            return
        }
        let index = document.index(for: page)
        guard index != NSNotFound else { return }
        pageLabel.text = "\(index + 1) / \(document.pageCount)"
        pageLabel.accessibilityValue = pageLabel.text
        if !slider.isTracking { slider.value = Float(index) }
        previousButton.isEnabled = index > 0
        nextButton.isEnabled = index + 1 < document.pageCount
        progress?.save(page: index)
        location.scheduleCheckpoint()
    }

    private func setContinuous(_ continuous: Bool) {
        guard canUseReader else { return }
        location.setMode(continuous ? .continuous : .paged)
        pageChanged()
    }

    private func menuElements() -> [UIMenuElement] {
        guard ready, didRestore, !isLeaving else { return [] }
        let continuous = UIAction(
            title: "连续滚动", image: UIImage(systemName: "arrow.down"),
            state: location.mode == .continuous ? .on : .off
        ) { [weak self] _ in self?.setContinuous(true) }
        let paged = UIAction(
            title: "逐页阅读", image: UIImage(systemName: "rectangle.portrait"),
            state: location.mode == .paged ? .on : .off
        ) { [weak self] _ in self?.setContinuous(false) }
        let fit = UIAction(title: "适合页面", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in
            guard let self, self.canUseReader else { return }
            self.location.fitPage()
        }
        let jump = UIAction(title: "跳转页码", image: UIImage(systemName: "number")) { [weak self] _ in self?.showPageJump() }
        let addBookmark = UIAction(title: "添加书签", image: UIImage(systemName: "bookmark")) { [weak self] _ in
            self?.performBookmarkAction(add: true)
        }
        let bookmarks = UIAction(title: "书签", image: UIImage(systemName: "bookmark")) { [weak self] _ in
            self?.performBookmarkAction(add: false)
        }
        var items: [UIMenuElement] = [
            UIMenu(options: .displayInline, children: [continuous, paged, fit]), jump,
            UIMenu(options: .displayInline, children: [addBookmark, bookmarks]),
        ]
        if !jumpHistory.isEmpty {
            items.append(
                UIAction(title: "返回跳转前位置", image: UIImage(systemName: "arrow.uturn.backward")) { [weak self] _ in
                    self?.returnFromJump()
                })
        }
        if hasSearchHighlight {
            items.append(
                UIAction(title: "清除搜索高亮", image: UIImage(systemName: "xmark.circle")) { [weak self] _ in
                    guard let self, self.canUseReader else { return }
                    self.clearSearchHighlight()
                })
        }
        return items
    }

    private func performBookmarkAction(add: Bool) {
        guard canUseReader, bookmarkTask == nil, let client = bookmarkClient, let fileURL,
            let document = pdfView.document, let page = pdfView.currentPage
        else { return }
        let pageIndex = document.index(for: page)
        guard (0..<document.pageCount).contains(pageIndex) else { return }
        location.checkpoint()
        let revision = loadRevision
        weak var window = view.window
        let selection = pdfView.currentSelection
        let selectedText = selection?.pages.allSatisfy { $0 === page } == true ? selection?.string : nil
        bookmarkTask = Task { @MainActor [weak self] in
            defer { if self?.loadRevision == revision { self?.bookmarkTask = nil } }
            do {
                let excerpt = try await PdfBookmarkExcerpt.load(
                    fileURL: fileURL, pageIndex: pageIndex, selectedText: selectedText)
                try Task.checkCancellation()
                guard let self, self.loadRevision == revision, self.view.window === window, self.canUseReader else {
                    throw CancellationError()
                }
                if add {
                    let draft = try await client.makeDraft(pageIndex: pageIndex, excerpt: excerpt)
                    try Task.checkCancellation()
                    guard self.loadRevision == revision, self.view.window === window, self.canUseReader else {
                        throw CancellationError()
                    }
                    let editor = ReaderTocBookmarkEditorViewController(
                        bookmark: draft,
                        onSave: { text, note in _ = try await client.save(draft, bookText: text, note: note, isNew: true) })
                    editor.canSubmit = { [weak self, weak editor] in
                        guard let self, let editor, self.loadRevision == revision, !self.isLeaving,
                            self.presentedViewController === editor, self.view.window === window,
                            let window, AppLockManager.shared.isUnlocked(in: window)
                        else { return false }
                        return true
                    }
                    editor.overrideUserInterfaceStyle = self.overrideUserInterfaceStyle
                    self.present(editor, animated: true)
                } else {
                    let list = PdfBookmarksViewController(client: client, currentPage: pageIndex, excerpt: excerpt)
                    list.canSubmit = { [weak self] in
                        guard let self, self.loadRevision == revision, !self.isLeaving, self.view.window === window,
                            let window, AppLockManager.shared.isUnlocked(in: window)
                        else { return false }
                        return true
                    }
                    list.onSelection = { [weak self] bookmark in
                        guard let self, self.loadRevision == revision, self.view.window === window else { return }
                        self.go(to: Int(bookmark.chapterIndex), remember: true)
                    }
                    let navigation = UINavigationController(rootViewController: list)
                    navigation.modalPresentationStyle = .formSheet
                    self.present(navigation, animated: true)
                }
            } catch is CancellationError {} catch {
                guard let self, self.loadRevision == revision, self.view.window === window, self.isVisible else { return }
                self.showTransientMessage(error.userFacingMessage)
            }
        }
    }

    private func rememberJump() {
        guard let anchor = location.capture(), jumpHistory.last != anchor else { return }
        jumpHistory.append(anchor)
        if jumpHistory.count > 20 { jumpHistory.removeFirst() }
    }

    private func returnFromJump() {
        guard canUseReader, let previous = jumpHistory.popLast() else { return }
        clearSearchHighlight()
        location.apply(previous)
        pageChanged()
        location.checkpoint()
    }

    private func clearSearchHighlight() {
        pdfView.highlightedSelections = nil
        pdfView.clearSelection()
        hasSearchHighlight = false
    }

    private func showPageJump() {
        guard canUseReader, let document = pdfView.document else { return }
        let alert = UIAlertController(title: "跳转页码", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.keyboardType = .numberPad
            field.text = "\(Int(self.slider.value.rounded()) + 1)"
            field.placeholder = "1...\(document.pageCount)"
            field.accessibilityIdentifier = "pdf.jump.page"
        }
        let jump = UIAlertAction(title: "跳转", style: .default) { [weak self, weak alert] _ in
            guard let value = alert?.textFields?.first?.text, let page = Int(value),
                (1...document.pageCount).contains(page), let alert
            else { return }
            alert.dismiss(animated: true) {
                DispatchQueue.main.async { self?.go(to: page - 1, remember: true) }
            }
        }
        alert.textFields?.first?.addAction(
            UIAction { [weak alert, weak jump] _ in
                let value = Int(alert?.textFields?.first?.text ?? "") ?? 0
                jump?.isEnabled = (1...document.pageCount).contains(value)
            }, for: .editingChanged)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(jump)
        present(alert, animated: true) { alert.textFields?.first?.selectAll(nil) }
    }

    @objc private func showSearch() {
        guard canUseReader, let fileURL else { return }
        location.checkpoint()
        let revision = loadRevision
        weak var window = view.window
        let search = PdfSearchViewController(fileURL: fileURL, initialQuery: lastSearchQuery)
        search.onQueryChange = { [weak self] query in self?.lastSearchQuery = query }
        search.onSelection = { [weak self] match in
            DispatchQueue.main.async {
                guard let self, self.loadRevision == revision, self.view.window === window,
                    self.canUseReader, let document = self.pdfView.document,
                    let selection = match.selection(in: document)
                else { return }
                self.rememberJump()
                selection.color = UIColor.systemYellow.withAlphaComponent(0.4)
                self.pdfView.highlightedSelections = [selection]
                self.pdfView.setCurrentSelection(selection, animate: true)
                self.pdfView.go(to: selection)
                self.hasSearchHighlight = true
                self.pageChanged()
                self.location.checkpoint()
            }
        }
        let navigation = UINavigationController(rootViewController: search)
        navigation.modalPresentationStyle = .formSheet
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(navigation, animated: true)
    }

    @objc private func showPages() {
        guard canUseReader, let document = pdfView.document, let current = pdfView.currentPage else { return }
        location.checkpoint()
        let revision = loadRevision
        weak var window = view.window
        let list = PdfPageListViewController(document: document, selectedPage: document.index(for: current))
        list.onSelection = { [weak self] page in
            DispatchQueue.main.async {
                guard let self, self.loadRevision == revision, self.view.window === window else { return }
                self.go(to: page, remember: true)
            }
        }
        present(UINavigationController(rootViewController: list), animated: true)
    }

    @objc private func sliderChanged() {
        guard !slider.isTracking else {
            pageLabel.text = "\(Int(slider.value.rounded()) + 1) / \(pdfView.document?.pageCount ?? 0)"
            return
        }
        go(to: Int(slider.value.rounded()), remember: true)
    }
    @objc private func previousPage() { go(to: Int(slider.value.rounded()) - 1) }
    @objc private func nextPage() { go(to: Int(slider.value.rounded()) + 1) }
    @objc private func retry() { loadDocument() }
    @objc private func goBack() {
        guard !isLeaving, canPerformNavigationAction else { return }
        location.checkpoint()
        isLeaving = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLeaving = false }
            do {
                try await self.progress?.flush()
                guard self.canPerformNavigationAction else { return }
                self.navigationController?.popViewController(animated: true)
            } catch {
                self.showTransientMessage(error.userFacingMessage)
            }
        }
    }
    @objc private func scaleChanged() { location.scheduleCheckpoint() }
    @objc private func appBackgrounded() { location.setActive(false); progress?.end() }
    @objc private func appActivated() { location.setActive(isVisible); beginSessionIfReady() }
}
