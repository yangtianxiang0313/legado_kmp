import shared
import UIKit

@MainActor
final class LocalBookImportResultViewController: UITableViewController {
    private enum Section {
        case summary, books, failures
    }

    private let summary: LocalBookImportSummary
    private let sections: [Section]
    private weak var owner: UIViewController?
    private weak var expectedWindow: UIWindow?
    private weak var expectedScene: UIWindowScene?
    private weak var expectedRoot: UIViewController?
    private weak var expectedNavigation: UINavigationController?
    private weak var expectedTop: UIViewController?
    private weak var resultSheet: UINavigationController?
    private var hasPresented = false
    private var isClosing = false

    init(summary: LocalBookImportSummary) {
        self.summary = summary
        var sections: [Section] = [.summary]
        if !summary.books.isEmpty { sections.append(.books) }
        if !summary.failures.isEmpty { sections.append(.failures) }
        self.sections = sections
        super.init(style: .insetGrouped)
        title = LocalBookImportResultText.title
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func present(from owner: UIViewController) {
        guard !hasPresented, parent == nil, presentingViewController == nil,
            owner.canPerformNavigationAction
        else { return }
        self.owner = owner
        expectedWindow = owner.viewIfLoaded?.window
        expectedScene = expectedWindow?.windowScene
        expectedRoot = expectedWindow?.rootViewController
        expectedNavigation = owner.navigationController
        expectedTop = expectedNavigation?.topViewController
        guard hasCurrentOwner() else { return }

        let navigation = UINavigationController(rootViewController: self)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 560, height: 620)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
        }
        resultSheet = navigation
        hasPresented = true
        owner.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = AndroidReplicaTheme.background
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 88
        tableView.sectionHeaderHeight = UITableView.automaticDimension
        tableView.estimatedSectionHeaderHeight = 36
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(closeResult)
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = LocalBookImportResultText.done
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .summary: return 1
        case .books: return summary.books.count
        case .failures: return summary.failures.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .summary: return nil
        case .books:
            return LocalBookImportResultText.booksHeader(summary.books.count, retained: summary.isCancelled)
        case .failures: return LocalBookImportResultText.failuresHeader(summary.failures.count)
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell =
            tableView.dequeueReusableCell(withIdentifier: "import-result")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "import-result")
        var content = cell.defaultContentConfiguration()
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.adjustsFontForContentSizeCategory = true
        content.textProperties.color = AndroidReplicaTheme.primaryText
        content.textProperties.numberOfLines = 0
        content.textProperties.lineBreakMode = .byWordWrapping
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = AndroidReplicaTheme.secondaryText
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.lineBreakMode = .byWordWrapping
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.accessibilityTraits = .staticText
        cell.accessibilityHint = nil
        switch sections[indexPath.section] {
        case .summary:
            content.text = resultTitle
            content.secondaryText = resultMessage
            content.image = UIImage(systemName: resultSymbol)
        case .books:
            content.textProperties.lineBreakMode = .byCharWrapping
            let book = summary.books[indexPath.row]
            let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            content.text = name.isEmpty ? LocalBookImportResultText.unnamedBook : name
            content.secondaryText = author.isEmpty ? nil : author
            content.image = UIImage(systemName: "book.closed")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
            cell.accessibilityHint = LocalBookImportResultText.openBookHint
        case .failures:
            content.textProperties.lineBreakMode = .byCharWrapping
            let issue = summary.failures[indexPath.row]
            content.text = Self.displayFileName(issue.fileName)
            content.secondaryText = Self.displayIssueMessage(issue)
            content.image = UIImage(systemName: "exclamationmark.triangle")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections[indexPath.section] == .books,
            let sheet = currentSheet, hasCurrentOwner(allowing: sheet), canPerformNavigationAction
        else { return }
        let book = summary.books[indexPath.row]
        beginClosing()
        // Keep this context alive until dismissal, but navigate only through the original owner.
        sheet.dismiss(animated: true) { [self] in
            DispatchQueue.main.async { [self] in
                guard hasCurrentOwner(), let owner, owner.canPerformNavigationAction else { return }
                BookReadingDestination.open(book, from: owner)
            }
        }
    }

    @objc private func closeResult() {
        guard let sheet = currentSheet else { return }
        beginClosing()
        sheet.dismiss(animated: true)
    }

    private var currentSheet: UINavigationController? {
        guard !isClosing, let sheet = resultSheet, sheet.topViewController === self,
            let presenter = sheet.presentingViewController, presenter.presentedViewController === sheet,
            sheet.presentedViewController == nil, !sheet.isBeingPresented, !sheet.isBeingDismissed,
            sheet.transitionCoordinator == nil
        else { return nil }
        return sheet
    }

    private func beginClosing() {
        isClosing = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        tableView.isUserInteractionEnabled = false
    }

    private func hasCurrentOwner(allowing ownedSheet: UIViewController? = nil) -> Bool {
        guard let owner, let window = expectedWindow, let scene = expectedScene,
            let root = expectedRoot, let navigation = expectedNavigation, let expectedTop,
            window.rootViewController === root, window.windowScene === scene,
            owner.navigationController === navigation, navigation.topViewController === expectedTop,
            owner.isVisibleInNavigationStack, owner.viewIfLoaded?.window === window,
            UIApplication.shared.applicationState == .active, scene.activationState == .foregroundActive,
            window.isKeyWindow, !window.isHidden, window.alpha > 0,
            window.isUserInteractionEnabled, !window.accessibilityElementsHidden,
            AppLockManager.shared.isUnlocked(in: window)
        else { return false }
        if let ownedSheet {
            guard ownedSheet.viewIfLoaded?.window === window, ownedSheet.presentedViewController == nil else {
                return false
            }
        }
        var ancestor: UIViewController? = owner
        var foundNavigation = false
        while let controller = ancestor {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent,
                controller.transitionCoordinator == nil,
                controller.viewIfLoaded?.window === window,
                controller.viewIfLoaded?.isHidden == false, (controller.viewIfLoaded?.alpha ?? 0) > 0
            else { return false }
            if let presented = controller.presentedViewController, presented !== ownedSheet { return false }
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller {
                return false
            }
            if controller === navigation { foundNavigation = true }
            if controller === root { return foundNavigation }
            ancestor = controller.parent
        }
        return false
    }

    private var resultTitle: String {
        if summary.isCancelled { return LocalBookImportResultText.cancelled }
        if !summary.failures.isEmpty {
            return summary.books.isEmpty ? LocalBookImportResultText.failed : LocalBookImportResultText.partialSuccess
        }
        if summary.processedFiles < summary.totalFiles { return LocalBookImportResultText.incomplete }
        return summary.books.isEmpty ? LocalBookImportResultText.noBooks : LocalBookImportResultText.completed
    }

    private var resultSymbol: String {
        if summary.isCancelled { return "stop.circle" }
        if summary.books.isEmpty || !summary.failures.isEmpty || summary.processedFiles < summary.totalFiles {
            return "exclamationmark.circle"
        }
        return "checkmark.circle"
    }

    private var resultMessage: String {
        var lines = [
            LocalBookImportResultText.statistics(
                processed: summary.processedFiles, total: summary.totalFiles,
                books: summary.books.count, failures: summary.failures.count)
        ]
        if summary.isCancelled {
            lines.append(
                summary.books.isEmpty
                    ? LocalBookImportResultText.cancelledWithoutBooks : LocalBookImportResultText.cancelledWithBooks)
        } else if summary.books.isEmpty {
            lines.append(
                summary.totalFiles == 0 && summary.failures.isEmpty
                    ? LocalBookImportResultText.noFiles : LocalBookImportResultText.noneAdded)
        } else if !summary.failures.isEmpty {
            lines.append(LocalBookImportResultText.successfulBooksRetained)
        }
        if !summary.isCancelled, summary.processedFiles < summary.totalFiles {
            lines.append(LocalBookImportResultText.remainingFiles(summary.totalFiles - summary.processedFiles))
        }
        return lines.joined(separator: "\n")
    }

    private static func displayFileName(_ fileName: String) -> String {
        let decoded = fileName.removingPercentEncoding ?? fileName
        let normalized = decoded.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(
            in: .whitespacesAndNewlines)
        let name = (normalized as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "." || name == ".." ? LocalBookImportResultText.unnamedFile : name
    }

    private static func displayIssueMessage(_ issue: LocalBookImportIssue) -> String {
        if let owned = LocalBookImportResultText.ownedIssue(issue.message) { return owned }
        var message = issue.message.removingPercentEncoding ?? issue.message
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayFileName(issue.fileName)
        let originalName = issue.fileName.removingPercentEncoding ?? issue.fileName
        if !originalName.isEmpty {
            message = message.replacingOccurrences(of: originalName, with: name)
        }
        // Error descriptions can include sandbox or security-scoped locations.
        let quotedPathPattern = #"[\"'“‘](?i:file://|[a-z]:[\\/]|~/|/)[^\"'”’\r\n]*[\"'”’]"#
        message = message.replacingOccurrences(
            of: quotedPathPattern, with: LocalBookImportResultText.filePath, options: .regularExpression)
        let pathPattern = #"(?i)(?<![a-z0-9_])(?:file://|[a-z]:[\\/]|~/|/)[^\s\"'<>，。；：！？（）【】]+"#
        message = message.replacingOccurrences(
            of: pathPattern, with: LocalBookImportResultText.filePath, options: .regularExpression)
        return message.isEmpty ? LocalBookImportResultText.unknownFailure : message
    }
}

