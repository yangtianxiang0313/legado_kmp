import UIKit
import UniformTypeIdentifiers

@MainActor
final class ThemeBackgroundCoordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    typealias PerformChange = (@escaping () async throws -> Void) async throws -> Void

    private weak var owner: UIViewController?
    private let client = ThemeBackgroundSettingsClient()
    private var selection: Selection?
    private weak var picker: UIDocumentPickerViewController?
    private var task: Task<Void, Never>?

    private struct Selection {
        let expected: ThemeBackgroundConfiguration
        let isCurrent: () -> Bool
        let performChange: PerformChange
    }

    init(owner: UIViewController?) { self.owner = owner }

    deinit { task?.cancel() }

    func show(channel: ThemeBackgroundChannel, isCurrent: @escaping () -> Bool, performChange: @escaping PerformChange) {
        guard task == nil, selection == nil, isCurrent(), let owner, owner.presentedViewController == nil else { return }
        do {
            let expected = try client.configuration(channel)
            let binding = Selection(expected: expected, isCurrent: isCurrent, performChange: performChange)
            let actions = ["背景图片模糊", "选择图片"] + (expected.imagePath == nil ? [] : ["删除"])
            let dialog = ReaderPreferenceChoiceDialogViewController(
                title: channel.title, items: actions, selectedIndex: -1,
                identifier: channel.identifier + ".actions"
            ) { [weak self] index in
                guard let self, self.isCurrent(binding) else { return }
                switch index {
                case 0: self.showBlurring(binding)
                case 1: self.showImport(binding)
                case 2: self.removeImage(binding)
                default: break
                }
            }
            dialog.canSelect = { [weak self] in self?.isCurrent(binding) == true }
            owner.present(dialog, animated: true)
        } catch { owner.presentError(error) }
    }

    private func isCurrent(_ binding: Selection) -> Bool {
        binding.isCurrent() && (try? client.configuration(binding.expected.channel)) == binding.expected
    }

    private func showBlurring(_ binding: Selection) {
        guard isCurrent(binding), let owner, owner.presentedViewController == nil else { return }
        let dialog = ThemeBackgroundBlurViewController(
            value: binding.expected.blurring, identifier: binding.expected.channel.identifier + ".blur"
        ) { [weak self] value in
            guard let self else { return }
            self.mutate(binding) { [client = self.client] in
                try await client.setBlurring(value, expected: binding.expected)
            }
        }
        dialog.canSubmit = { [weak self] in self?.isCurrent(binding) == true }
        owner.present(dialog, animated: true)
    }

    private func showImport(_ binding: Selection) {
        guard isCurrent(binding), let owner, owner.presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        picker.view.accessibilityIdentifier = binding.expected.channel.identifier + ".import"
        self.picker = picker
        selection = binding
        owner.present(picker, animated: true) { [weak self, weak picker] in
            picker?.presentationController?.delegate = self
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard controller === picker, let binding = selection else { return }
        picker = nil
        selection = nil
        let url = urls.count == 1 ? urls.first : nil
        afterDismissing(controller) { [weak self] in
            guard let self, let url, self.isCurrent(binding) else { return }
            self.mutate(binding) { [weak self] in
                guard let self else { throw CancellationError() }
                let imported = try await ThemeBackgroundImageStore.shared.importImage(from: url)
                do {
                    try Task.checkCancellation()
                    guard binding.isCurrent() else { throw CancellationError() }
                    try await self.client.replaceImage(imported.path, expected: binding.expected)
                    if let references = try? self.client.referencedPaths() {
                        await ThemeBackgroundImageStore.shared.removeIfUnreferenced(
                            binding.expected.imagePath, referencedPaths: references)
                    }
                } catch {
                    if imported.created, let references = try? self.client.referencedPaths() {
                        await ThemeBackgroundImageStore.shared.removeIfUnreferenced(imported.path, referencedPaths: references)
                    }
                    throw error
                }
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard controller === picker else { return }
        picker = nil
        selection = nil
        controller.dismiss(animated: true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === picker else { return }
        picker = nil
        selection = nil
    }

    private func removeImage(_ binding: Selection) {
        // Like ThemeConfigFragment, removing an image retains this channel's blur value.
        mutate(binding) { [client] in
            try await client.replaceImage(nil, expected: binding.expected)
            if let references = try? client.referencedPaths() {
                await ThemeBackgroundImageStore.shared.removeIfUnreferenced(
                    binding.expected.imagePath, referencedPaths: references)
            }
        }
    }

    private func mutate(_ binding: Selection, operation: @escaping () async throws -> Void) {
        guard task == nil, isCurrent(binding), owner?.presentedViewController == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                try await binding.performChange(operation)
            } catch {
                guard !(error is CancellationError), binding.isCurrent(), self.owner?.presentedViewController == nil else {
                    return
                }
                self.owner?.presentError(error)
            }
        }
    }

    private func afterDismissing(_ controller: UIViewController, action: @escaping @MainActor @Sendable () -> Void) {
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true, completion: action)
        } else {
            DispatchQueue.main.async(execute: action)
        }
    }
}
