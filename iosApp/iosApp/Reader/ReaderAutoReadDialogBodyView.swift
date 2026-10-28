import UIKit

final class ReaderAutoReadDialogBodyView: UIView {
  enum Command {
    case chapterList
    case mainMenu
    case stop
    case settings
  }

  var onCommand: ((Command) -> Void)?
  var onSpeedSelected: ((Int) -> Void)?

  // AutoReadDialog uses ThemeStore.bottomBackground, not ReadMenu.immersiveMenu.
  // ThemeConfig.applyTheme defaults: grey 200 by day, grey 850 by night.
  static let panelBackgroundColor = UIColor { traits in
    UIColor(white: traits.userInterfaceStyle == .dark ? 48.0 / 255.0 : 238.0 / 255.0, alpha: 1)
  }

  private static let textColor = UIColor { traits in
    traits.userInterfaceStyle == .dark ? .white : .black.withAlphaComponent(222.0 / 255.0)
  }

  private static let accentColor = UIColor { traits in
    traits.userInterfaceStyle == .dark
      ? UIColor(red: 216.0 / 255.0, green: 67.0 / 255.0, blue: 21.0 / 255.0, alpha: 1)
      : UIColor(red: 229.0 / 255.0, green: 57.0 / 255.0, blue: 53.0 / 255.0, alpha: 1)
  }

  private let speedTitleLabel = UILabel()
  private let speedValueLabel = UILabel()
  private let speedSlider = ReaderAutoReadSpeedSlider()
  private var actionButtons: [ReaderAutoReadActionControl] = []
  private var committedSpeed: Int
  private var deferredExternalSpeed: Int?

  var initialAccessibilityElement: UIView { speedSlider }

  init(currentSpeed: Int) {
    committedSpeed = min(max(currentSpeed, 1), 120)
    super.init(frame: .zero)
    configureViews()
    updateFonts(compatibleWith: traitCollection)
    applySpeed(committedSpeed)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    preconditionFailure("init(coder:) is unavailable")
  }

  override func sizeThatFits(_ size: CGSize) -> CGSize {
    CGSize(width: size.width, height: layoutContent(width: size.width, applyFrames: false))
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    _ = layoutContent(width: bounds.width, applyFrames: true)
  }

