import UIKit

@MainActor
final class CoverConfigurationPreviewView: UIView {
    let modeControl = UISegmentedControl(items: CoverConfigurationMode.allCases.map(\.title))
    let nameField = UITextField()
    let authorField = UITextField()
    private let cover = AndroidDefaultBookCoverView()
    var onChange: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        cover.followsLoadingPolicy = false
        cover.isAccessibilityElement = true
        cover.accessibilityElementsHidden = false
        cover.accessibilityIdentifier = "coverConfiguration.preview"
        modeControl.selectedSegmentIndex = 0
        modeControl.accessibilityIdentifier = "coverConfiguration.mode"
        modeControl.addAction(UIAction { [weak self] _ in self?.onChange?() }, for: .valueChanged)
        for (field, placeholder, identifier) in [
            (nameField, "预览书名", "coverConfiguration.previewName"),
            (authorField, "预览作者", "coverConfiguration.previewAuthor"),
        ] {
            field.placeholder = placeholder
            field.accessibilityLabel = placeholder
            field.accessibilityIdentifier = identifier
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.addAction(UIAction { [weak self] _ in self?.onChange?() }, for: .editingChanged)
            field.addAction(UIAction { [weak field] _ in field?.resignFirstResponder() }, for: .editingDidEndOnExit)
        }
        nameField.text = "阅读"
        authorField.text = "作者"
        let canvas = UIView()
        canvas.addSubview(cover)
        cover.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.heightAnchor.constraint(equalToConstant: 188),
            cover.widthAnchor.constraint(equalToConstant: 110),
            cover.heightAnchor.constraint(equalTo: cover.widthAnchor, multiplier: 7.0 / 5.0),
            cover.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            cover.centerYAnchor.constraint(equalTo: canvas.centerYAnchor),
        ])
        let stack = UIStackView(arrangedSubviews: [modeControl, canvas, nameField, authorField])
        stack.axis = .vertical
        stack.spacing = 8
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            authorField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    func render(configuration: CoverConfiguration, mode: CoverConfigurationMode) {
        cover.overrideUserInterfaceStyle = mode == .night ? .dark : .light
        cover.configurationOverride = configuration
        cover.configure(name: nameField.text, author: authorField.text)
        cover.accessibilityLabel = "\(mode.title)封面，\(nameField.text ?? "")，\(authorField.text ?? "")"
    }
}
