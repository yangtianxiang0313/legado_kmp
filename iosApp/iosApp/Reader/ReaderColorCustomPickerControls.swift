// Drawing adapted from ColorPickerView.java, com.jaredrummler:colorpicker:1.1.0.
// Copyright (C) 2017 Jared Rummler
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software distributed
// under the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

import UIKit

class ReaderColorCustomPickerTrackingControl: UIControl {
    private(set) var panelRect: CGRect = .zero
    private(set) var borderWidth: CGFloat = 0
    private(set) var metricScale: CGFloat = 1
    var onTrackLocation: ((CGPoint) -> Void)?

    private weak var trackingTouch: UITouch?
    private var lastTrackedPoint: CGPoint?

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(frame:)")
    }

    func configureGeometry(panelRect: CGRect, borderWidth: CGFloat, metricScale: CGFloat) {
        self.panelRect = panelRect
        self.borderWidth = borderWidth
        self.metricScale = metricScale
        setNeedsDisplay()
        setNeedsLayout()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        isEnabled && !panelRect.isEmpty && panelRect.contains(point)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard trackingTouch == nil, point(inside: touch.location(in: self), with: event) else { return false }
        // No scroll disabling, ancestor recognizer dependencies or simultaneous-recognition overrides.
        // A start inside this panel owns only this control's tracking; UIKit may still cancel it.
        trackingTouch = touch
        lastTrackedPoint = nil
        track(touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard isEnabled, trackingTouch === touch else { return false }
        track(touch)
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if isEnabled, let touch, trackingTouch === touch { track(touch) }
        finishTracking()
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        finishTracking()
        super.cancelTracking(with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishTracking() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsDisplay()
    }

    func drawBorder(in context: CGContext) {
        // ColorPickerView.applyThemeColors uses textColorSecondary for both border and Hue tracker.
        context.setFillColor(UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor)
        context.fill(panelRect.insetBy(dx: -borderWidth, dy: -borderWidth))
    }

    private func track(_ touch: UITouch) {
        guard let point = ReaderColorCustomPickerGeometry.clamped(touch.location(in: self), to: panelRect),
            point != lastTrackedPoint
        else { return }
        lastTrackedPoint = point
        // The initial down also emits, including a tap at the already selected position.
        onTrackLocation?(point)
        sendActions(for: .valueChanged)
    }

    private func finishTracking() {
        trackingTouch = nil
        lastTrackedPoint = nil
    }
}

final class ReaderColorCustomPickerSaturationValueControl: ReaderColorCustomPickerTrackingControl {
    var onSelection: ((CGFloat, CGFloat) -> Void)?

    private var hue: CGFloat = 0
    private var saturation: CGFloat = 0
    private var brightness: CGFloat = 0
    private var saturationGradient: CGGradient?
    private var saturationElement: ReaderColorCustomPickerAxisElement!
    private var brightnessElement: ReaderColorCustomPickerAxisElement!

    private static let valueGradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [UIColor.black.withAlphaComponent(0).cgColor, UIColor.black.cgColor] as CFArray,
        locations: [0, 1])

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isAccessibilityElement = false
        accessibilityIdentifier = "reader.colorPicker.saturationValue"
        shouldGroupAccessibilityChildren = true
        saturationElement = ReaderColorCustomPickerAxisElement(accessibilityContainer: self)
        saturationElement.accessibilityIdentifier = "reader.colorPicker.saturationValue.saturation"
        saturationElement.accessibilityLabel = "\u{9971}\u{548C}\u{5EA6}"
        saturationElement.onAdjust = { [weak self] direction in self?.adjustSaturation(by: direction) }
        brightnessElement = ReaderColorCustomPickerAxisElement(accessibilityContainer: self)
        brightnessElement.accessibilityIdentifier = "reader.colorPicker.saturationValue.value"
        brightnessElement.accessibilityLabel = "\u{660E}\u{5EA6}"
        brightnessElement.onAdjust = { [weak self] direction in self?.adjustBrightness(by: direction) }
        accessibilityElements = [saturationElement!, brightnessElement!]
        onTrackLocation = { [weak self] point in self?.select(at: point) }
        setSelection(hue: 0, saturation: 0, brightness: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(frame:)")
    }

    func setSelection(hue: CGFloat, saturation: CGFloat, brightness: CGFloat) {
        if self.hue != hue || saturationGradient == nil {
            self.hue = hue
            saturationGradient = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: [UIColor.white.cgColor, UIColor(hue: hue, saturation: 1, brightness: 1, alpha: 1).cgColor] as CFArray,
                locations: [0, 1])
        }
        self.saturation = saturation
        self.brightness = brightness
        saturationElement.accessibilityValue = "\(Int((saturation * 100).rounded()))%"
        brightnessElement.accessibilityValue = "\(Int((brightness * 100).rounded()))%"
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Separate focus areas expose both axes without adding visible labels or extra controls.
        saturationElement.accessibilityFrameInContainerSpace = CGRect(
            x: panelRect.minX, y: panelRect.minY, width: panelRect.width / 2, height: panelRect.height)
        brightnessElement.accessibilityFrameInContainerSpace = CGRect(
            x: panelRect.midX, y: panelRect.minY, width: panelRect.width / 2, height: panelRect.height)
    }

    override func draw(_ rect: CGRect) {
        guard !panelRect.isEmpty, let context = UIGraphicsGetCurrentContext(),
            let saturationGradient, let valueGradient = Self.valueGradient
        else { return }
        drawBorder(in: context)
        context.saveGState()
        context.clip(to: panelRect)
        context.drawLinearGradient(
            saturationGradient, start: CGPoint(x: panelRect.minX, y: panelRect.minY),
            end: CGPoint(x: panelRect.maxX, y: panelRect.minY), options: [])
        context.drawLinearGradient(
            valueGradient, start: CGPoint(x: panelRect.minX, y: panelRect.minY),
            end: CGPoint(x: panelRect.minX, y: panelRect.maxY), options: [])
        context.restoreGState()

        let center = CGPoint(x: panelRect.minX + saturation * panelRect.width, y: panelRect.minY + (1 - brightness) * panelRect.height)
        context.setLineWidth(2 * metricScale)
        context.setStrokeColor(UIColor.black.cgColor)
        strokeCircle(center: center, radius: 4 * metricScale, in: context)
        context.setStrokeColor(UIColor(white: 221.0 / 255, alpha: 1).cgColor)
        strokeCircle(center: center, radius: 5 * metricScale, in: context)
    }

    private func strokeCircle(center: CGPoint, radius: CGFloat, in context: CGContext) {
        context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private func select(at point: CGPoint) {
        let saturation = ReaderColorCustomPickerGeometry.unit((point.x - panelRect.minX) / panelRect.width)
        let brightness = 1 - ReaderColorCustomPickerGeometry.unit((point.y - panelRect.minY) / panelRect.height)
        onSelection?(saturation, brightness)
    }

    private func adjustSaturation(by direction: CGFloat) {
        guard isEnabled, isUserInteractionEnabled, !isHidden else { return }
        let newValue = ReaderColorCustomPickerGeometry.unit(saturation + direction * 0.01)
        guard newValue != saturation else { return }
        onSelection?(newValue, brightness)
        sendActions(for: .valueChanged)
    }

    private func adjustBrightness(by direction: CGFloat) {
        guard isEnabled, isUserInteractionEnabled, !isHidden else { return }
        let newValue = ReaderColorCustomPickerGeometry.unit(brightness + direction * 0.01)
        guard newValue != brightness else { return }
        onSelection?(saturation, newValue)
        sendActions(for: .valueChanged)
    }
}

