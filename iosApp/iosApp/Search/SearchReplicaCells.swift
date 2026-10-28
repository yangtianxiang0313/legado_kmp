import shared
import UIKit

extension SearchViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection _: Int) -> Int {
        if tableView === historyTableView {
            return historyItems.count
        }
        return results.count + (shouldShowLoadMoreCell ? 1 : 0)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === historyTableView {
            let cell = tableView.dequeueReusableCell(withIdentifier: "search-history", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = historyItems[indexPath.row].word
            configuration.secondaryText = nil
            cell.contentConfiguration = configuration
            cell.accessibilityIdentifier = UIIdentifiers.Search.historyCell
            return cell
        }
        guard indexPath.row < results.count else {
            return loadMoreCell()
        }
        let cell =
            tableView.dequeueReusableCell(
                withIdentifier: AndroidSearchResultCell.reuseIdentifier) as? AndroidSearchResultCell
            ?? AndroidSearchResultCell(style: .default, reuseIdentifier: AndroidSearchResultCell.reuseIdentifier)
        return resultCell(cell, for: results[indexPath.row])
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if tableView === historyTableView {
            selectHistory(at: indexPath)
            return
        }
        if shouldShowLoadMoreCell, indexPath.row == results.count {
            loadNextPage()
            return
        }
        guard indexPath.row < results.count else {
            return
        }
        openDetail(for: results[indexPath.row])
    }

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if tableView === historyTableView {
            return indexPath
        }
        if shouldShowLoadMoreCell, indexPath.row == results.count {
            return indexPath
        }
        return indexPath
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard tableView === historyTableView, indexPath.row < historyItems.count else { return nil }
        let item = historyItems[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: L10n.SourceManagement.deleteAction) { [weak self] _, _, completion in
            Task {
                do {
                    try await self?.screen.deleteSearchHistory(word: item.word)
                    await MainActor.run {
                        self?.refreshInputHelp()
                        completion(true)
                    }
                } catch {
                    await MainActor.run {
                        self?.presentError(error)
                        completion(false)
                    }
                }
            }
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    private func loadMoreCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: "search-load-more")
        var configuration = cell.defaultContentConfiguration()
        configuration.text = isLoadingNextPage ? L10n.Search.loadingNextPage : L10n.Common.loadMore
        configuration.textProperties.alignment = .center
        cell.contentConfiguration = configuration
        cell.accessibilityIdentifier = UIIdentifiers.Search.loadMoreCell
        cell.accessoryType = .none
        return cell
    }

    private func resultCell(_ cell: AndroidSearchResultCell, for book: SearchBook) -> UITableViewCell {
        let onShelf = BookshelfFacade.companion.isInBookshelf(
            keys: bookshelfKeys,
            name: book.name,
            author: book.author,
            bookUrl: book.bookUrl
        )
        cell.configure(book: book, isInBookshelf: onShelf)
        cell.accessibilityIdentifier = UIIdentifiers.Search.resultCell
        cell.onActivate = { [weak self] in
            self?.openDetail(for: book)
        }
        return cell
    }

    private func selectHistory(at indexPath: IndexPath) {
        guard indexPath.row < historyItems.count else { return }
        let keyword = historyItems[indexPath.row].word
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchedKey = bookshelfKeys.first { key in
            key.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        if matchedKey != nil {
            presentHistoryBookshelfChoice(keyword: trimmed)
        } else {
            searchBar.text = keyword
            searchBar.resignFirstResponder()
            setInputHelpVisible(false)
            performSearch()
        }
    }
}
