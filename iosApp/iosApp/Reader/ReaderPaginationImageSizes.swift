import UIKit
import shared

@MainActor
enum ReaderPaginationImageSizes {
    static func load(bookURL: String, layout: ReaderChapterLayout) async throws -> [String: CGSize] {
        try Task.checkCancellation()
        guard layout.normalizedImageStyle != "TEXT" else { return [:] }
        var rules: [String] = []
        var seen: Set<String> = []
        for page in layout.pages {
            try Task.checkCancellation()
            for fragment in page.fragments {
                try Task.checkCancellation()
                guard fragment.kind == .image, let rule = fragment.imageUrl, !rule.isEmpty,
                    seen.insert(rule).inserted
                else { continue }
                rules.append(rule)
            }
        }
        try Task.checkCancellation()
        guard !rules.isEmpty else { return [:] }
        let facade: BookImageFacade
        switch SharedRuntime.bookImageFacade() {
        case .success(let resolved):
            facade = resolved
        case .failure:
            try Task.checkCancellation()
            return [:]
        }
        try Task.checkCancellation()

        return try await withThrowingTaskGroup(of: (String, CGSize?).self) { group in
            var remaining = rules.makeIterator()
            for _ in 0..<min(3, rules.count) {
                try Task.checkCancellation()
                guard let rule = remaining.next() else { break }
                group.addTask { @MainActor in
                    (rule, try await loadSize(bookURL: bookURL, rule: rule, facade: facade))
                }
            }

            var sizes: [String: CGSize] = [:]
            while let (rule, size) = try await group.next() {
                try Task.checkCancellation()
                if let size { sizes[rule] = size }
                if let nextRule = remaining.next() {
                    try Task.checkCancellation()
                    group.addTask { @MainActor in
                        (nextRule, try await loadSize(bookURL: bookURL, rule: nextRule, facade: facade))
                    }
                }
            }
            try Task.checkCancellation()
            return sizes
        }
    }

    private static func loadSize(bookURL: String, rule: String, facade: BookImageFacade) async throws -> CGSize? {
        try Task.checkCancellation()
        do {
            // This callback bridge cannot cancel underlying I/O; gate its request and result instead.
            let size: ImageSize? = try await SharedAsync.optionalValue { completion in
                facade.getImageSize(bookUrl: bookURL, src: rule, completionHandler: completion)
            }
            try Task.checkCancellation()
            guard let size, size.width > 0, size.height > 0 else { return nil }
            return CGSize(width: CGFloat(size.width), height: CGFloat(size.height))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            return nil
        }
    }
}
