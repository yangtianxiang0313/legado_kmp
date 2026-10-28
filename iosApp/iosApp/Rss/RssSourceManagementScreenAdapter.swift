import Foundation
import shared

// The original adapter lives with the legacy screen; keep new management APIs here.
extension RssSourceManagementScreenAdapter {
    func setEnabled(sourceUrls: [String], enabled: Bool) async throws {
        for sourceUrl in Set(sourceUrls).sorted() {
            try await setEnabled(sourceUrl: sourceUrl, enabled: enabled)
        }
    }

    func addSources(sourceUrls: [String], toGroup group: String) async throws -> Int32 {
        let facade = try SharedRuntime.rssFacade().get()
        return try await facade.addRssSourcesToGroupAsync(sourceUrls: sourceUrls, group: group)
    }

    func renameGroup(oldName: String, newName: String) async throws -> Int32 {
        let facade = try SharedRuntime.rssFacade().get()
        return try await facade.renameRssSourceGroupAsync(oldName: oldName, newName: newName)
    }

    func deleteGroup(name: String) async throws -> Int32 {
        let facade = try SharedRuntime.rssFacade().get()
        return try await facade.deleteRssSourceGroupAsync(group: name)
    }
}
