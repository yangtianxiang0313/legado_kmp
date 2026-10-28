@file:OptIn(kotlinx.cinterop.ExperimentalForeignApi::class)

package io.legado.kmp.shared.image

import kotlinx.cinterop.ByteVar
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.readBytes
import kotlinx.cinterop.reinterpret
import kotlinx.cinterop.useContents
import kotlinx.cinterop.usePinned
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import platform.CoreFoundation.CFDataCreateMutable
import platform.CoreFoundation.CFDataGetBytePtr
import platform.CoreFoundation.CFDataGetLength
import platform.CoreFoundation.CFRelease
import platform.CoreFoundation.CFStringCreateWithCString
import platform.CoreFoundation.kCFStringEncodingUTF8
import platform.CoreGraphics.CGBitmapContextCreate
import platform.CoreGraphics.CGBitmapContextCreateImage
import platform.CoreGraphics.CGColorSpaceCreateDeviceRGB
import platform.CoreGraphics.CGColorSpaceRelease
import platform.CoreGraphics.CGContextClearRect
import platform.CoreGraphics.CGContextConcatCTM
import platform.CoreGraphics.CGContextDrawImage
import platform.CoreGraphics.CGContextDrawPDFPage
import platform.CoreGraphics.CGContextRef
import platform.CoreGraphics.CGContextRelease
import platform.CoreGraphics.CGDataProviderCreateWithCFData
import platform.CoreGraphics.CGDataProviderRelease
import platform.CoreGraphics.CGImageAlphaInfo
import platform.CoreGraphics.CGImageGetHeight
import platform.CoreGraphics.CGImageGetWidth
import platform.CoreGraphics.CGImageRef
import platform.CoreGraphics.CGImageRelease
import platform.CoreGraphics.kCGPDFMediaBox
import platform.CoreGraphics.CGPDFDocumentCreateWithProvider
import platform.CoreGraphics.CGPDFDocumentGetNumberOfPages
import platform.CoreGraphics.CGPDFDocumentGetPage
import platform.CoreGraphics.CGPDFDocumentRelease
import platform.CoreGraphics.CGPDFPageGetBoxRect
import platform.CoreGraphics.CGPDFPageGetDrawingTransform
import platform.CoreGraphics.CGRectMake
import platform.CoreGraphics.kCGBitmapByteOrder32Big
import platform.Foundation.CFBridgingRetain
import platform.Foundation.NSData
import platform.ImageIO.CGImageDestinationAddImage
import platform.ImageIO.CGImageDestinationCreateWithData
import platform.ImageIO.CGImageDestinationFinalize
import platform.UIKit.UIImage

internal suspend fun encodeLocalBookSvgSnapshot(image: UIImage, document: LocalBookSvgDocument): ByteArray =
    withContext(Dispatchers.Default) {
        val cgImage = checkNotNull(image.CGImage) { "Local book SVG snapshot has no pixel image" }
        val width = CGImageGetWidth(cgImage).toLong()
        val height = CGImageGetHeight(cgImage).toLong()
        check(width in 1..4096 && height in 1..4096 && width * height <= 10_000_000L &&
            kotlin.math.abs(width - document.width) <= 1 && kotlin.math.abs(height - document.height) <= 1
        ) { "Local book SVG snapshot has unexpected pixel dimensions" }
        rasterLocalBookSvg(document, rejectWhiteSnapshot = true) { context ->
            CGContextDrawImage(context, CGRectMake(0.0, 0.0, document.width.toDouble(), document.height.toDouble()), cgImage)
        }
    }

internal suspend fun encodeLocalBookSvgPdf(pdf: NSData, document: LocalBookSvgDocument): ByteArray =
    withContext(Dispatchers.Default) {
        require(pdf.length in 1uL..(32uL * 1024uL * 1024uL)) { "Local book SVG PDF exceeds the 32 MiB limit" }
        currentCoroutineContext().ensureActive()
        val data = checkNotNull(CFBridgingRetain(pdf))
        try {
            val provider = checkNotNull(CGDataProviderCreateWithCFData(data.reinterpret())) { "Cannot read SVG PDF" }
            try {
                val pdfDocument = checkNotNull(CGPDFDocumentCreateWithProvider(provider)) { "Invalid local book SVG PDF" }
                try {
                    check(CGPDFDocumentGetNumberOfPages(pdfDocument) == 1uL) { "Local book SVG PDF must have one page" }
                    val page = checkNotNull(CGPDFDocumentGetPage(pdfDocument, 1uL)) { "Local book SVG PDF has no page" }
                    val box = CGPDFPageGetBoxRect(page, kCGPDFMediaBox)
                    check(box.useContents {
                        size.width.isFinite() && size.height.isFinite() && size.width > 0.0 && size.height > 0.0 &&
                            kotlin.math.abs(size.width / document.width - size.height / document.height) < 0.01
                    }) { "Local book SVG PDF has unexpected page dimensions" }
                    rasterLocalBookSvg(document, rejectWhiteSnapshot = false) { context ->
                        val rect = CGRectMake(0.0, 0.0, document.width.toDouble(), document.height.toDouble())
                        CGContextConcatCTM(context, CGPDFPageGetDrawingTransform(page, kCGPDFMediaBox, rect, 0, true))
                        CGContextDrawPDFPage(context, page)
                    }
                } finally {
                    CGPDFDocumentRelease(pdfDocument)
                }
            } finally {
                CGDataProviderRelease(provider)
            }
        } finally {
            CFRelease(data)
        }
    }

