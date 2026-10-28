import UIKit
import shared
import SnapKit

final class RssSourceDebugViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {

    private let source: RssSource
    private let scaffoldView = LegacyRootScaffoldView()
    private let tableView = UITableView(frame: .zero, style: .grouped)
    private lazy var backButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "chevron.left",
        target: self,
        action: #selector(handleBack)
    )
    private lazy var startButton = makeLegacyBarButton(
        title: L10n.RssSourceDebug.startAction,
        imageSystemName: "play.fill",
        target: self,
        action: #selector(handleStart)
    )

    private var facade: RssFacade?

    // MARK: - Step State

    private enum StepStatus {
        case idle
        case loading
        case success(elapsedMs: Int)
        case failed(error: String, elapsedMs: Int)
    }

    private struct StepState {
        var status: StepStatus = .idle
        var results: [String] = []
    }

    private var steps: [StepState] = [StepState(), StepState(), StepState()]
    private var isRunning = false

    // Step data for chaining
    private var loadedSorts: [KotlinPair<NSString, NSString>] = []
    private var loadedArticles: [RssArticle] = []

    init(source: RssSource) {
        self.source = source
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let debugTitle = L10n.RssSourceDebug.title
        scaffoldView.titleBarView.setTitle(debugTitle)
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        configureChrome()
        configureTable()
        bootstrapFacade()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    // MARK: - Configure

    private func configureChrome() {
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        scaffoldView.titleBarView.setLeftViews([backButton])
        scaffoldView.titleBarView.setRightViews([startButton])
    }

    private func configureTable() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = UIIdentifiers.RSS.sourceDebugTable
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "debugResult")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.tableFooterView = UIView()
        scaffoldView.contentView.addSubview(tableView)
        tableView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    private func bootstrapFacade() {
        switch SharedRuntime.rssFacade() {
        case .success(let f):
            self.facade = f
            runDebug()
        case .failure(let error):
            steps[0].status = .failed(error: error.message, elapsedMs: 0)
            tableView.reloadData()
        }
    }

    // MARK: - Actions

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    @objc private func handleStart() {
        guard !isRunning else { return }
        runDebug()
    }

    // MARK: - Debug Flow

    private func runDebug() {
        guard let facade else { return }
        isRunning = true
        startButton.isEnabled = false
        steps = [StepState(), StepState(), StepState()]
        loadedSorts = []
        loadedArticles = []
        tableView.reloadData()

        Task { [weak self] in
            guard let self else { return }

            // Step 1: Load sorts
            await self.updateStep(0, status: .loading)
            let step1Start = CFAbsoluteTimeGetCurrent()
            do {
                let sorts = try await facade.loadSortsAsync(source: self.source, forceRefresh: true)
                let elapsed = self.elapsedMs(from: step1Start)
                self.loadedSorts = sorts
                let names = sorts.map { pair -> String in
                    let name = pair.first as String? ?? ""
                    return name.isEmpty ? (pair.second as String? ?? "") : name
                }
                await self.updateStep(0, status: .success(elapsedMs: elapsed), results: names)
            } catch {
                let elapsed = self.elapsedMs(from: step1Start)
                await self.updateStep(0, status: .failed(error: error.userFacingMessage, elapsedMs: elapsed))
                await self.finishDebug()
                return
            }

            // Step 2: Load articles (using first sort)
            guard let firstSort = self.loadedSorts.first else {
                await self.updateStep(1, status: .failed(error: L10n.RssSourceDebug.noSorts, elapsedMs: 0))
                await self.finishDebug()
                return
            }
            await self.updateStep(1, status: .loading)
            let step2Start = CFAbsoluteTimeGetCurrent()
            do {
                let sortName = firstSort.first as String? ?? ""
                let sortUrl = firstSort.second as String? ?? ""
                let payload = try await facade.loadArticlesAsync(
                    sortName: sortName,
                    sortUrl: sortUrl,
                    source: self.source,
                    page: 1
                )
                let elapsed = self.elapsedMs(from: step2Start)
                let articles = payload.articles
                self.loadedArticles = articles
                let titles = articles.map { $0.title }
                await self.updateStep(1, status: .success(elapsedMs: elapsed), results: titles)
            } catch {
                let elapsed = self.elapsedMs(from: step2Start)
                await self.updateStep(1, status: .failed(error: error.userFacingMessage, elapsedMs: elapsed))
                await self.finishDebug()
                return
            }

            // Step 3: Load content (using first article)
            guard let firstArticle = self.loadedArticles.first else {
                await self.updateStep(2, status: .failed(error: L10n.RssSourceDebug.noArticles, elapsedMs: 0))
                await self.finishDebug()
                return
            }
            await self.updateStep(2, status: .loading)
            let step3Start = CFAbsoluteTimeGetCurrent()
            do {
                let content = try await facade.loadContentAsync(article: firstArticle, source: self.source)
                let elapsed = self.elapsedMs(from: step3Start)
                let preview = contentPreview(content)
                await self.updateStep(2, status: .success(elapsedMs: elapsed), results: [preview])
            } catch {
                let elapsed = self.elapsedMs(from: step3Start)
                await self.updateStep(2, status: .failed(error: error.userFacingMessage, elapsedMs: elapsed))
                await self.finishDebug()
                return
            }

            await self.finishDebug()
        }
    }

    private func elapsedMs(from start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    private func contentPreview(_ html: String) -> String {
        // Strip HTML tags for a plain text preview
        let stripped = html
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count > 500 {
            return String(stripped.prefix(500)) + "..."
        }
        return stripped
    }

    @MainActor
    private func updateStep(_ index: Int, status: StepStatus, results: [String]? = nil) {
        steps[index].status = status
        if let results {
            steps[index].results = results
        }
        tableView.reloadData()
    }

    @MainActor
    private func finishDebug() {
        isRunning = false
        startButton.isEnabled = true
    }

    // MARK: - UITableViewDataSource

    func numberOfSections(in tableView: UITableView) -> Int {
        3
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        let step = steps[section]
        switch step.status {
        case .idle:
            return 0
        case .loading:
            return 1
        case .success:
            return max(step.results.count, 1)
        case .failed:
            return 1
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        let step = steps[section]
        let name = stepName(section)
        switch step.status {
        case .idle:
            return "\(name)"
        case .loading:
            return "\(name)  \(L10n.RssSourceDebug.statusLoading)"
        case .success(let ms):
            return "\(name)  \(L10n.RssSourceDebug.statusSuccess)  \(ms)ms"
        case .failed(_, let ms):
            return "\(name)  \(L10n.RssSourceDebug.statusFailed)  \(ms)ms"
        }
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "debugResult", for: indexPath)
        let step = steps[indexPath.section]
        var content = cell.defaultContentConfiguration()
        content.textProperties.numberOfLines = 0

        switch step.status {
        case .idle:
            break
        case .loading:
            content.text = L10n.RssSourceDebug.loadingMessage
            content.textProperties.color = .secondaryLabel
        case .success:
            if step.results.isEmpty {
                content.text = L10n.RssSourceDebug.emptyResult
                content.textProperties.color = .secondaryLabel
            } else {
                content.text = step.results[indexPath.row]
                content.textProperties.color = .label
            }
        case .failed(let error, _):
            content.text = error
            content.textProperties.color = .systemRed
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    // MARK: - UITableViewDelegate

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    // MARK: - Helpers

    private func stepName(_ index: Int) -> String {
        switch index {
        case 0: return L10n.RssSourceDebug.step1Name
        case 1: return L10n.RssSourceDebug.step2Name
        case 2: return L10n.RssSourceDebug.step3Name
        default: return ""
        }
    }
}
