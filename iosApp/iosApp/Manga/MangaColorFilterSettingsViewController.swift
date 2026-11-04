import UIKit

@MainActor
final class MangaColorFilterSettingsViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
    private var draft: MangaColorFilter
    private let settings: MangaReadingSettings
    private var saveTask: Task<Void, Never>?
    private var didSave = false
    private var errorMessage: String?
    private var isSaving: Bool { saveTask != nil }
    private var fields: [(String, String, WritableKeyPath<MangaColorFilter, Int>)] {
        let brightness = L10n.text("manga.ui.color_filter.brightness", "亮度")
        return [
            (brightness, brightness, \.l),
            ("R", L10n.text("manga.ui.color_filter.red_accessibility", "红色通道"), \.r),
            ("G", L10n.text("manga.ui.color_filter.green_accessibility", "绿色通道"), \.g),
            ("B", L10n.text("manga.ui.color_filter.blue_accessibility", "蓝色通道"), \.b),
            ("A", L10n.text("manga.ui.color_filter.alpha_accessibility", "透明度通道"), \.a),
        ]
    }

    init(settings: MangaReadingSettings) {
        self.settings = settings
        draft = settings.options.colorFilter
        super.init(style: .insetGrouped)
        title = L10n.text("manga.ui.color_filter.title", "颜色滤镜")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.backgroundView = nil
        tableView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        view.accessibilityIdentifier = "manga.colorFilter.editor"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .save, target: self, action: #selector(save))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 90
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.presentationController?.delegate = self
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !didSave { settings.previewColorFilter(nil) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 5 : 1 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 1 ? errorMessage : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(white: 0.14, alpha: 1)
        cell.selectionStyle = .none
        if indexPath.section == 1 {
            var content = cell.defaultContentConfiguration()
            content.text = L10n.text("manga.ui.color_filter.reset", "重置")
            content.textProperties.numberOfLines = 0
            content.image = UIImage(systemName: "arrow.counterclockwise")
            cell.contentConfiguration = content
            cell.selectionStyle = .default
            cell.accessibilityIdentifier = "manga.colorFilter.reset"
            cell.isUserInteractionEnabled = !isSaving
            return cell
        }
        let (title, accessibilityLabel, key) = fields[indexPath.row]
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        let value = UILabel()
        value.text =
            indexPath.row == 0 && draft.l == 0
            ? L10n.text("manga.ui.color_filter.system", "系统") : "\(draft[keyPath: key])"
        value.font = .monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        value.textColor = .secondaryLabel
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [label, value])
        heading.spacing = 12
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 255
        slider.value = Float(draft[keyPath: key])
        slider.isEnabled = !isSaving
        slider.accessibilityLabel = accessibilityLabel
        slider.accessibilityValue = value.text
        slider.accessibilityIdentifier = "manga.colorFilter.\(["l", "r", "g", "b", "a"][indexPath.row])"
        slider.addAction(
            UIAction { [weak self, weak slider, weak value] _ in
                guard let self, let slider, !self.isSaving else { return }
                let number = Int(slider.value.rounded())
                self.draft[keyPath: key] = number
                value?.text =
                    key == \.l && number == 0
                    ? L10n.text("manga.ui.color_filter.system", "系统") : "\(number)"
                slider.accessibilityValue = value?.text
                self.settings.previewColorFilter(self.draft)
            }, for: .valueChanged)
        let stack = UIStackView(arrangedSubviews: [heading, slider])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
        ])
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.section == 1, !isSaving else { return }
        draft.reset()
        settings.previewColorFilter(draft)
        tableView.reloadData()
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool { !isSaving }

    @objc private func cancel() {
        guard !isSaving else { return }
        settings.previewColorFilter(nil)
        navigationController?.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
    }

    @objc private func save() {
        guard !isSaving, canPerformNavigationAction, UIApplication.shared.applicationState == .active,
            view.window.map({ AppLockManager.shared.isUnlocked(in: $0) }) == true
        else { return }
        errorMessage = nil
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItem?.isEnabled = false
        saveTask = Task { [self] in
            defer {
                saveTask = nil
                isModalInPresentation = false
                navigationController?.isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItem?.isEnabled = true
            }
            do {
                try await settings.saveColorFilter(draft)
                didSave = true
                navigationController?.popViewController(animated: !UIAccessibility.isReduceMotionEnabled)
            } catch {
                errorMessage = error.userFacingMessage
                tableView.reloadData()
            }
        }
        tableView.reloadData()
    }
}
