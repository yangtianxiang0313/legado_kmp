// Palette/shade behavior adapted from Jared Rummler's colorpicker 1.1.0.
// Copyright (C) 2017 Jared Rummler
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy at http://www.apache.org/licenses/LICENSE-2.0
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

/// Pure 0xAARRGGBB operations; deliberately independent of UIKit and display traits.
/// Source: ColorPickerDialog.loadPresets/getColorShades/shadeColor and ColorPaletteAdapter.
enum ReaderColorPalette {
    typealias ARGB = UInt32

    enum SwatchKind {
        case preset
        case shade
    }

    static let materialColors: [ARGB] = [
        0xFFF4_4336, 0xFFE9_1E63, 0xFFFF_2C93, 0xFF9C_27B0, 0xFF67_3AB7,
        0xFF3F_51B5, 0xFF21_96F3, 0xFF03_A9F4, 0xFF00_BCD4, 0xFF00_9688,
        0xFF4C_AF50, 0xFF8B_C34A, 0xFFCD_DC39, 0xFFFF_EB3B, 0xFFFF_C107,
        0xFFFF_9800, 0xFF79_5548, 0xFF60_7D8B, 0xFF9E_9E9E,
    ]

    static let shadePercentages: [Double] = [
        0.9, 0.7, 0.5, 0.333, 0.166,
        -0.125, -0.25, -0.375, -0.5, -0.675, -0.7, -0.775,
    ]

    static let alphaThreshold: ARGB = 165

    /// First prepend current, then a distinct initial color, without moving existing entries.
    /// Initial retains its own alpha; Material entries and conditional black use current alpha.
    static func loadPresets(initialColor: ARGB, color: ARGB) -> [ARGB] {
        let alpha = color & 0xFF00_0000
        var presets = materialColors.map { alpha | ($0 & 0x00FF_FFFF) }
        if !presets.contains(color) {
            presets.insert(color, at: 0)
        }
        if initialColor != color, !presets.contains(initialColor) {
            presets.insert(initialColor, at: 0)
        }
        if presets.count == materialColors.count, !presets.contains(alpha) {
            presets.append(alpha)
        }
        return presets
    }

    /// The original twelve shades, in source order, all preserving the base alpha.
    static func getColorShades(_ color: ARGB) -> [ARGB] {
        shadePercentages.map { shadeColor(color, percent: $0) }
    }

    /// Percent is in -1...1. Java Math.round rounds half toward positive infinity,
    /// including negative channel deltas; Swift's default rounded() is not equivalent.
    static func shadeColor(_ color: ARGB, percent: Double) -> ARGB {
        precondition(percent.isFinite && (-1.0...1.0).contains(percent))
        let target = percent < 0 ? 0.0 : 255.0
        let amount = abs(percent)
        func channel(_ shift: ARGB) -> ARGB {
            let original = Double((color >> shift) & 0xFF)
            return ARGB(floor((target - original) * amount + 0.5) + original)
        }
        return (color & 0xFF00_0000) | (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    /// AndroidX ColorUtils.calculateLuminance: sRGB relative luminance, ignoring alpha.
    static func relativeLuminance(_ color: ARGB) -> Double {
        func linearChannel(_ shift: ARGB) -> Double {
            let channel = Double((color >> shift) & 0xFF) / 255.0
            return channel < 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearChannel(16) + 0.7152 * linearChannel(8) + 0.0722 * linearChannel(0)
    }

    /// Presets with alpha 166...254 always use white, unlike shade checkmarks.
    static func usesDarkCheckmark(for color: ARGB, kind: SwatchKind) -> Bool {
        let alpha = color >> 24
        switch kind {
        case .preset:
            if alpha != 255 { return alpha <= alphaThreshold }
            return relativeLuminance(color) >= 0.65
        case .shade:
            return relativeLuminance(color) >= 0.65 || alpha <= alphaThreshold
        }
    }

    /// nil means the theme's secondary-text border; shades keep that original border.
    static func borderColor(for color: ARGB, kind: SwatchKind) -> ARGB? {
        switch kind {
        case .preset:
            return color >> 24 <= alphaThreshold ? color | 0xFF00_0000 : nil
        case .shade:
            return nil
        }
    }

    /// Explicit eight-digit ARGB for transparency, six-digit RGB for opaque colors.
    static func hexString(for color: ARGB) -> String {
        color >> 24 == 255
            ? String(format: "#%06X", color & 0x00FF_FFFF)
            : String(format: "#%08X", color)
    }
}
