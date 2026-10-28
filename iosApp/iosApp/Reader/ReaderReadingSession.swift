import UIKit
import shared

/// Only visible, active reading time belongs to the text reader's session.
@MainActor
final class ReaderReadingSession: NSObject {
    private weak var reader: ReaderContainerViewController?
    private var facade: ReaderFacade?
    private var visible = false
    private var sceneSuspended = false
    private var desiredURL: String?
    private var activeURL: String?
    private var needsFlush = false
    private var worker: Task<Void, Never>?
    private var timer: Timer?

    init(reader: ReaderContainerViewController) {
        self.reader = reader
        super.init()
        for name in [UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(deactivated(_:)), name: name, object: nil)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activated(_:)), name: UIScene.didActivateNotification, object: nil)
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        if let facade, let activeURL {
            Task { try? await facade.endReadSession(bookUrl: activeURL) }
        }
    }

    func resume() {
        visible = true
        refresh()
    }

    func suspend() {
        visible = false
        desiredURL = nil
        timer?.invalidate()
        timer = nil
        drain()
    }

    func refresh() {
        // Pagination clears its applying flag after renderCurrentPage returns.
        DispatchQueue.main.async { [weak self] in self?.reconcileVisibleContent() }
    }

    private func reconcileVisibleContent() {
        guard visible, !sceneSuspended, let reader,
            reader.viewIfLoaded?.window?.windowScene?.activationState == .foregroundActive,
            reader.navigationController?.topViewController === reader,
            reader.canNavigateReaderPages, !reader.pages.isEmpty,
            reader.book?.bookUrl == reader.bookURL
        else { return }
        if facade == nil {
            do { facade = try BootstrapApiKt.sharedReaderFacade() } catch {
                SharedRuntime.log("reading session unavailable: \(error.localizedDescription)"); return
            }
        }
        desiredURL = reader.bookURL
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.needsFlush = true
                    self?.drain()
                }
            }
        }
        drain()
    }

    @objc private func deactivated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, reader?.viewIfLoaded?.window?.windowScene === scene else { return }
        sceneSuspended = true
        desiredURL = nil
        timer?.invalidate()
        timer = nil
        drain()
    }

    @objc private func activated(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, reader?.viewIfLoaded?.window?.windowScene === scene else { return }
        sceneSuspended = false
        refresh()
    }

    private func drain() {
        guard worker == nil, let facade else { return }
        worker = Task { [self] in
            while activeURL != desiredURL || needsFlush {
                if activeURL != desiredURL {
                    if let old = activeURL {
                        activeURL = nil
                        try? await facade.endReadSession(bookUrl: old)
                    }
                    if let next = desiredURL {
                        facade.beginReadSession(bookUrl: next)
                        activeURL = next
                    }
                } else if let activeURL, needsFlush {
                    needsFlush = false
                    try? await facade.updateReadTime(bookUrl: activeURL)
                } else {
                    needsFlush = false
                }
            }
            worker = nil
        }
    }
}
