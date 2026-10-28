import UIKit

extension ReaderContainerViewController {
    func performReaderBackAction() {
        guard canPerformNavigationAction else { return }
        if textSelectionMenu != nil {
            dismissTextSelectionMenu(clearSelection: true)
            return
        }
        if let readerOverflowMenu {
            readerOverflowMenu.dismiss()
            return
        }
        if jumpNavigationCoordinator.handleBack(in: self) { return }
        guard !exitCoordinator.isBusy else { return }
        if readAloudState?.status == .running {
            exitCoordinator.pauseReadAloudForBack()
            return
        }
        if isAutoPageRunning {
            stopAutoPage(showMessage: false)
            exitCoordinator.saveProgressForBack()
            return
        }
        guard !ReaderMoreSettingsPreferenceBridge.disableReturnKeyEnabled() || isMenuVisible else {
            setMenuVisible(false)
            return
        }
        exitCoordinator.requestExit()
    }

    var readerBackKeyCommands: [UIKeyCommand] {
        guard canPerformNavigationAction else { return [] }
        return [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(readerBackKeyCommand(_:))),
            UIKeyCommand(input: "[", modifierFlags: .command, action: #selector(readerBackKeyCommand(_:))),
        ].map { command in
            command.discoverabilityTitle = L10n.Reader.backAction
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc func readerBackKeyCommand(_: UIKeyCommand) {
        performReaderBackAction()
    }

    func performReaderAccessibilityEscape() -> Bool {
        if textSelectionMenu != nil {
            dismissTextSelectionMenu(clearSelection: true)
            return true
        }
        guard canPerformNavigationAction else { return false }
        performReaderBackAction()
        return true
    }
}

extension ReaderContainerViewController: NavigationBackActionHandling {
    func interceptNavigationBackGesture() -> Bool {
        // Even a shelf exit waits for the latest progress write; it never needs a prompt.
        exitCoordinator.enqueueBackAction()
        return true
    }
}
