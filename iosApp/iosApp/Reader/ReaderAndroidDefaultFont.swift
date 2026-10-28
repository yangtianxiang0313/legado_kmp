import CoreText
import UIKit

enum ReaderAndroidDefaultFont {
    private static let weightAxis = NSNumber(value: 0x7767_6874)
    private static let widthAxis = NSNumber(value: 0x7764_7468)
    private static let italicAxis = NSNumber(value: 0x6974_616C)
    private static let url = Bundle.main.url(forResource: "ReaderAndroidDefault", withExtension: "ttf")

    private static let descriptor: CTFontDescriptor? = {
        guard let url,
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
            let original = descriptors.first
        else { return nil }
        // The first named instance is Thin; Android's sans-serif default is 400/100/upright.
        return CTFontDescriptorCreateCopyWithAttributes(
            original,
            [kCTFontVariationAttribute: [weightAxis: 400, widthAxis: 100, italicAxis: 0]] as CFDictionary)
    }()

    static func font(size: CGFloat, weight: Int = 400) -> UIFont? {
        guard size.isFinite, size > 0, size <= 4096, (100...900).contains(weight),
            let descriptor, let url
        else { return nil }
        let weighted =
            weight == 400
            ? descriptor
            : CTFontDescriptorCreateCopyWithVariation(
                descriptor, weightAxis, CGFloat(weight))
        let font = CTFontCreateWithFontDescriptor(weighted, size, nil)
        guard let source = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL,
            source.standardizedFileURL == url.standardizedFileURL
        else { return nil }
        return font as UIFont
    }

    static func scaledFont(
        size: CGFloat, textStyle: UIFont.TextStyle, weight: Int = 400, compatibleWith traits: UITraitCollection
    ) -> UIFont {
        // Scaling a variable UIFont can substitute its face; scale the size before reopening the asset.
        let scaledSize = UIFontMetrics(forTextStyle: textStyle).scaledValue(for: size, compatibleWith: traits)
        let fallback: UIFont.Weight = weight >= 700 ? .bold : (weight >= 500 ? .medium : .regular)
        return font(size: scaledSize, weight: weight) ?? .systemFont(ofSize: scaledSize, weight: fallback)
    }
}
