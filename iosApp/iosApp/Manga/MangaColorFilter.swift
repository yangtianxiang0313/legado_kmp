import Foundation

/// RGBA pixel coefficients are (255 - value) / 255; l controls window brightness only.
struct MangaColorFilter: Codable, Equatable, Hashable, Sendable {
    var r: Int { didSet { r = Self.clamp(r) } }
    var g: Int { didSet { g = Self.clamp(g) } }
    var b: Int { didSet { b = Self.clamp(b) } }
    var a: Int { didSet { a = Self.clamp(a) } }
    var l: Int { didSet { l = Self.clamp(l) } }

    private var unknownFields: [String: JSONValue] = [:]
    private static let channelNames: Set<String> = ["r", "g", "b", "a", "l"]

    init(r: Int = 0, g: Int = 0, b: Int = 0, a: Int = 0, l: Int = 0) {
        self.r = Self.clamp(r)
        self.g = Self.clamp(g)
        self.b = Self.clamp(b)
        self.a = Self.clamp(a)
        self.l = Self.clamp(l)
    }

    init(json: String?) {
        guard let json,
            let decoded = try? JSONDecoder().decode(Self.self, from: Data(json.utf8))
        else {
            self.init()
            return
        }
        self = decoded
    }

    var identityPixel: Bool { r == 0 && g == 0 && b == 0 && a == 0 }
    var isIdentity: Bool { identityPixel && l == 0 }
    var pixelVariant: Self { Self(r: r, g: g, b: b, a: a) }

    mutating func reset() {
        r = 0
        g = 0
        b = 0
        a = 0
        l = 0
    }

    var json: String {
        guard !isIdentity || !unknownFields.isEmpty else { return "" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(
            r: Self.channel("r", in: container),
            g: Self.channel("g", in: container),
            b: Self.channel("b", in: container),
            a: Self.channel("a", in: container),
            l: Self.channel("l", in: container)
        )
        for key in container.allKeys where !Self.channelNames.contains(key.stringValue) {
            unknownFields[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(r, forKey: Key("r"))
        try container.encode(g, forKey: Key("g"))
        try container.encode(b, forKey: Key("b"))
        try container.encode(a, forKey: Key("a"))
        try container.encode(l, forKey: Key("l"))
        for (name, value) in unknownFields {
            try container.encode(value, forKey: Key(name))
        }
    }

    private static func clamp(_ value: Int) -> Int {
        min(255, max(0, value))
    }

    private static func channel(_ name: String, in container: KeyedDecodingContainer<Key>) -> Int {
        (try? container.decode(JSONValue.self, forKey: Key(name)))?.channelValue ?? 0
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    /// Decimal avoids routing large integers and precise fractions through Double.
    private enum JSONValue: Codable, Equatable, Hashable, Sendable {
        case null
        case bool(Bool)
        case number(Decimal)
        case approximateNumber(Double)
        case string(String)
        case array([JSONValue])
        case object([String: JSONValue])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() {
                self = .null
            } else if let value = try? container.decode(Bool.self) {
                self = .bool(value)
            } else if let value = try? container.decode(Decimal.self) {
                self = .number(value)
            } else if let value = try? container.decode(Double.self) {
                self = .approximateNumber(value)
            } else if let value = try? container.decode(String.self) {
                self = .string(value)
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
            case .number(let value): try container.encode(value)
            case .approximateNumber(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .object(let value): try container.encode(value)
            }
        }

        var channelValue: Int {
            switch self {
            case .number(let value):
                guard !value.isNaN, value > 0 else { return 0 }
                guard value < 255 else { return 255 }
                return NSDecimalNumber(decimal: value).intValue
            case .approximateNumber(let value):
                guard value.isFinite else { return 0 }
                return Int(min(255, max(0, value)))
            case .string(let value):
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let number = try? JSONDecoder().decode(Self.self, from: Data(text.utf8)) else {
                    return 0
                }
                switch number {
                case .number, .approximateNumber: return number.channelValue
                default: return 0
                }
            default:
                return 0
            }
        }
    }
}
