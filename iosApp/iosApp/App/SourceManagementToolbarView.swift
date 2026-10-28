import UIKit

/// BookSourceActivity uses the same AppCompat SearchView without a submit action.
final class SourceManagementToolbarView: NavigationToolbarView {
    private let chrome = AndroidSearchToolbarView(
        placeholder: L10n.SourceManagement.searchPlaceholder, showsMoreButton: true)
    let sortButton = SourceManagementToolbarActionButton(type: .custom)
    let groupButton = SourceManagementToolbarActionButton(type: .custom)
    var backButton: UIButton { chrome.backButton }
    var searchField: UITextField { chrome.searchField }
    var moreButton: UIButton { chrome.moreButton }
    var canInteract: (() -> Bool)?
    private var presentationActive = true

    override init(frame: CGRect) {
        super.init(frame: frame)
        chrome.isSubmitButtonEnabled = false
        chrome.searchField.accessibilityIdentifier = UIIdentifiers.SourceManagement.searchField
        chrome.moreButton.accessibilityIdentifier = "sourceManagement.more"
        chrome.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chrome)
        configure(sortButton, image: Self.sortImage, label: "排序", identifier: "sourceManagement.sort")
        configure(
            groupButton, image: UIImage(named: "BookDetailAndroidGroups")?.withRenderingMode(.alwaysTemplate),
            label: "分组", identifier: "sourceManagement.group")
        let actions = UIStackView(arrangedSubviews: [sortButton, groupButton])
        actions.axis = .horizontal
        actions.distribution = .fillEqually
        chrome.setTrailingAccessory(actions, width: 96)
        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: topAnchor),
            chrome.leadingAnchor.constraint(equalTo: leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: trailingAnchor),
            chrome.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        queryChanged()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override var intrinsicContentSize: CGSize { chrome.intrinsicContentSize }

    func updateLayout(availableSize: CGSize) {
        let previousHeight = chrome.intrinsicContentSize.height
        chrome.updateLayout(availableSize: availableSize)
        if previousHeight != chrome.intrinsicContentSize.height { invalidateIntrinsicContentSize() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        invalidateIntrinsicContentSize()
    }

    func setPresentationActive(_ active: Bool) {
        presentationActive = active
        chrome.setPresentationActive(active)
        for button in [sortButton, groupButton] {
            button.isEnabled = active
            if !active {
                button.cancelTracking(with: nil)
                button.isHighlighted = false
            }
        }
    }

    @objc func queryChanged() { chrome.updateQueryControls() }

    private func configure(_ button: SourceManagementToolbarActionButton, image: UIImage?, label: String, identifier: String) {
        button.configuration = nil
        button.backgroundColor = .clear
        button.setImage(image, for: .normal)
        button.imageView?.contentMode = .center
        button.accessibilityLabel = label
        button.accessibilityIdentifier = identifier
        button.addInteraction(UIToolTipInteraction(defaultToolTip: label))
        button.canInteract = { [weak self] in
            guard let self else { return false }
            return self.presentationActive && self.canInteract?() != false
                && self.window?.windowScene?.activationState == .foregroundActive
        }
        // Inherit the accessory stack's tint, which chrome updates with its other icons.
        button.tintColor = nil
    }

    // Original ic_sort.xml from Legado 5f5d314, GPL-3.0. No autoMirrored attribute.
    private static let sortImage: UIImage = {
        let polygons: [[CGPoint]] = [
            [CGPoint(x: 14.94, y: 4.66), CGPoint(x: 10.22, y: 4.66), CGPoint(x: 12.58, y: 2.30)],
            [CGPoint(x: 10.25, y: 19.37), CGPoint(x: 14.91, y: 19.37), CGPoint(x: 12.58, y: 21.70)],
            [
                CGPoint(x: 6.10, y: 6.27), CGPoint(x: 1.60, y: 17.73), CGPoint(x: 3.44, y: 17.73),
                CGPoint(x: 4.36, y: 15.28), CGPoint(x: 9.47, y: 15.28), CGPoint(x: 10.39, y: 17.73),
                CGPoint(x: 12.23, y: 17.73), CGPoint(x: 7.74, y: 6.27),
            ],
            [CGPoint(x: 4.97, y: 13.64), CGPoint(x: 6.91, y: 8.46), CGPoint(x: 8.85, y: 13.64)],
            [
                CGPoint(x: 15.73, y: 16.14), CGPoint(x: 21.85, y: 16.14), CGPoint(x: 21.85, y: 17.73),
                CGPoint(x: 13.32, y: 17.73), CGPoint(x: 13.32, y: 16.44), CGPoint(x: 19.24, y: 7.88),
                CGPoint(x: 13.36, y: 7.88), CGPoint(x: 13.36, y: 6.28), CGPoint(x: 21.66, y: 6.28),
                CGPoint(x: 21.66, y: 7.54),
            ],
        ]
        return UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { renderer in
            renderer.cgContext.setFillColor(UIColor.black.cgColor)
            for polygon in polygons {
                guard let first = polygon.first else { continue }
                renderer.cgContext.move(to: first)
                for point in polygon.dropFirst() { renderer.cgContext.addLine(to: point) }
                renderer.cgContext.closePath()
            }
            renderer.cgContext.fillPath()
        }.withRenderingMode(.alwaysTemplate)
    }()
}

final class SourceManagementToolbarActionButton: UIButton {
    var canInteract: (() -> Bool)?

    override func sendAction(_ action: Selector, to target: Any?, for event: UIEvent?) {
        guard isEnabled, canInteract?() != false else { return }
        super.sendAction(action, to: target, for: event)
    }

    override func sendActions(for controlEvents: UIControl.Event) {
        guard isEnabled, canInteract?() != false else { return }
        super.sendActions(for: controlEvents)
    }

    override func accessibilityActivate() -> Bool {
        guard isEnabled, canInteract?() != false else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}
