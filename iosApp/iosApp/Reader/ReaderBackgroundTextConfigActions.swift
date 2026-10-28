import UIKit
import shared

extension AndroidReaderBackgroundTextSheetViewController {
    func showRename() {
        guard canBeginPresetAction else { return }
        let name = presetName
        let index = presetIndex
        let queue = writes
        let dialog = ReaderConfigURLDialogViewController(name: name) { [weak self] newName in
            guard let self, newName != name, self.isCurrentPreset(name: name, index: index, queue: queue),
                self.presentedViewController == nil
            else { return }
            self.runCommand { [self] in
                guard self.isCurrentPreset(name: name, index: index, queue: queue) else { return }
                try await self.facade.renameReaderPresetAsync(oldName: name, newName: newName, expectedIndex: index)
            }
        }
        dialog.canSubmit = { [weak self] in self?.isCurrentPreset(name: name, index: index, queue: queue) == true }
        dialog.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
        present(dialog, animated: true)
    }

    func showRestore() {
        guard canBeginPresetAction else { return }
        let name = presetName
        let index = presetIndex
        let queue = writes
        do {
            let templates = try ReaderBackgroundTextFiles.restoreTemplates(facade: facade)
            let picker = ReaderBookChoiceDialogViewController(
                title: "选择预设布局", choices: templates.enumerated().map { .init(title: $0.element.name, accessibilityValue: String($0.offset)) },
                identifierPrefix: "readerAppearance.backgroundText.restore"
            ) { [weak self] selected in
                guard let self, templates.indices.contains(selected), self.isCurrentPreset(name: name, index: index, queue: queue),
                    self.presentedViewController == nil
                else { return }
                let template = templates[selected]
                self.runCommand { [self] in
                    guard self.isCurrentPreset(name: name, index: index, queue: queue) else { return }
                    try await self.facade.restoreReaderPresetAsync(name: name, template: template, expectedIndex: index)
                }
            }
            picker.overrideUserInterfaceStyle = traitCollection.userInterfaceStyle
            present(picker, animated: true)
        } catch { showActionError(error) }
    }

    func showConfigImport() {
        configTransfer.presentImportOptions(anchor: body.importButton)
    }

    func exportConfig() {
        configTransfer.export(anchor: body.exportButton)
    }

    // BgTextConfigDialog deletes immediately; ReadBookConfig protects the final five slots.
    func confirmDelete() {
        guard canBeginPresetAction else { return }
        guard facade.readerPresets.count > 5 else {
            showTransientMessage("数量已是最少,不能删除.")
            return
        }
        let name = presetName
        let index = presetIndex
        let queue = writes
        runCommand { [self] in
            guard isCurrentPreset(name: name, index: index, queue: queue) else { return }
            try await facade.deleteReaderPresetAsync(name: name, expectedIndex: index)
            guard canPresentBackgroundAction else { return }
            dismiss(animated: true)
        }
    }

    private var canBeginPresetAction: Bool {
        canPresentBackgroundAction && !isPerformingCommand && !visualBinding.isSwitching && presentedViewController == nil
    }

    private func isCurrentPreset(name: String, index: Int32, queue: ReaderBackgroundTextWriteQueue) -> Bool {
        canPresentBackgroundAction && !visualBinding.isSwitching && presetName == name && presetIndex == index && writes === queue
    }
}
