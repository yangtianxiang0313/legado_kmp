package io.legado.kmp.shared.facade

class LogFacade {
    fun watchLogs(onUpdate: (List<AppLogEntry>) -> Unit): FlowSubscription {
        return watchFlow(AppLogStore.entries, onUpdate, label = "LogFacade.logs")
    }

    suspend fun loadEntries(): List<AppLogEntry> = AppLogStore.entries.value

    suspend fun exportMarkdown(): String {
        val appLogs = AppLogStore.entries.value.joinToString(separator = "\n") { entry ->
            "- `${entry.timestamp}` [${entry.level}/${entry.tag}] ${entry.message}"
        }
        val crashLogs = CrashCollector.exportMarkdown()
        return buildString {
            appendLine("# App Logs")
            appendLine()
            appendLine(appLogs.ifBlank { "_No app logs._" })
            appendLine()
            appendLine(crashLogs)
        }
    }

    suspend fun clear() {
        AppLogStore.clear()
        CrashCollector.clear()
    }
}
