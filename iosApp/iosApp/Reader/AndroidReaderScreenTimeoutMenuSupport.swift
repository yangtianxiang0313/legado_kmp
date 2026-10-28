import Foundation

enum ReaderScreenTimeoutMenuSupport {
    static func title(_ timeout: ReaderScreenTimeout) -> String {
        switch timeout {
        case .system: return L10n.Reader.screenTimeoutDefault
        case .oneMinute: return L10n.Reader.screenTimeoutOneMinute
        case .fiveMinutes: return L10n.Reader.screenTimeoutFiveMinutes
        case .tenMinutes: return L10n.Reader.screenTimeoutTenMinutes
        case .always: return L10n.Reader.screenTimeoutAlways
        }
    }

    static func detail(_ timeout: ReaderScreenTimeout) -> String {
        switch timeout {
        case .system: return L10n.Reader.screenTimeoutDefaultDetail
        case .oneMinute: return L10n.Reader.screenTimeoutOneMinuteDetail
        case .fiveMinutes: return L10n.Reader.screenTimeoutFiveMinutesDetail
        case .tenMinutes: return L10n.Reader.screenTimeoutTenMinutesDetail
        case .always: return L10n.Reader.screenTimeoutAlwaysDetail
        }
    }

    static func image(_ timeout: ReaderScreenTimeout) -> String {
        switch timeout {
        case .system: return "timer"
        case .oneMinute: return "timer.circle"
        case .fiveMinutes: return "timer.circle.fill"
        case .tenMinutes: return "clock"
        case .always: return "lock.open.display"
        }
    }
}