private suspend fun rasterLocalBookSvg(
    document: LocalBookSvgDocument,
    rejectWhiteSnapshot: Boolean,
    draw: (CGContextRef) -> Unit,
): ByteArray {
    val coroutineContext = currentCoroutineContext()
    coroutineContext.ensureActive()
    // Explicit RGBA storage is zero-initialized, never prefilled with a white PDF page.
    val pixels = ByteArray(document.width * document.height * 4)
    return pixels.usePinned { pinned ->
        val colorSpace = checkNotNull(CGColorSpaceCreateDeviceRGB()) { "Cannot create SVG RGB color space" }
        try {
            val context = checkNotNull(CGBitmapContextCreate(
                pinned.addressOf(0), document.width.convert(), document.height.convert(), 8uL,
                (document.width * 4).convert(), colorSpace,
                CGImageAlphaInfo.kCGImageAlphaPremultipliedLast.value or kCGBitmapByteOrder32Big,
            )) { "Cannot create transparent SVG raster context" }
            try {
                CGContextClearRect(context, CGRectMake(0.0, 0.0, document.width.toDouble(), document.height.toDouble()))
                draw(context)
                coroutineContext.ensureActive()
                var visible = false
                var allOpaqueWhite = true
                for (offset in pixels.indices step 4) {
                    if (offset % (document.width * 4) == 0) coroutineContext.ensureActive()
                    val alpha = pixels[offset + 3].toInt() and 255
                    if (alpha != 0) visible = true
                    if (alpha != 255 || pixels[offset] != (-1).toByte() ||
                        pixels[offset + 1] != (-1).toByte() || pixels[offset + 2] != (-1).toByte()
                    ) allOpaqueWhite = false
                }
                check(visible) { "Local book SVG capture is fully transparent; no painted pixels were produced" }
                // Detached WK snapshots sometimes report success with only an opaque white canvas.
                // A legitimately white SVG is accepted through transparent PDF capture instead.
                check(!rejectWhiteSnapshot || !allOpaqueWhite) { "Local book SVG snapshot is an unconfirmed white canvas" }
                val image = checkNotNull(CGBitmapContextCreateImage(context)) { "Cannot materialize local book SVG pixels" }
                try {
                    encodeLocalBookSvgPng(image).also { coroutineContext.ensureActive() }
                } finally {
                    CGImageRelease(image)
                }
            } finally {
                CGContextRelease(context)
            }
        } finally {
            CGColorSpaceRelease(colorSpace)
        }
    }
}

private fun encodeLocalBookSvgPng(image: CGImageRef): ByteArray {
    val data = checkNotNull(CFDataCreateMutable(null, 0)) { "Cannot allocate SVG PNG buffer" }
    try {
        val type = checkNotNull(CFStringCreateWithCString(null, "public.png", kCFStringEncodingUTF8))
        try {
            val destination = checkNotNull(CGImageDestinationCreateWithData(data, type, 1uL, null)) {
                "Cannot create SVG PNG encoder"
            }
            try {
                CGImageDestinationAddImage(destination, image, null)
                check(CGImageDestinationFinalize(destination)) { "Cannot finish SVG PNG encoding" }
                val length = CFDataGetLength(data)
                check(length in 1..64L * 1024L * 1024L) { "Local book SVG PNG exceeds the 64 MiB output limit" }
                return checkNotNull(CFDataGetBytePtr(data)).reinterpret<ByteVar>().readBytes(length.toInt())
            } finally {
                CFRelease(destination)
            }
        } finally {
            CFRelease(type)
        }
    } finally {
        CFRelease(data)
    }
}
