import shared

enum SourceChangeBookTypePolicy {
    private static let text = BookType.shared.TEXT
    private static let image = BookType.shared.IMAGE
    private static let audio = BookType.shared.AUDIO
    private static let webFile = BookType.shared.WEB_FILE
    private static let local = BookType.shared.LOCAL
    // SearchBook.sameBookTypeLocal ignores status flags, but retains every type bit.
    private static let typeMask = text | image | audio | webFile | local
    private static let legacyTypeMask: Int32 = 0b111

    static func requiresConfirmation(candidate: BookSourceChangeCandidate, current: Book) -> Bool {
        let candidateType = comparisonType(
            candidate.bookType,
            localOrigin: BookType.shared.isLocalOrigin(origin: candidate.sourceUrl)
        )
        var currentType = comparisonType(
            current.type,
            localOrigin: BookType.shared.isLocalOrigin(origin: current.origin)
        )
        // Book.isLocal accepts legacy 0, which historical remote text rows also used.
        // comparisonType requires a local origin to add LOCAL for that ambiguous value.
        if current.isLocal && current.type != BookType.shared.LEGACY_LOCAL {
            currentType |= local
        }
        if current.isAudio { currentType |= audio }
        if current.isImage { currentType |= image }
        return candidateType != currentType
    }

    private static func comparisonType(_ rawType: Int32, localOrigin: Bool) -> Int32 {
        var result = rawType & typeMask
        if result == 0 {
            // Legacy enum values occupy the low three bits; status flags may coexist.
            // Modern type combinations must not be collapsed into one primary type.
            switch rawType & legacyTypeMask {
            case BookType.shared.LEGACY_LOCAL, BookType.shared.LEGACY_TEXT:
                result = text
            case BookType.shared.LEGACY_IMAGE:
                result = image
            case BookType.shared.LEGACY_AUDIO:
                result = audio
            case BookType.shared.LEGACY_EPUB:
                result = local | text
            case BookType.shared.LEGACY_WEB_FILE:
                result = webFile
            default:
                break
            }
        }
        if localOrigin { result |= local }
        return result
    }
}
