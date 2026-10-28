import CoreText
import Foundation
import UIKit

struct ReaderResolvedFont {
  let font: UIFont
  // NSAttributedString.Key.strokeWidth percentage; negative means fill + stroke.
  let strokeWidth: CGFloat
}

enum ReaderFontWeightResolver {
  private static let weightAxis = NSNumber(value: 0x7767_6874)  // wght
  private static let cache = FontCache()

  static func resolve(name: String?, size: CGFloat, weight: Int) -> ReaderResolvedFont {
    guard [300, 400, 700, 900].contains(weight) else {
      return fallback(size: safeSize(size), target: 400)
    }
    guard size.isFinite, size > 0, size <= 4096 else {
      return fallback(size: 17, target: weight)
    }
    guard let name, !name.isEmpty else {
      return fallback(size: size, target: weight)
    }
    let imported = ReaderFontStore.shared.font(for: name, size: size)
    let font: UIFont
    if let imported {
      font = imported
    } else if !name.hasPrefix("reader-font:"), let named = UIFont(name: name, size: size) {
      font = named
    } else {
      return fallback(size: size, target: weight)
    }
    // Also protect process-registered fonts requested by a legacy PostScript name.
    let sameFileOnly = imported != nil || ReaderFontStore.ownsSource(of: font)
    return cache.resolve(font: font, target: weight, sameFileOnly: sameFileOnly)
  }

  private static func safeSize(_ size: CGFloat) -> CGFloat {
    size.isFinite && size > 0 && size <= 4096 ? size : 17
  }

  private static func fallback(size: CGFloat, target: Int) -> ReaderResolvedFont {
    if let font = ReaderAndroidDefaultFont.font(size: size) {
      return cache.resolve(font: font, target: target, sameFileOnly: true)
    }
    let weight: UIFont.Weight
    switch target {
    case 300: weight = .light
    case 700: weight = .bold
    case 900: weight = .black
    default: weight = .regular
    }
    // UIKit labels are not raw weights: .black can be wght=1000, rather than 900.
    return cache.resolve(
      font: .systemFont(ofSize: size, weight: weight), target: target,
      sameFileOnly: false, nativeSystem: true)
  }

