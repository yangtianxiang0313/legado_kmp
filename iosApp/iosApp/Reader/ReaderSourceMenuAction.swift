import Foundation

/// ReadMenu.kt and book_read_source.xml at Legado 5f5d314.
enum ReaderSourceMenuAction: String {
    case login = "menu_login"
    case pay = "menu_chapter_pay"
    case edit = "menu_edit_source"
    case disable = "menu_disable_source"

    var title: String {
        switch self {
        case .login: return L10n.Reader.sourceMenuLogin
        case .pay: return L10n.Reader.sourceMenuPay
        case .edit: return L10n.Reader.sourceMenuEdit
        case .disable: return L10n.Reader.sourceMenuDisable
        }
    }

    static func visibleActions(loginURL: String?, isVIP: Bool, isPaid: Bool, loginUI: String? = nil) -> [Self] {
        let hasLogin =
            !(loginURL ?? "").isEmpty || loginUI?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return (hasLogin ? [.login] : [])
            + (hasLogin && isVIP && !isPaid ? [.pay] : [])
            + [.edit, .disable]
    }
}
