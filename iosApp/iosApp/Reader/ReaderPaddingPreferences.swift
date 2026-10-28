import shared

enum ReaderPaddingField: String, CaseIterable {
    case headerTop, headerBottom, headerLeft, headerRight
    case bodyTop, bodyBottom, bodyLeft, bodyRight
    case footerTop, footerBottom, footerLeft, footerRight

    var title: String {
        switch self {
        case .headerTop, .bodyTop, .footerTop: return "上边距"
        case .headerBottom, .bodyBottom, .footerBottom: return "下边距"
        case .headerLeft, .bodyLeft, .footerLeft: return "左边距"
        case .headerRight, .bodyRight, .footerRight: return "右边距"
        }
    }

    var maximum: Int32 { self == .bodyTop ? 200 : 100 }

    var identifier: String {
        switch self {
        case .headerTop: return "header.top"
        case .headerBottom: return "header.bottom"
        case .headerLeft: return "header.left"
        case .headerRight: return "header.right"
        case .bodyTop: return "body.top"
        case .bodyBottom: return "body.bottom"
        case .bodyLeft: return "body.left"
        case .bodyRight: return "body.right"
        case .footerTop: return "footer.top"
        case .footerBottom: return "footer.bottom"
        case .footerLeft: return "footer.left"
        case .footerRight: return "footer.right"
        }
    }

    func value(in style: ReaderStylePreferences) -> Int32 {
        switch self {
        case .headerTop: return style.headerPaddingTop
        case .headerBottom: return style.headerPaddingBottom
        case .headerLeft: return style.headerPaddingLeft
        case .headerRight: return style.headerPaddingRight
        case .bodyTop: return style.paddingTop
        case .bodyBottom: return style.paddingBottom
        case .bodyLeft: return style.paddingLeft
        case .bodyRight: return style.paddingRight
        case .footerTop: return style.footerPaddingTop
        case .footerBottom: return style.footerPaddingBottom
        case .footerLeft: return style.footerPaddingLeft
        case .footerRight: return style.footerPaddingRight
        }
    }
}

struct ReaderPaddingValues: Equatable {
    var values: [ReaderPaddingField: Int32]
    var showHeaderLine: Bool
    var showFooterLine: Bool

    init(style: ReaderStylePreferences) {
        values = Dictionary(uniqueKeysWithValues: ReaderPaddingField.allCases.map { ($0, $0.value(in: style)) })
        showHeaderLine = style.showHeaderLine
        showFooterLine = style.showFooterLine
    }

    func applying(to style: ReaderStylePreferences) -> ReaderStylePreferences {
        func value(_ field: ReaderPaddingField) -> Int32 {
            min(max(values[field] ?? field.value(in: style), 0), field.maximum)
        }
        return style.androidCopy(
            paddingTop: value(.bodyTop), paddingBottom: value(.bodyBottom),
            paddingLeft: value(.bodyLeft), paddingRight: value(.bodyRight),
            headerPaddingTop: value(.headerTop), headerPaddingBottom: value(.headerBottom),
            headerPaddingLeft: value(.headerLeft), headerPaddingRight: value(.headerRight),
            footerPaddingTop: value(.footerTop), footerPaddingBottom: value(.footerBottom),
            footerPaddingLeft: value(.footerLeft), footerPaddingRight: value(.footerRight),
            showHeaderLine: showHeaderLine, showFooterLine: showFooterLine)
    }
}

/// Serializes live edits and keeps their owner alive until the final write completes.
@MainActor
final class ReaderPaddingSettings {
    private let screen = ReaderAppearanceScreenAdapter()
    private var latestStyle: ReaderStylePreferences
    private var pending: ReaderPaddingValues?
    private var writeTask: Task<Void, Never>?
    private var writeError: Error?
    private let context: ReaderAppearanceSelectionContext?
    private var currentState: ReaderAppearanceState?
    var onContextChange: (() -> Void)?

    var isCurrent: Bool {
        guard let currentState else { return false }
        return context?.matches(currentState) != false
    }

    init(style: ReaderStylePreferences, context: ReaderAppearanceSelectionContext? = nil) throws {
        latestStyle = style
        self.context = context
        screen.onStateChange = { [weak self] state in
            guard let self else { return }
            currentState = state
            latestStyle = state.preferences.readerStyle
            if !isCurrent { pending = nil }
            onContextChange?()
        }
        try screen.bootstrap().get()
    }

    deinit {
        screen.unbind()
    }

    func update(_ values: ReaderPaddingValues) {
        guard isCurrent else { return }
        pending = values
        writeError = nil
        startWriteIfNeeded()
    }

    func finish() async throws {
        if writeTask == nil { startWriteIfNeeded() }
        await writeTask?.value
        if let writeError { throw writeError }
    }

    private func startWriteIfNeeded() {
        guard writeTask == nil, pending != nil else { return }
        writeError = nil
        writeTask = Task { [self] in
            while let values = pending {
                pending = nil
                guard isCurrent else { break }
                let updated = values.applying(to: latestStyle)
                do {
                    try await screen.setReaderStyle(style: updated)
                    latestStyle = updated
                } catch {
                    pending = pending ?? values
                    writeError = error
                    break
                }
            }
            writeTask = nil
        }
    }
}
