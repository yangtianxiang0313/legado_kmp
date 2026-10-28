@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.facade

import kotlinx.cinterop.LongVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.alloc
import kotlinx.cinterop.allocArrayOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.ptr
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.usePinned
import kotlinx.cinterop.value
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import okio.Buffer
import okio.ByteString
import okio.HashingSink
import okio.blackholeSink
import platform.CoreFoundation.CFDataCreate
import platform.CoreFoundation.CFDictionaryCreate
import platform.CoreFoundation.CFDictionaryGetValue
import platform.CoreFoundation.CFDictionaryRef
import platform.CoreFoundation.CFNumberGetValue
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringRef
import platform.CoreFoundation.kCFBooleanTrue
import platform.CoreFoundation.kCFNumberSInt64Type
import platform.CoreGraphics.CGImageRelease
import platform.ImageIO.CGImageSourceCopyPropertiesAtIndex
import platform.ImageIO.CGImageSourceCreateImageAtIndex
import platform.ImageIO.CGImageSourceCreateWithData
import platform.ImageIO.CGImageSourceGetCount
import platform.ImageIO.CGImageSourceGetStatus
import platform.ImageIO.CGImageSourceGetStatusAtIndex
import platform.ImageIO.kCGImagePropertyPixelHeight
import platform.ImageIO.kCGImagePropertyPixelWidth
import platform.ImageIO.kCGImageSourceShouldCache
import platform.ImageIO.kCGImageSourceShouldCacheImmediately
import platform.ImageIO.kCGImageStatusComplete

private const val MAX_VALIDATED_IMAGES = 64
private val imageDecodePermit = Semaphore(1)
private val validatedImagesLock = Mutex()
private val validatedImages = LinkedHashSet<ValidatedImageFingerprint>()

private data class ValidatedImageFingerprint(val length: Int, val sha256: ByteString)

/** Only an identical, previously fully decoded snapshot may skip ImageIO validation. */
internal actual suspend fun validateCacheImage(bytes: ByteArray) = withContext(Dispatchers.Default) {
    require(bytes.isNotEmpty() && bytes.size <= 64 * 1024 * 1024) { "Chapter image is empty or too large" }
    currentCoroutineContext().ensureActive()

    // Never hash the caller's mutable bytes and then decode a different version of them.
    // Each call temporarily owns one compressed copy; only a miss also creates CFData.
    val snapshot = bytes.copyOf()
    val fingerprint = imageFingerprint(snapshot)
    if (!wasImageValidated(fingerprint)) {
        imageDecodePermit.withPermit {
            currentCoroutineContext().ensureActive()
            // Another caller may have completed the same content while we waited.
            if (!wasImageValidated(fingerprint)) {
                decodeCacheImageSnapshot(snapshot)
                rememberValidatedImage(fingerprint)
            }
        }
    }
    currentCoroutineContext().ensureActive()
}

private suspend fun imageFingerprint(snapshot: ByteArray): ValidatedImageFingerprint {
    // Stream through a bounded buffer instead of making another image-sized hash copy.
    val buffer = Buffer()
    val sink = HashingSink.sha256(blackholeSink())
    return try {
        var offset = 0
        while (offset < snapshot.size) {
            currentCoroutineContext().ensureActive()
            val count = minOf(64 * 1024, snapshot.size - offset)
            buffer.write(snapshot, offset, count)
            sink.write(buffer, count.toLong())
            offset += count
        }
        currentCoroutineContext().ensureActive()
        ValidatedImageFingerprint(snapshot.size, sink.hash)
    } finally {
        sink.close()
    }
}

private suspend fun wasImageValidated(fingerprint: ValidatedImageFingerprint): Boolean = validatedImagesLock.withLock {
    currentCoroutineContext().ensureActive()
    val hit = validatedImages.remove(fingerprint)
    if (hit) validatedImages.add(fingerprint)
    hit
}

private suspend fun rememberValidatedImage(fingerprint: ValidatedImageFingerprint) = validatedImagesLock.withLock {
    currentCoroutineContext().ensureActive()
    validatedImages.remove(fingerprint)
    validatedImages.add(fingerprint)
    if (validatedImages.size > MAX_VALIDATED_IMAGES) {
        val oldest = validatedImages.iterator()
        oldest.next()
        oldest.remove()
    }
}

/** Called only under the process-wide permit; all native allocations are released before recording success. */
private suspend fun decodeCacheImageSnapshot(snapshot: ByteArray) {
    currentCoroutineContext().ensureActive()
    val data = snapshot.usePinned { pinned ->
        checkNotNull(CFDataCreate(null, pinned.addressOf(0).reinterpret(), snapshot.size.convert()))
    }
    try {
        val source = checkNotNull(CGImageSourceCreateWithData(data, null)) { "Chapter image format is not supported" }
        try {
            check(CGImageSourceGetStatus(source) == kCGImageStatusComplete) { "Chapter image container is incomplete" }
            val frames = CGImageSourceGetCount(source)
            require(frames > 0uL && frames <= 512uL) { "Chapter image has no frames or exceeds the frame limit" }
            memScoped {
                val keys = allocArrayOf(kCGImageSourceShouldCache, kCGImageSourceShouldCacheImmediately)
                val values = allocArrayOf(kCFBooleanTrue, kCFBooleanTrue)
                val options = checkNotNull(CFDictionaryCreate(null, keys.reinterpret(), values.reinterpret(), 2, null, null))
                try {
                    var pixels = 0L
                    for (index in 0uL until frames) {
                        currentCoroutineContext().ensureActive()
                        check(CGImageSourceGetStatusAtIndex(source, index) == kCGImageStatusComplete) {
                            "Chapter image frame is incomplete: $index"
                        }
                        val properties = checkNotNull(CGImageSourceCopyPropertiesAtIndex(source, index, null))
                        try {
                            val width = imageDimension(properties, kCGImagePropertyPixelWidth)
                            val height = imageDimension(properties, kCGImagePropertyPixelHeight)
                            require(width in 1..64_000_000L && height in 1..64_000_000L &&
                                width <= 64_000_000L / height
                            ) { "Chapter image dimensions exceed the decode limit" }
                            pixels += width * height
                            require(pixels <= 64_000_000L) { "Chapter image frames exceed the decode limit" }
                        } finally {
                            CFRelease(properties)
                        }
                        val decoded = checkNotNull(CGImageSourceCreateImageAtIndex(source, index, options)) {
                            "Chapter image frame could not be decoded: $index"
                        }
                        CGImageRelease(decoded)
                        check(CGImageSourceGetStatusAtIndex(source, index) == kCGImageStatusComplete) {
                            "Chapter image frame failed decoding: $index"
                        }
                    }
                } finally {
                    CFRelease(options)
                }
            }
        } finally {
            CFRelease(source)
        }
    } finally {
        CFRelease(data)
    }
    currentCoroutineContext().ensureActive()
}

private fun imageDimension(properties: CFDictionaryRef, key: CFStringRef?): Long = memScoped {
    val number = checkNotNull(CFDictionaryGetValue(properties, key)) { "Chapter image dimensions are missing" }
    val value = alloc<LongVar>()
    check(CFNumberGetValue(number.reinterpret(), kCFNumberSInt64Type, value.ptr)) { "Invalid chapter image dimensions" }
    value.value
}
