package io.legado.kmp.shared.content

import io.legado.kmp.shared.image.ImageDiskCache
import io.legado.kmp.shared.model.Book
import io.legado.kmp.shared.model.BookChapter
import io.legado.kmp.shared.model.getCacheFolderName
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * Book content helper methods, ported from legado BookHelp.kt.
 *
 * Provides:
 * - getDurChapter: Jaccard similarity + chapter-number based chapter matching for source change
 * - getChapterNum / getPureChapterName: chapter name parsing utilities
 * - saveImages: concurrent image downloading with deduplication
 */
object BookHelp {

    // ==================== getDurChapter (Jaccard similarity) ====================

    /**
     * 根据目录名获取当前章节。
     * 换源/更新后通过 Jaccard 相似度 + 章节编号双重匹配，在新目录中找到最接近的章节。
     */
    fun getDurChapter(
        oldDurChapterIndex: Int,
        oldDurChapterName: String?,
        newChapterList: List<BookChapter>,
        oldChapterListSize: Int = 0
    ): Int {
        if (oldDurChapterIndex <= 0) return 0
        if (newChapterList.isEmpty()) return oldDurChapterIndex
        val oldChapterNum = getChapterNum(oldDurChapterName)
        val oldName = getPureChapterName(oldDurChapterName)
        val newChapterSize = newChapterList.size
        val durIndex =
            if (oldChapterListSize == 0) oldDurChapterIndex
            else oldDurChapterIndex * oldChapterListSize / newChapterSize
        val min = max(0, min(oldDurChapterIndex, durIndex) - 10)
        val max = min(newChapterSize - 1, max(oldDurChapterIndex, durIndex) + 10)
        var nameSim = 0.0
        var newIndex = 0
        var newNum = 0
        if (oldName.isNotEmpty()) {
            for (i in min..max) {
                val newName = getPureChapterName(newChapterList[i].title)
                val temp = jaccardSimilarity(oldName, newName)
                if (temp > nameSim) {
                    nameSim = temp
                    newIndex = i
                }
            }
        }
        if (nameSim < 0.96 && oldChapterNum > 0) {
            for (i in min..max) {
                val temp = getChapterNum(newChapterList[i].title)
                if (temp == oldChapterNum) {
                    newNum = temp
                    newIndex = i
                    break
                } else if (abs(temp - oldChapterNum) < abs(newNum - oldChapterNum)) {
                    newNum = temp
                    newIndex = i
                }
            }
        }
        return if (nameSim > 0.96 || abs(newNum - oldChapterNum) < 1) {
            newIndex
        } else {
            min(max(0, newChapterList.size - 1), oldDurChapterIndex)
        }
    }

    /**
     * Overload taking a Book directly.
     */
    fun getDurChapter(
        oldBook: Book,
        newChapterList: List<BookChapter>
    ): Int {
        return oldBook.run {
            getDurChapter(durChapterIndex, durChapterTitle, newChapterList, totalChapterNum)
        }
    }

    // ==================== Chapter name parsing ====================

    private val chapterNamePattern1 by lazy {
        Regex(".*?第([\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)[章节篇回集话]")
    }

    private val chapterNamePattern2 by lazy {
        Regex("^(?:[\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[,:、])*([\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)(?:[,:、]|\\.[^\\d])")
    }

    private val regexA by lazy {
        "\\s".toRegex()
    }

    /**
     * 从章节名提取章节编号（支持中文数字转换）
     */
    fun getChapterNum(chapterName: String?): Int {
        chapterName ?: return -1
        val chapterName1 = fullToHalf(chapterName).replace(regexA, "")
        val match1 = chapterNamePattern1.find(chapterName1)
        if (match1 != null) {
            return stringToInt(match1.groupValues[1])
        }
        val match2 = chapterNamePattern2.find(chapterName1)
        if (match2 != null) {
            return stringToInt(match2.groupValues[1])
        }
        return stringToInt("-1")
    }

    private val regexOther by lazy {
        // 所有非字母数字中日韩文字 CJK区+扩展A-F区
        "[^\\w\\u4E00-\\u9FEF〇\\u3400-\\u4DBF]".toRegex()
    }

    private val regexB by lazy {
        //章节序号，排除处于结尾的状况，避免将章节名替换为空字串
        "^.*?第(?:[\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)[章节篇回集话](?!$)|^(?:[\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+[,:、])*(?:[\\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]+)(?:[,:、](?!$)|\\.(?=[^\\d]))".toRegex()
    }

    private val regexC by lazy {
        //前后附加内容，整个章节名都在括号中时只剔除首尾括号，避免将章节名替换为空字串
        "(?!^)(?:[〖【《〔\\[{(][^〖【《〔\\[{()〕》】〗\\]}]+)?[)〕》】〗\\]}]$|^[〖【《〔\\[{(](?:[^〖【《〔\\[{()〕》】〗\\]}]+[〕》】〗\\]})])?(?!$)".toRegex()
    }

