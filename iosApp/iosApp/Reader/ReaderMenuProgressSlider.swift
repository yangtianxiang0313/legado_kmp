import UIKit

struct ReaderMenuProgressContext: Hashable {
    let bookURL: String
    let chapterURL: String?
}

final class ReaderMenuProgressSlider: UISlider {
    var onCommit: ((Int, ReaderProgressBehavior) -> Void)?
    var onTrackingChange: ((Bool) -> Void)?

    private struct Progress {
        let index: Int
        let count: Int
        let behavior: ReaderProgressBehavior
        let context: ReaderMenuProgressContext

        var maximumIndex: Int { count - 1 }

        func sharesInteraction(with other: Progress) -> Bool {
            guard context.bookURL == other.context.bookURL,
                behavior == other.behavior, count == other.count
            else { return false }
            // ReadMenu.upSeekBar(): chapter progress spans the book, not the current chapter.
            return behavior == .chapter || context.chapterURL == other.context.chapterURL
        }
    }

    private enum InteractionKind {
        case touch
        case accessibility
    }

    private struct Interaction {
        let revision: UInt64
        let kind: InteractionKind
        var draft: Float
        var touchOffset: CGFloat = 0
    }

    private var progress: Progress?
    private var interaction: Interaction?
    private var revision: UInt64 = 0
    private var restingValue: Float = 0
    private var pageAvailable = true
    private var chapterAvailable = true
    private var interactionActive = false
    private var cancellingNativeTracking = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureInteraction()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInteraction()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isEnabled: Bool {
        didSet {
            if oldValue != isEnabled, !isEnabled {
                cancelTracking(with: nil)
            }
        }
    }

    override var isUserInteractionEnabled: Bool {
        didSet {
            if oldValue != isUserInteractionEnabled, !isUserInteractionEnabled {
                cancelTracking(with: nil)
            }
        }
    }

    func update(
        page: Int, pageCount: Int, chapter: Int, chapterCount: Int,
        behavior: ReaderProgressBehavior, context: ReaderMenuProgressContext
    ) {
        let count = max(behavior == .page ? pageCount : chapterCount, 1)
        let index = min(max(behavior == .page ? page : chapter, 0), count - 1)
        let next = Progress(index: index, count: count, behavior: behavior, context: context)
        let invalidatesInteraction = progress.map { !$0.sharesInteraction(with: next) } ?? true
        // Install the new authority before cancellation so callbacks never restore the old book.
        progress = next
        if invalidatesInteraction {
            cancelTracking(with: nil)
        } else if interaction == nil {
            restoreAuthoritativeValue()
        } else {
            updateAccessibilityValue()
        }
        updateAvailability()
    }

    func setAvailability(page: Bool, chapter: Bool) {
        guard pageAvailable != page || chapterAvailable != chapter else { return }
        pageAvailable = page
        chapterAvailable = chapter
        // Only disabling the selected mode ends its interaction; page loading must not
        // interrupt a book-wide chapter drag. isEnabled's observer performs the rollback.
        updateAvailability()
    }