  func updateFonts(compatibleWith traits: UITraitCollection) {
    let speedFont = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
      for: .systemFont(ofSize: 14), compatibleWith: traits)
    speedTitleLabel.font = speedFont
    speedValueLabel.font = speedFont
    let actionFont = UIFontMetrics(forTextStyle: .caption1).scaledFont(
      for: .systemFont(ofSize: 12), compatibleWith: traits)
    for button in actionButtons { button.configure(font: actionFont, textColor: Self.textColor) }
    speedSlider.configureAppearance(accent: Self.accentColor.resolvedColor(with: traits))
    setNeedsLayout()
  }

  func setInteractionEnabled(_ enabled: Bool) {
    speedSlider.isEnabled = enabled
    for button in actionButtons { button.isEnabled = enabled }
  }

  func updateSpeed(_ speed: Int) {
    let normalized = min(max(speed, 1), 120)
    if speedSlider.isTouchSessionActive {
      deferredExternalSpeed = normalized
      return
    }
    deferredExternalSpeed = nil
    applySpeed(normalized)
  }

  private func configureViews() {
    for label in [speedTitleLabel, speedValueLabel] {
      label.textColor = Self.textColor
      label.numberOfLines = 0
      label.adjustsFontForContentSizeCategory = true
      label.isAccessibilityElement = false
      addSubview(label)
    }
    speedTitleLabel.text = L10n.ReaderAppearance.autoReadSpeedTitle
    speedTitleLabel.textAlignment = .natural
    speedTitleLabel.lineBreakMode = .byWordWrapping
    speedValueLabel.textAlignment = .right
    speedValueLabel.lineBreakMode = .byCharWrapping
    speedValueLabel.accessibilityIdentifier = "reader.autoRead.speedValue"

    speedSlider.minimumValue = 1
    speedSlider.maximumValue = 120
    speedSlider.isContinuous = true
    speedSlider.minimumTrackTintColor = Self.accentColor
    speedSlider.thumbTintColor = Self.accentColor
    speedSlider.maximumTrackTintColor = UIColor { traits in
      traits.userInterfaceStyle == .dark
        ? UIColor.white.withAlphaComponent(77.0 / 255.0)
        : UIColor.black.withAlphaComponent(67.0 / 255.0)
    }
    speedSlider.accessibilityLabel = L10n.ReaderAppearance.autoReadSpeedTitle
    speedSlider.accessibilityIdentifier = "reader.autoRead.speed"
    speedSlider.addTarget(self, action: #selector(speedChanged), for: .valueChanged)
    speedSlider.onInteractionEnded = { [weak self] in self?.commitSpeed() }
    addSubview(speedSlider)

    let actions: [(Command, String, UIImage?, String)] = [
      (.chapterList, L10n.Reader.menuToc, ReaderMenuAndroidIcon.toc.image(), "chapterList"),
      (
        .mainMenu, L10n.Reader.mainMenuTitle,
        UIImage(named: "ReaderFindAndroidMenu")?.withRenderingMode(.alwaysTemplate), "mainMenu"
      ),
      (.stop, L10n.Reader.readAloudStopShort, ReaderMenuAndroidIcon.autoPageStop.image(), "stop"),
      (.settings, L10n.Reader.menuSettings, ReaderMenuAndroidIcon.settings.image(), "settings"),
    ]
    for (command, title, image, identifier) in actions {
      let button = ReaderAutoReadActionControl(title: title, image: image)
      button.accessibilityIdentifier = "reader.autoRead.\(identifier)"
      button.addAction(UIAction { [weak self] _ in self?.onCommand?(command) }, for: .touchUpInside)
      actionButtons.append(button)
      addSubview(button)
    }
    accessibilityElements = [speedSlider as Any] + actionButtons.map { $0 as Any }
  }

  @objc private func speedChanged() {
    let speed = min(max(Int(speedSlider.value.rounded()), 1), 120)
    speedSlider.value = Float(speed)
    updateSpeedLabel(speed)
  }

  private func commitSpeed() {
    let selected = min(max(Int(speedSlider.value.rounded()), 1), 120)
    if selected != committedSpeed {
      committedSpeed = selected
      onSpeedSelected?(selected)
    }
    // A synchronous save-failure updateSpeed already clears this pending
    // value, so an older external update cannot overwrite that rollback.
    if let deferredExternalSpeed {
      self.deferredExternalSpeed = nil
      applySpeed(deferredExternalSpeed)
    }
  }

  private func applySpeed(_ speed: Int) {
    committedSpeed = speed
    speedSlider.value = Float(speed)
    updateSpeedLabel(speed)
  }

  private func updateSpeedLabel(_ speed: Int) {
    // AutoReadDialog formats Locale.ROOT "%ds", without a space.
    let text = "\(speed)s"
    speedValueLabel.text = text
    speedSlider.accessibilityValue = text
  }

  private func layoutContent(width: CGFloat, applyFrames: Bool) -> CGFloat {
    let horizontalPadding = min(16, max(0, (width - 1) / 2))
    let contentWidth = max(1, width - horizontalPadding * 2)
    let headerPadding = min(8, max(0, (contentWidth - 1) / 2))
    let headerWidth = max(1, contentWidth - headerPadding * 2)
    let headerX = horizontalPadding + headerPadding
    let font = speedValueLabel.font ?? .systemFont(ofSize: 14)
    // Reserve the maximum value so dragging never changes the panel height.
    let valueWidth = ceil(("120s" as NSString).size(withAttributes: [.font: font]).width)
    let titleWidth = ceil(
      speedTitleLabel.sizeThatFits(
        CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      ).width)
    var y: CGFloat = 6 + 8
    if titleWidth + valueWidth + 8 <= headerWidth {
      let titleSize = speedTitleLabel.sizeThatFits(
        CGSize(width: headerWidth - valueWidth - 8, height: CGFloat.greatestFiniteMagnitude))
      let valueSize = speedValueLabel.sizeThatFits(
        CGSize(width: valueWidth, height: CGFloat.greatestFiniteMagnitude))
      let height = ceil(max(titleSize.height, valueSize.height))
      if applyFrames {
        speedTitleLabel.frame = CGRect(
          x: headerX, y: y, width: headerWidth - valueWidth - 8, height: height)
        speedValueLabel.frame = CGRect(
          x: headerX + headerWidth - valueWidth, y: y, width: valueWidth, height: height)
      }
      y += height
    } else {
      let titleHeight = ceil(
        speedTitleLabel.sizeThatFits(
          CGSize(width: headerWidth, height: CGFloat.greatestFiniteMagnitude)
        ).height)
      let paragraph = NSMutableParagraphStyle()
      paragraph.lineBreakMode = .byCharWrapping
      let valueHeight = ceil(
        ("120s" as NSString).boundingRect(
          with: CGSize(width: headerWidth, height: CGFloat.greatestFiniteMagnitude),
          options: [.usesLineFragmentOrigin, .usesFontLeading],
          attributes: [.font: font, .paragraphStyle: paragraph], context: nil
        ).height)
      if applyFrames {
        speedTitleLabel.frame = CGRect(x: headerX, y: y, width: headerWidth, height: titleHeight)
        speedValueLabel.frame = CGRect(
          x: headerX, y: y + titleHeight + 4, width: headerWidth, height: valueHeight)
      }
      y += titleHeight + 4 + valueHeight
    }
    y += 8

    let sliderMargin = min(15, max(0, (contentWidth - 1) / 2))
    if applyFrames {
      speedSlider.frame = CGRect(
        x: horizontalPadding + sliderMargin, y: y,
        width: max(1, contentWidth - sliderMargin * 2), height: 18)
    }
    y += 18 + 8

    let preferredButtonWidth = actionButtons.map(\.preferredWidth).max() ?? 50
    let buttonWidth = min(contentWidth, preferredButtonWidth)
    let columns = min(4, max(1, Int(contentWidth / buttonWidth)))
    let rows = (actionButtons.count + columns - 1) / columns
    let rowHeight = actionButtons.map { $0.preferredHeight(for: buttonWidth) }.max() ?? 50
    let gap =
      columns > 1 ? max(0, contentWidth - CGFloat(columns) * buttonWidth) / CGFloat(columns - 1) : 0
    if applyFrames {
      let isRTL = effectiveUserInterfaceLayoutDirection == .rightToLeft
      for (index, button) in actionButtons.enumerated() {
        let leading = CGFloat(index % columns) * (buttonWidth + gap)
        button.frame = CGRect(
          x: horizontalPadding + (isRTL ? contentWidth - leading - buttonWidth : leading),
          y: y + CGFloat(index / columns) * (rowHeight + 8), width: buttonWidth, height: rowHeight)
      }
    }
    return ceil(y + CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * 8 + 6)
  }
}

