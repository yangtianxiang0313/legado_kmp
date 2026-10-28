import Foundation
import shared

final class SourceImportScreenAdapter {
    private var facade: SourceManagementFacade?

    func bootstrap() -> Result<Void, SharedRuntimeError> {
        switch SharedRuntime.sourceManagementFacade() {
        case .success(let facade):
            self.facade = facade
            return .success(())
        case .failure(let error):
            return .failure(error)
        }
    }

    func preparePreview(source: ImportSource) async throws -> SourceImportPreview {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.value { completion in
            switch source {
            case .payload(let payload):
                facade.previewSourceImport(payload: payload, completionHandler: completion)
            case .url(let url):
                facade.previewSourceImportByUrl(url: url, completionHandler: completion)
            case .file(let file):
                facade.previewSourceImport(payload: file.payload, completionHandler: completion)
            }
        }
    }

    func importSelected(sources: [BookSource], options: SourceImportOptions) async throws -> SourceImportResult {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.value { completion in
            facade.importSelectedSources(sources: sources, options: options, completionHandler: completion)
        }
    }

    func prepareEditorDrafts(payload: String) async throws -> SourceEditorImportPreview {
        guard let facade else { throw runtimeNotReadyError() }
        return try await SharedAsync.value { completion in
            facade.previewEditorSourceImport(payload: payload, completionHandler: completion)
        }
    }

    private func runtimeNotReadyError() -> Error {
        NSError(
            domain: "io.legado.kmp.ios", code: -1,
            userInfo: [NSLocalizedDescriptionKey: L10n.SourceImport.unavailable]
        )
    }
}

enum ImportSource {
    case payload(String)
    case url(String)
    case file(ImportFileSelection)
}

struct ImportFileSelection {
    let displayName: String
    let payload: String
}

enum ImportMode {
    case json, url, file

    init(selectedIndex: Int) {
        switch selectedIndex {
        case 1: self = .url
        case 2: self = .file
        default: self = .json
        }
    }

    var segmentIndex: Int {
        switch self {
        case .json: return 0
        case .url: return 1
        case .file: return 2
        }
    }
}
