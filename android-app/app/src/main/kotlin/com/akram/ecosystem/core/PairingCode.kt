package com.akram.ecosystem.core

import java.security.MessageDigest

/**
 * Verification code shown on both devices during pairing. See docs/protocol.md §5:
 * uint24(first 3 bytes of SHA-256(concat(sorted([derA, derB])))) mod 1e6, zero-padded.
 */
object PairingCode {
    fun derive(derA: ByteArray, derB: ByteArray): String {
        val (first, second) = if (lexCompare(derA, derB) <= 0) derA to derB else derB to derA
        val digest = MessageDigest.getInstance("SHA-256").digest(first + second)
        val value = (((digest[0].toInt() and 0xFF) shl 16) or
            ((digest[1].toInt() and 0xFF) shl 8) or
            (digest[2].toInt() and 0xFF)) % 1_000_000
        return "%06d".format(value)
    }

    /** Unsigned lexicographic byte comparison (bytes are signed in Kotlin). */
    private fun lexCompare(a: ByteArray, b: ByteArray): Int {
        for (i in 0 until minOf(a.size, b.size)) {
            val cmp = (a[i].toInt() and 0xFF).compareTo(b[i].toInt() and 0xFF)
            if (cmp != 0) return cmp
        }
        return a.size.compareTo(b.size)
    }
}