private final class ReaderAutoReadSpeedSlider: UISlider {
  var onInteractionEnded: (() -> Void)?
  private(set) var isTouchSessionActive = false

  func configureAppearance(accent: UIColor) {
    // Android's Material SeekBar has an 18dp drawable with a 12dp circle.
    // Explicit images also avoid iOS 26's oversized system thumb.
    let appearances: [(UIControl.State, CGFloat)] = [
      (.normal, 12), (.highlighted, 14), (.disabled, 8),
    ]
    for (state, diameter) in appearances {
      let image = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { _ in
        let inset = (18 - diameter) / 2
        UIImage(systemName: "circle.fill")?.withTintColor(accent, renderingMode: .alwaysOriginal)
          .draw(in: CGRect(x: inset, y: inset, width: diameter, height: diameter))
      }
      setThumbImage(image, for: state)
    }
  }

  override func trackRect(forBounds bounds: CGRect) -> CGRect {
    let inset = min(16, max(0, (bounds.width - 1) / 2))
    return CGRect(
      x: bounds.minX + inset, y: bounds.midY - 1, width: max(1, bounds.width - inset * 2), height: 2
    )
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    bounds.insetBy(dx: 0, dy: -max(0, (44 - bounds.height) / 2)).contains(point)
  }

  override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
    let accepted = super.beginTracking(touch, with: event)
    isTouchSessionActive = accepted
    return accepted
  }

  override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
    super.endTracking(touch, with: event)
    finishTouchSession()
  }

  override func cancelTracking(with event: UIEvent?) {
    super.cancelTracking(with: event)
    finishTouchSession()
  }

  override func accessibilityIncrement() { step(by: 1) }
  override func accessibilityDecrement() { step(by: -1) }

  private func finishTouchSession() {
    guard isTouchSessionActive else { return }
    isTouchSessionActive = false
    onInteractionEnded?()
  }

  private func step(by delta: Float) {
    guard isEnabled, !isTouchSessionActive else { return }
    let next = min(max(value.rounded() + delta, minimumValue), maximumValue)
    guard next != value else { return }
    value = next
    sendActions(for: .valueChanged)
    onInteractionEnded?()
  }
}

