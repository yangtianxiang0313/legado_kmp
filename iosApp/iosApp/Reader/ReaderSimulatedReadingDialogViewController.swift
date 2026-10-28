import UIKit
import shared

struct ReaderSimulatedReadingRequest: Equatable {
    let enabled: Bool
    let startDateIso: String
    let startChapter: Int32
    let dailyChapters: Int32
}

@MainActor
enum ReaderSimulatedReadingDates {
    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    static func string(_ date: Date = Date()) -> String { formatter.string(from: date) }
    static func date(_ text: String) -> Date? {
        guard text.utf8.count == 10, let date = formatter.date(from: text), string(date) == text else { return nil }
        return date
    }

    static func initialDraft(book: Book, currentChapterIndex: Int) -> ReaderSimulatedReadingDraft {
        let config = book.config
        return ReaderSimulatedReadingDraft(
            enabled: config.readSimulating,
            startDate: config.readSimulating ? config.startDate?.description() ?? string() : string(),
            startChapter: String(
                config.readSimulating ? Int(config.startChapter?.int32Value ?? 0) : currentChapterIndex),
            dailyChapters: String(config.dailyChapters))
    }

    static func request(_ draft: ReaderSimulatedReadingDraft, chapterCount: Int) throws -> ReaderSimulatedReadingRequest
    {
        func number(_ text: String, fallback: Int) throws -> Int32 {
            if text.isEmpty { return Int32(clamping: max(0, fallback)) }
            guard text.utf8.count <= 5, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int32(text) else {
                throw invalid("章节数需填写最多五位的非负整数。")
            }
            return value
        }
        let iso = draft.startDate.isEmpty ? string() : draft.startDate
        guard date(iso) != nil else { throw invalid("请选择有效的开始日期。") }
        return try ReaderSimulatedReadingRequest(
            enabled: draft.enabled, startDateIso: iso,
            startChapter: number(draft.startChapter, fallback: 0),
            dailyChapters: number(draft.dailyChapters, fallback: chapterCount))
    }

    private static func invalid(_ message: String) -> NSError {
        NSError(domain: "io.legado.reader.simulation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// BaseReadBookActivity.showSimulatedReading at Legado 5f5d314.
@MainActor
final class ReaderSimulatedReadingDialogViewController: UIViewController {
    var onClose: (() -> Void)?
    private let contentView: ReaderSimulatedReadingDialogContentView
    private let outsideControl = UIControl()
    private let chapterCount: Int
    private var onConfirm: ((ReaderSimulatedReadingRequest) -> Void)?
    private var pending: ReaderSimulatedReadingRequest?
    private var isVisible = false
    private var isClosing = false
    private var isFinished = false
    private var hasAppeared = false
    private var closeID: UUID?
    private weak var originalPresenter: UIViewController?
    private weak var originalWindow: UIWindow?

    init(
        draft: ReaderSimulatedReadingDraft, chapterCount: Int, onClose: (() -> Void)? = nil,
        onConfirm: @escaping (ReaderSimulatedReadingRequest) -> Void
    ) {
        contentView = ReaderSimulatedReadingDialogContentView(draft: draft)
        self.chapterCount = chapterCount
        self.onClose = onClose
        self.onConfirm = onConfirm
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var canBecomeFirstResponder: Bool { true }
    override var keyCommands: [UIKeyCommand]? {
        let command = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(cancel))
        command.discoverabilityTitle = L10n.Common.cancel
        command.wantsPriorityOverSystemBehavior = true
        return isClosing ? nil : [command]
    }

    override func loadView() {
        let root = ReaderSimulatedReadingRootView()
        root.onWindowChange = { [weak self] in self?.scheduleRefresh() }
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "reader.simulatedReading.dialog"
        view.accessibilityViewIsModal = true
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
        outsideControl.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        outsideControl.isAccessibilityElement = false
        outsideControl.accessibilityElementsHidden = true
        outsideControl.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        view.addSubview(outsideControl)
        view.addSubview(contentView)
        view.accessibilityElements = [contentView]
        contentView.onConfirm = { [weak self] in self?.close(confirming: true) }
        contentView.onCancel = { [weak self] in self?.close(confirming: false) }
        contentView.onPickDate = { [weak self] in self?.pickDate() }
        contentView.onChange = { [weak self] in self?.view.setNeedsLayout() }
        contentView.applyFonts(traits: traitCollection)
        for name in [
            UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification, UIScene.didActivateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: name, object: nil)
        }
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isFinished, !isClosing else { return }
        hasAppeared = true
        isVisible = true
        if originalPresenter == nil {
            originalPresenter = presentingViewController
            originalWindow = view.window
        }
        becomeFirstResponder()
        scheduleRefresh()
        UIAccessibility.post(notification: .screenChanged, argument: contentView)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if closeID == nil, isBeingDismissed || originalPresenter?.isBeingDismissed == true {
            pending = nil
            isClosing = true
        }
        updateInteraction()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        scheduleRefresh()
    }

    override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
        guard !isFinished else {
            completion?()
            return
        }
        if presentedViewController != nil {
            super.dismiss(animated: flag, completion: completion)
            return
        }
        pending = nil
        closeID = nil
        isClosing = true
        isVisible = false
        updateInteraction()
        super.dismiss(animated: flag) { [self] in
            finishIfDetached()
            scheduleRefresh()
            completion?()
        }
    }

    override func accessibilityPerformEscape() -> Bool {
        guard canInteract else { return false }
        close(confirming: false)
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard isViewLoaded else { return }
        contentView.applyFonts(traits: traitCollection)
        view.setNeedsLayout()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        outsideControl.frame = view.bounds
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let size = view.bounds.size
        let landscape = size.width > size.height
        let fraction: CGFloat =
            min(size.width, size.height) >= 720
            ? (landscape ? 0.45 : 0.72)
            : (min(size.width, size.height) >= 480
                ? (landscape ? 0.55 : 0.80) : (landscape ? 0.65 : 0.95))
        let width = min(safe.width, size.width * fraction)
        var available = safe
        let keyboard = view.keyboardLayoutGuide.layoutFrame.intersection(safe)
        if !keyboard.isNull, keyboard.height > 0 { available.size.height = max(0, keyboard.minY - safe.minY) }
        let preferred = contentView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        let height = min(available.height, preferred.height)
        contentView.frame = CGRect(
            x: safe.midX - width / 2, y: available.midY - height / 2, width: width, height: height)
        contentView.layoutIfNeeded()
    }

    private var canInteract: Bool {
        guard hasAppeared, isVisible, !isClosing, !isFinished, !isBeingPresented, !isBeingDismissed,
            presentedViewController == nil, let presenter = originalPresenter,
            presenter.presentedViewController === self, let window = originalWindow,
            window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
            viewIfLoaded?.window === window, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            UIApplication.shared.applicationState == .active
        else { return false }
        return true
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = canInteract
        contentView.setInteraction(editable: enabled, cancelEnabled: enabled, submitEnabled: enabled)
        outsideControl.isEnabled = enabled
    }

    @objc private func cancel() { close(confirming: false) }

    private func close(confirming: Bool) {
        guard canInteract else { return }
        if confirming {
            contentView.startField.unmarkText()
            contentView.dailyField.unmarkText()
            do {
                pending = try ReaderSimulatedReadingDates.request(contentView.draft, chapterCount: chapterCount)
            } catch {
                contentView.showStatus(error.userFacingMessage)
                view.setNeedsLayout()
                return
            }
        } else {
            pending = nil
        }
        let id = UUID()
        closeID = id
        isClosing = true
        isVisible = false
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            if closeID == id { closeID = nil }
            finishIfDetached()
            scheduleRefresh()
        }
    }

