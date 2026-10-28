import AVFoundation
import SnapKit
import UIKit

final class QRCodeScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let scaffoldView = LegacyRootScaffoldView()
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasProcessedCode = false

    var onQRCodeScanned: ((String) -> Void)?

    private lazy var backButton = makeLegacyBarButton(
        title: nil,
        imageSystemName: "chevron.left",
        target: self,
        action: #selector(handleBack)
    )

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(scaffoldView)
        scaffoldView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        scaffoldView.titleBarView.setTitle(L10n.SourceMgmt.scanQrCodeTitle)
        backButton.accessibilityIdentifier = UIIdentifiers.Common.drillDownBackButton
        scaffoldView.titleBarView.setLeftViews([backButton])

        checkCameraPermissionAndSetup()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        if !captureSession.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.captureSession.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if captureSession.isRunning {
            captureSession.stopRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = scaffoldView.contentView.bounds
    }

    @objc private func handleBack() {
        navigationController?.popViewController(animated: true)
    }

    private func checkCameraPermissionAndSetup() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setupCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.setupCamera()
                    } else {
                        self?.showPermissionDenied()
                    }
                }
            }
        case .denied, .restricted:
            showPermissionDenied()
        @unknown default:
            showPermissionDenied()
        }
    }

    private func setupCamera() {
        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showCameraUnavailable()
            return
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            showCameraUnavailable()
            return
        }

        guard captureSession.canAddInput(videoInput) else {
            showCameraUnavailable()
            return
        }
        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(metadataOutput) else {
            showCameraUnavailable()
            return
        }
        captureSession.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.frame = scaffoldView.contentView.bounds
        preview.videoGravity = .resizeAspectFill
        scaffoldView.contentView.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        addScanOverlay()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }

    private func addScanOverlay() {
        let overlayLabel = UILabel()
        overlayLabel.text = L10n.SourceMgmt.scanQrCodeTitle
        overlayLabel.textColor = .white
        overlayLabel.font = .preferredFont(forTextStyle: .headline)
        overlayLabel.textAlignment = .center
        scaffoldView.contentView.addSubview(overlayLabel)
        overlayLabel.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.bottom.equalToSuperview().inset(80)
        }
    }

    private func showPermissionDenied() {
        let alert = UIAlertController(
            title: L10n.SourceMgmt.cameraPermissionDeniedTitle,
            message: L10n.SourceMgmt.cameraPermissionDeniedMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: L10n.SourceMgmt.openSettings, style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        present(alert, animated: true)
    }

    private func showCameraUnavailable() {
        let alert = UIAlertController(
            title: L10n.SourceMgmt.cameraUnavailableTitle,
            message: L10n.SourceMgmt.cameraUnavailableMessage,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: L10n.Common.ok, style: .default) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }

    // MARK: - AVCaptureMetadataOutputObjectsDelegate

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasProcessedCode else { return }
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              metadataObject.type == .qr,
              let stringValue = metadataObject.stringValue else {
            return
        }

        hasProcessedCode = true
        captureSession.stopRunning()
        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onQRCodeScanned?(stringValue)
    }
}
