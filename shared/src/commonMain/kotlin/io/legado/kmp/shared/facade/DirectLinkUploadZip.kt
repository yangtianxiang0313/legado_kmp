package io.legado.kmp.shared.facade

import okio.Buffer

/** A stored UTF-8 ZIP avoids boxing every byte when uploading large files. */
internal fun buildDirectLinkZip(fileName: String, data: ByteArray): ByteArray {
    val name = fileName.encodeToByteArray()
    require(name.size <= 65535) { "文件名过长" }
    val crcTable = IntArray(256) { value ->
        var crc = value
        repeat(8) { crc = (crc ushr 1) xor (if (crc and 1 != 0) 0xedb88320.toInt() else 0) }
        crc
    }
    var crc = -1
    data.forEach { crc = (crc ushr 8) xor crcTable[(crc xor it.toInt()) and 255] }
    crc = crc.inv()
    val output = Buffer()
    output.writeIntLe(0x04034b50).writeShortLe(20).writeShortLe(0x0800)
        .writeShortLe(0).writeShortLe(0).writeShortLe(0).writeIntLe(crc)
        .writeIntLe(data.size).writeIntLe(data.size).writeShortLe(name.size).writeShortLe(0)
        .write(name).write(data)
    val centralOffset = output.size.toInt()
    output.writeIntLe(0x02014b50).writeShortLe(20).writeShortLe(20).writeShortLe(0x0800)
        .writeShortLe(0).writeShortLe(0).writeShortLe(0).writeIntLe(crc)
        .writeIntLe(data.size).writeIntLe(data.size).writeShortLe(name.size)
        .writeShortLe(0).writeShortLe(0).writeShortLe(0).writeShortLe(0).writeIntLe(0).writeIntLe(0).write(name)
    val centralSize = output.size.toInt() - centralOffset
    output.writeIntLe(0x06054b50).writeShortLe(0).writeShortLe(0).writeShortLe(1).writeShortLe(1)
        .writeIntLe(centralSize).writeIntLe(centralOffset).writeShortLe(0)
    return output.readByteArray()
}
