import Foundation
import PDFKit

struct PdfSearchMatch {
    struct PageRange: Equatable {
        let pageIndex: Int
        let range: NSRange
    }

    let pageIndex: Int
    let text: String
    let matchedText: String
    let ranges: [PageRange]

    @MainActor
    func selection(in document: PDFDocument) -> PDFSelection? {
        guard !document.isLocked, !ranges.isEmpty,
            pageIndex == ranges.map(\.pageIndex).min()
        else { return nil }

        var selections: [PDFSelection] = []
        for item in ranges {
            guard item.pageIndex >= 0, item.pageIndex < document.pageCount,
                let page = document.page(at: item.pageIndex), page.document === document,
                Self.isValid(item.range, characterCount: page.numberOfCharacters),
                let selection = page.selection(for: item.range),
                selection.pages.count == 1, selection.pages.first === page,
                selection.numberOfTextRanges(on: page) == 1,
                selection.range(at: 0, on: page) == item.range
            else { return nil }
            selections.append(selection)
        }

        let selection = PDFSelection(document: document)
        selection.add(selections)
        guard let mappedText = selection.string,
            mappedText.utf16.elementsEqual(matchedText.utf16)
        else { return nil }
        return selection
    }

    fileprivate static func make(from selection: PDFSelection, in document: PDFDocument) -> PdfSearchMatch? {
        guard let matchedText = selection.string, !matchedText.isEmpty else { return nil }
        var ranges: [PageRange] = []
        for page in selection.pages {
            let index = document.index(for: page)
            guard page.document === document, index != NSNotFound,
                index >= 0, index < document.pageCount
            else { return nil }
            let count = selection.numberOfTextRanges(on: page)
            guard count > 0 else { return nil }
            for rangeIndex in 0..<count {
                let range = selection.range(at: rangeIndex, on: page)
                guard isValid(range, characterCount: page.numberOfCharacters) else { return nil }
                ranges.append(PageRange(pageIndex: index, range: range))
            }
        }
        ranges.sort {
            if $0.pageIndex != $1.pageIndex { return $0.pageIndex < $1.pageIndex }
            return $0.range.location < $1.range.location
        }
        guard let first = ranges.first else { return nil }

        let context = selection.copy() as? PDFSelection
        context?.extend(atStart: 48)
        context?.extend(atEnd: 64)
        let plainText = (context?.string ?? matchedText)
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let snippet = String(plainText.prefix(300)) + (plainText.count > 300 ? "…" : "")
        return PdfSearchMatch(pageIndex: first.pageIndex, text: snippet, matchedText: matchedText, ranges: ranges)
    }

    private static func isValid(_ range: NSRange, characterCount: Int) -> Bool {
        range.location != NSNotFound && range.location >= 0 && range.length > 0
            && range.location <= characterCount && range.length <= characterCount - range.location
    }
}

@MainActor
final class PdfSearchCoordinator {
    enum Status: Equatable {
        case idle
        case searching
        case completed
        case cancelled
        case truncated
        case failed(String)
    }

    static let maximumQueryLength = 512
    static let maximumResults = 1_000

    var onUpdate: (() -> Void)?
    private(set) var query = ""
    private(set) var status: Status = .idle
    private(set) var results: [PdfSearchMatch] = []

    private let fileURL: URL
    private var generation = UUID()
    private var finder: PdfSearchFinder?
    private var startWork: DispatchWorkItem?
    private var updateWork: DispatchWorkItem?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    deinit {
        startWork?.cancel()
        updateWork?.cancel()
    }

