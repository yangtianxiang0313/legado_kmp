package io.legado.kmp.shared.util

/**
 * HTML entity decoder equivalent to Apache Commons StringEscapeUtils.unescapeHtml4()
 *
 * Supports:
 * - Named HTML4 entities (~250 entities)
 * - Decimal numeric entities: &#123;
 * - Hexadecimal numeric entities: &#x7B;
 */
fun unescapeHtml4(input: String): String {
    if ('&' !in input) return input
    return buildString(input.length) {
        var i = 0
        while (i < input.length) {
            val ch = input[i]
            if (ch != '&') {
                append(ch)
                i++
                continue
            }
            val semicolon = input.indexOf(';', i + 1)
            if (semicolon < 0 || semicolon - i > 10) {
                append(ch)
                i++
                continue
            }
            val entity = input.substring(i + 1, semicolon)
            val decoded = decodeEntity(entity)
            if (decoded != null) {
                append(decoded)
            } else {
                append(input, i, semicolon + 1)
            }
            i = semicolon + 1
        }
    }
}

private fun decodeEntity(entity: String): String? {
    if (entity.isEmpty()) return null
    // Numeric entities
    if (entity.startsWith("#")) {
        val codePoint = if (entity.startsWith("#x", ignoreCase = true) || entity.startsWith("#X")) {
            entity.substring(2).toIntOrNull(16)
        } else {
            entity.substring(1).toIntOrNull()
        }
        return codePoint?.let { codePointToString(it) }
    }
    // Named entities
    return HTML4_ENTITIES[entity]
}

private fun codePointToString(codePoint: Int): String {
    return if (codePoint in 0..0xFFFF) {
        codePoint.toChar().toString()
    } else if (codePoint in 0x10000..0x10FFFF) {
        val high = ((codePoint - 0x10000) shr 10) + 0xD800
        val low = ((codePoint - 0x10000) and 0x3FF) + 0xDC00
        "${high.toChar()}${low.toChar()}"
    } else {
        null.toString()
    }
}

/**
 * Complete HTML4 named entity map.
 * Reference: https://www.w3.org/TR/html4/sgml/entities.html
 */
