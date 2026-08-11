package com.akram.ecosystem.core

import java.io.File
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Every Mac this phone has been paired with, each with its own shared secret.
 *
 * Keyed by the Mac's device id, so several Macs can be paired at once and each
 * proves itself with its own secret — pairing a laptop must not unpair a desktop.
 */
object PairedPeers {

    @Serializable
    data class Peer(
        val deviceId: String,
        val name: String,
        val secretHex: String,
    )

    @Serializable
    private data class Store(val peers: List<Peer> = emptyList())

    private const val FILE_NAME = "paired-peers.json"
    private const val LEGACY_SECRET = "pair-secret.bin"
    private val json = Json { ignoreUnknownKeys = true }

    fun all(dir: File): List<Peer> {
        val file = File(dir, FILE_NAME)
        if (!file.exists()) return emptyList()
        return runCatching { json.decodeFromString<Store>(file.readText()).peers }
            .getOrDefault(emptyList())
    }

    fun isEmpty(dir: File) = all(dir).isEmpty() && legacySecret(dir) == null

    @OptIn(ExperimentalStdlibApi::class)
    fun secretFor(dir: File, deviceId: String): ByteArray? =
        all(dir).firstOrNull { it.deviceId == deviceId }
            ?.secretHex?.let { runCatching { it.hexToByteArray() }.getOrNull() }

    @OptIn(ExperimentalStdlibApi::class)
    fun add(dir: File, deviceId: String, name: String, secret: ByteArray) {
        val peers = all(dir).filterNot { it.deviceId == deviceId } +
            Peer(deviceId, name, secret.toHexString())
        File(dir, FILE_NAME).writeText(json.encodeToString(Store(peers)))
    }

    fun remove(dir: File, deviceId: String) {
        val peers = all(dir).filterNot { it.deviceId == deviceId }
        File(dir, FILE_NAME).writeText(json.encodeToString(Store(peers)))
    }

    fun clear(dir: File) {
        File(dir, FILE_NAME).delete()
        File(dir, LEGACY_SECRET).delete()
    }

    /**
     * The single secret written before multiple Macs were supported. Used once to
     * recognise an already-paired Mac, which is then recorded under its device id
     * so nobody has to pair again after updating.
     */
    fun legacySecret(dir: File): ByteArray? =
        File(dir, LEGACY_SECRET).takeIf { it.exists() }?.readBytes()

    fun retireLegacySecret(dir: File) {
        File(dir, LEGACY_SECRET).delete()
    }
}
