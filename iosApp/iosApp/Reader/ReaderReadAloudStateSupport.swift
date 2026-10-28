import UIKit
import shared

enum ReaderReadAloudStateSupport {
    static func state(_ state: ReadAloudState, for bookURL: String) -> ReadAloudState {
        guard state.bookUrl != bookURL else { return state }
        return ReadAloudState(
            engine: .systemTts,
            status: .idle,
            progress: ReadAloudProgress(
                chapterIndex: 0, blockIndex: 0, utteranceRangeStart: 0,
                utteranceRangeEnd: 0, isInBackground: false, speechRate: 1,
                remainingTimerMinutes: 0
            ),
            isSupported: true,
            isBackgroundPlaybackEnabled: false,
            message: nil,
            bookUrl: nil
        )
    }

    @MainActor
    static func receive(_ state: ReadAloudState, in controller: ReaderContainerViewController) {
        if isActiveReader(controller), state.bookUrl == controller.bookURL {
            controller.continueReadAloudAfterChapterEndIfNeeded(previous: controller.readAloudState, current: state)
        }
        controller.readAloudState = state
        controller.readAloudSheetController?.update(state: state)
        if state.status == .running || state.status == .paused {
            controller.stopAutoPage(showMessage: false)
        }
        applyPlayback(in: controller)
    }

    @MainActor
    static func applyPlayback(in controller: ReaderContainerViewController) {
        guard let state = controller.readAloudState,
            state.bookUrl == controller.bookURL,
            Int(state.progress.chapterIndex) == controller.chapterIndex,
            !controller.pages.isEmpty,
            isActiveReader(controller)
        else {
            controller.readAloudService.apply(state: nil)
            controller.renderView.highlightedBlockIndex = nil
            return
        }
        controller.readAloudService.apply(state: state)
        controller.updateReadAloudHighlight(state)
    }

    @MainActor
    private static func isActiveReader(_ controller: ReaderContainerViewController) -> Bool {
        controller.viewIfLoaded?.window != nil
            && !controller.isMovingFromParent
            && !controller.isBeingDismissed
            && controller.navigationController?.topViewController === controller
    }
}