    func search(query rawQuery: String) {
        releaseFinder()
        generation = UUID()
        let token = generation
        query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        results.removeAll(keepingCapacity: true)

        guard rawQuery.utf16.count <= Self.maximumQueryLength else {
            status = .failed("搜索词过长（最多 512 个 UTF-16 单元）")
            publish()
            return
        }
        guard !query.isEmpty else {
            status = .idle
            publish()
            return
        }
        guard fileURL.isFileURL else {
            status = .failed("PDF 查找需要本地文件")
            publish()
            return
        }

        let session = PdfSearchFinder(fileURL: fileURL, query: query) { [weak self] event in
            self?.receive(event, generation: token)
        }
        finder = session
        status = .searching
        publish()
        guard generation == token, finder === session else { return }

        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.generation == token, self.finder === session else { return }
            self.startWork = nil
            session.start()
        }
        startWork = work
        DispatchQueue.main.async(execute: work)
    }

    func cancel() {
        generation = UUID()
        releaseFinder()
        if status == .searching {
            status = .cancelled
            publish()
        }
    }

    private func receive(_ event: PdfSearchFinder.Event, generation token: UUID) {
        guard generation == token, status == .searching, finder != nil else { return }
        switch event {
        case .match(let match):
            guard results.count < Self.maximumResults else { return }
            results.append(match)
            if results.count == Self.maximumResults {
                status = .truncated
                releaseFinder()
                publish()
            } else {
                scheduleUpdate(generation: token)
            }
        case .finished:
            status = .completed
            releaseFinder()
            publish()
        case .failed(let message):
            status = .failed(message)
            releaseFinder()
            publish()
        }
    }

    private func scheduleUpdate(generation token: UUID) {
        guard updateWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token else { return }
            self.publish()
        }
        updateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func publish() {
        updateWork?.cancel()
        updateWork = nil
        onUpdate?()
    }

    private func releaseFinder() {
        startWork?.cancel()
        startWork = nil
        updateWork?.cancel()
        updateWork = nil
        let previous = finder
        finder = nil
        previous?.cancel()
    }
}

// Each query owns its document and observers on the main thread. PDFKit owns the asynchronous scan.
@MainActor
private final class PdfSearchFinder {
    enum Event {
        case match(PdfSearchMatch)
        case finished
        case failed(String)
    }

    private let fileURL: URL
    private let query: String
    private var onEvent: ((Event) -> Void)?
    private var document: PDFDocument?
    private var observers: [NSObjectProtocol] = []
    private var hasStarted = false
    private var isStopped = false
    private var hasScopedAccess = false

    init(fileURL: URL, query: String, onEvent: @escaping (Event) -> Void) {
        self.fileURL = fileURL
        self.query = query
        self.onEvent = onEvent
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        let document = document
        let fileURL = fileURL
        let hasScopedAccess = hasScopedAccess
        if Thread.isMainThread {
            document?.cancelFindString()
            if hasScopedAccess { fileURL.stopAccessingSecurityScopedResource() }
        } else {
            DispatchQueue.main.async {
                document?.cancelFindString()
                if hasScopedAccess { fileURL.stopAccessingSecurityScopedResource() }
            }
        }
    }

    func start() {
        guard !hasStarted, !isStopped else { return }
        hasStarted = true
        hasScopedAccess = fileURL.startAccessingSecurityScopedResource()
        guard let document = PDFDocument(url: fileURL) else {
            onEvent?(.failed("PDF 无法打开，文件可能已移除或损坏"))
            return
        }
        self.document = document
        guard !document.isLocked else {
            onEvent?(.failed("PDF 已锁定，无法查找正文"))
            return
        }
        guard document.pageCount > 0 else {
            onEvent?(.failed("PDF 没有可查找的页面"))
            return
        }

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .PDFDocumentDidFindMatch, object: document, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.receiveMatch(notification) }
            })
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .PDFDocumentDidEndFind, object: document, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated { self?.receiveEnd(notification) }
            })
        document.beginFindString(query, withOptions: .caseInsensitive)
    }

    func cancel() {
        guard !isStopped else { return }
        isStopped = true
        onEvent = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let previous = document
        document = nil
        previous?.cancelFindString()
        if hasScopedAccess {
            hasScopedAccess = false
            fileURL.stopAccessingSecurityScopedResource()
        }
    }

    private func receiveMatch(_ notification: Notification) {
        guard !isStopped, let document,
            let source = notification.object as? PDFDocument, source === document
        else { return }
        guard let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection,
            let match = PdfSearchMatch.make(from: selection, in: document)
        else {
            onEvent?(.failed("PDF 匹配内容无法定位"))
            return
        }
        onEvent?(.match(match))
    }

    private func receiveEnd(_ notification: Notification) {
        guard !isStopped, let document,
            let source = notification.object as? PDFDocument, source === document
        else { return }
        onEvent?(.finished)
    }
}
