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

    static func request(_ draft: ReaderSimulatedReadingDraft, chapterCount: Int) throws -> ReaderSimulatedReadingRequest {
        func number(_ text: String, fallback: Int) throws -> Int32 {
            if text.isEmpty { return Int32(clamping: max(0, fallback)) }
            guard text.utf8.count <= 5, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int32(text) else {
                throw invalid(
                    NSLocalizedString(
                        "reader.simulated_reading.invalid_number", value: "章节数需填写最多五位的非负整数。", comment: ""))
            }
            return value
        }
        let iso = draft.startDate.isEmpty ? string() : draft.startDate
        guard date(iso) != nil else {
            throw invalid(
                NSLocalizedString(
                    "reader.simulated_reading.invalid_date", value: "请选择有效的开始日期。", comment: ""))
        }
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
    private let ownership = ReaderBookDialogOwnership()
    private var datePickerID: UUID?
    private weak var datePickerNavigation: UINavigationController?

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
        return canInteract ? [command] : nil
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
            UIResponder.keyboardDidHideNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged), name: name, object: nil)
        }
        for name in ReaderBookDialogOwnership.environmentNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(activationChanged(_:)), name: name, object: nil)
        }
        updateInteraction()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isFinished, !isClosing else { return }
        hasAppeared = true
        isVisible = true
        ownership.capture(from: self)
        scheduleRefresh()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.canInteract else { return }
            self.becomeFirstResponder()
            UIAccessibility.post(notification: .screenChanged, argument: self.contentView)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        if closeID == nil, isPresentationLeaving {
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
        close(confirming: false)
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
            presentedViewController == nil, let presenter = presentingViewController,
            presenter.presentedViewController === self, let window = ownership.window,
            window.isKeyWindow, window.windowScene?.activationState == .foregroundActive,
            viewIfLoaded?.window === window, !presenter.isBeingDismissed, !presenter.isMovingFromParent,
            UIApplication.shared.applicationState == .active, ownership.isCurrent(allowing: self)
        else { return false }
        return true
    }

    private var isPresentationLeaving: Bool {
        var current: UIViewController? = self
        while let controller = current {
            if controller.isBeingDismissed || controller.isMovingFromParent { return true }
            current = controller.parent ?? controller.presentingViewController
        }
        return false
    }

    private func updateInteraction() {
        guard isViewLoaded else { return }
        let enabled = canInteract
        let current = enabled && ownership.matchesReaderIdentity
        contentView.setInteraction(editable: current, cancelEnabled: enabled, submitEnabled: current)
        outsideControl.isEnabled = enabled
    }

    @objc private func cancel() { close(confirming: false) }

    @discardableResult
    private func close(confirming: Bool) -> Bool {
        guard canInteract else { return false }
        if confirming, !ownership.matchesReaderIdentity { return false }
        if confirming {
            contentView.startField.unmarkText()
            contentView.dailyField.unmarkText()
            do {
                pending = try ReaderSimulatedReadingDates.request(contentView.draft, chapterCount: chapterCount)
            } catch {
                contentView.showStatus(error.userFacingMessage)
                view.setNeedsLayout()
                return true
            }
        } else {
            pending = nil
        }
        guard canInteract else {
            pending = nil
            return false
        }
        let id = UUID()
        closeID = id
        isClosing = true
        isVisible = false
        updateInteraction()
        view.endEditing(true)
        resignFirstResponder()
        if !ownership.isCurrent(allowing: self) { pending = nil }
        super.dismiss(animated: !UIAccessibility.isReduceMotionEnabled) { [self] in
            if closeID == id { closeID = nil }
            finishIfDetached()
            scheduleRefresh()
        }
        return true
    }

    private func pickDate() {
        guard canInteract else { return }
        view.endEditing(true)
        guard canInteract else { return }
        let id = UUID()
        let picker = ReaderSimulationDatePickerViewController(
            date: ReaderSimulatedReadingDates.date(contentView.draft.startDate) ?? Date()
        ) { [weak self] date in
            guard let self, self.datePickerID == id else { return }
            self.datePickerID = nil
            let navigation = self.datePickerNavigation
            self.datePickerNavigation = nil
            if let date, !self.isClosing, !self.isFinished, self.presentedViewController == nil,
                navigation?.presentingViewController == nil, navigation?.viewIfLoaded?.window == nil,
                self.ownership.isCurrent(allowing: self), self.ownership.matchesReaderIdentity
            {
                self.contentView.setStartDate(ReaderSimulatedReadingDates.string(date))
            }
            self.scheduleRefresh()
        }
        let navigation = UINavigationController(rootViewController: picker)
        navigation.modalPresentationStyle = .formSheet
        navigation.preferredContentSize = CGSize(width: 360, height: 300)
        datePickerID = id
        datePickerNavigation = navigation
        present(navigation, animated: true)
        updateInteraction()
    }

    @objc private func environmentChanged() { scheduleRefresh() }
    @objc private func activationChanged(_ notification: Notification) {
        guard ownership.belongs(notification) else { return }
        ownership.receive(notification)
        if ReaderBookDialogOwnership.interruptionNotifications.contains(notification.name) { pending = nil }
        scheduleRefresh()
    }
    private func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            self?.updateInteraction()
            self?.view.setNeedsLayout()
            self?.finishIfDetached()
        }
    }

    private func finishIfDetached() {
        guard hasAppeared, !isFinished, closeID == nil, presentingViewController == nil, parent == nil,
            presentedViewController == nil, viewIfLoaded?.window == nil, viewIfLoaded?.superview == nil
        else { return }
        isFinished = true
        NotificationCenter.default.removeObserver(self)
        let request = pending
        let confirm = onConfirm
        let close = onClose
        pending = nil
        onConfirm = nil
        onClose = nil
        if let request, ownership.isCurrent(), ownership.matchesReaderIdentity { confirm?(request) }
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
    private var isVisible = false
    private var deliveryRevoked = false
    private let ownership = ReaderBookDialogOwnership()
    private weak var originalPresenter: UIViewController?
    private weak var originalRoot: UIViewController?
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
        title = ReaderSimulationText.startDate
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
        for name in ReaderBookDialogOwnership.environmentNotifications {
            NotificationCenter.default.addObserver(
                self, selector: #selector(environmentChanged(_:)), name: name, object: nil)
        }
    }
    override func accessibilityPerformEscape() -> Bool {
        finish(nil)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let navigation = navigationController, originalPresenter == nil {
            originalPresenter = navigation.presentingViewController
            originalRoot = view.window?.rootViewController
            ownership.capture(from: navigation)
        }
        isVisible = true
        navigationController?.presentationController?.delegate = self
        updateInteraction()
        DispatchQueue.main.async { [weak self] in self?.updateInteraction() }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        updateInteraction()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard !isClosing else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.navigationController?.presentingViewController == nil,
                self.viewIfLoaded?.window == nil
            else { return }
            self.deliver(nil)
        }
    }
    func presentationControllerDidDismiss(_: UIPresentationController) {
        guard !isClosing else { return }
        deliver(nil)
    }
    private func deliver(_ date: Date?) {
        let callback = onChoose
        onChoose = nil
        isClosing = true
        NotificationCenter.default.removeObserver(self)
        callback?(date)
    }
    @objc private func cancel() { finish(nil) }
    @objc private func done() { finish(picker.date) }
    @discardableResult
    private func finish(_ date: Date?) -> Bool {
        guard canInteract else { return false }
        isClosing = true
        deliveryRevoked = false
        updateInteraction()
        dismiss(animated: true) { [self] in
            let accepted = !deliveryRevoked && ownership.isCurrent() ? date : nil
            deliver(accepted)
        }
        return true
    }
    private var canInteract: Bool {
        guard isVisible, !isClosing, let window = ownership.window,
            ownership.isEnvironmentAvailable,
            !window.isHidden, window.alpha > 0, window.isKeyWindow,
            window.rootViewController === originalRoot, window.windowScene?.activationState == .foregroundActive,
            UIApplication.shared.applicationState == .active, AppLockManager.shared.isUnlocked(in: window),
            viewIfLoaded?.window === window, let navigation = navigationController,
            navigation.topViewController === self, let presenter = originalPresenter,
            navigation.presentingViewController === presenter, presenter.presentedViewController === navigation
        else { return false }
        // The owned form sheet may cover/remove its presenter's view on a compact device.
        var current: UIViewController? = self
        var expected: UIViewController?
        var last: UIViewController?
        while let controller = current {
            guard !controller.isBeingPresented, !controller.isBeingDismissed,
                !controller.isMovingFromParent, !controller.isMovingToParent
            else { return false }
            if let presented = controller.presentedViewController, presented !== expected { return false }
            if let parent = controller.parent as? UINavigationController, parent.topViewController !== controller {
                return false
            }
            if let parent = controller.parent as? UITabBarController, parent.selectedViewController !== controller {
                return false
            }
            last = controller
            if let parent = controller.parent {
                expected = nil
                current = parent
            } else {
                expected = controller
                current = controller.presentingViewController
            }
        }
        return last === originalRoot
    }
    @objc private func environmentChanged(_ notification: Notification) {
        guard ownership.belongs(notification) else { return }
        ownership.receive(notification)
        if ReaderBookDialogOwnership.interruptionNotifications.contains(notification.name) { deliveryRevoked = true }
        updateInteraction()
        DispatchQueue.main.async { [weak self] in self?.updateInteraction() }
    }
    private func updateInteraction() {
        let enabled = canInteract
        navigationItem.leftBarButtonItem?.isEnabled = enabled
        navigationItem.rightBarButtonItem?.isEnabled = enabled
        picker.isUserInteractionEnabled = enabled
    }
}
