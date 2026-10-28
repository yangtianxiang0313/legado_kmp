package io.legado.kmp.shared.domain.localbook

actual fun createPlatformPdfBookParser(): PdfBookParser = IosPdfBookParser()

actual fun createPlatformUmdBookParser(): UmdBookParser = BinaryUmdBookParser()

actual fun createPlatformMobiBookParser(fileStore: LocalBookFileStore): MobiBookParser = PalmDocMobiBookParser(fileStore)
