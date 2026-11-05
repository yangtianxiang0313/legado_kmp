import UIKit

@MainActor
final class MangaReaderGestures: NSObject, UIGestureRecognizerDelegate {
    private let canInteract: () -> Bool
    private let onTap: (CGPoint) -> Void
    private let onZoom: (CGPoint) -> Void
    private let doubleTap = UITapGestureRecognizer()

    init(
        collection: UICollectionView, canInteract: @escaping () -> Bool,
        onTap: @escaping (CGPoint) -> Void, onZoom: @escaping (CGPoint) -> Void,
        onMenu: @escaping () -> Void
    ) {
        self.canInteract = canInteract
        self.onTap = onTap
        self.onZoom = onZoom
        super.init()
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        doubleTap.addTarget(self, action: #selector(zoomed(_:)))
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        singleTap.delegate = self
        doubleTap.delegate = self
        collection.addGestureRecognizer(singleTap)
        collection.addGestureRecognizer(doubleTap)
        collection.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.Reader.mainMenuTitle) { [weak self] _ in
                guard self?.canInteract() == true else { return false }
                onMenu()
                return true
            }
        ]
    }

    func setZoomEnabled(_ enabled: Bool) { doubleTap.isEnabled = enabled }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var target = touch.view
        while let view = target {
            if view is UIControl { return false }
            target = view.superview
        }
        return canInteract()
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard canInteract(), let view = gesture.view else { return }
        onTap(gesture.location(in: view))
    }

    @objc private func zoomed(_ gesture: UITapGestureRecognizer) {
        guard canInteract(), let view = gesture.view else { return }
        onZoom(gesture.location(in: view))
    }
}
