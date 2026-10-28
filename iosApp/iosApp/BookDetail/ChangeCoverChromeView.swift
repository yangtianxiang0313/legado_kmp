import SnapKit
import UIKit

/// ChangeCoverDialog's 56pt toolbar and 2pt progress, without UINavigationBar chrome.
final class ChangeCoverChromeView: UIView {
    var onClose: (() -> Void)?
    var onSearchToggle: (() -> Void)?

    private let toolbar = UIView()
    private let loadingBar = ChangeCoverLoadingBar()
    private let titleLabel = ReaderTocSingleLineLabel()
    private let closeButton = UIButton(type: .custom)
    private let searchToggleButton = UIButton(type: .custom)
    private let searchTooltip = UIToolTipInteraction(defaultToolTip: L10n.BookDetail.changeCoverStopSearch)
    private var toolbarHeight: Constraint?

    // ic_stop_black_24dp at 5f5d314: M6,6h12v12H6z in a 24dp viewport.
    private static let stopImage = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
        context.cgContext.setFillColor(UIColor.black.cgColor)
        context.cgContext.fill(CGRect(x: 6, y: 6, width: 12, height: 12))
    }.withRenderingMode(.alwaysTemplate)

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.text = L10n.BookDetail.changeCoverSource
        titleLabel.accessibilityLabel = L10n.BookDetail.changeCoverSource
        titleLabel.textAlignment = .left
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.accessibilityTraits = .header
        titleLabel.accessibilityIdentifier = "changeCover.title"
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // iOS callers include overFullScreen presentation, so retain their explicit dismissal entry.
        closeButton.setImage(ReaderMenuAndroidIcon.clear.image(size: 24), for: .normal)
        closeButton.accessibilityLabel = L10n.Common.cancel
        closeButton.accessibilityIdentifier = "changeCover.close"
        closeButton.addInteraction(UIToolTipInteraction(defaultToolTip: L10n.Common.cancel))
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        searchToggleButton.accessibilityIdentifier = "changeCover.searchToggle"
        searchToggleButton.addInteraction(searchTooltip)
        searchToggleButton.addAction(UIAction { [weak self] _ in self?.onSearchToggle?() }, for: .touchUpInside)

        addSubview(toolbar)
        addSubview(loadingBar)
        toolbar.addSubview(closeButton)
        toolbar.addSubview(titleLabel)
        toolbar.addSubview(searchToggleButton)
        toolbar.snp.makeConstraints {
            $0.top.equalTo(safeAreaLayoutGuide.snp.top)
            $0.leading.trailing.equalToSuperview()
            toolbarHeight = $0.height.equalTo(56).constraint
        }
        closeButton.snp.makeConstraints {
            $0.trailing.equalTo(searchToggleButton.snp.leading)
            $0.top.equalToSuperview()
            $0.width.equalTo(48)
            $0.height.equalTo(56)
        }
        searchToggleButton.snp.makeConstraints {
            $0.trailing.equalTo(toolbar.safeAreaLayoutGuide.snp.trailing)
            $0.top.equalToSuperview()
            $0.width.equalTo(48)
            $0.height.equalTo(56)
        }
        titleLabel.snp.makeConstraints {
            $0.leading.equalTo(toolbar.safeAreaLayoutGuide.snp.leading).offset(16)
            $0.trailing.equalTo(closeButton.snp.leading).offset(-4)
            $0.centerY.equalToSuperview()
            $0.top.greaterThanOrEqualToSuperview().offset(4)
            $0.bottom.lessThanOrEqualToSuperview().inset(4)
        }
        loadingBar.snp.makeConstraints {
            $0.top.equalTo(toolbar.snp.bottom)
            $0.leading.trailing.equalToSuperview()
            $0.bottom.equalToSuperview()
            $0.height.equalTo(2)
        }
        updateTextMetrics()
        setSearching(false)
        applyTheme()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateTextMetrics()
        applyTheme()
    }

    private func updateTextMetrics() {
        // ToolbarTitle: 20sp medium; AppCompat Toolbar has 4dp title margins and a 56dp minimum.
        let font = ReaderAndroidDefaultFont.scaledFont(
            size: 20, textStyle: .headline, weight: 500, compatibleWith: traitCollection)
        titleLabel.font = font
        let padding = AndroidExploreTextMetrics.padding(font: font, scale: traitCollection.displayScale)
        let scale = max(1, traitCollection.displayScale)
        let titleHeight = ceil((font.lineHeight + padding.top + padding.bottom) * scale) / scale
        toolbarHeight?.update(offset: max(56, titleHeight + 8))
    }

    func setStatus(_ text: String) {
        titleLabel.accessibilityValue = text
        searchToggleButton.accessibilityValue = text
    }

    func setSearching(_ searching: Bool) {
        loadingBar.setLoading(searching)
        searchToggleButton.setImage(
            searching ? Self.stopImage : ReaderMenuAndroidIcon.refresh.image(size: 24), for: .normal)
        let label = searching ? L10n.BookDetail.changeCoverStopSearch : L10n.BookDetail.changeCoverRestartSearch
        searchToggleButton.accessibilityLabel = label
        searchTooltip.defaultToolTip = label
    }

    private func applyTheme() {
        backgroundColor = AndroidReplicaTheme.toolbarBackground
        toolbar.backgroundColor = AndroidReplicaTheme.toolbarBackground
        loadingBar.backgroundColor = .clear
        titleLabel.textColor = AndroidReplicaTheme.toolbarText
        closeButton.tintColor = AndroidReplicaTheme.toolbarText
        searchToggleButton.tintColor = AndroidReplicaTheme.toolbarText
    }
}

