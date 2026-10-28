package io.legado.kmp.shared.facade

import kotlinx.datetime.LocalDate
import kotlinx.serialization.json.*

/** Android 5f5d314 Backup/Restore and data/entities: names are file names, not KMP envelope keys. */
internal object AndroidBackupExportTables {
    val files = linkedMapOf(
        "bookshelf.json" to "bookshelf", "bookmark.json" to "bookmark", "bookGroup.json" to "bookGroup",
        "bookSource.json" to "bookSource", "rssSources.json" to "rssSource", "rssStar.json" to "rssStar",
        "replaceRule.json" to "replaceRule", "readRecord.json" to "readRecord", "searchHistory.json" to "searchHistory",
        "sourceSub.json" to "sourceSub", "txtTocRule.json" to "txtTocRule", "httpTTS.json" to "httpTTS",
        "keyboardAssists.json" to "keyboardAssists", "dictRule.json" to "dictRule", "servers.json" to "servers",
    )

    fun exportRows(field: String, rows: JsonArray): JsonArray = JsonArray(rows.map { element ->
        val row = element.jsonObject.toMutableMap()
        if (field == "bookshelf") {
            val config = row["readConfig"] as? JsonObject
            val date = config?.get("startDate") as? JsonPrimitive
            if (config != null && date != null && date !is JsonNull) {
                val parsed = LocalDate.parse(date.content)
                // Android uses GSON's reflective java.time.LocalDate representation, not ISO text.
                row["readConfig"] = JsonObject(config + ("startDate" to buildJsonObject {
                    put("year", parsed.year)
                    put("month", parsed.monthNumber)
                    put("day", parsed.dayOfMonth)
                }))
            }
        }
        JsonObject(row)
    })

    fun importRows(field: String, rows: JsonArray): JsonArray = JsonArray(rows.map { element ->
        val row = element.jsonObject.toMutableMap()
        if (field == "bookshelf") {
            val config = row["readConfig"] as? JsonObject
            val date = config?.get("startDate") as? JsonObject
            if (config != null && date != null) {
                val parsed = LocalDate(
                    date.getValue("year").jsonPrimitive.int,
                    date.getValue("month").jsonPrimitive.int,
                    date.getValue("day").jsonPrimitive.int,
                )
                row["readConfig"] = JsonObject(config + ("startDate" to JsonPrimitive(parsed.toString())))
            }
        }
        JsonObject(row)
    })
}
