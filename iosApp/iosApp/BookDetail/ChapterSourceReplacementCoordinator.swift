import Foundation

@MainActor
final class ChapterSourceCommitGate {
    private weak var coordinator: ChapterSourceReplacementCoordinator?
    private let operationID: UUID
    private var hasBegun = false

    fileprivate init(coordinator: ChapterSourceReplacementCoordinator, operationID: UUID) {
        self.coordinator = coordinator
        self.operationID = operationID
    }

    /// Call once, immediately before the non-cancellable persistent write.
    func begin() throws {
        try Task.checkCancellation()
        guard !hasBegun, let coordinator else { throw CancellationError() }
        try coordinator.beginCommit(operationID)
        hasBegun = true
    }
}

@MainActor
final class ChapterSourceReplacementCoordinator {
    enum Phase { case preparing, committing, terminal }
    enum Outcome {
        case committed
        case cancelled
        case failed(Error)
    }

    private struct Operation {
        let id: UUID
        let canCommit: () -> Bool
        let onCommit: () -> Void
        let onFinish: (Outcome) -> Void
    }

    private var operation: Operation?
    private var task: Task<Void, Never>?
    private(set) var phase: Phase = .terminal
    var isCommitting: Bool { phase == .committing }

    @discardableResult
    func start(
        canCommit: @escaping () -> Bool,
        onCommit: @escaping () -> Void,
        onFinish: @escaping (Outcome) -> Void,
        replace: @escaping @MainActor (ChapterSourceCommitGate) async throws -> Void
    ) -> Bool {
        guard phase == .terminal else { return false }
        let id = UUID()
        operation = Operation(id: id, canCommit: canCommit, onCommit: onCommit, onFinish: onFinish)
        phase = .preparing
        task = Task { @MainActor [self] in
            let outcome: Outcome
            do {
                try Task.checkCancellation()
                let gate = ChapterSourceCommitGate(coordinator: self, operationID: id)
                try await replace(gate)
                guard operation?.id == id else { return }
                // Returning without a gate authorization is not a successful commit.
                // After authorization, late cancellation must not discard a successful write.
                outcome = isCommitting ? .committed : .cancelled
            } catch {
                guard operation?.id == id else { return }
                outcome =
                    error is CancellationError || (phase == .preparing && Task.isCancelled)
                    ? .cancelled : .failed(error)
            }
            finish(outcome, operationID: id)
        }
        return true
    }

    func cancel() {
        guard phase == .preparing, let operation else { return }
        finish(.cancelled, operationID: operation.id, cancelTask: true)
    }

    fileprivate func beginCommit(_ id: UUID) throws {
        try Task.checkCancellation()
        guard let operation, operation.id == id, phase == .preparing,
            let task, !task.isCancelled, operation.canCommit()
        else { throw CancellationError() }
        try Task.checkCancellation()
        guard self.operation?.id == id, phase == .preparing else { throw CancellationError() }
        phase = .committing
        operation.onCommit()
    }

    private func finish(_ outcome: Outcome, operationID: UUID, cancelTask: Bool = false) {
        guard let operation, operation.id == operationID else { return }
        // Retire the identity before cancellation can deliver an old request's completion.
        self.operation = nil
        phase = .terminal
        let finishedTask = task
        task = nil
        if cancelTask { finishedTask?.cancel() }
        operation.onFinish(outcome)
    }
}
