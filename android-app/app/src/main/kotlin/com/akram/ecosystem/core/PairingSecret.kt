package com.akram.ecosystem.core

import java.io.File
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

/**
 * The Mac authenticates itself with an HMAC challenge-response instead of a TLS
 * client certificate (which forced a keychain on macOS). Both sides derive the
 * same secret from the phone's certificate and the nonce the Mac sent during
 * pairing — the 6-digit code the user compared covers both inputs.
 */
object PairingSecret {
    private const val FILE_NAME = "pair-secret.bin"
    private val random = SecureRandom()

    fun file(dir: File) = File(dir, FILE_NAME)

    fun load(dir: File): ByteArray? = file(dir).takeIf { it.exists() }?.readBytes()

    fun save(dir: File, secret: ByteArray) {
        file(dir).writeBytes(secret)
    }

    fun newNonce(): ByteArray = ByteArray(32).also { random.nextBytes(it) }

    /** HKDF-SHA256(ikm = nonce, salt = peer certificate, info) → 32 bytes. */
    fun derive(nonce: ByteArray, peerCertDer: ByteArray): ByteArray {
        val prk = hmac(peerCertDer, nonce)
        val info = "ecosystem-auth-v1".toByteArray()
        return hmac(prk, info + byteArrayOf(1)).copyOf(32)
    }

    fun response(nonce: ByteArray, secret: ByteArray): String {
        @OptIn(ExperimentalStdlibApi::class)
        return hmac(secret, nonce).toHexString()
    }

    fun constantTimeEquals(a: String, b: String): Boolean {
        if (a.length != b.length) return false
        return MessageDigest.isEqual(a.toByteArray(), b.toByteArray())
    }

    private fun hmac(key: ByteArray, data: ByteArray): ByteArray =
        Mac.getInstance("HmacSHA256").run {
            init(SecretKeySpec(if (key.isEmpty()) ByteArray(32) else key, "HmacSHA256"))
            doFinal(data)
        }
}
