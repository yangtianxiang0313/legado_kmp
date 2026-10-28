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
        title = "导入结果"
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
            return summary.isCancelled ? "已保留的书籍（\(summary.books.count)）" : "已加入书架（\(summary.books.count)）"
        case .failures: return "导入失败（\(summary.failures.count)）"
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
        content.textProperties.lineBreakMode = .byCharWrapping
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .subheadline)
        content.secondaryTextProperties.adjustsFontForContentSizeCategory = true
        content.secondaryTextProperties.color = AndroidReplicaTheme.secondaryText
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.lineBreakMode = .byCharWrapping
        cell.accessoryType = .none
        cell.selectionStyle = .none
        cell.accessibilityTraits = .staticText
        switch sections[indexPath.section] {
        case .summary:
            content.text = resultTitle
            content.secondaryText = resultMessage
            content.image = UIImage(systemName: resultSymbol)
        case .books:
            let book = summary.books[indexPath.row]
            let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
            content.text = name.isEmpty ? "未命名书籍" : name
            content.secondaryText = author.isEmpty ? nil : author
            content.image = UIImage(systemName: "book.closed")
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            cell.accessibilityTraits = .button
        case .failures:
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
            guard ownedSheet.viewIfLoaded?.window === window, ownedSheet.presentedViewController == nil else { return false }
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
            if let tabs = controller.parent as? UITabBarController, tabs.selectedViewController !== controller { return false }
            if controller === navigation { foundNavigation = true }
            if controller === root { return foundNavigation }
            ancestor = controller.parent
        }
        return false
    }

    private var resultTitle: String {
        if summary.isCancelled { return "导入已取消" }
        if !summary.failures.isEmpty { return summary.books.isEmpty ? "导入失败" : "部分导入成功" }
        if summary.processedFiles < summary.totalFiles { return "导入未全部完成" }
        return summary.books.isEmpty ? "未导入书籍" : "导入完成"
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
            "已处理 \(summary.processedFiles) / \(summary.totalFiles) 个文件，成功 \(summary.books.count) 本，失败 \(summary.failures.count) 项。"
        ]
        if summary.isCancelled {
            lines.append(summary.books.isEmpty ? "已停止后续导入，本次没有成功加入书架的书籍。" : "已停止后续导入，已成功处理的书籍全部保留在书架中。")
        } else if summary.books.isEmpty {
            lines.append(summary.totalFiles == 0 && summary.failures.isEmpty ? "没有需要导入的文件。" : "本次没有成功加入书架的书籍。")
        } else if !summary.failures.isEmpty {
            lines.append("已成功导入的书籍已保留在书架中，其余失败原因见下方。")
        }
        if !summary.isCancelled, summary.processedFiles < summary.totalFiles {
            lines.append("尚有 \(summary.totalFiles - summary.processedFiles) 个文件未完成处理。")
        }
        return lines.joined(separator: "\n")
    }

    private static func displayFileName(_ fileName: String) -> String {
        let decoded = fileName.removingPercentEncoding ?? fileName
        let normalized = decoded.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (normalized as NSString).lastPathComponent
        return name.isEmpty || name == "/" || name == "." || name == ".." ? "未命名文件" : name
    }

    private static func displayIssueMessage(_ issue: LocalBookImportIssue) -> String {
        var message = issue.message.removingPercentEncoding ?? issue.message
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = displayFileName(issue.fileName)
        let originalName = issue.fileName.removingPercentEncoding ?? issue.fileName
        if !originalName.isEmpty {
            message = message.replacingOccurrences(of: originalName, with: name)
        }
        // Error descriptions can include sandbox or security-scoped locations.
        let quotedPathPattern = #"[\"'“‘](?i:file://|[a-z]:[\\/]|~/|/)[^\"'”’\r\n]*[\"'”’]"#
        message = message.replacingOccurrences(of: quotedPathPattern, with: "[文件路径]", options: .regularExpression)
        let pathPattern = #"(?i)(?<![a-z0-9_])(?:file://|[a-z]:[\\/]|~/|/)[^\s\"'<>，。；：！？（）【】]+"#
        message = message.replacingOccurrences(of: pathPattern, with: "[文件路径]", options: .regularExpression)
        return message.isEmpty ? "无法导入此文件，未提供具体原因。" : message
    }
}
