package com.akram.ecosystem.core

import java.io.File
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.X509Certificate
import java.util.Date
import org.bouncycastle.asn1.x500.X500Name
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder

/**
 * This device's long-lived TLS identity: a P-256 key and self-signed certificate,
 * persisted as PKCS#12 in the app's private files dir. See docs/protocol.md §1, §5.
 */
class Identity private constructor(
    val privateKey: PrivateKey,
    val certificate: X509Certificate,
) {
    val certDer: ByteArray get() = certificate.encoded

    companion object {
        private const val ALIAS = "ecosystem"
        private const val FILE_NAME = "ecosystem.p12"
        private val PASSWORD = "ecosystem-local".toCharArray()
        private const val TEN_YEARS_MILLIS = 10L * 365 * 24 * 60 * 60 * 1000

        fun loadOrCreate(dir: File): Identity {
            val file = File(dir, FILE_NAME)
            if (file.exists()) return load(file)

            val keyPair = KeyPairGenerator.getInstance("EC")
                .apply { initialize(256) }
                .generateKeyPair()
            val now = System.currentTimeMillis()
            val name = X500Name("CN=Ecosystem-Android")
            val holder = JcaX509v3CertificateBuilder(
                /* issuer = */ name,
                /* serial = */ BigInteger.valueOf(now),
                /* notBefore = */ Date(now - 24 * 60 * 60 * 1000),
                /* notAfter = */ Date(now + TEN_YEARS_MILLIS),
                /* subject = */ name,
                keyPair.public,
            ).build(JcaContentSignerBuilder("SHA256withECDSA").build(keyPair.private))
            val cert = JcaX509CertificateConverter().getCertificate(holder)

            val ks = KeyStore.getInstance("PKCS12")
            ks.load(null, null)
            ks.setKeyEntry(ALIAS, keyPair.private, PASSWORD, arrayOf(cert))
            dir.mkdirs()
            file.outputStream().use { ks.store(it, PASSWORD) }
            return Identity(keyPair.private, cert)
        }

        private fun load(file: File): Identity {
            val ks = KeyStore.getInstance("PKCS12")
            file.inputStream().use { ks.load(it, PASSWORD) }
            return Identity(
                ks.getKey(ALIAS, PASSWORD) as PrivateKey,
                ks.getCertificate(ALIAS) as X509Certificate,
            )
        }
    }
}
