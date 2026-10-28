import UIKit

enum ReaderHardwarePagingPreference {
    private static let keyPageOnLongPressKey = "key_page_on_long_press"
    private static let keyPageKey = "volume_key_page"
    private static let keyPageOnReadAloudKey = "volume_key_page_on_play"
    private static let mouseWheelPageKey = "mouse_wheel_page"
    private static let previousCustomKeyCodesKey = "prevKeyCodes"
    private static let nextCustomKeyCodesKey = "nextKeyCodes"

    static func keyPageEnabled() -> Bool {
        UserDefaults.standard.object(forKey: keyPageKey) as? Bool ?? true
    }

    static func setKeyPageEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keyPageKey)
    }

    static func keyPageOnReadAloudEnabled() -> Bool {
        UserDefaults.standard.object(forKey: keyPageOnReadAloudKey) as? Bool ?? false
    }

    static func setKeyPageOnReadAloudEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keyPageOnReadAloudKey)
    }

    static func keyPageOnLongPressEnabled() -> Bool {
        UserDefaults.standard.object(forKey: keyPageOnLongPressKey) as? Bool ?? false
    }

    static func setKeyPageOnLongPressEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: keyPageOnLongPressKey)
    }

    static func mouseWheelPageEnabled() -> Bool {
        UserDefaults.standard.object(forKey: mouseWheelPageKey) as? Bool ?? true
    }

    static func setMouseWheelPageEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: mouseWheelPageKey)
    }

    static func previousCustomKeyTokens() -> [String] {
        customKeyTokens(forKey: previousCustomKeyCodesKey)
    }

    static func setPreviousCustomKeyTokens(_ tokens: [String]) {
        UserDefaults.standard.set(normalizedCustomKeyTokens(tokens), forKey: previousCustomKeyCodesKey)
    }

    static func nextCustomKeyTokens() -> [String] {
        customKeyTokens(forKey: nextCustomKeyCodesKey)
    }

    static func setNextCustomKeyTokens(_ tokens: [String]) {
        UserDefaults.standard.set(normalizedCustomKeyTokens(tokens), forKey: nextCustomKeyCodesKey)
    }

    private static func customKeyTokens(forKey key: String) -> [String] {
        if let tokens = UserDefaults.standard.array(forKey: key) as? [String] {
            return normalizedCustomKeyTokens(tokens)
        }
        if let tokenText = UserDefaults.standard.string(forKey: key) {
            return normalizedCustomKeyTokens(tokenText.split { $0 == "," || $0 == "\n" }.map(String.init))
        }
        return []
    }

    private static func normalizedCustomKeyTokens(_ tokens: [String]) -> [String] {
        tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
    }
}

private struct ReaderHardwarePagingKeyBinding {
    let input: String
    let modifierFlags: UIKeyModifierFlags

    var commandKey: String {
        "\(modifierFlags.rawValue)|\(input)"
    }

    static let defaultNext: [ReaderHardwarePagingKeyBinding] = [
        named(input: UIKeyCommand.inputPageDown),
        named(input: " "),
        named(input: UIKeyCommand.inputRightArrow),
        named(input: UIKeyCommand.inputDownArrow),
    ]

    static let defaultPrevious: [ReaderHardwarePagingKeyBinding] = [
        named(input: UIKeyCommand.inputPageUp),
        named(input: UIKeyCommand.inputLeftArrow),
        named(input: UIKeyCommand.inputUpArrow),
    ]

    static func bindings(from tokens: [String]) -> [ReaderHardwarePagingKeyBinding] {
        unique(tokens.compactMap(parse))
    }

    static func unique(_ bindings: [ReaderHardwarePagingKeyBinding]) -> [ReaderHardwarePagingKeyBinding] {
        var seen = Set<String>()
        return bindings.filter { seen.insert($0.commandKey).inserted }
    }

    private static func named(input: String, modifierFlags: UIKeyModifierFlags = []) -> ReaderHardwarePagingKeyBinding {
        ReaderHardwarePagingKeyBinding(input: input, modifierFlags: modifierFlags)
    }

    private static func parse(_ token: String) -> ReaderHardwarePagingKeyBinding? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }

        if let compound = parseCompoundToken(trimmed) {
            return compound
        }
        return parseKeyToken(trimmed, modifierFlags: [])
    }

    private static func parseCompoundToken(_ token: String) -> ReaderHardwarePagingKeyBinding? {
        let parts = token.split(separator: "+", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count > 1, let keyPart = parts.last, keyPart.isEmpty == false else { return nil }

        var modifierFlags: UIKeyModifierFlags = []
        for modifierPart in parts.dropLast() {
            guard let modifier = modifierFlag(for: modifierPart) else { return nil }
            modifierFlags.insert(modifier)
        }
        return parseKeyToken(keyPart, modifierFlags: modifierFlags)
    }

    private static func parseKeyToken(_ token: String, modifierFlags: UIKeyModifierFlags) -> ReaderHardwarePagingKeyBinding? {
        let keyToken = normalizedInputToken(token)
        let lowered = keyToken.lowercased()
        let compact = lowered.replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "uikeycommand.input", with: "")
            .replacingOccurrences(of: "input", with: "")
            .replacingOccurrences(of: "key", with: "")
            .replacingOccurrences(of: "char", with: "")
            .replacingOccurrences(of: ":", with: "")

        switch compact {
        case "pagedown", "pgdn":
            return named(input: UIKeyCommand.inputPageDown, modifierFlags: modifierFlags)
        case "pageup", "pgup":
            return named(input: UIKeyCommand.inputPageUp, modifierFlags: modifierFlags)
        case "left", "leftarrow", "arrowleft":
            return named(input: UIKeyCommand.inputLeftArrow, modifierFlags: modifierFlags)
        case "right", "rightarrow", "arrowright":
            return named(input: UIKeyCommand.inputRightArrow, modifierFlags: modifierFlags)
        case "up", "uparrow", "arrowup":
            return named(input: UIKeyCommand.inputUpArrow, modifierFlags: modifierFlags)
        case "down", "downarrow", "arrowdown":
            return named(input: UIKeyCommand.inputDownArrow, modifierFlags: modifierFlags)
        case "space", "spacebar":
            return named(input: " ", modifierFlags: modifierFlags)
        case "tab":
            return named(input: "\t", modifierFlags: modifierFlags)
        case "enter", "return":
            return named(input: "\r", modifierFlags: modifierFlags)
        default:
            break
        }

        if keyToken.count == 1 {
            return named(input: keyToken, modifierFlags: modifierFlags)
        }
        return nil
    }

    private static func normalizedInputToken(_ token: String) -> String {
        var normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()
        for prefix in ["uikeycommand.input", "input:", "key:", "char:"] where lowercased.hasPrefix(prefix) {
            normalized.removeFirst(prefix.count)
            return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return normalized
    }

    private static func modifierFlag(for token: String) -> UIKeyModifierFlags? {
        switch token.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") {
        case "cmd", "command", "meta":
            return .command
        case "shift":
            return .shift
        case "ctrl", "control":
            return .control
        case "alt", "option", "alternate":
            return .alternate
        case "capslock", "alphashift":
            return .alphaShift
        case "numpad", "numericpad":
            return .numericPad
        default:
            return nil
        }
    }
}

