import Foundation
import shared

/// The picker owns presentation; the originating page owns identity, persistence and publication.
@MainActor
struct WholeBookSourceSelection {
    let canSelect: () -> Bool
    let prepare: (BookSourceChangeCandidate) async throws -> PreparedBookSourceChange
    let commit: (PreparedBookSourceChange) async throws -> Void
    let onSettled: () -> Void
    let onCommitted: () -> Void
}