enum LocalBookImportResultText {
    static let title = text("title", "导入结果")
    static let done = text("done", "完成")
    static let cancelled = text("cancelled", "导入已取消")
    static let failed = text("failed", "导入失败")
    static let partialSuccess = text("partial_success", "部分导入成功")
    static let incomplete = text("incomplete", "导入未全部完成")
    static let noBooks = text("no_books", "未导入书籍")
    static let completed = text("completed", "导入完成")
    static let cancelledWithoutBooks = text("cancelled_without_books", "已停止后续导入，本次没有成功加入书架的书籍。")
    static let cancelledWithBooks = text("cancelled_with_books", "已停止后续导入，已成功处理的书籍全部保留在书架中。")
    static let noFiles = text("no_files", "没有需要导入的文件。")
    static let noneAdded = text("none_added", "本次没有成功加入书架的书籍。")
    static let successfulBooksRetained = text("successful_books_retained", "已成功导入的书籍已保留在书架中，其余失败原因见下方。")
    static let unnamedBook = text("unnamed_book", "未命名书籍")
    static let unnamedFile = text("unnamed_file", "未命名文件")
    static let filePath = text("file_path", "[文件路径]")
    static let unknownFailure = text("unknown_failure", "无法导入此文件，未提供具体原因。")
    static let openBookHint = text("open_book_hint", "打开书籍阅读")