@Suppress("SpellCheckingInspection")
private val HTML4_ENTITIES: Map<String, String> = buildMap(260) {
    // Latin Extended-A
    put("OElig", "\u0152")
    put("oelig", "\u0153")
    put("Scaron", "\u0160")
    put("scaron", "\u0161")
    put("Yuml", "\u0178")
    // Spacing modifier letters
    put("circ", "\u02C6")
    put("tilde", "\u02DC")
    // General punctuation
    put("ensp", "\u2002")
    put("emsp", "\u2003")
    put("thinsp", "\u2009")
    put("zwnj", "\u200C")
    put("zwj", "\u200D")
    put("lrm", "\u200E")
    put("rlm", "\u200F")
    put("ndash", "\u2013")
    put("mdash", "\u2014")
    put("lsquo", "\u2018")
    put("rsquo", "\u2019")
    put("sbquo", "\u201A")
    put("ldquo", "\u201C")
    put("rdquo", "\u201D")
    put("bdquo", "\u201E")
    put("dagger", "\u2020")
    put("Dagger", "\u2021")
    put("permil", "\u2030")
    put("lsaquo", "\u2039")
    put("rsaquo", "\u203A")
    put("euro", "\u20AC")
    // Latin-1 Supplement (ISO 8859-1 characters)
    put("nbsp", "\u00A0")
    put("iexcl", "\u00A1")
    put("cent", "\u00A2")
    put("pound", "\u00A3")
    put("curren", "\u00A4")
    put("yen", "\u00A5")
    put("brvbar", "\u00A6")
    put("sect", "\u00A7")
    put("uml", "\u00A8")
    put("copy", "\u00A9")
    put("ordf", "\u00AA")
    put("laquo", "\u00AB")
    put("not", "\u00AC")
    put("shy", "\u00AD")
    put("reg", "\u00AE")
    put("macr", "\u00AF")
    put("deg", "\u00B0")
    put("plusmn", "\u00B1")
    put("sup2", "\u00B2")
    put("sup3", "\u00B3")
    put("acute", "\u00B4")
    put("micro", "\u00B5")
    put("para", "\u00B6")
    put("middot", "\u00B7")
    put("cedil", "\u00B8")
    put("sup1", "\u00B9")
    put("ordm", "\u00BA")
    put("raquo", "\u00BB")
    put("frac14", "\u00BC")
    put("frac12", "\u00BD")
    put("frac34", "\u00BE")
    put("iquest", "\u00BF")
    put("Agrave", "\u00C0")
    put("Aacute", "\u00C1")
    put("Acirc", "\u00C2")
    put("Atilde", "\u00C3")
    put("Auml", "\u00C4")
    put("Aring", "\u00C5")
    put("AElig", "\u00C6")
    put("Ccedil", "\u00C7")
    put("Egrave", "\u00C8")
    put("Eacute", "\u00C9")
    put("Ecirc", "\u00CA")
    put("Euml", "\u00CB")
    put("Igrave", "\u00CC")
    put("Iacute", "\u00CD")
    put("Icirc", "\u00CE")
    put("Iuml", "\u00CF")
    put("ETH", "\u00D0")
    put("Ntilde", "\u00D1")
    put("Ograve", "\u00D2")
    put("Oacute", "\u00D3")
    put("Ocirc", "\u00D4")
    put("Otilde", "\u00D5")
    put("Ouml", "\u00D6")
    put("times", "\u00D7")
    put("Oslash", "\u00D8")
    put("Ugrave", "\u00D9")
    put("Uacute", "\u00DA")
    put("Ucirc", "\u00DB")
    put("Uuml", "\u00DC")
    put("Yacute", "\u00DD")
    put("THORN", "\u00DE")
    put("szlig", "\u00DF")
    put("agrave", "\u00E0")
    put("aacute", "\u00E1")
    put("acirc", "\u00E2")
    put("atilde", "\u00E3")
    put("auml", "\u00E4")
    put("aring", "\u00E5")
    put("aelig", "\u00E6")
    put("ccedil", "\u00E7")
    put("egrave", "\u00E8")
    put("eacute", "\u00E9")
    put("ecirc", "\u00EA")
    put("euml", "\u00EB")
    put("igrave", "\u00EC")
    put("iacute", "\u00ED")
    put("icirc", "\u00EE")
    put("iuml", "\u00EF")
    put("eth", "\u00F0")
    put("ntilde", "\u00F1")
    put("ograve", "\u00F2")
    put("oacute", "\u00F3")
    put("ocirc", "\u00F4")
    put("otilde", "\u00F5")
    put("ouml", "\u00F6")
    put("divide", "\u00F7")
    put("oslash", "\u00F8")
    put("ugrave", "\u00F9")
    put("uacute", "\u00FA")
    put("ucirc", "\u00FB")
    put("uuml", "\u00FC")
    put("yacute", "\u00FD")
    put("thorn", "\u00FE")
    put("yuml", "\u00FF")
    // Basic XML entities
    put("quot", "\"")
    put("amp", "&")
    put("apos", "'")
    put("lt", "<")
    put("gt", ">")
    // Greek letters
    put("fnof", "\u0192")
    put("Alpha", "\u0391")
    put("Beta", "\u0392")
    put("Gamma", "\u0393")
    put("Delta", "\u0394")
    put("Epsilon", "\u0395")
    put("Zeta", "\u0396")
    put("Eta", "\u0397")
    put("Theta", "\u0398")
    put("Iota", "\u0399")
    put("Kappa", "\u039A")
    put("Lambda", "\u039B")
    put("Mu", "\u039C")
    put("Nu", "\u039D")
    put("Xi", "\u039E")
    put("Omicron", "\u039F")
    put("Pi", "\u03A0")
    put("Rho", "\u03A1")
    put("Sigma", "\u03A3")
    put("Tau", "\u03A4")
    put("Upsilon", "\u03A5")
    put("Phi", "\u03A6")
    put("Chi", "\u03A7")
    put("Psi", "\u03A8")
    put("Omega", "\u03A9")
    put("alpha", "\u03B1")
    put("beta", "\u03B2")
    put("gamma", "\u03B3")
    put("delta", "\u03B4")
    put("epsilon", "\u03B5")
    put("zeta", "\u03B6")
    put("eta", "\u03B7")
    put("theta", "\u03B8")
    put("iota", "\u03B9")
    put("kappa", "\u03BA")
    put("lambda", "\u03BB")
    put("mu", "\u03BC")
    put("nu", "\u03BD")
    put("xi", "\u03BE")
    put("omicron", "\u03BF")
    put("pi", "\u03C0")
    put("rho", "\u03C1")
    put("sigmaf", "\u03C2")
    put("sigma", "\u03C3")
    put("tau", "\u03C4")
    put("upsilon", "\u03C5")
    put("phi", "\u03C6")
    put("chi", "\u03C7")
    put("psi", "\u03C8")
    put("omega", "\u03C9")
    put("thetasym", "\u03D1")
    put("upsih", "\u03D2")
    put("piv", "\u03D6")
    // Mathematical operators
    put("bull", "\u2022")
    put("hellip", "\u2026")
    put("prime", "\u2032")
    put("Prime", "\u2033")
    put("oline", "\u203E")
    put("frasl", "\u2044")
    put("weierp", "\u2118")
    put("image", "\u2111")
    put("real", "\u211C")
    put("trade", "\u2122")
    put("alefsym", "\u2135")
    put("larr", "\u2190")
    put("uarr", "\u2191")
    put("rarr", "\u2192")
    put("darr", "\u2193")
    put("harr", "\u2194")
    put("crarr", "\u21B5")
    put("lArr", "\u21D0")
    put("uArr", "\u21D1")
    put("rArr", "\u21D2")
    put("dArr", "\u21D3")
    put("hArr", "\u21D4")
    put("nabla", "\u2207")
    put("isin", "\u2208")
    put("notin", "\u2209")
    put("ni", "\u220B")
    put("prod", "\u220F")
    put("sum", "\u2211")
    put("minus", "\u2212")
    put("lowast", "\u2217")
    put("radic", "\u221A")
    put("prop", "\u221D")
    put("infin", "\u221E")
    put("ang", "\u2220")
    put("and", "\u2227")
    put("or", "\u2228")
    put("cap", "\u2229")
    put("cup", "\u222A")
    put("int", "\u222B")
    put("there4", "\u2234")
    put("sim", "\u223C")
    put("cong", "\u2245")
    put("asymp", "\u2248")
    put("ne", "\u2260")
    put("equiv", "\u2261")
    put("le", "\u2264")
    put("ge", "\u2265")
    put("sub", "\u2282")
    put("sup", "\u2283")
    put("nsub", "\u2284")
    put("sube", "\u2286")
    put("supe", "\u2287")
    put("oplus", "\u2295")
    put("otimes", "\u2297")
    put("perp", "\u22A5")
    put("sdot", "\u22C5")
    // Miscellaneous technical
    put("lceil", "\u2308")
    put("rceil", "\u2309")
    put("lfloor", "\u230A")
    put("rfloor", "\u230B")
    put("lang", "\u2329")
    put("rang", "\u232A")
    // Geometric shapes
    put("loz", "\u25CA")
    // Miscellaneous symbols
    put("spades", "\u2660")
    put("clubs", "\u2663")
    put("hearts", "\u2665")
    put("diams", "\u2666")
    // Letterlike symbols
    put("forall", "\u2200")
    put("part", "\u2202")
    put("exist", "\u2203")
    put("empty", "\u2205")
}
