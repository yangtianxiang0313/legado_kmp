package io.legado.kmp.shared.analyze.parser

internal open class JsonPathPredicatePathException(message: String) : IllegalArgumentException(message)

internal class JsonPathMissingPathException(message: String) : JsonPathPredicatePathException(message)
