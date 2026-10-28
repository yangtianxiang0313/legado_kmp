import Foundation

// Global C-compatible signal handler (cannot capture context)
private func crashSignalHandler(_ signalNumber: Int32) {
    let name: String
    switch signalNumber {
    case SIGABRT: name = "SIGABRT"
    case SIGSEGV: name = "SIGSEGV"
    case SIGBUS:  name = "SIGBUS"
    case SIGFPE:  name = "SIGFPE"
    case SIGILL:  name = "SIGILL"
    case SIGTRAP: name = "SIGTRAP"
    default:      name = "SIGNAL(\(signalNumber))"
    }

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let callStack = Thread.callStackSymbols
    var info = """
    === LEGADO CRASH REPORT ===
    Time: \(timestamp)
    Type: Signal
    Name: \(name)
    Reason: Signal \(signalNumber) received

    Call Stack:
    """
    for (index, symbol) in callStack.enumerated() {
        info += "\n  \(index): \(symbol)"
    }
    info += "\n=== END CRASH REPORT ===\n"

    // Write directly (no static method calls to avoid context capture issues)
    let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
        ?? NSTemporaryDirectory()
    let path = (docs as NSString).appendingPathComponent("legado_crash_log.txt")
    var existing = ""
    if let data = FileManager.default.contents(atPath: path),
       let text = String(data: data, encoding: .utf8) {
        existing = text
    }
    let combined = existing + info
    try? combined.write(toFile: path, atomically: true, encoding: .utf8)

    // Re-raise to let the system handle it
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}

/// Installs global exception and signal handlers to capture crash context.
///
/// Crash details are written to a file in the app's Documents directory.
/// On next launch, the crash log can be read and exported via SettingsFacade.exportCrashReports().
enum CrashHook {
    private static var isInstalled = false
    private static let crashLogFileName = "legado_crash_log.txt"

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true

        // Objective-C exception handler
        NSSetUncaughtExceptionHandler { exception in
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let callStack = exception.callStackSymbols
            var info = """
            === LEGADO CRASH REPORT ===
            Time: \(timestamp)
            Type: NSException
            Name: \(exception.name.rawValue)
            Reason: \(exception.reason ?? "unknown")

            Call Stack:
            """
            for (index, symbol) in callStack.enumerated() {
                info += "\n  \(index): \(symbol)"
            }
            info += "\n=== END CRASH REPORT ===\n"

            let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
                ?? NSTemporaryDirectory()
            let path = (docs as NSString).appendingPathComponent("legado_crash_log.txt")
            var existing = ""
            if let data = FileManager.default.contents(atPath: path),
               let text = String(data: data, encoding: .utf8) {
                existing = text
            }
            let combined = existing + info
            try? combined.write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Signal handlers for common crash signals
        let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGFPE, SIGILL, SIGTRAP]
        for sig in signals {
            signal(sig, crashSignalHandler)
        }

        // Check for previous crash on launch
        checkPreviousCrash()
    }

    /// Returns the path to the crash log file, or nil if no crash log exists.
    static var crashLogPath: String? {
        let path = crashLogFilePath()
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Reads and clears the crash log from previous session.
    static func consumeCrashLog() -> String? {
        let path = crashLogFilePath()
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        try? FileManager.default.removeItem(atPath: path)
        return text
    }

    // MARK: - Private

    private static func checkPreviousCrash() {
        if let log = consumeCrashLog() {
            SharedRuntime.log("Previous crash detected:\n\(log.prefix(500))")
        }
    }

    private static func crashLogFilePath() -> String {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        return (docs as NSString).appendingPathComponent(crashLogFileName)
    }
}
