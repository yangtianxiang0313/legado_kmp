import UIKit

extension SearchViewController {
    func showEmptyResultSuggestion() {
        if screen.precisionSearch {
            presentReplicaOptionSheet(
                title: L10n.Search.suggestDisablePrecision,
                options: [
                    .init(title: L10n.Search.disablePrecision, systemImage: "target", isSelected: false) { [weak self] in
                        guard let self else { return }
                        Task {
                            try? await self.screen.togglePrecisionSearch()
                            await MainActor.run { self.performSearch() }
                        }
                    },
                    closeOption(),
                ]
            )
        } else if case .allEnabled = selectedScope {
            return
        } else {
            presentReplicaOptionSheet(
                title: L10n.Search.suggestAllSources,
                options: [
                    .init(title: L10n.Search.switchToAll, systemImage: "globe", isSelected: false) { [weak self] in
                        guard let self else { return }
                        self.selectedScope = .allEnabled
                        self.updateSourceMenu()
                        self.updateScopeSummary(session: nil)
                        self.performSearch()
                    },
                    closeOption(),
                ]
            )
        }
    }

    func presentHistoryBookshelfChoice(keyword: String) {
        let title = String(format: L10n.Search.historyBookOnShelfMessage, keyword)
        presentReplicaOptionSheet(
            title: title,
            options: [
                .init(title: L10n.Search.historyOpenDetail, systemImage: "book", isSelected: false) { [weak self] in
                    self?.openBookshelfDetailOrSearch(keyword: keyword)
                },
                .init(title: L10n.Search.historySearchInstead, systemImage: "magnifyingglass", isSelected: false) { [weak self] in
                    self?.searchHistoryKeyword(keyword)
                },
                .init(title: L10n.Common.cancel, systemImage: "chevron.down.circle", isSelected: false) {},
            ]
        )
    }

    @objc func handleScopeButtonTapped() {
        dismissSearchInputOverlays()
        presentScopeSelector()
    }

