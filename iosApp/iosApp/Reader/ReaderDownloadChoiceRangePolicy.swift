import Foundation

/// BaseReadBookActivity.showDownloadDialog at Legado 5f5d314.
/// The UI is one-based; only the start value 0 (including empty input) denotes the first chapter.
struct ReaderDownloadChoiceRangePolicy {
    enum Field: Hashable {
        case start
        case end

        var title: String {
            switch self {
            case .start:
                return NSLocalizedString(
                    "reader.download.choice.start", value: "开始", comment: "Legado start")
            case .end:
                return NSLocalizedString(
                    "reader.download.choice.end", value: "结束", comment: "Legado end")
            }
        }
    }

    enum ValidationError: Error {
        case noChapters
        case invalidNumber(Field)
        case outsideChapterCount(Field, Int)
        case reversedRange

        var field: Field? {
            switch self {
            case .invalidNumber(let field), .outsideChapterCount(let field, _): return field
            case .noChapters, .reversedRange: return nil
            }
        }

        var message: String {
            switch self {
            case .noChapters:
                return NSLocalizedString(
                    "reader.download.choice.empty", value: "当前没有可下载的章节",
                    comment: "Empty download catalog")
            case .invalidNumber(let field):
                return String(
                    format: NSLocalizedString(
                        "reader.download.choice.invalid_number", value: "%@章节只能输入最多 5 位数字，可留空",
                        comment: "Invalid download chapter number"), field.title)
            case .outsideChapterCount(let field, let count):
                return String(
                    format: NSLocalizedString(
                        "reader.download.choice.outside_catalog", value: "%@章节超出有效范围，当前共 %@ 章",
                        comment: "Download chapter outside catalog"), field.title, String(count))
            case .reversedRange:
                return NSLocalizedString(
                    "reader.download.choice.reversed", value: "开始章节不能大于结束章节",
                    comment: "Reversed download range")
            }
        }
    }

    static let maximumInputDigits = 5

    let chapterCount: Int
    let initialStartText: String
    var initialEndText: String { String(chapterCount) }

    init(currentChapterIndex: Int, chapterCount: Int) {
        self.chapterCount = chapterCount
        // Preserve the exact default instead of overflowing or truncating it to a different chapter.
        if currentChapterIndex == Int.max {
            initialStartText = String(UInt(currentChapterIndex) + 1)
        } else {
            initialStartText = String(currentChapterIndex + 1)
        }
    }

    static func acceptsInput(_ text: String) -> Bool {
        text.utf8.count <= maximumInputDigits && text.utf8.allSatisfy { (48...57).contains($0) }
    }

    func resolve(startText: String, endText: String) -> Result<ClosedRange<Int>, ValidationError> {
        guard chapterCount > 0 else { return .failure(.noChapters) }
        guard Self.acceptsInput(startText), let start = startText.isEmpty ? 0 : Int(startText) else {
            return .failure(.invalidNumber(.start))
        }
        guard Self.acceptsInput(endText), let end = endText.isEmpty ? chapterCount : Int(endText) else {
            return .failure(.invalidNumber(.end))
        }
        guard start <= chapterCount else { return .failure(.outsideChapterCount(.start, chapterCount)) }
        guard end > 0, end <= chapterCount else {
            return .failure(.outsideChapterCount(.end, chapterCount))
        }
        // Reject before normalization: clamping a reversed range could download an unrelated chapter.
        guard start <= end else { return .failure(.reversedRange) }
        let startIndex = start == 0 ? 0 : start - 1
        return .success(startIndex...(end - 1))
    }
}
