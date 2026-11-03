import UIKit

@MainActor
final class RssFavoriteTabs: UIScrollView {
    var onSelect: ((RssFavoriteGroup) -> Void)?
    private let stack = UIStackView()
    private var displayed: [RssFavoriteGroup] = []
    private var displayGeneration = UUID()
    private var selected: RssFavoriteGroup?
    private var revealSelection = false
    private var previousSize: CGSize = .zero
    private var displayedContentSizeCategory: UIContentSizeCategory?
    private var displayedLayoutDirection: UITraitEnvironmentLayoutDirection?
    private lazy var preferredHeight = heightAnchor.constraint(equalToConstant: 48)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AndroidReplicaTheme.background
        showsHorizontalScrollIndicator = false
        accessibilityIdentifier = "rss.favorites.tabs"
        stack.axis = .horizontal
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
            preferredHeight, stack.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func display(groups: [RssFavoriteGroup], selected: RssFavoriteGroup?) {
        isHidden = groups.count < 2
        let category = traitCollection.preferredContentSizeCategory
        let direction = traitCollection.layoutDirection
        guard
            groups != displayed || selected != self.selected
                || category != displayedContentSizeCategory || direction != displayedLayoutDirection
        else { return }
        displayGeneration = UUID()
        let generation = displayGeneration
        displayed = groups
        self.selected = selected
        displayedContentSizeCategory = category
        displayedLayoutDirection = direction
        revealSelection = true
        let font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .systemFont(ofSize: 14, weight: .medium), compatibleWith: traitCollection)
        var requiredHeight = max(48, ceil(font.lineHeight) + 24)
        for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() }
        for group in groups {
            let button = UIButton(type: .system)
            button.setTitle(group.label, for: .normal)
            button.titleLabel?.font = font
            button.titleLabel?.adjustsFontForContentSizeCategory = true
            button.titleLabel?.numberOfLines = 0
            button.titleLabel?.lineBreakMode = .byWordWrapping
            button.titleLabel?.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.contentEdgeInsets = UIEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            let titleSize = (group.label as NSString).boundingRect(
                with: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil
            ).size
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: max(72, ceil(titleSize.width) + 40))
                .isActive = true
            requiredHeight = max(requiredHeight, ceil(titleSize.height) + 24)
            button.accessibilityLabel = group.label
            button.accessibilityTraits = group == selected ? [.button, .selected] : [.button]
            button.setTitleColor(
                group == selected ? AndroidReplicaTheme.accent : AndroidReplicaTheme.primaryText, for: .normal)
            button.addInteraction(UIToolTipInteraction(defaultToolTip: group.label))
            button.addAction(
                UIAction { [weak self, weak button, weak stack = self.stack] _ in
                    guard let self, let button, let stack,
                        self.displayGeneration == generation,
                        self.stack === stack, stack.superview === self,
                        button.superview === stack,
                        stack.arrangedSubviews.contains(where: { $0 === button })
                    else { return }
                    self.onSelect?(group)
                }, for: .touchUpInside)
            if group == selected {
                let indicator = UIView()
                indicator.backgroundColor = AndroidReplicaTheme.accent
                indicator.isUserInteractionEnabled = false
                indicator.translatesAutoresizingMaskIntoConstraints = false
                button.addSubview(indicator)
                NSLayoutConstraint.activate([
                    indicator.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    indicator.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    indicator.bottomAnchor.constraint(equalTo: button.bottomAnchor),
                    indicator.heightAnchor.constraint(equalToConstant: 2),
                ])
            }
            stack.addArrangedSubview(button)
        }
        preferredHeight.constant = requiredHeight
        setNeedsLayout()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        display(groups: displayed, selected: selected)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard !isHidden, bounds.width > 0, revealSelection || previousSize != bounds.size else { return }
        revealSelection = false
        previousSize = bounds.size
        stack.layoutIfNeeded()
        if let index = displayed.firstIndex(where: { $0 == selected }) {
            let button = stack.arrangedSubviews[index]
            var rect = button.convert(button.bounds, to: self)
            let width = min(rect.width, bounds.width)
            if effectiveUserInterfaceLayoutDirection == .rightToLeft { rect.origin.x = rect.maxX - width }
            rect.size.width = width
            scrollRectToVisible(rect, animated: false)
        }
    }
}
