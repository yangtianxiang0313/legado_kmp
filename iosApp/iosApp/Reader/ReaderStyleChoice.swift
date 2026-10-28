import Foundation

/// Legado 5f5d314: TextFontWeightConverter.kt, ChineseConverter.kt, ReadStyleDialog.kt,
/// values-zh/strings.xml, values-zh/arrays.xml and values/arrays.xml.
enum ReaderStyleChoice: CaseIterable {
    case fontWeight
    case indent
    case chineseMode

    var titleText: String {
        switch self {
        case .fontWeight:
            return NSLocalizedString(
                "reader.style.choice.font_weight.title", value: "文章字重切换", comment: "Legado text_font_weight_converter")
        case .indent:
            return NSLocalizedString(
                "reader.style.choice.indent.title", value: "缩进", comment: "Legado text_indent")
        case .chineseMode:
            return NSLocalizedString(
                "reader.style.choice.chinese_mode.title", value: "中文简繁体转换", comment: "Legado chinese_converter")
        }
    }

    var items: [String] {
        switch self {
        case .fontWeight:
            return [
                NSLocalizedString("reader.style.choice.font_weight.normal", value: "正常", comment: "Legado text_font_weight index 0"),
                NSLocalizedString("reader.style.choice.font_weight.bold", value: "粗体", comment: "Legado text_font_weight index 1"),
                NSLocalizedString("reader.style.choice.font_weight.light", value: "细体", comment: "Legado text_font_weight index 2"),
            ]
        case .indent:
            return [
                NSLocalizedString("reader.style.choice.indent.none", value: "无缩进", comment: "Legado indent_0"),
                NSLocalizedString("reader.style.choice.indent.one", value: "一字符缩进", comment: "Legado indent_1"),
                NSLocalizedString("reader.style.choice.indent.two", value: "二字符缩进", comment: "Legado indent_2"),
                NSLocalizedString("reader.style.choice.indent.three", value: "三字符缩进", comment: "Legado indent_3"),
                NSLocalizedString("reader.style.choice.indent.four", value: "四字符缩进", comment: "Legado indent_4"),
            ]
        case .chineseMode:
            return [
                NSLocalizedString("reader.style.choice.chinese_mode.off", value: "关闭", comment: "Legado chinese_mode index 0"),
                NSLocalizedString("reader.style.choice.chinese_mode.simplified", value: "繁体转简体", comment: "Legado chinese_mode index 1"),
                NSLocalizedString("reader.style.choice.chinese_mode.traditional", value: "简体转繁体", comment: "Legado chinese_mode index 2"),
            ]
        }
    }
}
