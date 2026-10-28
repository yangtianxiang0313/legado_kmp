import UIKit
import shared

@MainActor
final class ReaderBackgroundColorSelectionCoordinator {
    private struct Selection {
        let id = UUID()
        let presetName: String
        let variant: ReaderVisualVariant
        let queue: ReaderBackgroundTextWriteQueue
        let target: AndroidReaderStyleColorTarget
    }

    private weak var owner: AndroidReaderBackgroundTextSheetViewController?
    private weak var dialog: ReaderColorPickerDialogViewController?
    private var selection: Selection?
    private var backgroundObserver: NSObjectProtocol?

    init(owner: AndroidReaderBackgroundTextSheetViewController) {
        self.owner = owner
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIScene.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let scene = notification.object as? UIScene else { return }
            Task { @MainActor [weak self] in
                guard self?.owner?.viewIfLoaded?.window?.windowScene === scene else { return }
                self?.deactivate()
            }
        }
    }

    deinit {
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }

    func present(_ target: AndroidReaderStyleColorTarget) {
        guard let owner, owner.canPresentBackgroundAction, !owner.isPerformingCommand,
            !owner.visualBinding.isSwitching, owner.presentedViewController == nil, dialog == nil
        else { return }
        let selected = Selection(
            presetName: owner.presetName, variant: owner.visualBinding.variant, queue: owner.writes, target: target)
        selection = selected
        let picker = ReaderColorPickerDialogViewController(
            color: Self.initialColor(style: selected.queue.style, target: target),
            onClose: { [weak self] in
                guard self?.selection?.id == selected.id else { return }
                self?.dialog = nil
                self?.selection = nil
            },
            onSelect: { [weak self] color in
                guard let self, self.accepts(selected), self.owner?.presentedViewController == nil else { return }
                let value = color.hexString
                selected.queue.update { style in
                    selected.target == .text
                        ? style.androidCopy(textColorHex: value)
                        : style.androidCopy(backgroundColorHex: value, backgroundImagePath: .some(nil))
                }
            })
        picker.canSubmit = { [weak self] in self?.accepts(selected) == true }
        picker.overrideUserInterfaceStyle = owner.traitCollection.userInterfaceStyle
        dialog = picker
        owner.present(picker, animated: true)
    }

    func deactivate() {
        selection = nil
        let picker = dialog
        dialog = nil
        picker?.dismiss(animated: false)
    }

    static func initialColor(style: ReaderStylePreferences, target: AndroidReaderStyleColorTarget) -> UIColor {
        if target == .background, style.backgroundImagePath?.isEmpty == false {
            return UIColor(hex: "#015A86")!
        }
        let defaults = AndroidReaderStyleScale.defaultColors(for: style.backgroundMode)
        let value = target == .text ? style.textColorHex ?? defaults.text : style.backgroundColorHex ?? defaults.background
        return UIColor(hex: value) ?? (target == .text ? .black : .white)
    }

    private func accepts(_ selected: Selection) -> Bool {
        guard selection?.id == selected.id, let owner,
            owner.canPresentBackgroundAction, !owner.isPerformingCommand, !owner.visualBinding.isSwitching,
            owner.presetName == selected.presetName, owner.visualBinding.variant == selected.variant,
            owner.writes === selected.queue
        else { return false }
        return true
    }
}