private final class ReaderAutoReadActionControl: UIControl {
  private let imageView = UIImageView()
  private let label = UILabel()

  var preferredWidth: CGFloat {
    max(
      50,
      ceil(
        label.sizeThatFits(
          CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        ).width))
  }

  init(title: String, image: UIImage?) {
    super.init(frame: .zero)
    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityTraits = .button
    imageView.image = image
    imageView.contentMode = .scaleAspectFit
    imageView.isAccessibilityElement = false
    imageView.isUserInteractionEnabled = false
    label.text = title
    label.textAlignment = .center
    label.numberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    label.adjustsFontForContentSizeCategory = true
    label.isAccessibilityElement = false
    label.isUserInteractionEnabled = false
    addSubview(imageView)
    addSubview(label)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    preconditionFailure("init(coder:) is unavailable")
  }

  override var isHighlighted: Bool {
    didSet {
      backgroundColor =
        isHighlighted
        ? UIColor { traits in
          (traits.userInterfaceStyle == .dark ? UIColor.white : UIColor.black).withAlphaComponent(
            0.12)
        } : .clear
    }
  }

  func configure(font: UIFont, textColor: UIColor) {
    label.font = font
    label.textColor = textColor
    imageView.tintColor = textColor
    setNeedsLayout()
  }

  func preferredHeight(for width: CGFloat) -> CGFloat {
    let textHeight = ceil(
      label.sizeThatFits(
        CGSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
      ).height)
    return max(50, 24 + 3 + textHeight + 7)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let textHeight = ceil(
      label.sizeThatFits(
        CGSize(width: max(1, bounds.width), height: CGFloat.greatestFiniteMagnitude)
      ).height)
    let labelY = bounds.height - 7 - textHeight
    label.frame = CGRect(x: 0, y: labelY, width: bounds.width, height: textHeight)
    let iconSize = min(24, bounds.width)
    imageView.frame = CGRect(
      x: (bounds.width - iconSize) / 2, y: max(0, (labelY - 3 - iconSize) / 2),
      width: iconSize, height: iconSize)
  }

  override func accessibilityActivate() -> Bool {
    guard isEnabled else { return false }
    sendActions(for: .touchUpInside)
    return true
  }
}
