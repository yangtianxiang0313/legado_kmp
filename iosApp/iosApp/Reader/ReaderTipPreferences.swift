import Foundation
import shared

enum ReaderTipText {
    static let visibility = NSLocalizedString("reader.tip.visibility", value: "显示/隐藏", comment: "Android show_hide")
    static let left = NSLocalizedString("reader_appearance.padding_left", value: "左", comment: "Android left")
    static let middle = NSLocalizedString("reader.tip.middle", value: "中", comment: "Android middle")
    static let right = NSLocalizedString("reader_appearance.padding_right", value: "右", comment: "Android right")
    static let textColor = NSLocalizedString("reader_appearance.text_color_title", value: "文字颜色", comment: "Android text_color")
    static let dividerColor = NSLocalizedString("reader.tip.divider_color", value: "分隔线颜色", comment: "Android tip_divider_color")
    static let none = NSLocalizedString("reader.tip.none", value: "无", comment: "Android read_tip value 0")
    static let bookName = NSLocalizedString("reader_appearance.tip_slot_book_name", value: "书名", comment: "Android read_tip value 7")
    static let chapterTitle = NSLocalizedString("reader.tip.chapter_title", value: "标题", comment: "Android read_tip value 1")
    static let time = NSLocalizedString("reader_appearance.tip_slot_time", value: "时间", comment: "Android read_tip value 2")
    static let battery = NSLocalizedString("reader_appearance.tip_slot_battery", value: "电量", comment: "Android read_tip value 3")
    static let batteryPercent = NSLocalizedString("reader.tip.battery_percent", value: "电量%", comment: "Android read_tip value 10")
    static let pages = NSLocalizedString("reader.tip.pages", value: "页数", comment: "Android read_tip value 4")
    static let progressPercent = NSLocalizedString("reader.tip.progress_percent", value: "进度(%)", comment: "Android read_tip value 5")
    static let progressFraction = NSLocalizedString(
        "reader.tip.progress_fraction", value: "进度(xx/yyy)", comment: "Android read_tip value 11")
    static let pagesProgress = NSLocalizedString("reader.tip.pages_progress", value: "页数及进度", comment: "Android read_tip value 6")
    static let timeBattery = NSLocalizedString("reader.tip.time_battery", value: "时间及电量", comment: "Android read_tip value 8")
    static let timeBatteryPercent = NSLocalizedString(
        "reader.tip.time_battery_percent", value: "时间及电量%", comment: "Android read_tip value 9")
    static let headerAuto = NSLocalizedString(
        "reader_appearance.header_mode_auto", value: "状态栏显示时隐藏", comment: "Android hide_when_status_bar_show")
    static let show = NSLocalizedString("reader_appearance.tip_mode_show", value: "显示", comment: "Android show")
    static let hide = NSLocalizedString("reader_appearance.tip_mode_hidden", value: "隐藏", comment: "Android hide")
    static let followContent = NSLocalizedString("reader.tip.follow_content", value: "跟随内容", comment: "Android tip_color")
    static let defaultColor = NSLocalizedString(
        "reader_appearance.tip_divider_color_default", value: "默认", comment: "Android tip_divider_color")
    static let customize = NSLocalizedString("reader_appearance.custom_color_button", value: "自定义", comment: "Android tip_color")
    static let titleLeft = NSLocalizedString("reader.tip.title_left", value: "靠左", comment: "Android title_left")
    static let titleCenter = NSLocalizedString("reader_appearance.title_mode_center", value: "居中", comment: "Android title_center")
    static let bodyTitle = NSLocalizedString("reader_appearance.advanced_text_section", value: "正文标题", comment: "Android body_title")
    static let textSize = NSLocalizedString("reader_appearance.sheet_font_size_title", value: "字号", comment: "Android title_font_size")
    static let topMargin = NSLocalizedString("reader.tip.top_margin", value: "上边距", comment: "Android title_margin_top")
    static let bottomMargin = NSLocalizedString("reader.tip.bottom_margin", value: "下边距", comment: "Android title_margin_bottom")
    static let header = NSLocalizedString("reader.tip.header", value: "页眉", comment: "Android top_text")
    static let footer = NSLocalizedString("reader.tip.footer", value: "页脚", comment: "Android bottom_text")
    static let headerFooter = NSLocalizedString("reader.tip.header_footer", value: "页眉&页脚", comment: "Android header_footer")
    static let selected = NSLocalizedString("replace_rule.checked", value: "已选择", comment: "Selected accessibility state")
    static let notSelected = NSLocalizedString("replace_rule.unchecked", value: "未选择", comment: "Unselected accessibility state")
    static let accessibilityPairFormat = NSLocalizedString(
        "reader.tip.accessibility_pair_format", value: "%@，%@", comment: "Section and option accessibility label")

    static var titleModes: [String] { [titleLeft, titleCenter, hide] }
    static var headerModes: [String] { [headerAuto, show, hide] }
    static var footerModes: [String] { [show, hide] }
    static var tipColors: [String] { [followContent, customize] }
    static var dividerColors: [String] { [defaultColor, followContent, customize] }
}

