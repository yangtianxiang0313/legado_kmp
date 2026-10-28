import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import shared

enum ReaderBackgroundTextFiles {
    static func read(_ url: URL, limit: Int) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var result = Data()
        while let chunk = try file.read(upToCount: min(65_536, limit - result.count + 1)), !chunk.isEmpty {
            result.append(chunk)
            guard result.count <= limit else { throw invalidConfig }
        }
        return result
    }

    static var invalidConfig: NSError {
        NSError(domain: "io.legado.reader.background", code: 1, userInfo: [NSLocalizedDescriptionKey: "阅读配置格式无效"])
    }

    static func importImage(_ data: Data) throws -> String {
        guard data.count <= 32 * 1024 * 1024, let image = UIImage(data: data),
            image.size.width > 0, image.size.height > 0,
            let source = CGImageSourceCreateWithData(data as CFData, nil), let type = CGImageSourceGetType(source),
            let ext = UTType(type as String)?.preferredFilenameExtension
        else {
            throw NSError(domain: "io.legado.reader.background", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法读取背景图片"])
        }
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("ReaderBackgrounds", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + "." + ext
        try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
        return "legado-background-file:" + fileName
    }

    static func restoreTemplates(facade: SettingsFacade, bundle: Bundle = .main) throws -> [ReaderPreset] {
        guard let url = bundle.url(forResource: "readConfig", withExtension: "json", subdirectory: "ReaderBackgrounds") else {
            throw invalidConfig
        }
        let data = try Data(contentsOf: url)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw invalidConfig }
        let codec = ReaderPresetTransferCodec()
        return try rows.map { row in
            let normalized = try JSONSerialization.data(withJSONObject: row)
            return try codec.decode(jsonString: String(decoding: normalized, as: UTF8.self))
        }
    }
}
