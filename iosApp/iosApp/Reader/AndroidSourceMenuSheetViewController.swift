import UIKit

final class AndroidSourceMenuSheetViewController: UIViewController {
    struct Action {
        let title: String
        let systemImage: String
        var detail: String? = nil
        var isEnabled: Bool = true
        let isDestructive: Bool
        let handler: () -> Void
    }

    private let sheetTitle: String
    private let sourceTitle: String
    private let sourceMessage: String
    private let actions: [Action]
    private let scrollView = UIScrollView()
    private let stackView = UIStackView()

    init(sheetTitle: String = L10n.Reader.menuSource, sourceTitle: String, sourceMessage: String, actions: [Action]) {
        self.sheetTitle = sheetTitle
        self.sourceTitle = sourceTitle
        self.sourceMessage = sourceMessage
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 0, height: Self.preferredHeight(actionCount: actions.count))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = sheetTitle
        view.backgroundColor = AndroidReplicaTheme.background
        configureViews()
    }

    private func configureViews() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.delaysContentTouches = false
        stackView.axis = .vertical
        stackView.spacing = 0
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 14),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -14),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -10),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -28),
        ])

        stackView.addArrangedSubview(makeHeader())
        if actions.isEmpty {
            stackView.addArrangedSubview(makeEmptyState())
        } else {
            for (index, action) in actions.enumerated() {
                stackView.addArrangedSubview(makeActionButton(action, showsSeparator: index > 0))
            }
        }
    }

    private func makeHeader() -> UIView {
        let container = UIView()

        let iconView = UIImageView(image: UIImage(systemName: "link"))
        iconView.tintColor = AndroidReplicaTheme.secondaryText.withAlphaComponent(0.82)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        let titleLabel = UILabel()
        let trimmedTitle = sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        titleLabel.text = trimmedTitle.isEmpty ? sheetTitle : sourceTitle
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText
        titleLabel.numberOfLines = 2

        let messageLabel = UILabel()
        let trimmedMessage = sourceMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        messageLabel.text = trimmedMessage.isEmpty ? L10n.Reader.chapterSourceInfoUnavailable : sourceMessage
        messageLabel.font = .preferredFont(forTextStyle: .caption1)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = AndroidReplicaTheme.secondaryText
        messageLabel.numberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingMiddle

        let labels = UIStackView(arrangedSubviews: [titleLabel, messageLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.isAccessibilityElement = false

        let separator = UIView()
        separator.backgroundColor = AndroidReplicaTheme.divider
        separator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(labels)
        container.addSubview(separator)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labels.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            labels.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -10),

            separator.leadingAnchor.constraint(equalTo: labels.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        container.isAccessibilityElement = true
        container.accessibilityLabel = titleLabel.text
        container.accessibilityValue = messageLabel.text
        return container
    }

    private func makeEmptyState() -> UIView {
        let container = UIView()

        let iconView = UIImageView(image: UIImage(systemName: "tray"))
        iconView.tintColor = AndroidReplicaTheme.secondaryText
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = UILabel()
        titleLabel.text = L10n.Reader.sourceMenuEmptyTitle
        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = AndroidReplicaTheme.primaryText

        let detailLabel = UILabel()
        detailLabel.text = L10n.Reader.sourceMenuEmptyMessage
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = AndroidReplicaTheme.secondaryText
        detailLabel.numberOfLines = 0

        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 3
        labels.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(labels)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 13),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            labels.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            labels.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
        return container
    }

    private func makeActionButton(_ action: Action, showsSeparator: Bool) -> UIControl {
        let row = SourceMenuActionRow(action: action, showsSeparator: showsSeparator)
        row.addAction(UIAction { [weak self, weak row] _ in
            row?.isEnabled = false
            self?.dismiss(animated: true) {
                action.handler()
            }
        }, for: .touchUpInside)
        return row
    }

    private static func preferredHeight(actionCount: Int) -> CGFloat {
        let visibleActionCount = max(actionCount, 1)
        let headerHeight: CGFloat = 64
        let rowHeight: CGFloat = 48
        let verticalChrome: CGFloat = 54
        let contentHeight = verticalChrome + headerHeight + CGFloat(visibleActionCount) * rowHeight
        return min(max(contentHeight, 260), 560)
    }
}

private final class SourceMenuActionRow: UIControl {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let separator = UIView()
    private let isDestructiveAction: Bool

    init(action: AndroidSourceMenuSheetViewController.Action, showsSeparator: Bool) {
        isDestructiveAction = action.isDestructive
        super.init(frame: .zero)
        configure(action: action, showsSeparator: showsSeparator)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    private func configure(action: AndroidSourceMenuSheetViewController.Action, showsSeparator: Bool) {
        isEnabled = action.isEnabled
        isAccessibilityElement = true
        accessibilityLabel = action.title
        accessibilityValue = action.detail
        accessibilityTraits = action.isEnabled ? [.button] : [.button, .notEnabled]

        iconView.image = UIImage(systemName: action.systemImage)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.text = action.title
        titleLabel.font = .preferredFont(forTextStyle: .body).withWeight(.regular)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail

        let hasDetail = action.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        detailLabel.text = action.detail
        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.numberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.isHidden = hasDetail == false

        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.isUserInteractionEnabled = false

        separator.backgroundColor = AndroidReplicaTheme.divider
        separator.isHidden = showsSeparator == false
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(iconView)
        addSubview(labels)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: labels.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            labels.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),

            heightAnchor.constraint(greaterThanOrEqualToConstant: hasDetail ? 52 : 44),
        ])
        updateAppearance()
    }

    private func updateAppearance() {
        backgroundColor = isHighlighted && isEnabled
            ? AndroidReplicaTheme.menuBackground.withAlphaComponent(0.72)
            : .clear
        alpha = isEnabled ? 1 : 0.52
        accessibilityTraits = isEnabled ? [.button] : [.button, .notEnabled]
        let foreground = isDestructiveAction ? UIColor.systemRed : AndroidReplicaTheme.primaryText
        iconView.tintColor = foreground.withAlphaComponent(isDestructiveAction ? 0.88 : 0.72)
        titleLabel.textColor = foreground
        detailLabel.textColor = isDestructiveAction
            ? UIColor.systemRed.withAlphaComponent(0.72)
            : AndroidReplicaTheme.secondaryText
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
