import UIKit

/// GroupEditDialog.deleteGroup uses AndroidAlertBuilder's delete / sure_del / no / yes.
@MainActor
enum BookshelfGroupDeletionConfirmation {
    static func present(
        in editor: BookGroupEditorViewController,
        isCurrent: @escaping () -> Bool,
        onConfirm: @escaping () -> Void
    ) {
        guard editor.presentedViewController == nil, isCurrent(),
            let window = editor.viewIfLoaded?.window, let scene = window.windowScene
        else {
            editor.setBusy(false)
            return
        }
        let confirmation = ReaderRestoreProgressDialogViewController(
            title: "删除", message: "是否确认删除？",
            accessibilityIdentifierPrefix: "bookshelf.group.delete"
        ) { [weak editor] accepted in
            guard let editor else { return }
            guard accepted, isCurrent(), editor.presentedViewController == nil else {
                editor.setBusy(false)
                return
            }
            onConfirm()
        }
        confirmation.canConfirm = { [weak editor, weak confirmation, weak window, weak scene] in
            guard let editor, let confirmation, let window, let scene, isCurrent(),
                editor.viewIfLoaded?.window === window, window.isKeyWindow, !window.isHidden,
                window.alpha > 0.01, window.windowScene === scene, scene.activationState == .foregroundActive,
                UIApplication.shared.applicationState == .active,
                !editor.isBeingPresented, !editor.isBeingDismissed, !editor.isMovingFromParent
            else { return false }
            if confirmation.presentingViewController == nil { return editor.presentedViewController == nil }
            return editor.presentedViewController === confirmation
                && confirmation.presentingViewController?.presentedViewController === confirmation
                && confirmation.viewIfLoaded?.window === window
        }
        editor.present(confirmation, animated: !UIAccessibility.isReduceMotionEnabled)
    }
}