  private static func resolve(font: UIFont, target: Int, sameFileOnly: Bool, nativeSystem: Bool)
    -> ReaderResolvedFont
  {
    let base = FontState(font: font)
    if let varied = varying(
      base, target: target, sameFileOnly: sameFileOnly, nativeSystem: nativeSystem)
    {
      return resolved(varied, target: target)
    }

    var best = base
    func consider(_ font: UIFont) {
      let candidate = FontState(font: font)
      guard
        compatible(candidate, with: base, sameFileOnly: sameFileOnly, nativeSystem: nativeSystem),
        abs(candidate.weight - base.weight) > 0.01,
        candidate.font.fontName != base.font.fontName || candidate.values != base.values
      else { return }
      let distance = abs(candidate.weight - CGFloat(target))
      let bestDistance = abs(best.weight - CGFloat(target))
      let preferredTie =
        target >= 600 ? candidate.weight > best.weight : candidate.weight < best.weight
      if distance < bestDistance || (distance == bestDistance && preferredTie) {
        best = candidate
      }
    }

    let bold: CTFontSymbolicTraits = target >= 600 ? .boldTrait : []
    if let symbolic = CTFontCreateCopyWithSymbolicTraits(
      font as CTFont, font.pointSize, nil, bold, .boldTrait)
    {
      consider(symbolic as UIFont)
    }
    if nativeSystem {
      let weights: [UIFont.Weight] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
      ]
      for weight in weights {
        consider(.systemFont(ofSize: font.pointSize, weight: weight))
      }
    }
    // Family enumeration finds real light/black faces that a binary bold trait cannot select.
    for name in UIFont.fontNames(forFamilyName: font.familyName).sorted().prefix(128) {
      if name != font.fontName, let candidate = UIFont(name: name, size: font.pointSize) {
        consider(candidate)
      }
    }
    return resolved(best, target: target)
  }

  private static func resolved(_ state: FontState, target: Int) -> ReaderResolvedFont {
    let fakeBold = target >= 600 && CGFloat(target) - state.weight >= 200
    // Android 16 FreeType's framework outline embolden uses size / 34.
    // Approximate it with CoreText fill + stroke, not identical rasterization.
    let stroke: CGFloat = fakeBold ? -100.0 / 34.0 : 0
    return ReaderResolvedFont(font: state.font, strokeWidth: stroke)
  }

  private static func varying(
    _ base: FontState, target: Int, sameFileOnly: Bool, nativeSystem: Bool
  ) -> FontState? {
    guard let axis = base.axes.first(where: { $0.identifier == weightAxis }) else { return nil }
    let requested = min(max(CGFloat(target), axis.minimum), axis.maximum)
    if abs(requested - base.weight) <= 0.01 { return base }

    // Start with the actual descriptor AND effective coordinates, including width/optical size.
    let original = CTFontDescriptorCreateCopyWithAttributes(
      CTFontCopyFontDescriptor(base.font as CTFont),
      [kCTFontVariationAttribute: base.values] as CFDictionary)
    let descriptor = CTFontDescriptorCreateCopyWithVariation(original, axis.identifier, requested)
    let font =
      CTFontCreateCopyWithAttributes(base.font as CTFont, base.font.pointSize, nil, descriptor)
      as UIFont
    let candidate = FontState(font: font)
    guard compatible(candidate, with: base, sameFileOnly: sameFileOnly, nativeSystem: nativeSystem),
      candidate.source == base.source,
      candidate.axes.contains(where: { $0.identifier == weightAxis }),
      abs(candidate.weight - requested) <= 0.01,
      abs(candidate.weight - base.weight) > 0.01
    else { return nil }
    return candidate
  }

  private static func compatible(
    _ candidate: FontState, with base: FontState, sameFileOnly: Bool, nativeSystem: Bool
  ) -> Bool {
    let preserved: UIFontDescriptor.SymbolicTraits = [
      .traitItalic, .traitMonoSpace, .traitCondensed, .traitExpanded, .traitVertical,
    ]
    // Explicit variations expose the underlying SF family instead of UIKit's UI-family alias.
    let sameSystemSource = nativeSystem && base.source != nil && candidate.source == base.source
    guard candidate.font.familyName == base.font.familyName || sameSystemSource,
      candidate.font.pointSize == base.font.pointSize,
      candidate.font.fontDescriptor.symbolicTraits.intersection(preserved)
        == base.font.fontDescriptor.symbolicTraits.intersection(preserved),
      abs(candidate.width - base.width) <= 0.001,
      CTFontGetMatrix(candidate.font as CTFont) == CTFontGetMatrix(base.font as CTFont)
    else { return false }
    if sameFileOnly {
      guard let source = base.source, candidate.source == source else { return false }
    }
    for axis in base.axes where axis.identifier != weightAxis {
      guard let other = candidate.axes.first(where: { $0.identifier == axis.identifier }),
        abs(axis.value(in: base.values) - other.value(in: candidate.values)) <= 0.01
      else { return false }
    }
    return true
  }

  private static func sourceURL(_ font: UIFont) -> URL? {
    guard let url = CTFontCopyAttribute(font as CTFont, kCTFontURLAttribute) as? URL, url.isFileURL
    else {
      return nil
    }
    return url.standardizedFileURL
  }

  private struct Axis {
    let identifier: NSNumber
    let minimum: CGFloat
    let maximum: CGFloat
    let defaultValue: CGFloat

    func value(in values: [NSNumber: NSNumber]) -> CGFloat {
      guard let number = values[identifier], number.doubleValue.isFinite else {
        return defaultValue
      }
      return min(max(CGFloat(number.doubleValue), minimum), maximum)
    }
  }

  private struct FontState {
    let font: UIFont
    let source: URL?
    let axes: [Axis]
    let values: [NSNumber: NSNumber]
    let weight: CGFloat
    let width: CGFloat

    init(font: UIFont) {
      self.font = font
      source = sourceURL(font)
      let ctFont = font as CTFont
      let axes = Self.axes(ctFont)
      let values = CTFontCopyVariation(ctFont) as? [NSNumber: NSNumber] ?? [:]
      self.axes = axes
      self.values = values
      let traits = CTFontCopyTraits(ctFont) as? [String: Any] ?? [:]
      width =
        (traits[kCTFontWidthTrait as String] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
      if let axis = axes.first(where: { $0.identifier == weightAxis }) {
        weight = axis.value(in: values)
      } else if let actual = Self.tableWeight(ctFont) {
        weight = actual
      } else {
        weight = Self.estimatedWeight(
          traits, bold: font.fontDescriptor.symbolicTraits.contains(.traitBold))
      }
    }

    private static func axes(_ font: CTFont) -> [Axis] {
      let dictionaries = CTFontCopyVariationAxes(font) as? [[String: Any]] ?? []
      return dictionaries.compactMap { dictionary in
        guard let identifier = dictionary[kCTFontVariationAxisIdentifierKey as String] as? NSNumber,
          let minimum = dictionary[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber,
          let maximum = dictionary[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber,
          let defaultValue = dictionary[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber,
          minimum.doubleValue.isFinite, maximum.doubleValue.isFinite,
          defaultValue.doubleValue.isFinite,
          minimum.doubleValue <= defaultValue.doubleValue,
          defaultValue.doubleValue <= maximum.doubleValue
        else { return nil }
        return Axis(
          identifier: identifier, minimum: CGFloat(minimum.doubleValue),
          maximum: CGFloat(maximum.doubleValue), defaultValue: CGFloat(defaultValue.doubleValue))
      }
    }

    private static func tableWeight(_ font: CTFont) -> CGFloat? {
      // OS/2 usWeightClass is a big-endian UInt16 at byte offset 4, not a UIKit trait.
      guard let table = CTFontCopyTable(font, CTFontTableTag(kCTFontTableOS2), .init(rawValue: 0)),
        CFDataGetLength(table) >= 6, let bytes = CFDataGetBytePtr(table)
      else { return nil }
      let value = Int(bytes[4]) * 256 + Int(bytes[5])
      return (1...1000).contains(value) ? CGFloat(value) : nil
    }

    private static func estimatedWeight(_ traits: [String: Any], bold: Bool) -> CGFloat {
      guard let normalized = traits[kCTFontWeightTrait as String] as? NSNumber,
        normalized.doubleValue.isFinite
      else { return bold ? 700 : 400 }
      // Metadata fallback only: convert normalized traits; never use them as raw wght values.
      let weights: [(UIFont.Weight, CGFloat)] = [
        (.ultraLight, 100), (.thin, 200), (.light, 300), (.regular, 400), (.medium, 500),
        (.semibold, 600), (.bold, 700), (.heavy, 800), (.black, 900),
      ]
      let value = CGFloat(normalized.doubleValue)
      return weights.min { abs($0.0.rawValue - value) < abs($1.0.rawValue - value) }?.1 ?? 400
    }
  }

  private struct CacheKey: Hashable {
    let descriptor: UIFontDescriptor
    let variations: NSDictionary
    let size: CGFloat
    let source: URL?
    let target: Int
    let sameFileOnly: Bool
    let nativeSystem: Bool
  }

  private final class FontCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [CacheKey: ReaderResolvedFont] = [:]
    private var recency: [CacheKey] = []
    private let capacity = 128

    func resolve(font: UIFont, target: Int, sameFileOnly: Bool, nativeSystem: Bool = false)
      -> ReaderResolvedFont
    {
      let variations = CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber] ?? [:]
      let key = CacheKey(
        descriptor: font.fontDescriptor, variations: variations as NSDictionary,
        size: font.pointSize, source: sourceURL(font), target: target,
        sameFileOnly: sameFileOnly, nativeSystem: nativeSystem)
      lock.lock()
      defer { lock.unlock() }
      if let cached = entries[key] {
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
        return cached
      }
      let result = ReaderFontWeightResolver.resolve(
        font: font, target: target,
        sameFileOnly: sameFileOnly, nativeSystem: nativeSystem)
      if recency.count >= capacity {
        entries.removeValue(forKey: recency.removeFirst())
      }
      entries[key] = result
      recency.append(key)
      return result
    }
  }
}
