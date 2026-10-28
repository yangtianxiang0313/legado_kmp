import Photos
import UIKit

final class ImagePreviewViewController: UIViewController, NavigationContentChromeProviding {
    private let image: UIImage
    private let imageURL: URL?
    private let onClose: (() -> Void)?
    private let zoomView: ReaderImageZoomView
    private let closeButton = UIButton(type: .system)
    private var isClosing = false

    init(image: UIImage, imageURL: URL? = nil, onClose: (() -> Void)? = nil) {
        self.image = image
        self.imageURL = imageURL
        self.onClose = onClose
        zoomView = ReaderImageZoomView(image: image)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        modalPresentationCapturesStatusBarAppearance = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard !isClosing, presentedViewController == nil else { return super.keyCommands }
        let escape = UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(closeTapped))
        escape.discoverabilityTitle = "关闭"
        escape.wantsPriorityOverSystemBehavior = true
        return [escape]
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        view.accessibilityIdentifier = "reader.imagePreview.root"
        view.accessibilityViewIsModal = true

        zoomView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(zoomView)

        closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
        closeButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 18, weight: .regular), forImageIn: .normal)
        closeButton.tintColor = AndroidReplicaTheme.primaryText
        closeButton.accessibilityLabel = "关闭"
        closeButton.accessibilityIdentifier = "reader.imagePreview.close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            zoomView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            zoomView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            zoomView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            zoomView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !isClosing, presentedViewController == nil else { return }
        becomeFirstResponder()
        UIAccessibility.post(notification: .screenChanged, argument: closeButton)
    }

    override func accessibilityPerformEscape() -> Bool {
        guard presentedViewController == nil else { return false }
        closeTapped()
        return true
    }

    @objc private func closeTapped() {
        guard !isClosing, presentedViewController == nil else { return }
        isClosing = true
        closeButton.isEnabled = false
        resignFirstResponder()
        if let onClose {
            onClose()
        } else {
            dismiss(animated: true)
        }
    }

    func saveImageToPhotos(completion: @escaping (Bool, Error?) -> Void) {
        let image = self.image
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    completion(false, nil)
                }
                return
            }
            PHPhotoLibrary.shared().performChanges(
                {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                },
                completionHandler: { success, error in
                    DispatchQueue.main.async {
                        completion(success, error)
                    }
                })
        }
    }
}
