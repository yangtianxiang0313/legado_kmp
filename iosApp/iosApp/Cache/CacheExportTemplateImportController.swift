import UIKit
import UniformTypeIdentifiers

@MainActor
final class CacheExportTemplateImportController: NSObject, UIDocumentPickerDelegate {
    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    private(set) var usesCustomTemplate: Bool
    private(set) var isBusy = false
    private weak var owner: UIViewController?
    private let store: CacheExportTemplateStore
    private let initialBase64: String
    private let initialName: String
    private var selection: CacheExportTemplateSelection?
    private var unavailableMessage: String?
    private var task: Task<Void, Never>?
    private var picker: UIDocumentPickerViewController?
    private var generation = UUID()
    private var closed = false
    private var didLoad = false

    init(owner: UIViewController, options: CacheExportOptions, store: CacheExportTemplateStore) {
        self.owner = owner
        self.store = store
        usesCustomTemplate = options.useCustomEpubTemplate
        initialBase64 = options.epubTemplateBase64
        initialName = options.epubTemplateName
        super.init()
    }

    deinit { task?.cancel() }

    var canConfirm: Bool {
        !closed && !isBusy && picker == nil && (!usesCustomTemplate || selection != nil)
    }

    func load() {
        guard !didLoad, !closed else { return }
        didLoad = true
        begin {
            try await CacheExportTemplateImport.load(
                from: self.store, base64Zip: self.initialBase64, name: self.initialName)
        }
    }

    func cell(for row: Int) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.font = .preferredFont(forTextStyle: .body)
        cell.textLabel?.adjustsFontForContentSizeCategory = true
        cell.textLabel?.numberOfLines = 0
        cell.detailTextLabel?.font = .preferredFont(forTextStyle: .footnote)
        cell.detailTextLabel?.adjustsFontForContentSizeCategory = true
        cell.detailTextLabel?.numberOfLines = 0
        let selected = row == 0 ? !usesCustomTemplate : row == 1 && usesCustomTemplate
        cell.accessoryType = selected ? .checkmark : .none
        cell.accessibilityTraits = selected ? [.button, .selected] : .button
        switch row {
        case 0:
            cell.textLabel?.text = "内置模板"
            cell.accessibilityIdentifier = "cache.export.options.template.builtin"
        case 1:
            cell.textLabel?.text = "自定义模板"
            if isBusy {
                cell.detailTextLabel?.text = "正在处理模板…"
            } else if let selection {
                cell.detailTextLabel?.text =
                    selection.snapshot.name + " · "
                    + ByteCountFormatter.string(fromByteCount: Int64(selection.snapshot.archive.count), countStyle: .file)
            } else {
                cell.detailTextLabel?.text = unavailableMessage ?? "未导入模板"
                cell.detailTextLabel?.textColor = usesCustomTemplate ? .systemRed : .secondaryLabel
            }
            cell.accessibilityIdentifier = "cache.export.options.template.custom"
        default:
            cell.textLabel?.text = "导入 ZIP"
            cell.imageView?.image = UIImage(systemName: "doc.badge.plus")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityIdentifier = "cache.export.options.template.import"
        }
        if isBusy || picker != nil {
            cell.isUserInteractionEnabled = false
            cell.textLabel?.textColor = .secondaryLabel
            cell.accessibilityTraits.insert(.notEnabled)
        }
        return cell
    }

    func select(row: Int) {
        guard !closed, !isBusy, picker == nil else { return }
        switch row {
        case 0: usesCustomTemplate = false
        case 1:
            usesCustomTemplate = true
            if selection == nil { unavailableMessage = CacheExportTemplateError.unavailable.localizedDescription }
        default:
            presentPicker()
        }
        onChange?()
    }

    func close() {
        closed = true
        generation = UUID()
        task?.cancel()
        picker?.delegate = nil
        picker = nil
        onChange = nil
        onError = nil
    }

    func confirm(_ options: CacheExportOptions) async throws -> CacheExportOptions {
        guard canConfirm else {
            throw isBusy ? CacheExportTemplateError.busy : CacheExportTemplateError.unavailable
        }
        var snapshot = options
        snapshot.useCustomEpubTemplate = usesCustomTemplate
        snapshot.epubTemplateBase64 = ""
        snapshot.epubTemplateName = ""
        guard usesCustomTemplate else { return snapshot }
        guard let selection else { throw CacheExportTemplateError.unavailable }
        // From this point the settings owner locks cancellation and awaits the actual disk result.
        isBusy = true
        onChange?()
        defer {
            isBusy = false
            onChange?()
        }
        try await CacheExportTemplateImport.commit(selection.snapshot, to: store)
        snapshot.epubTemplateBase64 = selection.snapshot.base64Zip
        snapshot.epubTemplateName = selection.snapshot.name
        return snapshot
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard picker === controller, !closed else { return }
        let token = generation
        controller.dismiss(animated: true) { [weak self] in
            guard let self, !self.closed, self.generation == token, self.picker === controller else { return }
            self.picker = nil
            guard urls.count == 1, let url = urls.first else {
                self.onChange?()
                self.onError?("请选择一个模板 ZIP")
                return
            }
            self.begin(importing: true) { try await CacheExportTemplateImport.importFile(at: url) }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        guard picker === controller else { return }
        picker = nil
        onChange?()
    }

    private func presentPicker() {
        guard let owner, owner.presentedViewController == nil, owner.viewIfLoaded?.window != nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.zip], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.accessibilityLabel = "导入 EPUB 模板"
        self.picker = picker
        owner.view.endEditing(true)
        owner.present(picker, animated: true)
    }

    private func begin(
        importing: Bool = false,
        operation: @escaping @MainActor () async throws -> CacheExportTemplateSelection?
    ) {
        guard !closed, task == nil else { return }
        isBusy = true
        onChange?()
        let token = UUID()
        generation = token
        task = Task { [weak self] in
            do {
                let selection = try await operation()
                guard let self, self.accepts(token) else { return }
                self.selection = selection
                if importing { self.usesCustomTemplate = true }
                self.unavailableMessage =
                    selection == nil && self.usesCustomTemplate
                    ? CacheExportTemplateError.unavailable.localizedDescription : nil
                self.finish(token)
            } catch {
                guard let self, self.accepts(token) else { return }
                if !importing {
                    self.unavailableMessage = CacheExportTemplateError.unavailable.localizedDescription
                }
                self.finish(token)
                if importing, !(error is CancellationError) { self.onError?(error.localizedDescription) }
            }
        }
    }

    private func accepts(_ token: UUID) -> Bool {
        !closed && generation == token && owner != nil
            && owner?.isBeingDismissed == false && owner?.navigationController?.isBeingDismissed != true
    }

    private func finish(_ token: UUID) {
        guard generation == token else { return }
        task = nil
        isBusy = false
        onChange?()
    }
}
