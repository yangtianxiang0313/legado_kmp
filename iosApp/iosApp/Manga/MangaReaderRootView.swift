import UIKit

@MainActor
final class MangaReaderRootView: UIView {
    init(
        collection: UICollectionView, chrome: MangaReaderChrome,
        state: MangaReaderStateView, catalogState: MangaReaderStateView
    ) {
        super.init(frame: .zero)
        backgroundColor = .black
        for child in [collection, state, catalogState, chrome] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            collection.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            collection.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            chrome.leadingAnchor.constraint(equalTo: collection.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: collection.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: collection.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: collection.bottomAnchor),
        ])
        for child in [state, catalogState] {
            NSLayoutConstraint.activate([
                child.leadingAnchor.constraint(equalTo: collection.leadingAnchor),
                child.trailingAnchor.constraint(equalTo: collection.trailingAnchor),
                child.topAnchor.constraint(equalTo: collection.topAnchor),
                child.bottomAnchor.constraint(equalTo: collection.bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { preconditionFailure("init(coder:) is unavailable") }
}
