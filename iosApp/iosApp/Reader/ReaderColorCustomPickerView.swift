import UIKit

/// Legado 5f5d314, colorpicker 1.1.0 TYPE_CUSTOM, without the alpha slider or dialog chrome.
final class ReaderColorCustomPickerView: UIView {
    private(set) var color: UIColor = .black
    var onColorChange: ((UIColor) -> Void)?

    private let saturationValueControl = ReaderColorCustomPickerSaturationValueControl()
    private let hueControl = ReaderColorCustomPickerHueControl()
    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var brightness: CGFloat = 0
    private var colorAlpha: CGFloat = 1

    init(color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isAccessibilityElement = false
        accessibilityIdentifier = "reader.colorPicker.custom"
        shouldGroupAccessibilityChildren = true
        addSubview(saturationValueControl)
        addSubview(hueControl)
        accessibilityElements = [saturationValueControl, hueControl]

        saturationValueControl.onSelection = { [weak self] saturation, brightness in
            guard let self else { return }
            self.saturation = saturation
            self.brightness = brightness
            self.publishSelection()
        }
        hueControl.onSelection = { [weak self] hue in
            guard let self else { return }
            self.hue = hue
            self.publishSelection()
        }
        setColor(color)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(color:)")
    }

    /// External assignments never emit onColorChange. Non-component pattern colors are ignored.
    func setColor(_ color: UIColor) {
        let resolved = color.resolvedColor(with: traitCollection)
        guard let components = Self.components(of: resolved) else { return }
        // External RGB assignments follow ColorPickerView.setColor, including achromatic resets.
        hue = components.hue
        saturation = components.saturation
        brightness = components.brightness
        colorAlpha = components.alpha
        self.color = resolved
        refreshControls()
    }

    override var intrinsicContentSize: CGSize { ReaderColorCustomPickerGeometry.preferredSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        ReaderColorCustomPickerGeometry.sizeThatFits(size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let geometry = ReaderColorCustomPickerGeometry(bounds: bounds, displayScale: traitCollection.displayScale)
        layout(saturationValueControl, panelFrame: geometry.saturationValueFrame, geometry: geometry)
        layout(hueControl, panelFrame: geometry.hueFrame, geometry: geometry)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // Padding, the inter-panel gap and tracker overhangs remain available to the host scroll view.
        return hit === self ? nil : hit
    }

    private func layout(
        _ control: ReaderColorCustomPickerTrackingControl, panelFrame: CGRect, geometry: ReaderColorCustomPickerGeometry
    ) {
        control.isHidden = panelFrame.isEmpty
        guard !panelFrame.isEmpty else {
            control.frame = .zero
            return
        }
        let outset = geometry.trackerOutset
        control.frame = panelFrame.insetBy(dx: -outset, dy: -outset)
        let border = geometry.borderWidth
        let localPanel = CGRect(
            x: outset + border, y: outset + border,
            width: panelFrame.width - border * 2, height: panelFrame.height - border * 2)
        control.configureGeometry(panelRect: localPanel, borderWidth: border, metricScale: geometry.metricScale)
    }

    private func publishSelection() {
        color = UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: colorAlpha)
        refreshControls()
        onColorChange?(color)
    }

    private func refreshControls() {
        saturationValueControl.setSelection(hue: hue, saturation: saturation, brightness: brightness)
        hueControl.setSelection(hue: hue)
    }

    private static func components(of color: UIColor) -> (hue: CGFloat, saturation: CGFloat, brightness: CGFloat, alpha: CGFloat)? {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 1
        if !color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            var white: CGFloat = 0
            guard color.getWhite(&white, alpha: &alpha) else { return nil }
            brightness = white
        }
        guard hue.isFinite, saturation.isFinite, brightness.isFinite, alpha.isFinite else { return nil }
        return (
            ReaderColorCustomPickerGeometry.unit(hue), ReaderColorCustomPickerGeometry.unit(saturation),
            ReaderColorCustomPickerGeometry.unit(brightness), ReaderColorCustomPickerGeometry.unit(alpha)
        )
    }
}
