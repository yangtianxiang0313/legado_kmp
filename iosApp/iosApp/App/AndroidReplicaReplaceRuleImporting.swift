import shared
import UIKit
import UniformTypeIdentifiers

extension AndroidReplicaReplaceRuleViewController {
    func showUrlImportSheet() {
        let controller = AndroidReplicaTextInputSheetViewController(
            titleText: L10n.ReplaceRule.importFromUrl,
            placeholder: L10n.ReplaceRule.importUrlPlaceholder,
            initialValue: nil,
            keyboardType: .URL
        ) { [weak self] text in
            self?.validateAndImportUrl(text)
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 260), animated: true)
    }

    func validateAndImportUrl(_ text: String) {
        let urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard urlText.isEmpty == false else {
            showTransientMessage(L10n.ReplaceRule.importUrlEmpty)
            return
        }
        guard urlText.lowercased().hasPrefix("http://") || urlText.lowercased().hasPrefix("https://") else {
            showTransientMessage(L10n.ReplaceRule.importUrlInvalid)
            return
        }
        importFromUrl(urlText)
    }

    func importFromUrl(_ urlString: String) {
        guard let url = URL(string: urlString) else {
            showTransientMessage(L10n.ReplaceRule.importUrlInvalid)
            return
        }
        showTransientMessage(L10n.ReplaceRule.importLoading)
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let json = String(data: data, encoding: .utf8) else {
                    await MainActor.run { self?.showTransientMessage(L10n.ReplaceRule.importParseFailed) }
                    return
                }
                let rules = self?.parseReplaceRulesJson(json) ?? []
                await MainActor.run { self?.showImportPreview(rules) }
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    func showFileImportPicker() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.json, UTType.plainText])
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }

    func documentPicker(_: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url), let json = String(data: data, encoding: .utf8) else {
            showTransientMessage(L10n.ReplaceRule.importFileReadFailed)
            return
        }
        showImportPreview(parseReplaceRulesJson(json))
    }

    func importFromClipboard() {
        guard let clipboardText = UIPasteboard.general.string,
              clipboardText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            showTransientMessage(L10n.ReplaceRule.importClipboardEmpty)
            return
        }
        showImportPreview(parseReplaceRulesJson(clipboardText))
    }

    func showImportPreview(_ rules: [ReplaceRule]) {
        guard rules.isEmpty == false else {
            showTransientMessage(L10n.ReplaceRule.importNoValidRules)
            return
        }
        let controller = AndroidReplicaReplaceRuleImportPreviewSheetViewController(rules: rules) { [weak self] customGroup in
            self?.executeImport(rules: rules, customGroup: customGroup)
        }
        present(controller.wrappedInReaderBottomSheet(fixedHeight: 560), animated: true)
    }

    func executeImport(rules: [ReplaceRule], customGroup: String?) {
        let group = customGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalRules = group?.isEmpty == false ? rules.map { $0.copyWithGroup(group) } : rules
        Task { [weak self] in
            do {
                try await self?.screen.saveRules(finalRules)
                await MainActor.run {
                    self?.showTransientMessage(L10n.ReplaceRule.importSuccessMessage(finalRules.count))
                }
            } catch {
                await MainActor.run { self?.showTransientMessage(error.userFacingMessage) }
            }
        }
    }

    func parseReplaceRulesJson(_ json: String) -> [ReplaceRule] {
        guard let data = json.data(using: .utf8) else { return [] }
        let object = try? JSONSerialization.jsonObject(with: data)
        let items: [[String: Any]]
        if let array = object as? [[String: Any]] {
            items = array
        } else if let dict = object as? [String: Any] {
            items = [dict]
        } else {
            return []
        }

        return items.enumerated().compactMap { index, dict -> ReplaceRule? in
            makeReplaceRule(from: dict, fallbackIndex: index)
        }
    }

    private func makeReplaceRule(from dict: [String: Any], fallbackIndex index: Int) -> ReplaceRule? {
        let pattern = dict["pattern"] as? String ?? dict["regex"] as? String ?? ""
        guard pattern.isEmpty == false else { return nil }

        let fallbackId = Int64(Date().timeIntervalSince1970 * 1000) + Int64(index)
        let id = int64Value(dict["id"]) ?? fallbackId
        let timeout = int64Value(dict["timeout"])
            ?? int64Value(dict["timeoutMillisecond"])
            ?? 3000
        let order = int32Value(dict["order"])
            ?? int32Value(dict["serialNumber"])
            ?? Int32(index)

        return ReplaceRule(
            id: id,
            name: dict["name"] as? String ?? dict["replaceSummary"] as? String ?? "",
            group: dict["group"] as? String,
            pattern: pattern,
            replacement: dict["replacement"] as? String ?? "",
            scope: dict["scope"] as? String ?? dict["useTo"] as? String,
            scopeTitle: dict["scopeTitle"] as? Bool ?? false,
            scopeContent: dict["scopeContent"] as? Bool ?? true,
            excludeScope: dict["excludeScope"] as? String,
            isEnabled: dict["isEnabled"] as? Bool ?? dict["enable"] as? Bool ?? true,
            isRegex: dict["isRegex"] as? Bool ?? false,
            timeoutMillisecond: timeout,
            order: order
        )
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? Double { return Int64(value) }
        return nil
    }

    private func int32Value(_ value: Any?) -> Int32? {
        if let value = value as? Int32 { return value }
        if let value = value as? Int { return Int32(value) }
        if let value = value as? Double { return Int32(value) }
        return nil
    }

    func exportRules(_ rules: [ReplaceRule]) {
        guard rules.isEmpty == false else {
            showTransientMessage(L10n.ReplaceRule.exportEmpty)
            return
        }
        let jsonArray = rules.map { $0.exportDictionary }
        guard let data = try? JSONSerialization.data(withJSONObject: jsonArray, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8)
        else {
            showTransientMessage(L10n.ReplaceRule.importParseFailed)
            return
        }
        let activityController = UIActivityViewController(activityItems: [jsonString], applicationActivities: nil)
        activityController.popoverPresentationController?.sourceView = view
        activityController.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(activityController, animated: true)
    }
}