    @objc func handleScopeLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        dismissSearchInputOverlays()
        presentScopeSelector()
    }

    @objc func handleMoreButtonTapped() {
        dismissSearchInputOverlays()
        presentMoreSelector()
    }

    @objc func handleClearHistoryTapped() {
        presentReplicaOptionSheet(
            title: L10n.Search.clearHistoryConfirm,
            options: [
                .init(title: L10n.Common.close, systemImage: "chevron.down.circle", isSelected: false) {},
                .init(
                    title: L10n.Search.clearHistory,
                    systemImage: "trash",
                    isSelected: false,
                    isDestructive: true
                ) { [weak self] in
                    guard let self else { return }
                    Task {
                        try? await self.screen.clearSearchHistory()
                        await MainActor.run {
                            self.refreshInputHelp()
                        }
                    }
                },
            ]
        )
    }

    func dismissSearchInputOverlays() {
        searchBar.resignFirstResponder()
        setInputHelpVisible(false)
    }

    func presentScopeSelector() {
        SearchScopeDialogSourceLoader.load(from: self) { [weak self] sources in
            guard let self else { return }
            let scopeVC = SearchScopeViewController(
                groups: self.groups,
                sources: sources,
                currentScope: self.selectedScope
            )
            scopeVC.onScopeSelected = { [weak self] newScope in
                self?.applyNewScope(newScope)
            }
            self.present(scopeVC, animated: true)
        }
    }

    func presentMoreSelector() {
        presentReplicaOptionSheet(
            title: L10n.Bookshelf.moreActions,
            options: moreSelectorOptions()
        )
    }

    func updateMoreMenu() {
        var children: [UIMenuElement] = [
            UIAction(
                title: L10n.Settings.precisionSearchTitle,
                image: UIImage(systemName: "target"),
                state: screen.precisionSearch ? .on : .off
            ) { [weak self] _ in
                self?.togglePrecisionSearch()
            },
            UIAction(
                title: L10n.Settings.sourceManagementTitle,
                image: UIImage(systemName: "square.stack.3d.down.right")
            ) { [weak self] _ in
                self?.openSourceManagement()
            },
        ]
        if currentSession?.isRunning == true {
            children.append(
                UIAction(
                    title: currentSession?.isPaused == true ? L10n.Search.resumeSearch : L10n.Search.pauseSearch,
                    image: UIImage(systemName: currentSession?.isPaused == true ? "play.fill" : "pause.fill")
                ) { [weak self] _ in
                    self?.toggleSearchPauseState()
                }
            )
            children.append(
                UIAction(title: L10n.Search.stopSearch, image: UIImage(systemName: "stop.fill")) { [weak self] _ in
                    self?.screen.cancelSearch()
                }
            )
        }
        if currentSession?.hasMore == true,
           currentSession?.results.isEmpty == false,
           currentSession?.isRunning == false
        {
            children.append(
                UIAction(title: L10n.Search.nextPage, image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                    self?.loadNextPage()
                }
            )
        }
        moreButton.menu = UIMenu(children: children)
    }

    private func moreSelectorOptions() -> [AndroidReplicaOptionSheetViewController.Option] {
        var options: [AndroidReplicaOptionSheetViewController.Option] = [
            .init(
                title: L10n.Settings.precisionSearchTitle,
                systemImage: screen.precisionSearch ? nil : "target",
                isSelected: screen.precisionSearch
            ) { [weak self] in
                self?.togglePrecisionSearch()
            },
            .init(
                title: L10n.Settings.sourceManagementTitle,
                systemImage: "square.stack.3d.down.right",
                isSelected: false
            ) { [weak self] in
                self?.openSourceManagement()
            },
        ]

        if currentSession?.isRunning == true {
            options.append(
                .init(
                    title: currentSession?.isPaused == true ? L10n.Search.resumeSearch : L10n.Search.pauseSearch,
                    systemImage: currentSession?.isPaused == true ? "play.fill" : "pause.fill",
                    isSelected: false
                ) { [weak self] in
                    self?.toggleSearchPauseState()
                }
            )
            options.append(
                .init(title: L10n.Search.stopSearch, systemImage: "stop.fill", isSelected: false) { [weak self] in
                    self?.screen.cancelSearch()
                }
            )
        }

        if currentSession?.hasMore == true,
           currentSession?.results.isEmpty == false,
           currentSession?.isRunning == false
        {
            options.append(
                .init(title: L10n.Search.nextPage, systemImage: "arrow.down.circle", isSelected: false) { [weak self] in
                    self?.loadNextPage()
                }
            )
        }
        options.append(closeOption())
        return options
    }

    private func openBookshelfDetailOrSearch(keyword: String) {
        searchBar.resignFirstResponder()
        setInputHelpVisible(false)
        Task { [weak self] in
            guard let self else { return }
            do {
                let books = try await self.screen.searchBookshelf(query: keyword)
                await MainActor.run {
                    if let book = books.first {
                        let controller = AndroidReplicaBookDetailViewController(bookURL: book.bookUrl)
                        self.navigationController?.pushViewController(controller, animated: true)
                    } else {
                        self.searchHistoryKeyword(keyword)
                    }
                }
            } catch {
                await MainActor.run {
                    self.searchHistoryKeyword(keyword)
                }
            }
        }
    }

    private func searchHistoryKeyword(_ keyword: String) {
        searchBar.text = keyword
        searchBar.resignFirstResponder()
        setInputHelpVisible(false)
        performSearch()
    }

    private func presentReplicaOptionSheet(
        title: String,
        options: [AndroidReplicaOptionSheetViewController.Option]
    ) {
        let controller = AndroidReplicaOptionSheetViewController(titleText: title, options: options)
        present(
            controller.wrappedInReaderBottomSheet(
                fixedHeight: AndroidReplicaOptionSheetViewController.preferredHeight(optionCount: options.count)
            ),
            animated: true
        )
    }

    private func closeOption() -> AndroidReplicaOptionSheetViewController.Option {
        .init(title: L10n.Common.close, systemImage: "chevron.down.circle", isSelected: false) {}
    }
}