    /// Call with false at menu dismissal, detachment, or scene suspension, and true when interactive again.
    func setInteractionActive(_ active: Bool) {
        interactionActive = active
        if !active {
            cancelTracking(with: nil)
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            setInteractionActive(false)
        }
        super.willMove(toWindow: newWindow)
    }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview == nil {
            setInteractionActive(false)
        }
        super.willMove(toSuperview: newSuperview)
    }

    override func trackRect(forBounds bounds: CGRect) -> CGRect {
        // AppCompat's SeekBar style contributes 16dp padding at both ends.
        CGRect(x: bounds.minX + 16, y: bounds.midY - 1, width: max(bounds.width - 32, 0), height: 2)
    }

    override func thumbRect(forBounds bounds: CGRect, trackRect rect: CGRect, value: Float) -> CGRect {
        let nativeRect = super.thumbRect(forBounds: bounds, trackRect: rect, value: value)
        let fraction = progressFraction(for: value)
        return CGRect(
            x: rect.minX + rect.width * fraction - nativeRect.width / 2,
            y: rect.midY - nativeRect.height / 2,
            width: nativeRect.width, height: nativeRect.height)
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        let verticalInset = max(44 - bounds.height, 0) / 2
        return bounds.insetBy(dx: 0, dy: -verticalInset).contains(point)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let token = beginTouchInteraction() else { return false }
        captureTouchOffset(touch)
        // Keep UIKit's tracking lifecycle, but accept the entire Android seek row.
        _ = super.beginTracking(touch, with: event)
        guard interaction?.revision == token else { return false }
        guard canInteract else {
            cancelTracking(with: event)
            return false
        }
        captureTouch(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard let current = interaction, current.kind == .touch, canInteract else { return false }
        _ = super.continueTracking(touch, with: event)
        guard interaction?.revision == current.revision else {
            restoreValueIfIdle()
            return false
        }
        guard canInteract else {
            cancelTracking(with: event)
            return false
        }
        captureTouch(touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard touch != nil else {
            cancelTracking(with: event)
            super.endTracking(touch, with: event)
            return
        }
        let token = interaction?.revision
        if let touch, interaction?.kind == .touch, canInteract {
            captureTouch(touch)
        }
        super.endTracking(touch, with: event)
        // UIKit may dispatch touchUp during or after super; both paths consume the same interaction.
        if let token, interaction?.revision == token {
            finishTouchInteraction()
        }
    }

    override func cancelTracking(with event: UIEvent?) {
        let wasTouchTracking = interaction?.kind == .touch
        revision &+= 1
        interaction = nil
        if !cancellingNativeTracking {
            cancellingNativeTracking = true
            super.cancelTracking(with: event)
            cancellingNativeTracking = false
        }
        restoreAuthoritativeValue()
        if wasTouchTracking {
            onTrackingChange?(false)
        }
    }

    override func accessibilityIncrement() {
        adjustAccessibility(increment: true)
    }

    override func accessibilityDecrement() {
        adjustAccessibility(increment: false)
    }

    private var canInteract: Bool {
        guard let progress else { return false }
        let available = progress.behavior == .page ? pageAvailable : chapterAvailable
        return interactionActive && isEnabled && isUserInteractionEnabled && available
    }

    private func configureInteraction() {
        isContinuous = true
        accessibilityIdentifier = UIIdentifiers.Reader.pageSlider
        addTarget(self, action: #selector(handleTouchDown), for: .touchDown)
        addTarget(self, action: #selector(handleValueChanged), for: .valueChanged)
        addTarget(self, action: #selector(handleTouchUp), for: [.touchUpInside, .touchUpOutside])
        addTarget(self, action: #selector(handleTouchCancel), for: .touchCancel)
        // UISlider maps primaryActionTriggered to valueChanged; it is not a release event.
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(applicationWillResignActive),
            name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        updateAvailability()
    }

    private func updateAvailability() {
        guard let progress else {
            isEnabled = false
            return
        }
        isEnabled = progress.behavior == .page ? pageAvailable : chapterAvailable
    }

    @discardableResult
    private func beginTouchInteraction() -> UInt64? {
        guard canInteract else { return nil }
        if let interaction {
            return interaction.kind == .touch ? interaction.revision : nil
        }
        revision &+= 1
        let token = revision
        interaction = Interaction(revision: token, kind: .touch, draft: value)
        onTrackingChange?(true)
        return interaction?.revision == token ? token : nil
    }

    private func captureDraft() {
        interaction?.draft = value
        updateAccessibilityValue()
    }

    private func captureTouchOffset(_ touch: UITouch) {
        let rect = trackRect(forBounds: bounds)
        guard rect.width > 0, maximumValue > minimumValue else { return }
        // AbsSeekBar captures against unmirrored progress, including in RTL.
        let fraction = CGFloat((value - minimumValue) / (maximumValue - minimumValue))
        let offset = fraction - (touch.location(in: self).x - rect.minX) / rect.width
        // AbsSeekBar retains the grab offset only within half its constant-size thumb drawable.
        let thumbWidth = max(
            thumbImage(for: .normal)?.size.width ?? 0, thumbImage(for: .highlighted)?.size.width ?? 0)
        if abs(offset * rect.width) <= thumbWidth / 2 {
            interaction?.touchOffset = offset
        }
    }

    private func captureTouch(_ touch: UITouch) {
        let rect = trackRect(forBounds: bounds)
        guard rect.width > 0 else { return }
        let touchFraction = (touch.location(in: self).x - rect.minX) / rect.width
        var fraction = effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - touchFraction : touchFraction
        if (0...1).contains(touchFraction) {
            fraction += interaction?.touchOffset ?? 0
        }
        fraction = min(max(fraction, 0), 1)
        let draft = minimumValue + Float(fraction) * (maximumValue - minimumValue)
        // SeekBar progress is integral even while dragging, not just on release.
        if let progress {
            super.setValue(Float(roundedIndex(draft, progress: progress)), animated: false)
        }
        captureDraft()
    }

    private func progressFraction(for value: Float) -> CGFloat {
        let range = maximumValue - minimumValue
        var fraction: CGFloat = range > 0 ? CGFloat((value - minimumValue) / range) : 0
        fraction = min(max(fraction, 0), 1)
        return effectiveUserInterfaceLayoutDirection == .rightToLeft ? 1 - fraction : fraction
    }

    private func finishTouchInteraction() {
        guard interaction?.kind == .touch else { return }
        guard canInteract else {
            cancelTracking(with: nil)
            return
        }
        captureDraft()
        finishInteraction()
    }

    private func finishInteraction() {
        guard let current = interaction, let progress, canInteract else { return }
        let index = roundedIndex(current.draft, progress: progress)
        interaction = nil
        presentRestingValue(Float(index))
        if current.kind == .touch {
            onTrackingChange?(false)
        }
        // A tracking callback may dismiss the menu or replace its context synchronously.
        guard revision == current.revision, canInteract else {
            restoreValueIfIdle()
            return
        }
        presentRestingValue(Float(index))
        onCommit?(index, progress.behavior)
    }

    private func adjustAccessibility(increment: Bool) {
        guard canInteract, interaction == nil else { return }
        revision &+= 1
        let token = revision
        interaction = Interaction(revision: token, kind: .accessibility, draft: value)
        // Preserve UISlider's native AX step; it does not deliver a touchUp event.
        if increment {
            super.accessibilityIncrement()
        } else {
            super.accessibilityDecrement()
        }
        guard interaction?.revision == token else {
            restoreValueIfIdle()
            return
        }
        captureDraft()
        finishInteraction()
    }

    private func restoreAuthoritativeValue() {
        guard let progress else { return }
        minimumValue = 0
        maximumValue = Float(progress.maximumIndex)
        presentRestingValue(Float(progress.index))
    }

    private func restoreValueIfIdle() {
        if interaction == nil {
            super.setValue(restingValue, animated: false)
            updateAccessibilityValue()
        }
    }

    private func presentRestingValue(_ newValue: Float) {
        restingValue = newValue
        super.setValue(newValue, animated: false)
        updateAccessibilityValue()
    }

    private func roundedIndex(_ rawValue: Float, progress: Progress) -> Int {
        guard rawValue.isFinite else { return progress.index }
        let bounded = min(max(rawValue, 0), Float(progress.maximumIndex))
        return min(Int(exactly: bounded.rounded()) ?? progress.maximumIndex, progress.maximumIndex)
    }

    private func updateAccessibilityValue() {
        guard let progress else { return }
        let index = roundedIndex(interaction?.draft ?? value, progress: progress)
        accessibilityValue = "\(index + 1)/\(progress.count)"
        accessibilityLabel =
            progress.behavior == .page ? L10n.Reader.progressBehaviorPage : L10n.Reader.progressBehaviorChapter
    }

    @objc private func handleTouchDown() {
        beginTouchInteraction()
    }

    @objc private func handleValueChanged() {
        guard interaction != nil, canInteract else {
            restoreValueIfIdle()
            return
        }
        captureDraft()
    }

    @objc private func handleTouchUp() {
        finishTouchInteraction()
    }

    @objc private func handleTouchCancel() {
        cancelTracking(with: nil)
    }

    @objc private func applicationWillResignActive() {
        setInteractionActive(false)
    }

    @objc private func sceneWillDeactivate(_ notification: Notification) {
        guard let scene = notification.object as? UIScene, scene === window?.windowScene else { return }
        setInteractionActive(false)
    }
}