    private func pickDate() {
        guard canInteract else { return }
        view.endEditing(true)
        let picker = ReaderSimulationDatePickerViewController(
            date: ReaderSimulatedReadingDates.date(contentView.draft.startDate) ?? Date()
        ) { [weak self] date in
            guard let self, !self.isClosing, !self.isFinished else { return }
            if let date { self.contentView.setStartDate(ReaderSimulatedReadingDates.string(date)) }
            self.scheduleRefresh()
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 360, height: 300)
        present(navigation, animated: true)
        updateInteraction()
    }

    @objc private func environmentChanged() { scheduleRefresh() }
    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.updateInteraction()
            self?.view.setNeedsLayout()
            self?.finishIfDetached()
        }
    }

    private func finishIfDetached() {
        guard hasAppeared, !isFinished, closeID == nil, presentingViewController == nil, parent == nil,
            viewIfLoaded?.window == nil
        else { return }
        isFinished = true
        NotificationCenter.default.removeObserver(self)
        let request = pending
        let confirm = onConfirm
        let close = onClose
        pending = nil
        onConfirm = nil
        onClose = nil
        if let request, originalWindow?.windowScene?.activationState == .foregroundActive,
            originalPresenter?.isBeingDismissed != true, originalPresenter?.isMovingFromParent != true
        {
            confirm?(request)
        }
        close?()
    }
}

private final class ReaderSimulatedReadingRootView: UIView {
    var onWindowChange: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

@MainActor
final class ReaderSimulationDatePickerViewController: UIViewController, UIAdaptivePresentationControllerDelegate {
    let picker = UIDatePicker()
    private var onChoose: ((Date?) -> Void)?
    private var isClosing = false
    init(date: Date, onChoose: @escaping (Date?) -> Void) {
        self.onChoose = onChoose
        super.init(nibName: nil, bundle: nil)
        picker.calendar = Calendar(identifier: .gregorian)
        picker.timeZone = .current
        picker.datePickerMode = .date
        picker.preferredDatePickerStyle = .wheels
        picker.date = date
    }
    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "开始日期"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(done))
        picker.accessibilityIdentifier = "reader.simulatedReading.datePicker"
        picker.minimumDate = ReaderSimulatedReadingDates.date("0001-01-01")
        picker.maximumDate = ReaderSimulatedReadingDates.date("9999-12-31")
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            picker.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            picker.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])
    }
    override func accessibilityPerformEscape() -> Bool {
        guard !isClosing else { return false }
        cancel()
        return true
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }
    func presentationControllerDidDismiss(_: UIPresentationController) {
        let callback = onChoose
        onChoose = nil
        isClosing = true
        callback?(nil)
    }
    @objc private func cancel() { finish(nil) }
    @objc private func done() { finish(picker.date) }
    private func finish(_ date: Date?) {
        guard !isClosing else { return }
        isClosing = true
        let callback = onChoose
        onChoose = nil
        dismiss(animated: true) { callback?(date) }
    }
}
