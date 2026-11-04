import UIKit

@MainActor
final class MangaReadingSettingsViewController: UITableViewController {
    private let settings: MangaReadingSettings
    private var enabled: Bool { settings.isReady && !settings.isSaving }

    init(settings: MangaReadingSettings) {
        self.settings = settings
        super.init(style: .insetGrouped)
        title = L10n.text("manga.ui.settings.title", "漫画设置")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        tableView.backgroundView = nil
        tableView.backgroundColor = UIColor(white: 0.08, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(close))
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        settings.onStateChange = { [weak self] in self?.tableView.reloadData() }
        settings.load()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 3 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        [8, 1, 3][section]
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        [
            L10n.text("manga.ui.settings.section.reading", "阅读方式"),
            L10n.text("manga.ui.settings.section.prefetch", "预加载"),
            L10n.text("manga.ui.settings.section.image", "图像"),
        ][section]
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        section == 0 ? settings.lastError : nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let options = settings.options
        if indexPath.section == 0 {
            if indexPath.row == 5 { return autoPageSpeedCell(value: options.autoPageSpeed) }
            if indexPath.row == 6 {
                let control = UISwitch()
                control.isOn = options.hideChapterTitle
                control.isEnabled = enabled
                control.accessibilityIdentifier = "manga.settings.hideTitle"
                control.accessibilityLabel = L10n.text("manga.ui.settings.hide_chapter_title", "隐藏章节标题")
                control.addAction(
                    UIAction { [weak self, weak control] _ in
                        guard let control else { return }
                        self?.settings.set(.hideTitle(control.isOn))
                    }, for: .valueChanged)
                return cell(title: L10n.text("manga.ui.settings.hide_chapter_title", "隐藏章节标题"), control: control)
            }
            if indexPath.row == 7 {
                return configurationCell(
                    title: L10n.text("manga.ui.settings.footer", "页脚设置"), identifier: "manga.settings.footer")
            }
            let titles = [
                L10n.text("manga.ui.settings.horizontal_scroll", "横向滚动"),
                L10n.text("manga.ui.settings.page_snap", "整页吸附"),
                L10n.text("manga.ui.settings.page_animation", "翻页动画"),
                L10n.text("manga.ui.settings.allows_zoom", "允许图片缩放"),
                L10n.text("manga.ui.settings.tap_to_turn", "点击翻页"),
            ]
            let values = [
                options.horizontalScroll, options.pageSnap, options.animatesPages, options.allowsZoom, options.clickScroll,
            ]
            let control = UISwitch()
            control.isOn = values[indexPath.row]
            control.isEnabled = enabled && (indexPath.row != 1 || (options.horizontalScroll && options.animatesPages))
            control.accessibilityIdentifier =
                "manga.settings.\(["horizontal", "snap", "animation", "zoom", "click"][indexPath.row])"
            control.accessibilityLabel = titles[indexPath.row]
            control.addAction(
                UIAction { [weak self, weak control] _ in
                    guard let self, let control else { return }
                    let changes: [MangaReadingSettings.Change] = [
                        .horizontal(control.isOn), .pageSnap(control.isOn), .animation(control.isOn),
                        .zoom(control.isOn), .clickScroll(control.isOn),
                    ]
                    self.settings.set(changes[indexPath.row])
                }, for: .valueChanged)
            return cell(title: titles[indexPath.row], control: control)
        }
        if indexPath.section == 1 {
            let stepper = UIStepper()
            stepper.minimumValue = 0
            stepper.maximumValue = 100
            stepper.value = Double(options.prefetchCount)
            stepper.isEnabled = enabled
            stepper.isContinuous = false
            stepper.accessibilityIdentifier = "manga.settings.prefetch"
            stepper.accessibilityLabel = L10n.text("manga.ui.settings.prefetch_images", "预加载图片")
            let count =
                options.prefetchCount == 1
                ? L10n.format("manga.ui.settings.image_count_single", "%ld 张", Int(options.prefetchCount))
                : L10n.format("manga.ui.settings.image_count", "%ld 张", Int(options.prefetchCount))
            stepper.accessibilityValue = count
            stepper.addAction(
                UIAction { [weak self, weak stepper] _ in
                    guard let stepper else { return }
                    self?.settings.set(.prefetch(Int(stepper.value)))
                }, for: .valueChanged)
            return cell(title: L10n.text("manga.ui.settings.prefetch_images", "预加载图片"), detail: count, control: stepper)
        }
        if indexPath.row == 2 {
            return configurationCell(
                title: L10n.text("manga.ui.color_filter.title", "颜色滤镜"), identifier: "manga.settings.colorFilter")
        }
        if indexPath.row == 0 {
            let segments = UISegmentedControl(items: [
                L10n.text("manga.ui.settings.display.original", "原图"),
                L10n.text("manga.ui.settings.display.grayscale", "灰度"),
                L10n.text("manga.ui.settings.display.eink", "墨水屏"),
            ])
            switch options.displayStyle {
            case .original: segments.selectedSegmentIndex = 0
            case .grayscale: segments.selectedSegmentIndex = 1
            case .eInk: segments.selectedSegmentIndex = 2
            }
            segments.isEnabled = enabled
            segments.accessibilityIdentifier = "manga.settings.displayStyle"
            segments.accessibilityLabel = L10n.text("manga.ui.settings.display_style_accessibility", "图像显示方式")
            segments.addAction(
                UIAction { [weak self, weak segments] _ in
                    guard let self, let segments else { return }
                    let styles: [MangaImageDisplayStyle] = [
                        .original, .grayscale, .eInk(threshold: self.settings.options.eInkThreshold),
                    ]
                    guard styles.indices.contains(segments.selectedSegmentIndex) else { return }
                    self.settings.set(.displayStyle(styles[segments.selectedSegmentIndex]))
                }, for: .valueChanged)
            return cell(title: L10n.text("manga.ui.settings.display_style", "显示方式"), control: segments, vertical: true)
        }
        let slider = UISlider()
        slider.minimumValue = 0
        slider.maximumValue = 255
        slider.value = Float(options.eInkThreshold)
        slider.isEnabled =
            enabled
            && {
                if case .eInk = options.displayStyle { return true }
                return false
            }()
        slider.accessibilityIdentifier = "manga.settings.threshold"
        slider.accessibilityLabel = L10n.text("manga.ui.settings.eink_threshold", "墨水屏阈值")
        let result = cell(
            title: L10n.text("manga.ui.settings.eink_threshold", "墨水屏阈值"),
            detail: "\(options.eInkThreshold)", control: slider, vertical: true)
        slider.addAction(
            UIAction { [weak self, weak slider, weak result] _ in
                guard let slider else { return }
                let value = Int(slider.value.rounded())
                slider.accessibilityValue = "\(value)"
                (result?.contentView.viewWithTag(91) as? UILabel)?.text = "\(value)"
                if !slider.isTracking { self?.settings.set(.threshold(value)) }
            }, for: .valueChanged)
        slider.addAction(
            UIAction { [weak self, weak slider] _ in
                guard let slider else { return }
                self?.settings.set(.threshold(Int(slider.value.rounded())))
            }, for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return result
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard enabled, canPerformNavigationAction else { return }
        if indexPath == IndexPath(row: 7, section: 0) {
            let controller = MangaFooterSettingsViewController(configuration: settings.options.footer) { [settings] value in
                try await settings.saveFooter(value)
            }
            navigationController?.pushViewController(controller, animated: !UIAccessibility.isReduceMotionEnabled)
        } else if indexPath == IndexPath(row: 2, section: 2) {
            navigationController?.pushViewController(
                MangaColorFilterSettingsViewController(settings: settings), animated: !UIAccessibility.isReduceMotionEnabled)
        }
    }

    private func configurationCell(title: String, identifier: String) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(white: 0.14, alpha: 1)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = identifier
        cell.isUserInteractionEnabled = enabled
        cell.contentView.alpha = enabled ? 1 : 0.5
        return cell
    }