    /**
     * 去除章节名中的编号/括号/空格，提取纯章节名
     */
    fun getPureChapterName(chapterName: String?): String {
        return if (chapterName == null) "" else fullToHalf(chapterName)
            .replace(regexA, "")
            .replace(regexB, "")
            .replace(regexC, "")
            .replace(regexOther, "")
    }

    // ==================== Image saving ====================

    /** Regex to match image src from content: <img src="xxx"> or similar patterns */
    private val imgPattern by lazy {
        Regex("<img[^>]*src\\s*=\\s*\"([^\"]+)\"[^>]*/?>", RegexOption.IGNORE_CASE)
    }

    /**
     * 并发下载章节内所有图片，使用 Mutex 防重入。
     *
     * @param book 当前书籍
     * @param chapter 当前章节
     * @param content 章节正文内容（含 <img> 标签）
     * @param imageDiskCache 图片磁盘缓存
     * @param downloadImage 下载单张图片的挂起函数，输入 src URL，返回图片字节数据
     * @param concurrency 并发下载数
     */
    suspend fun saveImages(
        book: Book,
        chapter: BookChapter,
        content: String,
        imageDiskCache: ImageDiskCache,
        downloadImage: suspend (src: String) -> ByteArray,
        concurrency: Int = 3
    ) = coroutineScope {
        val bookFolderName = book.getCacheFolderName()
        val imageSrcs = extractImageSrcs(chapter.url, content)
        if (imageSrcs.isEmpty()) return@coroutineScope

        val semaphore = Semaphore(concurrency)
        val mapMutex = Mutex()
        val downloadMutexes = mutableMapOf<String, Mutex>()

        for (src in imageSrcs) {
            launch {
                semaphore.withPermit {
                    if (imageDiskCache.isImageExist(bookFolderName, src)) {
                        return@withPermit
                    }
                    val mutex: Mutex
                    mapMutex.lock()
                    try {
                        mutex = downloadMutexes.getOrPut(src) { Mutex() }
                    } finally {
                        mapMutex.unlock()
                    }
                    mutex.lock()
                    try {
                        if (imageDiskCache.isImageExist(bookFolderName, src)) {
                            return@withPermit
                        }
                        val bytes = downloadImage(src)
                        imageDiskCache.writeImage(bookFolderName, src, bytes)
                    } catch (_: Exception) {
                        // Log but don't crash - matches legado behavior
                    } finally {
                        mapMutex.lock()
                        try {
                            downloadMutexes.remove(src)
                        } finally {
                            mapMutex.unlock()
                        }
                        mutex.unlock()
                    }
                }
            }
        }
    }

    /**
     * Extract all image source URLs from content.
     */
    fun extractImageSrcs(chapterUrl: String, content: String): List<String> {
        val result = mutableListOf<String>()
        for (match in imgPattern.findAll(content)) {
            val src = match.groupValues[1]
            if (src.isNotBlank()) {
                result.add(getAbsoluteURL(chapterUrl, src))
            }
        }
        return result
    }

    /**
     * Simple URL resolution for image sources.
     */
    private fun getAbsoluteURL(baseUrl: String, src: String): String {
        if (src.startsWith("http://") || src.startsWith("https://") || src.startsWith("data:")) {
            return src
        }
        if (src.startsWith("//")) {
            val scheme = if (baseUrl.startsWith("https://")) "https:" else "http:"
            return scheme + src
        }
        if (baseUrl.isBlank()) return src
        if (src.startsWith("/")) {
            val schemeEnd = baseUrl.indexOf("://")
            if (schemeEnd > 0) {
                val pathStart = baseUrl.indexOf('/', schemeEnd + 3)
                return if (pathStart > 0) {
                    baseUrl.substring(0, pathStart) + src
                } else {
                    baseUrl + src
                }
            }
        }
        // Relative URL
        val lastSlash = baseUrl.lastIndexOf('/')
        return if (lastSlash > baseUrl.indexOf("://") + 2) {
            baseUrl.substring(0, lastSlash + 1) + src
        } else {
            "$baseUrl/$src"
        }
    }

    // ==================== Book name/author formatting ====================

    /**
     * Regex to strip author attribution from book names.
     * Matches legado AppPattern.nameRegex: "\\s+作\\s*者.*|\\s+\\S+\\s+著"
     */
    private val nameRegex by lazy {
        Regex("\\s+作\\s*者.*|\\s+\\S+\\s+著")
    }

