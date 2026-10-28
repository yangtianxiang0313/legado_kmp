import UIKit
import shared

/// ReadStyleDialog's horizontal scheme list; its presenter owns all persistence.
final class ReaderStylePresetStripView: UIView {
    var onSelect: ((Int) -> Void)?
    var onEdit: ((Int) -> Void)?
    var onAdd: (() -> Void)?

    private let scrollView = ReaderStylePresetScrollView()
    private let stackView = UIStackView()
    private let addButton = UIButton(type: .custom)
    private let addCircleView = UIView()
    private var chips: [ReaderStylePresetChip] = []
    private var presetNames: [String] = []

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.isDirectionalLockEnabled = true
        scrollView.bounces = false
        scrollView.accessibilityIdentifier = UIIdentifiers.ReaderAppearance.presetScroll
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        // item_read_style has 6dp on each side; rv_style adds 12dp at its edges.
        stackView.spacing = 12
        addSubview(scrollView)
        scrollView.addSubview(stackView)
        configureAddButton()
        stackView.addArrangedSubview(addButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 18),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -18),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        preconditionFailure("init(coder:) is unavailable")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 48)
    }

    func configure(
        presets: [ReaderPreset], selectedName: String, palette: ReaderMenuPalette, isNight: Bool
    ) {
        configure(presets: presets, selectedName: selectedName, palette: palette, variant: isNight ? .night : .day)
    }

    func configure(
        presets: [ReaderPreset], selectedName: String, palette: ReaderMenuPalette, variant: ReaderVisualVariant
    ) {
        configure(presets: presets, selectedIndex: presets.firstIndex { $0.name == selectedName } ?? -1, palette: palette, variant: variant)
    }

    func configure(
        presets: [ReaderPreset], selectedIndex: Int, palette: ReaderMenuPalette, variant: ReaderVisualVariant
    ) {
        let names = presets.map(\.name)
        let listChanged = names != presetNames
        let offset = scrollView.contentOffset
        if listChanged {
            replaceChips(names: names)
        }
        for (index, pair) in zip(chips, presets).enumerated() {
            let (chip, preset) = pair
            chip.configure(
                preset: preset, selected: index == selectedIndex, palette: palette, variant: variant)
        }
        backgroundColor = palette.bottomBackground
        addButton.backgroundColor = palette.bottomBackground
        addButton.tintColor = palette.bodyText
        addCircleView.backgroundColor = palette.bottomBackground
        addCircleView.layer.borderColor = palette.bodyText.resolvedColor(with: traitCollection).cgColor

        // Do not force layout or set the offset during normal updates: this keeps
        // an active drag/deceleration, button touch and VoiceOver element intact.
        if listChanged {
            layoutIfNeeded()
            let maximumOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
            scrollView.setContentOffset(
                CGPoint(x: min(max(0, offset.x), maximumOffset), y: 0), animated: false)
        }
    }

    private func replaceChips(names: [String]) {
        for chip in chips {
            stackView.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        chips = names.enumerated().map { index, _ in
            let chip = ReaderStylePresetChip()
            chip.accessibilityIdentifier = "\(UIIdentifiers.ReaderAppearance.presetButton).\(index)"
            chip.onSelect = { [weak self] _ in self?.onSelect?(index) }
            chip.onEdit = { [weak self] _ in self?.onEdit?(index) }
            stackView.insertArrangedSubview(chip, at: index)
            return chip
        }
        presetNames = names
    }

    private func configureAddButton() {
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.isAccessibilityElement = true
        addButton.accessibilityIdentifier = "\(UIIdentifiers.ReaderAppearance.presetButton).add"
        addButton.accessibilityLabel = "添加配色"
        addButton.accessibilityTraits = .button
        addButton.addAction(UIAction { [weak self] _ in self?.onAdd?() }, for: .touchUpInside)

        // ReadStyleDialog's footer sets 6dp padding on the 48dp CircleImageView.
        // Its image and border therefore use a centered 36dp circle, not the full cell.
        addCircleView.translatesAutoresizingMaskIntoConstraints = false
        addCircleView.layer.cornerRadius = 18
        addCircleView.layer.borderWidth = 1
        addCircleView.clipsToBounds = true
        addCircleView.isUserInteractionEnabled = false
        addCircleView.isAccessibilityElement = false
        addButton.addSubview(addCircleView)

        // Existing unchanged ic_add asset; do not substitute an SF Symbol.
        let icon = UIImageView(image: UIImage(named: "BookshelfAndroidAdd")?.withRenderingMode(.alwaysTemplate))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.contentMode = .scaleAspectFit
        icon.isUserInteractionEnabled = false
        icon.isAccessibilityElement = false
        addCircleView.addSubview(icon)
        NSLayoutConstraint.activate([
            addButton.widthAnchor.constraint(equalToConstant: 48),
            addButton.heightAnchor.constraint(equalToConstant: 48),
            addCircleView.widthAnchor.constraint(equalToConstant: 36),
            addCircleView.heightAnchor.constraint(equalToConstant: 36),
            addCircleView.centerXAnchor.constraint(equalTo: addButton.centerXAnchor),
            addCircleView.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            icon.leadingAnchor.constraint(equalTo: addCircleView.leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: addCircleView.trailingAnchor),
            icon.topAnchor.constraint(equalTo: addCircleView.topAnchor),
            icon.bottomAnchor.constraint(equalTo: addCircleView.bottomAnchor),
        ])
    }
}

private final class ReaderStylePresetScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            if abs(velocity.y) > abs(velocity.x) { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    override func touchesShouldCancel(in view: UIView) -> Bool {
        view is UIControl || super.touchesShouldCancel(in: view)
    }
}
