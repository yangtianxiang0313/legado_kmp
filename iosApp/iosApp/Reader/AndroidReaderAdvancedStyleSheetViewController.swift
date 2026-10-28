import shared
import UIKit

final class AndroidReaderAdvancedStyleSheetViewController: UIViewController {
    private var style: ReaderStylePreferences
    private let onUpdate: (ReaderStylePreferences) -> Void

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let titleModeControl = UISegmentedControl(items: [
        L10n.ReaderAppearance.titleModeDefault,
        L10n.ReaderAppearance.titleModeCenter,
        L10n.ReaderAppearance.titleModeHidden,
    ])
    private let titleSizeRow = AndroidReaderStyleSliderRow(title: L10n.ReaderAppearance.titleSizeTitle, identifier: "readerAppearance.advanced.titleSizeSlider")
    private let titleTopSpacingRow = AndroidReaderStyleSliderRow(title: L10n.ReaderAppearance.titleTopSpacingTitle, identifier: "readerAppearance.advanced.titleTopSpacingSlider")
    private let titleBottomSpacingRow = AndroidReaderStyleSliderRow(title: L10n.ReaderAppearance.titleBottomSpacingTitle, identifier: "readerAppearance.advanced.titleBottomSpacingSlider")

    init(
        style: ReaderStylePreferences,
        onUpdate: @escaping (ReaderStylePreferences) -> Void
    ) {
        self.style = style
        self.onUpdate = onUpdate
        super.init(nibName: nil, bundle: nil)
        title = L10n.ReaderAppearance.advancedSheetTitle
        preferredContentSize = CGSize(width: 0, height: 380)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = AndroidReplicaTheme.background
        configureLayout()
        buildContent()
        refresh()
    }

    private func configureLayout() {
        scrollView.alwaysBounceVertical = true
        scrollView.delaysContentTouches = false
        stackView.axis = .vertical
        stackView.spacing = 16
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(stackView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -20),
            stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private func buildContent() {
        titleModeControl.addAction(UIAction { [weak self] _ in
            self?.changeTitleMode()
        }, for: .valueChanged)
        titleModeControl.accessibilityIdentifier = "readerAppearance.advanced.titleModeControl"

        titleSizeRow.configure(min: 0, max: 12) { [weak self] value in
            guard let self else { return }
            let rounded = value.rounded().coerced(to: 0 ... 12)
            self.titleSizeRow.valueText = L10n.ReaderAppearance.floatPointValue(rounded)
            self.commit { $0.androidCopy(titleSize: rounded) }
        }

        titleTopSpacingRow.configure(min: 0, max: 40) { [weak self] value in
            guard let self else { return }
            let rounded = Int32(value.rounded()).coerced(to: 0 ... 40)
            self.titleTopSpacingRow.valueText = L10n.ReaderAppearance.pointValue(rounded)
            self.commit { $0.androidCopy(titleTopSpacing: rounded) }
        }

        titleBottomSpacingRow.configure(min: 0, max: 40) { [weak self] value in
            guard let self else { return }
            let rounded = Int32(value.rounded()).coerced(to: 0 ... 40)
            self.titleBottomSpacingRow.valueText = L10n.ReaderAppearance.pointValue(rounded)
            self.commit { $0.androidCopy(titleBottomSpacing: rounded) }
        }

        stackView.addArrangedSubview(makeSection(title: L10n.ReaderAppearance.advancedTextSection, rows: [
            makeSegmentedRow(title: L10n.ReaderAppearance.titleModeTitle, control: titleModeControl),
            titleSizeRow,
            titleTopSpacingRow,
            titleBottomSpacingRow,
        ]))
    }

    private func makeSection(title: String, rows: [UIView]) -> UIView {
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = AndroidReplicaTheme.secondaryText
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.82

        let section = UIStackView(arrangedSubviews: [titleLabel])
        section.axis = .vertical
        section.spacing = 10
        rows.forEach(section.addArrangedSubview)
        return section
    }

    private func makeSegmentedRow(title: String, control: UISegmentedControl) -> UIView {
        let titleLabel = makeRowTitleLabel(title)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [titleLabel, control])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 12
        return row
    }

    private func makeRowTitleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = AndroidReplicaTheme.primaryText
        label.adjustsFontForContentSizeCategory = true
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.82
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func refresh() {
        titleModeControl.selectedSegmentIndex = Int(style.titleMode.coerced(to: 0 ... 2))
        titleModeControl.accessibilityLabel = L10n.ReaderAppearance.titleModeTitle
        titleModeControl.accessibilityValue = titleModeText(style.titleMode)

        let titleSize = style.titleSize.coerced(to: 0 ... 12)
        titleSizeRow.set(value: titleSize, text: L10n.ReaderAppearance.floatPointValue(titleSize))
        titleTopSpacingRow.set(
            value: Float(style.titleTopSpacing.coerced(to: 0 ... 40)),
            text: L10n.ReaderAppearance.pointValue(style.titleTopSpacing)
        )
        titleBottomSpacingRow.set(
            value: Float(style.titleBottomSpacing.coerced(to: 0 ... 40)),
            text: L10n.ReaderAppearance.pointValue(style.titleBottomSpacing)
        )
    }

    private func changeTitleMode() {
        let selected = Int32(titleModeControl.selectedSegmentIndex).coerced(to: 0 ... 2)
        commit { $0.androidCopy(titleMode: selected) }
    }

    private func commit(_ update: (ReaderStylePreferences) -> ReaderStylePreferences) {
        style = update(style)
        refresh()
        onUpdate(style)
    }

    private func titleModeText(_ value: Int32) -> String {
        switch value {
        case 1:
            return L10n.ReaderAppearance.titleModeCenter
        case 2:
            return L10n.ReaderAppearance.titleModeHidden
        default:
            return L10n.ReaderAppearance.titleModeDefault
        }
    }
}

private extension Int32 {
    func coerced(to range: ClosedRange<Int32>) -> Int32 {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