enum ReaderTipSelection: String, CaseIterable {
    case headerMode, headerLeft, headerMiddle, headerRight
    case footerMode, footerLeft, footerMiddle, footerRight
    case tipColor, dividerColor

    var title: String {
        switch self {
        case .headerMode, .footerMode: return ReaderTipText.visibility
        case .headerLeft, .footerLeft: return ReaderTipText.left
        case .headerMiddle, .footerMiddle: return ReaderTipText.middle
        case .headerRight, .footerRight: return ReaderTipText.right
        case .tipColor: return ReaderTipText.textColor
        case .dividerColor: return ReaderTipText.dividerColor
        }
    }

    var slot: AndroidReaderStyleTipSlot? {
        switch self {
        case .headerLeft: return .headerLeft
        case .headerMiddle: return .headerMiddle
        case .headerRight: return .headerRight
        case .footerLeft: return .footerLeft
        case .footerMiddle: return .footerMiddle
        case .footerRight: return .footerRight
        default: return nil
        }
    }
}

enum ReaderTipChange {
    case titleMode(Int32)
    case titleSize(Float)
    case titleTopSpacing(Int32)
    case titleBottomSpacing(Int32)
    case headerMode(Int32)
    case footerMode(Int32)
    case slot(AndroidReaderStyleTipSlot, Int32)
    case tipColor(String?)
    case dividerColor(String?)

    var normalized: ReaderTipChange? {
        switch self {
        case .titleMode(let value): return .titleMode((0...2).contains(value) ? value : 0)
        case .titleSize(let value):
            guard value.isFinite else { return nil }
            return .titleSize(min(max(value, 0), 10).rounded())
        case .titleTopSpacing(let value): return .titleTopSpacing(min(max(value, 0), 100))
        case .titleBottomSpacing(let value): return .titleBottomSpacing(min(max(value, 0), 100))
        case .headerMode(let value): return .headerMode(min(max(value, 0), 2))
        case .footerMode(let value): return .footerMode(min(max(value, 0), 1))
        case .slot(let slot, let value):
            guard ReaderTipValues.slotOptions.contains(where: { $0.value == value }) else { return nil }
            return .slot(slot, value)
        case .tipColor, .dividerColor: return self
        }
    }

    func applying(to style: ReaderStylePreferences) -> ReaderStylePreferences {
        var values = ReaderTipValues(style: style)
        guard values.apply(self) else { return style }
        return style.androidCopy(
            titleMode: values.titleMode, titleSize: values.titleSize,
            titleTopSpacing: values.titleTopSpacing, titleBottomSpacing: values.titleBottomSpacing,
            tipHeaderLeft: values.tipHeaderLeft, tipHeaderMiddle: values.tipHeaderMiddle,
            tipHeaderRight: values.tipHeaderRight, tipFooterLeft: values.tipFooterLeft,
            tipFooterMiddle: values.tipFooterMiddle, tipFooterRight: values.tipFooterRight,
            tipColorHex: .some(values.tipColorHex), tipDividerColorHex: .some(values.tipDividerColorHex),
            headerMode: values.headerMode, footerMode: values.footerMode)
    }
}

struct ReaderTipValues: Equatable {
    // An explicit policy, not a captured color; existing nil and custom hex values keep their meaning.
    static let followTextColor = "@text"
    static let slotOptions: [(value: Int32, title: String)] = [
        (0, ReaderTipText.none), (7, ReaderTipText.bookName), (1, ReaderTipText.chapterTitle),
        (2, ReaderTipText.time), (3, ReaderTipText.battery), (10, ReaderTipText.batteryPercent),
        (4, ReaderTipText.pages), (5, ReaderTipText.progressPercent), (11, ReaderTipText.progressFraction),
        (6, ReaderTipText.pagesProgress), (8, ReaderTipText.timeBattery), (9, ReaderTipText.timeBatteryPercent),
    ]

    var titleMode: Int32
    var titleSize: Float
    var titleTopSpacing: Int32
    var titleBottomSpacing: Int32
    var headerMode: Int32
    var footerMode: Int32
    var tipHeaderLeft: Int32
    var tipHeaderMiddle: Int32
    var tipHeaderRight: Int32
    var tipFooterLeft: Int32
    var tipFooterMiddle: Int32
    var tipFooterRight: Int32
    var tipColorHex: String?
    var tipDividerColorHex: String?
    var contentColorHex: String?

    init(style: ReaderStylePreferences) {
        titleMode = style.titleMode
        titleSize = style.titleSize
        titleTopSpacing = style.titleTopSpacing
        titleBottomSpacing = style.titleBottomSpacing
        headerMode = style.headerMode
        footerMode = style.footerMode
        tipHeaderLeft = style.tipHeaderLeft
        tipHeaderMiddle = style.tipHeaderMiddle
        tipHeaderRight = style.tipHeaderRight
        tipFooterLeft = style.tipFooterLeft
        tipFooterMiddle = style.tipFooterMiddle
        tipFooterRight = style.tipFooterRight
        tipColorHex = style.tipColorHex
        tipDividerColorHex = style.tipDividerColorHex
        contentColorHex = style.textColorHex
    }

