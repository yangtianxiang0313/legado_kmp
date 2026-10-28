import Foundation
import mamba

/// Rewrites a complete playlist without selecting variants or changing its timeline.
/// `baseURL` must be the remote response's final URL, after validated redirects.
/// The caller owns relay registration, HTTP methods, headers, redirects and cancellation.
enum HLSPlaylistRewriter {
    enum Failure: Swift.Error, LocalizedError {
        case playlistTooLarge
        case tooManyTags
        case invalidText
        case unsupportedSyntax
        case malformedPlaylist
        case unsupportedResourceTag
        case unsupportedEncryption
        case invalidRemoteURL
        case insecureRemoteURL
        case invalidRelayURL
        case parseFailed
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .playlistTooLarge: return "播放列表过大"
            case .tooManyTags: return "播放列表条目过多"
            case .invalidText: return "播放列表编码无效"
            case .unsupportedSyntax: return "暂不支持此播放列表格式"
            case .malformedPlaylist: return "播放列表格式错误"
            case .unsupportedResourceTag: return "暂不支持此播放资源"
            case .unsupportedEncryption: return "不支持此加密方式或受保护内容"
            case .invalidRemoteURL: return "播放资源地址无效"
            case .insecureRemoteURL: return "已阻止不安全的资源连接"
            case .invalidRelayURL: return "本地播放资源注册失败"
            case .parseFailed: return "播放列表解析失败"
            case .writeFailed: return "播放列表转换失败"
            }
        }
    }

    private static let maximumBytes = 2 * 1024 * 1024
    private static let maximumTags = 20_000
    private static let maximumURLBytes = 8 * 1024
    // Bounds the work of Mamba 2.4.0's character-by-character attribute parser.
    private static let maximumLineBytes = 64 * 1024

    /// `register` is nonescaping and runs synchronously on the caller's executor.
    /// It must return stable, package-owned loopback routes, never redirect routes.
    /// Failed rewrites can leave registrations behind; their lifetime belongs to the caller.
    static func rewrite(
        _ data: Data,
        baseURL: URL,
        register: (URL) throws -> URL
    ) throws -> Data {
        let input = try framedInput(data)
        let finalURL = baseURL.absoluteURL
        _ = try httpComponents(finalURL, failure: .invalidRemoteURL)

        // Own a snapshot: MambaStringRef must never point into caller-mutable NSData.
        let snapshot = data.withUnsafeBytes { Data($0) }
        // Mamba's convenience classifier omits I-frame-only masters. Use its public
        // model constructor, still parsing every line and attribute through Mamba.
        let resultBox = ParseResultBox()
        PlaylistParser().parse(
            playlistData: snapshot,
            customData: finalURL,
            playlistConstructor: { parsed, url, registry, storage in
                switch parsed {
                case .failure(let error):
                    return .parseError(error)
                case .success(let tags):
                    let master = tags.contains {
                        $0.tagDescriptor == PantosTag.EXT_X_STREAM_INF || $0.tagDescriptor == PantosTag.EXT_X_MEDIA
                            || $0.tagDescriptor == PantosTag.EXT_X_I_FRAME_STREAM_INF
                    }
                    let media = tags.contains {
                        $0.tagDescriptor == PantosTag.EXTINF || $0.tagDescriptor == PantosTag.EXT_X_TARGETDURATION
                    }
                    guard !(master && media) else { return .parseError(.unexpectedPlaylistType) }
                    if master {
                        return .parsedMaster(
                            MasterPlaylist(
                                url: url, tags: tags, registeredPlaylistTags: registry,
                                playlistMemoryStorage: storage
                            ))
                    }
                    if media {
                        return .parsedVariant(
                            VariantPlaylist(
                                url: url, tags: tags, registeredPlaylistTags: registry,
                                playlistMemoryStorage: storage
                            ))
                    }
                    return .parseError(.unableToDeterminePlaylistType)
                }
            },
            resultCallback: { resultBox.complete($0) }
        )
        let result = resultBox.wait()
        switch result {
        case .parsedMaster(let playlist):
            return try rewritePlaylist(playlist, input: input, baseURL: finalURL, register: register)
        case .parsedVariant(let playlist):
            return try rewritePlaylist(playlist, input: input, baseURL: finalURL, register: register)
        case .parseError:
            // Mamba's errors can embed signed URLs or key bodies. Do not propagate them.
            throw Failure.parseFailed
        }
    }

    private struct FramedInput {
        let canonical: Data
        let lineCount: Int
    }

    /// Avoid Mamba's synchronous timeout helper, which reads a concurrently captured mutable result.
    private final class ParseResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var result: ParserResult?

        func complete(_ value: ParserResult) {
            lock.lock()
            let first = result == nil
            if first { result = value }
            lock.unlock()
            if first { semaphore.signal() }
        }

        func wait() -> ParserResult {
            guard semaphore.wait(timeout: .now() + 1) == .success else { return .parseError(.timedOut) }
            lock.lock()
            defer { lock.unlock() }
            return result ?? .parseError(.timedOut)
        }
    }

    private struct Reference {
        let tagIndex: Int
        let attribute: String?
        let rawValue: String
        let url: URL
    }

    private struct Replacement {
        let attribute: String?
        let value: String
    }

    private struct Attribute {
        let text: String
        let isQuoted: Bool
    }

    private struct RelayOrigin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }

    // This checks framing only. Tag and attribute parsing is exclusively Mamba's job.
    private static func framedInput(_ data: Data) throws -> FramedInput {
        guard data.count <= maximumBytes else { throw Failure.playlistTooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalidText }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard
            !normalized.unicodeScalars.contains(where: {
                ($0.value < 0x20 && $0.value != 0x0A && $0.value != 0x09) || (0x7F...0x9F).contains($0.value)
                    || $0.value == 0xFEFF
                    || $0.value == 0x2028 || $0.value == 0x2029
            })
        else { throw Failure.invalidText }
        guard normalized == "#EXTM3U" || normalized.hasPrefix("#EXTM3U\n") else {
            throw Failure.malformedPlaylist
        }

        var lines = [Substring]()
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.utf8.count <= maximumLineBytes else { throw Failure.unsupportedSyntax }
            guard lines.count < maximumTags else { throw Failure.tooManyTags }
            lines.append(line)
        }
        return FramedInput(
            canonical: Data((lines.joined(separator: "\n") + "\n").utf8),
            lineCount: lines.count
        )
    }

    private static func rewritePlaylist<P: PlaylistInterface>(
        _ original: P,
        input: FramedInput,
        baseURL: URL,
        register: (URL) throws -> URL
    ) throws -> Data {
        // All tags, string refs and the edited copy stay inside this lifetime.
        try withExtendedLifetime(original) {
            let writer = PlaylistWriter(suppressMambaIdentityString: true)
            let tags = original.tags
            guard tags.count + 1 == input.lineCount else { throw Failure.unsupportedSyntax }
            guard try write(original, using: writer) == input.canonical else {
                throw Failure.unsupportedSyntax
            }

            // Validate the entire model before invoking the caller's registration closure.
            var references = [Reference]()
            for (index, tag) in tags.enumerated() {
                if let reference = try inspect(tag, index: index, baseURL: baseURL) {
                    references.append(reference)
                }
            }

            var registered = [String: String]()
            var relayRoutes = [String: String]()
            var origin: RelayOrigin?
            var replacements = [Int: Replacement]()
            var outputBytes = input.canonical.count
            for reference in references {
                let remote = reference.url.absoluteString
                let local: String
                if let existing = registered[remote] {
                    local = existing
                } else {
                    // Do not call register inside transform: Mamba dispatches it on its own queue.
                    let route = try register(reference.url)
                    let routeOrigin = try relayOrigin(route)
                    if let origin = origin, origin != routeOrigin { throw Failure.invalidRelayURL }
                    origin = routeOrigin
                    local = route.absoluteString
                    if let existing = relayRoutes[local], existing != remote {
                        throw Failure.invalidRelayURL
                    }
                    registered[remote] = local
                    relayRoutes[local] = remote
                }

                // A repeated remote URL MUST keep the same local URI for implicit BYTERANGE offsets.
                outputBytes += local.utf8.count - reference.rawValue.utf8.count
                guard outputBytes <= maximumBytes else { throw Failure.playlistTooLarge }
                replacements[reference.tagIndex] = Replacement(attribute: reference.attribute, value: local)
            }

            var edited = original
            var index = 0
            try edited.transform { tag in
                defer { index += 1 }
                guard let replacement = replacements[index] else { return tag }
                if let attribute = replacement.attribute {
                    var result = tag
                    result.set(value: replacement.value, forKey: attribute, shouldBeQuoteEscaped: true)
                    return result
                }
                // Location tags have no tagName. The stringTagData initializer is not suitable.
                return PlaylistTag(tagDescriptor: PantosTag.Location, tagData: .init(string: replacement.value))
            }
            let output = try write(edited, using: writer)
            guard output.count == outputBytes, output.count <= maximumBytes else {
                throw Failure.writeFailed
            }
            // The returned buffer owns its bytes, independently of every Mamba object.
            return output.withUnsafeBytes { Data($0) }
        }
    }

    private static func write<P: PlaylistInterface>(_ playlist: P, using writer: PlaylistWriter) throws -> Data {
        do {
            let result: Data = try writer.write(playlist: playlist)
            return result
        } catch {
            throw Failure.writeFailed
        }
    }

    private static func inspect(_ tag: PlaylistTag, index: Int, baseURL: URL) throws -> Reference? {
        let body = tag.tagData.stringValue()
        if tag.tagDescriptor == PantosTag.Comment {
            // Never treat a possibly meaningful EXT tag misclassified by Mamba as a comment.
            guard !body.uppercased().hasPrefix("#EXT") else { throw Failure.unsupportedSyntax }
            return nil
        }
        guard !body.contains("{$") else { throw Failure.unsupportedSyntax }
        if tag.tagDescriptor == PantosTag.Location {
            return Reference(tagIndex: index, attribute: nil, rawValue: body, url: try resolve(body, baseURL: baseURL))
        }
        guard let name = tag.tagName?.stringValue(), validTagName(name) else {
            throw Failure.unsupportedSyntax
        }
        guard !unsupportedResourceTags.contains(name) else { throw Failure.unsupportedResourceTag }

        if tag.tagDescriptor == PantosTag.UnknownTag {
            try inspectUnknown(name: name, body: body)
            return nil
        }
        guard tag.tagDescriptor != PantosTag.EXTM3U else { throw Failure.malformedPlaylist }
        guard tag.tagDescriptor.type() == .keyValue else { return nil }

        let attributes = try validateAttributes(tag)
        let uriRequired: Bool
        let uriAllowed: Bool
        switch tag.tagDescriptor {
        case PantosTag.EXT_X_KEY, PantosTag.EXT_X_SESSION_KEY:
            try validateKey(tag, attributes: attributes, session: tag.tagDescriptor == PantosTag.EXT_X_SESSION_KEY)
            uriRequired = tag.value(forKey: "METHOD") == "AES-128"
            uriAllowed = uriRequired
        case PantosTag.EXT_X_MAP, PantosTag.EXT_X_I_FRAME_STREAM_INF:
            uriRequired = true
            uriAllowed = true
        case PantosTag.EXT_X_MEDIA:
            uriRequired = tag.value(forKey: "TYPE") == "SUBTITLES"
            uriAllowed = tag.value(forKey: "TYPE") != "CLOSED-CAPTIONS"
        case PantosTag.EXT_X_SESSION_DATA:
            let hasURI = tag.value(forKey: "URI") != nil
            let hasValue = tag.value(forKey: "VALUE") != nil
            guard hasURI != hasValue else { throw Failure.malformedPlaylist }
            uriRequired = hasURI
            uriAllowed = true
        default:
            uriRequired = false
            uriAllowed = false
        }

        if tag.tagDescriptor == PantosTag.EXT_X_DATERANGE,
            tag.value(forKey: "CLASS")?.lowercased() == "com.apple.hls.interstitial"
        {
            throw Failure.unsupportedResourceTag
        }
        for key in tag.keys {
            if key == "URI", uriAllowed { continue }
            if ["METHOD", "IV", "KEYFORMAT", "KEYFORMATVERSIONS"].contains(key),
                (tag.tagDescriptor == PantosTag.EXT_X_KEY || tag.tagDescriptor == PantosTag.EXT_X_SESSION_KEY)
            {
                continue
            }
            if key == "ALLOWED-CPC" { throw Failure.unsupportedEncryption }
            if standardAttributes.contains(key) { continue }
            guard !resourceIndicator(key) else { throw Failure.unsupportedResourceTag }
            // Unknown extensions to a known tag must not smuggle a new resource field.
            if let value = tag.value(forKey: key), !inertValue(value) {
                throw Failure.unsupportedResourceTag
            }
        }

        guard let raw = tag.value(forKey: "URI") else {
            if uriRequired { throw Failure.malformedPlaylist }
            return nil
        }
        guard uriAllowed, attributes["URI"]?.isQuoted == true else {
            throw Failure.unsupportedResourceTag
        }
        return Reference(tagIndex: index, attribute: "URI", rawValue: raw, url: try resolve(raw, baseURL: baseURL))
    }

    private static func validateKey(_ tag: PlaylistTag, attributes: [String: Attribute], session: Bool) throws {
        let allowed: Set<String> = ["METHOD", "URI", "IV", "KEYFORMAT", "KEYFORMATVERSIONS"]
        guard tag.keys.allSatisfy({ allowed.contains($0) }),
            attributes["METHOD"]?.isQuoted == false,
            let method = tag.value(forKey: "METHOD")
        else {
            throw Failure.unsupportedEncryption
        }
        if method == "NONE" {
            guard !session, tag.keys.count == 1 else { throw Failure.unsupportedEncryption }
            return
        }
        guard method == "AES-128" else { throw Failure.unsupportedEncryption }
        if let format = tag.value(forKey: "KEYFORMAT") {
            guard format == "identity", attributes["KEYFORMAT"]?.isQuoted == true else {
                throw Failure.unsupportedEncryption
            }
        }
        if let versions = tag.value(forKey: "KEYFORMATVERSIONS") {
            guard versions == "1", attributes["KEYFORMATVERSIONS"]?.isQuoted == true else {
                throw Failure.unsupportedEncryption
            }
        }
        if let iv = tag.value(forKey: "IV") {
            let digits = iv.dropFirst(2)
            guard attributes["IV"]?.isQuoted == false,
                iv.hasPrefix("0x") || iv.hasPrefix("0X"),
                !digits.isEmpty, digits.utf8.count <= 32,
                digits.utf8.allSatisfy({ isHex($0) })
            else {
                throw Failure.unsupportedEncryption
            }
        }
    }

    // Mamba 2.4.0 tolerates duplicate keys, unmatched quotes and surrounding spaces.
    // Reconstitute its tokens without normalization and require an exact match, so
    // AVPlayer and Mamba cannot disagree about which URI / METHOD / KEYFORMAT wins.
    private static func validateAttributes(_ tag: PlaylistTag) throws -> [String: Attribute] {
        guard !tag.keys.isEmpty else { throw Failure.unsupportedSyntax }
        var pairs = [String]()
        var attributes = [String: Attribute]()
        for key in tag.keys {
            guard !key.isEmpty, key.utf8.allSatisfy({ isUppercaseToken($0) }),
                let text: String = tag.value(forKey: key), let storage = tag.valueData(forKey: key),
                !text.contains("\""), !text.contains("{$")
            else {
                throw Failure.unsupportedSyntax
            }
            let quoted = try isQuoted(storage, key: key, text: text)
            if !quoted {
                guard !text.isEmpty,
                    !text.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
                    !text.contains(","), !text.contains("=")
                else {
                    throw Failure.unsupportedSyntax
                }
            }
            pairs.append(key + "=" + (quoted ? "\"" + text + "\"" : text))
            attributes[key] = Attribute(text: text, isQuoted: quoted)
        }
        guard pairs.joined(separator: ",").utf8.elementsEqual(tag.tagData.stringValue().utf8) else {
            throw Failure.unsupportedSyntax
        }
        return attributes
    }

    // Mamba 2.4.0 exposes the value data as an opaque public struct. Let its public
    // writer reveal quoting, without accessing internal fields or parsing raw HLS.
    private static func isQuoted(_ storage: PlaylistTagValueData, key: String, text: String) throws -> Bool {
        let single = PlaylistTag(tagDescriptor: PantosTag.EXT_X_DATERANGE, parsedValues: [key: storage])
        let stream = OutputStream.toMemory()
        stream.open()
        defer { stream.close() }
        do {
            try GenericDictionaryTagWriter().write(tag: single, toStream: stream)
        } catch {
            throw Failure.writeFailed
        }
        guard stream.streamError == nil,
            let encoded = stream.property(forKey: .dataWrittenToMemoryStreamKey) as? Data
        else {
            throw Failure.writeFailed
        }
        let prefix = "#EXT-X-DATERANGE:" + key + "="
        if encoded == Data((prefix + "\"" + text + "\"").utf8) { return true }
        guard encoded == Data((prefix + text).utf8) else { throw Failure.unsupportedSyntax }
        return false
    }

    private static func inspectUnknown(name: String, body: String) throws {
        guard !resourceIndicator(name) else { throw Failure.unsupportedResourceTag }
        guard !body.isEmpty else { return }
        if body.contains("=") {
            let dictionary: PlaylistTagDictionary
            do {
                dictionary = try GenericDictionaryTagParser(tag: PantosTag.UnknownTag).parseTag(fromTagString: body)
            } catch {
                throw Failure.unsupportedSyntax
            }
            let parsed = PlaylistTag(
                tagDescriptor: PantosTag.EXT_X_DATERANGE, stringTagData: body, parsedValues: dictionary
            )
            let attributes = try validateAttributes(parsed)
            for (key, attribute) in attributes {
                guard !resourceIndicator(key), inertValue(attribute.text) else {
                    throw Failure.unsupportedResourceTag
                }
            }
        } else {
            guard inertValue(body) else { throw Failure.unsupportedResourceTag }
        }
    }

    // Unknown metadata may contain scalar numbers or plain words, not paths, URI
    // schemes, dotted filenames, templates, JSON or opaque resource-bearing syntax.
    private static func inertValue(_ value: String) -> Bool {
        if value.isEmpty { return true }
        if value.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil { return true }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == " "
        }
    }

    private static func resourceIndicator(_ name: String) -> Bool {
        let upper = name.uppercased()
        return [
            "URI", "URL", "HREF", "SRC", "SOURCE", "RESOURCE", "ASSET", "MANIFEST",
            "PLAYLIST", "LOCATION", "STEERING", "DEFINE", "IMPORT", "TEMPLATE",
            "LICENSE", "FAIRPLAY", "DRM", "KEY", "PATH", "LINK",
        ].contains(where: { upper.contains($0) })
    }

    private static let unsupportedResourceTags: Set<String> = [
        "#EXT-X-DEFINE", "#EXT-X-CONTENT-STEERING", "#EXT-X-PART",
        "#EXT-X-PRELOAD-HINT", "#EXT-X-RENDITION-REPORT", "#EXT-X-IMAGE-STREAM-INF",
        "#EXT-X-TILES", "#EXT-X-SESSION-URL", "#EXT-X-SESSION-URI",
    ]

    private static let standardAttributes: Set<String> = [
        "TYPE", "GROUP-ID", "LANGUAGE", "ASSOC-LANGUAGE", "NAME", "DEFAULT", "AUTOSELECT",
        "FORCED", "INSTREAM-ID", "CHARACTERISTICS", "CHANNELS", "STABLE-RENDITION-ID",
        "BIT-DEPTH", "SAMPLE-RATE", "BANDWIDTH", "AVERAGE-BANDWIDTH", "SCORE", "PROGRAM-ID",
        "CODECS", "SUPPLEMENTAL-CODECS", "RESOLUTION", "FRAME-RATE", "HDCP-LEVEL", "VIDEO-RANGE",
        "REQ-VIDEO-LAYOUT", "STABLE-VARIANT-ID", "PATHWAY-ID", "AUDIO", "VIDEO", "SUBTITLES", "CLOSED-CAPTIONS",
        "DATA-ID", "VALUE", "BYTERANGE", "TIME-OFFSET", "PRECISE", "ID", "CLASS", "START-DATE",
        "END-DATE", "DURATION", "PLANNED-DURATION", "END-ON-NEXT", "SCTE35-CMD", "SCTE35-OUT",
        "SCTE35-IN", "SKIPPED-SEGMENTS", "RECENTLY-REMOVED-DATERANGES",
    ]

    private static func resolve(_ raw: String, baseURL: URL) throws -> URL {
        try validateURLText(raw, failure: .invalidRemoteURL)
        guard let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL else {
            throw Failure.invalidRemoteURL
        }
        let components = try httpComponents(resolved, failure: .invalidRemoteURL)
        if baseURL.scheme?.lowercased() == "https", components.scheme?.lowercased() != "https" {
            throw Failure.insecureRemoteURL
        }
        return resolved
    }

    private static func httpComponents(_ url: URL, failure: Failure) throws -> URLComponents {
        try validateURLText(url.absoluteString, failure: failure)
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = components.host, !host.isEmpty,
            components.user == nil, components.password == nil, components.fragment == nil,
            components.percentEncodedHost?.contains("%") == false
        else { throw failure }
        if let port = components.port, !(1...65535).contains(port) { throw failure }
        return components
    }

    private static func relayOrigin(_ url: URL) throws -> RelayOrigin {
        guard url.baseURL == nil else { throw Failure.invalidRelayURL }
        let components = try httpComponents(url, failure: .invalidRelayURL)
        guard let host = components.host?.lowercased(),
            ["127.0.0.1", "[::1]", "::1"].contains(host),
            let port = components.port, !components.path.isEmpty, components.path != "/"
        else {
            throw Failure.invalidRelayURL
        }
        return RelayOrigin(scheme: components.scheme!.lowercased(), host: host, port: port)
    }

    private static func validateURLText(_ raw: String, failure: Failure) throws {
        guard !raw.isEmpty, raw.utf8.count <= maximumURLBytes,
            !raw.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
                    || ["\\", "\"", "<", ">", "`", "{", "}"].contains(String($0))
            }), let decoded = raw.removingPercentEncoding,
            !decoded.contains("{$"), !decoded.contains("\\"),
            !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw failure
        }
    }

    private static func validTagName(_ name: String) -> Bool {
        name.hasPrefix("#EXT") && name.dropFirst().utf8.allSatisfy { isUppercaseToken($0) }
    }

    private static func isUppercaseToken(_ value: UInt8) -> Bool {
        (65...90).contains(value) || (48...57).contains(value) || value == 45
    }

    private static func isHex(_ value: UInt8) -> Bool {
        (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value)
    }
}
