import CoreImage
import UIKit

enum BookSourceEditorSharing {
    static func controller(payload: Data, anchor: UIView) -> UIActivityViewController {
        var items: [Any] = [String(decoding: payload, as: UTF8.self)]
        if let image = qrCodeImage(payload: payload) { items.insert(image, at: 0) }
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = anchor
        controller.popoverPresentationController?.sourceRect = anchor.bounds
        return controller
    }

    private static func qrCodeImage(payload: Data) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(payload, forKey: "inputMessage")
        // BookSourceEditActivity.shareWithQr uses ErrorCorrectionLevel.L.
        filter.setValue("L", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let image = CIContext(options: nil).createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
