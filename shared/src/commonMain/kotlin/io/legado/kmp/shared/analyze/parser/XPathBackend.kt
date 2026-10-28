package io.legado.kmp.shared.analyze.parser

interface XPathBackend {
    fun getElements(content: Any, xPath: String): List<Any>

    fun getStringList(content: Any, xPath: String): List<String>
}

expect fun createXPathBackend(): XPathBackend