final class ChangeCoverLoadingBar: UIView {
    private let fillView = UIView()
    private var isLoading = false
    private var secondProgress = 0
    private var direction = 1
    private var displayLink: CADisplayLink?

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        // RefreshProgressBar.secondColor defaults to 0xffc1c1c1, independent of the theme.
        fillView.backgroundColor = UIColor(white: 193.0 / 255.0, alpha: 1)
        fillView.isHidden = true
        addSubview(fillView)
        accessibilityIdentifier = "changeCover.loadingBar"
        isUserInteractionEnabled = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateAnimation), name: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    deinit { displayLink?.invalidate() }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateFillFrame()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateAnimation()
    }

    func setLoading(_ loading: Bool) {
        guard isLoading != loading else { return }
        isLoading = loading
        updateAnimation()
    }

    @objc private func updateAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        fillView.isHidden = !isLoading
        if !isLoading {
            secondProgress = 0
            direction = 1
        }
        updateFillFrame()
        guard isLoading, window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        let target = ChangeCoverLoadingTickTarget(bar: self)
        let link = CADisplayLink(target: target, selector: #selector(ChangeCoverLoadingTickTarget.tick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func advanceFrame() {
        // RefreshProgressBar.onDraw: speed=2, secondMaxProgress=100; no easing or fixed duration.
        if secondProgress >= 100 { direction = -1 } else if secondProgress <= 0 { direction = 1 }
        secondProgress = min(100, max(0, secondProgress + direction * 2))
        updateFillFrame()
    }

    private func updateFillFrame() {
        if UIAccessibility.isReduceMotionEnabled {
            fillView.frame = bounds
            return
        }
        let scale = max(1, traitCollection.displayScale)
        let width = floor(bounds.width * scale)
        let center = floor(width / 2) / scale
        let halfWidth = floor(floor(width * CGFloat(secondProgress) / 100) / 2) / scale
        fillView.frame = CGRect(x: center - halfWidth, y: 0, width: halfWidth * 2, height: bounds.height)
    }
}

@MainActor
private final class ChangeCoverLoadingTickTarget: NSObject {
    private weak var bar: ChangeCoverLoadingBar?

    init(bar: ChangeCoverLoadingBar) { self.bar = bar }

    @objc func tick() { bar?.advanceFrame() }
}

final class ChangeCoverStatusFooterView: UICollectionReusableView {
    static let reuseIdentifier = "ChangeCoverStatusFooterView"
    private let label = AndroidExploreTextLabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = false
        label.accessibilityIdentifier = "changeCover.progressLabel"
        addSubview(label)
        label.snp.makeConstraints { $0.edges.equalToSuperview().inset(12) }
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func configure(text: String?, isError: Bool) {
        label.text = text
        label.textColor = isError ? .systemRed : AndroidReplicaTheme.secondaryText
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateAppearance()
    }

    private func updateAppearance() {
        backgroundColor = AndroidReplicaTheme.bottomBackground
        label.font = ReaderAndroidDefaultFont.scaledFont(
            size: 14, textStyle: .body, compatibleWith: traitCollection)
    }

    static func height(for text: String, width: CGFloat, traits: UITraitCollection = .current) -> CGFloat {
        let label = AndroidExploreTextLabel()
        label.font = ReaderAndroidDefaultFont.scaledFont(size: 14, textStyle: .body, compatibleWith: traits)
        label.numberOfLines = 0
        label.text = text
        return ceil(label.sizeThatFits(CGSize(width: max(1, width - 24), height: .greatestFiniteMagnitude)).height + 24)
    }
}
