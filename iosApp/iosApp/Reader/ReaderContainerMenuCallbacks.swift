import UIKit

extension ReaderContainerViewController {
    func configureReaderMenuCallbacks() {
        readMenu.isHidden = true
        readMenu.onBack = { [weak self] in self?.performReaderBackAction() }
        readMenu.onBookInfo = { [weak self] in self?.openReaderBookInfoFromMenu() }
        readMenu.onPreviousChapter = { [weak self] in self?.openPreviousChapter(toLast: false) }
        readMenu.onNextChapter = { [weak self] in self?.openNextChapter() }
        readMenu.onPageSliderChange = { [weak self] value, behavior in
            self?.skipBySliderValue(value, behavior: behavior)
        }
        readMenu.onRefresh = { [weak self] in self?.reloadCurrentChapter() }
        readMenu.onRefreshLongPress = { [weak self] in self?.showRefreshMenu() }
        readMenu.onDownload = { [weak self] in self?.showDownloadMenu() }
        readMenu.onSetCharset = { [weak self] in self?.showCharsetOperationMenu() }
        readMenu.onSearch = { [weak self] in self?.showSearchMenu() }
        readMenu.onAutoPage = { [weak self] in self?.toggleAutoPageFromMenu() }
        readMenu.onReplace = { [weak self] in self?.showReplaceRuleMenu() }
        readMenu.onNight = { [weak self] in self?.toggleNightTheme() }
        readMenu.onToc = { [weak self] in self?.showChapterPicker() }
        readMenu.onReadAloud = { [weak self] in self?.toggleReadAloudFromMenu() }
        readMenu.onReadAloudLongPress = { [weak self] in self?.showReadAloudSheet() }
        readMenu.onSettings = { [weak self] in self?.showReaderAppearance() }
        readMenu.onMoreSettings = { [weak self] in self?.showMoreSettingsSheet() }
        readMenu.onMore = { [weak self] in self?.showReaderOperationMenu() }
        readMenu.onSource = { [weak self] in self?.showSourceMenu() }
        readMenu.onChangeSource = { [weak self] in self?.showBookChangeSourceFromMenu() }
        readMenu.onChangeSourceLongPress = { [weak self] in self?.showChangeSourceMenu() }
        readMenu.onChapterSource = { [weak self] in self?.openCurrentChapterSourceFromMenu() }
        readMenu.onDismiss = { [weak self] in self?.setMenuVisible(false) }
        readMenu.onBrightnessChange = { [weak self] value in self?.handleReaderBrightnessSlider(value) }
        readMenu.onBrightnessAutoChange = { [weak self] isAuto, value in
            self?.handleReaderBrightnessAuto(isAuto: isAuto, sliderValue: value)
        }

        configureSearchMenuCallbacks()
    }
}
