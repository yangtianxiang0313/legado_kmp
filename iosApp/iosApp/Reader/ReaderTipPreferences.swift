import Foundation
import shared

enum ReaderTipSelection: String, CaseIterable {
    case headerMode, headerLeft, headerMiddle, headerRight
    case footerMode, footerLeft, footerMiddle, footerRight
    case tipColor, dividerColor

    var title: String {
        switch self {
        case .headerMode, .footerMode: return "显示/隐藏"
        case .headerLeft, .footerLeft: return "左"
        case .headerMiddle, .footerMiddle: return "中"
        case .headerRight, .footerRight: return "右"
        case .tipColor: return "文字颜色"
        case .dividerColor: return "分隔线颜色"
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
        (0, "无"), (7, "书名"), (1, "标题"), (2, "时间"), (3, "电量"), (10, "电量%"),
        (4, "页数"), (5, "进度(%)"), (11, "进度(xx/yyy)"), (6, "页数及进度"),
        (8, "时间及电量"), (9, "时间及电量%"),
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
            return Self.slotOptions.first { $0.value == slotValue(slot) }?.title ?? "无"
        }
        switch selection {
        case .headerMode: return ["状态栏显示时隐藏", "显示", "隐藏"][Int(min(max(headerMode, 0), 2))]
        case .footerMode: return footerMode == 1 ? "隐藏" : "显示"
        case .tipColor: return tipColorHex ?? "跟随内容"
        case .dividerColor:
            return tipDividerColorHex == Self.followTextColor ? "跟随内容" : (tipDividerColorHex ?? "默认")
        default: return "无"
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