extension ReaderContainerViewController {
    var readerHardwarePagingKeyCommands: [UIKeyCommand]? {
        guard canExposeHardwarePagingKeyCommands else { return nil }
        let customPreviousBindings = ReaderHardwarePagingKeyBinding.bindings(
            from: ReaderHardwarePagingPreference.previousCustomKeyTokens()
        )
        let customPreviousKeys = Set(customPreviousBindings.map(\.commandKey))
        let customNextBindings = ReaderHardwarePagingKeyBinding.bindings(
            from: ReaderHardwarePagingPreference.nextCustomKeyTokens()
        ).filter { customPreviousKeys.contains($0.commandKey) == false }
        let customKeys = Set((customPreviousBindings + customNextBindings).map(\.commandKey))

        let previousBindings = customPreviousBindings
            + ReaderHardwarePagingKeyBinding.defaultPrevious.filter { customKeys.contains($0.commandKey) == false }
        let nextBindings = customNextBindings
            + ReaderHardwarePagingKeyBinding.defaultNext.filter { customKeys.contains($0.commandKey) == false }

        return previousBindings.map { readerHardwarePagingKeyCommand(binding: $0, next: false) }
            + nextBindings.map { readerHardwarePagingKeyCommand(binding: $0, next: true) }
    }

    func installHardwarePagingHandlers() {
        guard #available(iOS 13.4, *) else { return }
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(readerHardwareScrollWheelCommand(_:)))
        recognizer.allowedScrollTypesMask = .discrete
        recognizer.cancelsTouchesInView = false
        renderView.addGestureRecognizer(recognizer)
    }

    @objc func readerHardwareNextPageCommand(_: UIKeyCommand) {
        handleHardwarePaging(next: true, debounceInterval: hardwareKeyDebounceInterval)
    }

    @objc func readerHardwarePreviousPageCommand(_: UIKeyCommand) {
        handleHardwarePaging(next: false, debounceInterval: hardwareKeyDebounceInterval)
    }

    @available(iOS 13.4, *)
    @objc func readerHardwareScrollWheelCommand(_ gesture: UIPanGestureRecognizer) {
        guard ReaderHardwarePagingPreference.mouseWheelPageEnabled(), gesture.state == .changed else { return }
        let offset = gesture.translation(in: view).y
        guard abs(offset) >= 8 else { return }
        handleHardwarePaging(next: offset < 0, debounceInterval: 0.2)
        gesture.setTranslation(.zero, in: view)
    }

    private var hardwareKeyDebounceInterval: TimeInterval {
        ReaderHardwarePagingPreference.keyPageOnLongPressEnabled() ? 0.08 : 0.6
    }

    private func readerHardwarePagingKeyCommand(binding: ReaderHardwarePagingKeyBinding, next: Bool) -> UIKeyCommand {
        UIKeyCommand(
            input: binding.input,
            modifierFlags: binding.modifierFlags,
            action: next ? #selector(readerHardwareNextPageCommand(_:)) : #selector(readerHardwarePreviousPageCommand(_:))
        )
    }

    private func handleHardwarePaging(next: Bool, debounceInterval: TimeInterval) {
        guard canHandleHardwarePaging else { return }
        let now = CACurrentMediaTime()
        guard now - hardwarePagingLastFireTime >= debounceInterval else { return }
        hardwarePagingLastFireTime = now
        resetReaderScreenTimeoutTimer()
        turnPageByTap(next: next)
    }

    private var canHandleHardwarePaging: Bool {
        canUseHardwareKeyPaging
            && isMenuVisible == false
            && searchMenu.isHidden
            && textSelectionMenu == nil
            && isAutoChangingSource == false
            && presentedViewController == nil
            && loadingIndicator.isAnimating == false
            && loadFailureView.isHidden
            && pages.isEmpty == false
    }

    private var canExposeHardwarePagingKeyCommands: Bool {
        canUseHardwareKeyPaging
            && isMenuVisible == false
            && searchMenu.isHidden
            && textSelectionMenu == nil
            && presentedViewController == nil
    }

    private var canUseHardwareKeyPaging: Bool {
        view.window != nil
    }

    private var isReadAloudActive: Bool {
        readAloudState?.status == .running || readAloudState?.status == .paused
    }
}
