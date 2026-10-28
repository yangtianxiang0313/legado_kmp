package io.legado.kmp.shared.domain.localbook

expect fun createPlatformPdfBookParser(): PdfBookParser

expect fun createPlatformUmdBookParser(): UmdBookParser

expect fun createPlatformMobiBookParser(fileStore: LocalBookFileStore): MobiBookParser
