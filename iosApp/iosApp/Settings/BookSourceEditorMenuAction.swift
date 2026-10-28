import Foundation

/// source_edit.xml order at Android 5f5d314; dormant iOS commands do not add primary entries.
enum BookSourceEditorMenuAction: String {
    case login = "menu_login"
    case search = "menu_search"
    case clearCookie = "menu_clear_cookie"
    case autoComplete = "menu_auto_complete"
    case copy = "menu_copy_source"
    case paste = "menu_paste_source"
    case sourceVariable = "menu_set_source_variable"
    case scanQR = "menu_qr_code_camera"
    case shareQR = "menu_share_qr"
    case shareString = "menu_share_str"
    case help = "menu_help"
    case variableHelp = "sourceEdit.variableHelp"
    case review = "sourceEdit.review"

    static func visibleActions(hasLogin: Bool) -> [Self] {
        (hasLogin ? [.login] : []) + [
            .search, .clearCookie, .autoComplete, .copy, .paste,
            .sourceVariable, .scanQR, .shareQR, .shareString, .help,
        ]
    }

    var title: String {
        switch self {
        case .login: return L10n.SourceEdit.loginAction
        case .search: return "搜索"
        case .clearCookie: return "清除 Cookie"
        case .autoComplete: return "自动补全"
        case .copy: return L10n.SourceEdit.copyAction
        case .paste: return L10n.SourceEdit.pasteAction
        case .sourceVariable: return "设置源变量"
        case .scanQR: return "二维码导入"
        case .shareQR: return L10n.SourceEdit.qrShareAction
        case .shareString: return "字符串分享"
        case .help: return "帮助"
        case .variableHelp: return L10n.SourceEdit.variableHelpAction
        case .review: return L10n.SourceEdit.ruleReviewTitle
        }
    }
}