    /**
     * Regex to strip prefixes/suffixes from author names.
     * Matches legado AppPattern.authorRegex: "^\\s*作\\s*者[:：\\s]+|\\s+著"
     */
    private val authorRegex by lazy {
        Regex("^\\s*作\\s*者[:：\\s]+|\\s+著")
    }

    /**
     * Format/normalize a book name by removing author attribution patterns.
     * Mirrors legado BookHelp.formatBookName.
     */
    fun formatBookName(name: String): String {
        return name.replace(nameRegex, "").trim()
    }

    /**
     * Format/normalize an author name by removing common prefixes/suffixes.
     * Mirrors legado BookHelp.formatBookAuthor.
     */
    fun formatBookAuthor(author: String): String {
        return author.replace(authorRegex, "").trim()
    }

    // ==================== String utilities ====================

    /**
     * Jaccard similarity using character-level 2-grams.
     * Matches legado's use of Apache commons-text JaccardSimilarity.
     */
    internal fun jaccardSimilarity(left: String, right: String): Double {
        if (left.isEmpty() && right.isEmpty()) return 1.0
        if (left.isEmpty() || right.isEmpty()) return 0.0
        if (left == right) return 1.0

        val leftBigrams = toBigrams(left)
        val rightBigrams = toBigrams(right)

        val intersection = leftBigrams.intersect(rightBigrams).size
        val union = leftBigrams.union(rightBigrams).size

        return if (union == 0) 0.0 else intersection.toDouble() / union.toDouble()
    }

    private fun toBigrams(str: String): Set<String> {
        if (str.length < 2) return setOf(str)
        val set = mutableSetOf<String>()
        for (i in 0 until str.length - 1) {
            set.add(str.substring(i, i + 2))
        }
        return set
    }

    /**
     * 字符串全角转换为半角
     */
    internal fun fullToHalf(input: String): String {
        val c = input.toCharArray()
        for (i in c.indices) {
            if (c[i].code == 12288) {
                // 全角空格
                c[i] = 32.toChar()
                continue
            }
            if (c[i].code in 65281..65374)
                c[i] = (c[i].code - 65248).toChar()
        }
        return c.concatToString()
    }

    /**
     * 字符串转数字（支持中文数字）
     */
    internal fun stringToInt(str: String?): Int {
        if (str != null) {
            val num = fullToHalf(str).replace("\\s+".toRegex(), "")
            return try {
                num.toInt()
            } catch (_: NumberFormatException) {
                chineseNumToInt(num)
            }
        }
        return -1
    }

    /**
     * 中文大写数字转数字
     */
    internal fun chineseNumToInt(chNum: String): Int {
        var result = 0
        var tmp = 0
        var billion = 0
        val cn = chNum.toCharArray()

        // "一零二五" 形式
        if (cn.size > 1 && chNum.matches("^[〇零一二三四五六七八九壹贰叁肆伍陆柒捌玖]+$".toRegex())) {
            val sb = StringBuilder()
            for (c in cn) {
                val v = ChnMap[c] ?: return -1
                sb.append((48 + v).toChar())
            }
            return try {
                sb.toString().toInt()
            } catch (_: NumberFormatException) {
                -1
            }
        }

        // "一千零二十五", "一千二" 形式
        return runCatching {
            for (i in cn.indices) {
                val tmpNum = ChnMap[cn[i]] ?: return -1
                when {
                    tmpNum == 100000000 -> {
                        result += tmp
                        result *= tmpNum
                        billion = billion * 100000000 + result
                        result = 0
                        tmp = 0
                    }

                    tmpNum == 10000 -> {
                        result += tmp
                        result *= tmpNum
                        tmp = 0
                    }

                    tmpNum >= 10 -> {
                        if (tmp == 0) tmp = 1
                        result += tmpNum * tmp
                        tmp = 0
                    }

                    else -> {
                        tmp = if (i >= 2 && i == cn.size - 1 && (ChnMap[cn[i - 1]] ?: 0) > 10)
                            tmpNum * (ChnMap[cn[i - 1]] ?: 1) / 10
                        else
                            tmp * 10 + tmpNum
                    }
                }
            }
            result += tmp + billion
            result
        }.getOrDefault(-1)
    }

    private val ChnMap: Map<Char, Int> by lazy {
        val map = HashMap<Char, Int>()
        val cnStr1 = "零一二三四五六七八九十"
        for (i in cnStr1.indices) {
            map[cnStr1[i]] = i
        }
        val cnStr2 = "〇壹贰叁肆伍陆柒捌玖拾"
        for (i in cnStr2.indices) {
            map[cnStr2[i]] = i
        }
        map['两'] = 2
        map['百'] = 100
        map['佰'] = 100
        map['千'] = 1000
        map['仟'] = 1000
        map['万'] = 10000
        map['亿'] = 100000000
        map
    }
}