final class ReaderColorCustomPickerHueControl: ReaderColorCustomPickerTrackingControl {
    var onSelection: ((CGFloat) -> Void)?
    private var hue: CGFloat = 0

    private static let hueGradient: CGGradient? = {
        let colors = (0...6).map { index in
            UIColor(hue: 1 - CGFloat(index) / 6, saturation: 1, brightness: 1, alpha: 1).cgColor
        }
        return CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
            locations: (0...6).map { CGFloat($0) / 6 })
    }()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isAccessibilityElement = true
        accessibilityIdentifier = "reader.colorPicker.hue"
        accessibilityLabel = "\u{8272}\u{76F8}"
        accessibilityTraits = .adjustable
        onTrackLocation = { [weak self] point in
            guard let self else { return }
            let hue = 1 - ReaderColorCustomPickerGeometry.unit((point.y - self.panelRect.minY) / self.panelRect.height)
            self.onSelection?(hue)
        }
        setSelection(hue: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        preconditionFailure("Use init(frame:)")
    }

    func setSelection(hue: CGFloat) {
        self.hue = hue
        accessibilityValue = "\(Int((hue * 360).rounded()))\u{00B0}"
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard !panelRect.isEmpty, let context = UIGraphicsGetCurrentContext(), let gradient = Self.hueGradient else { return }
        drawBorder(in: context)
        context.saveGState()
        context.clip(to: panelRect)
        context.drawLinearGradient(
            gradient, start: CGPoint(x: panelRect.minX, y: panelRect.minY),
            end: CGPoint(x: panelRect.minX, y: panelRect.maxY), options: [])
        context.restoreGState()

        let tracker = CGRect(
            x: panelRect.minX - 2 * metricScale, y: panelRect.minY + (1 - hue) * panelRect.height - 2 * metricScale,
            width: panelRect.width + 4 * metricScale, height: 4 * metricScale)
        context.setLineWidth(2 * metricScale)
        context.setStrokeColor(UIColor.secondaryLabel.resolvedColor(with: traitCollection).cgColor)
        context.addPath(UIBezierPath(roundedRect: tracker, cornerRadius: 2 * borderWidth).cgPath)
        context.strokePath()
    }

    override func accessibilityIncrement() { adjust(by: 1) }

    override func accessibilityDecrement() { adjust(by: -1) }

    private func adjust(by direction: CGFloat) {
        guard isEnabled, isUserInteractionEnabled, !isHidden else { return }
        let newValue = ReaderColorCustomPickerGeometry.unit(hue + direction / 360)
        guard newValue != hue else { return }
        onSelection?(newValue)
        sendActions(for: .valueChanged)
    }
}

private final class ReaderColorCustomPickerAxisElement: UIAccessibilityElement {
    var onAdjust: ((CGFloat) -> Void)?

    override init(accessibilityContainer container: Any) {
        super.init(accessibilityContainer: container)
        accessibilityTraits = .adjustable
    }

    override func accessibilityIncrement() { onAdjust?(1) }

    override func accessibilityDecrement() { onAdjust?(-1) }
}
