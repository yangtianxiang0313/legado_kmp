import UIKit

enum AppUI {
    enum Spacing {
        static let xxSmall: CGFloat = 6
        static let xSmall: CGFloat = 8
        static let small: CGFloat = 12
        static let medium: CGFloat = 16
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 24
        static let xxLarge: CGFloat = 32
    }

    enum CornerRadius {
        static let medium: CGFloat = 14
        static let large: CGFloat = 16
    }

    enum Layout {
        static let sourceRowHeight: CGFloat = 64
        static let searchRowHeight: CGFloat = 92
        static let legacyTitleBarHeight: CGFloat = 54
    }

    enum Bookshelf {
        static func formattedLatestUpdateTime(_ timestamp: Int64, now: Date = Date()) -> String {
            let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1000)
            let seconds = abs(nowMilliseconds - timestamp) / 1000
            let suffix = timestamp < nowMilliseconds ? "前" : "后"
            let value: Int64
            let unit: String
            switch seconds {
            case ..<60:
                value = seconds
                unit = "秒"
            case ..<3600:
                value = seconds / 60
                unit = "分钟"
            case ..<86400:
                value = seconds / 3600
                unit = "小时"
            case ..<604_800:
                value = seconds / 86400
                unit = "天"
            case ..<2_628_000:
                value = seconds / 604_800
                unit = "周"
            case ..<31_536_000:
                value = seconds / 2_628_000
                unit = "月"
            default:
                value = seconds / 31_536_000
                unit = "年"
            }
            return "\(value)\(unit)\(suffix)"
        }
    }

    enum ReaderAppearance {
        static let minFontSize: Float = 14
        static let maxFontSize: Float = 32
        static let minLineSpacing: Float = 1.1
        static let maxLineSpacing: Float = 2.4
        static let minHorizontalPadding: Float = 12
        static let maxHorizontalPadding: Float = 36
    }

    enum Reader {
        static let pageTurnThreshold: CGFloat = 0.3
        static let progressDebounceNanoseconds: UInt64 = 350_000_000
    }
}
