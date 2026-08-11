package com.akram.ecosystem.core

import java.io.File

/** Locates protocol/test-vectors by walking up from the test working directory. */
object TestVectors {
    fun file(name: String): File {
        var dir: File? = File(System.getProperty("user.dir") ?: ".").absoluteFile
        while (dir != null) {
            val candidate = File(dir, "protocol/test-vectors/$name")
            if (candidate.exists()) return candidate
            dir = dir.parentFile
        }
        error("test vector not found: $name")
    }
}

@OptIn(ExperimentalStdlibApi::class)
fun ByteArray.toHex(): String = toHexString()

@OptIn(ExperimentalStdlibApi::class)
fun String.hexBytes(): ByteArray = hexToByteArray()