    @discardableResult
    mutating func apply(_ change: ReaderTipChange) -> Bool {
        guard let change = change.normalized else { return false }
        switch change {
        case .titleMode(let value):
            guard titleMode != value else { return false }
            titleMode = value
        case .titleSize(let value):
            guard titleSize != value else { return false }
            titleSize = value
        case .titleTopSpacing(let value):
            guard titleTopSpacing != value else { return false }
            titleTopSpacing = value
        case .titleBottomSpacing(let value):
            guard titleBottomSpacing != value else { return false }
            titleBottomSpacing = value
        case .headerMode(let value):
            guard headerMode != value else { return false }
            headerMode = value
        case .footerMode(let value):
            guard footerMode != value else { return false }
            footerMode = value
        case .tipColor(let value):
            guard tipColorHex != value else { return false }
            tipColorHex = value
        case .dividerColor(let value):
            guard tipDividerColorHex != value else { return false }
            tipDividerColorHex = value
        case .slot(let slot, let value):
            let previous = slotValues
            if value != 0 {
                if tipHeaderLeft == value { tipHeaderLeft = 0 }
                if tipHeaderMiddle == value { tipHeaderMiddle = 0 }
                if tipHeaderRight == value { tipHeaderRight = 0 }
                if tipFooterLeft == value { tipFooterLeft = 0 }
                if tipFooterMiddle == value { tipFooterMiddle = 0 }
                if tipFooterRight == value { tipFooterRight = 0 }
            }
            switch slot {
            case .headerLeft: tipHeaderLeft = value
            case .headerMiddle: tipHeaderMiddle = value
            case .headerRight: tipHeaderRight = value
            case .footerLeft: tipFooterLeft = value
            case .footerMiddle: tipFooterMiddle = value
            case .footerRight: tipFooterRight = value
            }
            return previous != slotValues
        }
        return true
    }

    private var slotValues: [Int32] {
        [tipHeaderLeft, tipHeaderMiddle, tipHeaderRight, tipFooterLeft, tipFooterMiddle, tipFooterRight]
    }

    func slotValue(_ slot: AndroidReaderStyleTipSlot) -> Int32 {
        switch slot {
        case .headerLeft: return tipHeaderLeft
        case .headerMiddle: return tipHeaderMiddle
        case .headerRight: return tipHeaderRight
        case .footerLeft: return tipFooterLeft
        case .footerMiddle: return tipFooterMiddle
        case .footerRight: return tipFooterRight
        }
    }

    func text(for selection: ReaderTipSelection) -> String {
        if let slot = selection.slot {
            return Self.slotOptions.first { $0.value == slotValue(slot) }?.title ?? ReaderTipText.none
        }
        switch selection {
        case .headerMode: return ReaderTipText.headerModes[Int(min(max(headerMode, 0), 2))]
        case .footerMode: return footerMode == 1 ? ReaderTipText.hide : ReaderTipText.show
        case .tipColor: return tipColorHex ?? ReaderTipText.followContent
        case .dividerColor:
            return tipDividerColorHex == Self.followTextColor
                ? ReaderTipText.followContent : (tipDividerColorHex ?? ReaderTipText.defaultColor)
        default: return ReaderTipText.none
        }
    }
}

/// Each batch merges only its field changes into a fresh facade snapshot.
@MainActor
final class ReaderTipSettings {
    private let facade: SettingsFacade
    private var pending: [ReaderTipChange] = []
    private var writeTask: Task<Void, Never>?
    private var writeError: Error?

    init() throws {
        facade = try SharedRuntime.settingsFacade().get()
    }

    func update(_ change: ReaderTipChange) {
        guard let change = change.normalized else { return }
        pending.append(change)
        startWriteIfNeeded()
    }

    func finish() async throws {
        startWriteIfNeeded()
        // An update can start a new batch before this waiter resumes from the old task.
        while let task = writeTask {
            await task.value
        }
        if let writeError { throw writeError }
    }

    private func startWriteIfNeeded() {
        guard writeTask == nil, !pending.isEmpty else { return }
        writeError = nil
        writeTask = Task { [self] in
            while !pending.isEmpty {
                let currentStyle = await readerStylePreferenceSnapshot(facade: facade)
                // Include edits received while acquiring the snapshot, preserving slot-operation order.
                let changes = pending
                pending.removeAll(keepingCapacity: true)
                var style = currentStyle
                for change in changes { style = change.applying(to: style) }
                guard !style.isEqual(currentStyle) else { continue }
                do {
                    try await facade.setReaderLayoutAsync(style: style)
                    writeError = nil
                } catch {
                    pending = changes + pending
                    writeError = error
                    break
                }
            }
            writeTask = nil
        }
    }
}
