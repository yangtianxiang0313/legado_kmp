import Foundation

/// MangaFooterConfig / ReaderInfoBarView at Android 5f5d31404.
struct MangaFooterConfiguration: Codable, Equatable, Sendable {
    enum Orientation: Int, CaseIterable, Sendable {
        case left = 0
        case center = 1
    }

    var hideChapterLabel: Bool
    var hideChapter: Bool
    var hidePageNumberLabel: Bool
    var hidePageNumber: Bool
    var hideProgressRatioLabel: Bool
    var hideProgressRatio: Bool
    // Keep the raw integer: opening the form must not rewrite a future orientation.
    var footerOrientation: Int
    var hideFooter: Bool
    var hideChapterName: Bool

    private var unknownFields: [String: JSONValue] = [:]

    var orientation: Orientation {
        get { Orientation(rawValue: footerOrientation) ?? .left }
        set { footerOrientation = newValue.rawValue }
    }

    init(
        hideChapterLabel: Bool = false,
        hideChapter: Bool = false,
        hidePageNumberLabel: Bool = false,
        hidePageNumber: Bool = false,
        hideProgressRatioLabel: Bool = false,
        hideProgressRatio: Bool = false,
        footerOrientation: Int = Orientation.left.rawValue,
        hideFooter: Bool = false,
        hideChapterName: Bool = false
    ) {
        self.hideChapterLabel = hideChapterLabel
        self.hideChapter = hideChapter
        self.hidePageNumberLabel = hidePageNumberLabel
        self.hidePageNumber = hidePageNumber
        self.hideProgressRatioLabel = hideProgressRatioLabel
        self.hideProgressRatio = hideProgressRatio
        self.footerOrientation = footerOrientation
        self.hideFooter = hideFooter
        self.hideChapterName = hideChapterName
    }

    /// Missing/empty/invalid stored JSON uses the same default configuration as Android.
    init(json: String?) {
        guard let json, let data = json.data(using: .utf8),
            let configuration = try? JSONDecoder().decode(Self.self, from: data)
        else {
            self.init()
            return
        }
        self = configuration
    }

    var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // All stored values are JSON-decoded numbers, strings, containers, or finite scalar fields.
        guard let data = try? encoder.encode(self) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case hideChapterLabel, hideChapter, hidePageNumberLabel, hidePageNumber
        case hideProgressRatioLabel, hideProgressRatio, footerOrientation, hideFooter, hideChapterName
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hideChapterLabel = try container.decodeIfPresent(Bool.self, forKey: .hideChapterLabel) ?? false
        hideChapter = try container.decodeIfPresent(Bool.self, forKey: .hideChapter) ?? false
        hidePageNumberLabel = try container.decodeIfPresent(Bool.self, forKey: .hidePageNumberLabel) ?? false
        hidePageNumber = try container.decodeIfPresent(Bool.self, forKey: .hidePageNumber) ?? false
        hideProgressRatioLabel = try container.decodeIfPresent(Bool.self, forKey: .hideProgressRatioLabel) ?? false
        hideProgressRatio = try container.decodeIfPresent(Bool.self, forKey: .hideProgressRatio) ?? false
        footerOrientation = try container.decodeIfPresent(Int.self, forKey: .footerOrientation) ?? Orientation.left.rawValue
        hideFooter = try container.decodeIfPresent(Bool.self, forKey: .hideFooter) ?? false
        hideChapterName = try container.decodeIfPresent(Bool.self, forKey: .hideChapterName) ?? false

        let fields = try decoder.container(keyedBy: JSONKey.self)
        let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))
        for key in fields.allKeys where !knownKeys.contains(key.stringValue) {
            unknownFields[key.stringValue] = try fields.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hideChapterLabel, forKey: .hideChapterLabel)
        try container.encode(hideChapter, forKey: .hideChapter)
        try container.encode(hidePageNumberLabel, forKey: .hidePageNumberLabel)
        try container.encode(hidePageNumber, forKey: .hidePageNumber)
        try container.encode(hideProgressRatioLabel, forKey: .hideProgressRatioLabel)
        try container.encode(hideProgressRatio, forKey: .hideProgressRatio)
        try container.encode(footerOrientation, forKey: .footerOrientation)
        try container.encode(hideFooter, forKey: .hideFooter)
        try container.encode(hideChapterName, forKey: .hideChapterName)
        var fields = encoder.container(keyedBy: JSONKey.self)
        for (key, value) in unknownFields {
            try fields.encode(value, forKey: JSONKey(key))
        }
    }

    private struct JSONKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    /// Recursive structured storage preserves future objects, arrays, nulls and scalar types.
    private enum JSONValue: Codable, Equatable, Sendable {
        case null
        case bool(Bool)
        case string(String)
        case number(Decimal)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .number(value)
            } else if let value = try? container.decode([JSONValue].self) {
                self = .array(value)
            } else {
                self = .object(try container.decode([String: JSONValue].self))
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .null: try container.encodeNil()
            case .bool(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }
    }
}