    static func booksHeader(_ count: Int, retained: Bool) -> String {
        retained
            ? format("retained_books_header", "已保留的书籍（%d）", count)
            : format("added_books_header", "已加入书架（%d）", count)
    }

    static func failuresHeader(_ count: Int) -> String {
        format("failures_header", "导入失败（%d）", count)
    }

    static func statistics(processed: Int, total: Int, books: Int, failures: Int) -> String {
        format("statistics", "已处理 %1$d / %2$d 个文件，成功 %3$d 本，失败 %4$d 项。", processed, total, books, failures)
    }

    static func remainingFiles(_ count: Int) -> String {
        format("remaining_files", "尚有 %d 个文件未完成处理。", count)
    }

    static func ownedIssue(_ raw: String) -> String? {
        if raw == LocalBookFormats.unsupportedMessage {
            return text("error.unsupported_type", LocalBookFormats.unsupportedMessage)
        }
        // Match only complete messages emitted by the app, never arbitrary error fragments.
        let keys = [
            "压缩包超过 16 GiB，无法导入": "archive_too_large",
            "请选择有效的常规文件": "invalid_file",
            "不能导入空文件": "empty_file",
            "本地书籍目录异常，无法导入": "invalid_storage",
            "无法创建本地书籍文件": "cannot_create_file",
            "本地文件导入失败，请重试": "file_import_failed",
            "压缩包导入失败": "archive_import_failed",
            "压缩包中没有可导入的书籍": "archive_empty",
            "请选择压缩包内需要导入的书籍": "select_archive_books",
            "请选择压缩包内需要导入的一本书": "select_archive_book",
            "本地导入文件已失效": "expired_file",
        ]
        guard let key = keys[raw] else { return nil }
        return text("error." + key, raw)
    }

    private static func text(_ key: String, _ fallback: String) -> String {
        Bundle.main.localizedString(forKey: "consumer.import_result." + key, value: fallback, table: nil)
    }

    private static func format(_ key: String, _ fallback: String, _ arguments: CVarArg...) -> String {
        String(format: text(key, fallback), locale: Locale.current, arguments: arguments)
    }
}