    private func autoPageSpeedCell(value: Int) -> UITableViewCell {
        let stepper = UIStepper()
        stepper.minimumValue = 1
        stepper.maximumValue = Double(max(100, value))
        stepper.value = Double(value)
        stepper.isEnabled = enabled
        stepper.isContinuous = false
        stepper.accessibilityIdentifier = "manga.settings.autoPageSpeed"
        stepper.accessibilityLabel = L10n.text("manga.ui.settings.auto_reading_speed", "自动阅读速度")
        stepper.accessibilityValue = "\(value)"
        stepper.addAction(
            UIAction { [weak self, weak stepper] _ in
                guard let stepper else { return }
                self?.settings.set(.autoPageSpeed(Int(stepper.value)))
            }, for: .valueChanged)
        return cell(title: L10n.text("manga.ui.settings.auto_reading_speed", "自动阅读速度"), detail: "\(value)", control: stepper)
    }

    private func cell(title: String, detail: String? = nil, control: UIView, vertical: Bool = false) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.backgroundColor = UIColor(white: 0.14, alpha: 1)
        cell.selectionStyle = .none
        let label = UILabel()
        label.text = title
        label.font = .preferredFont(forTextStyle: .body)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        let value = UILabel()
        value.text = detail
        value.tag = 91
        value.font = .preferredFont(forTextStyle: .subheadline)
        value.textColor = .secondaryLabel
        value.setContentCompressionResistancePriority(.required, for: .horizontal)
        let heading = UIStackView(arrangedSubviews: [label, value])
        heading.spacing = 12
        let stacked = vertical || traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let stack = UIStackView(arrangedSubviews: [heading, control])
        stack.axis = stacked ? .vertical : .horizontal
        stack.alignment = stacked ? .fill : .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
        ])
        return cell
    }

    @objc private func close() { dismiss(animated: !UIAccessibility.isReduceMotionEnabled) }
}
