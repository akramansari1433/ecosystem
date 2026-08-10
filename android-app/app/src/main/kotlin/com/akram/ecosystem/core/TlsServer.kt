package com.akram.ecosystem.core

import java.security.KeyStore
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import javax.net.ssl.X509TrustManager

/**
 * TOFU trust: before pairing accepts any non-empty chain (recording the leaf);
 * after pairing requires an exact DER match of the pinned certificate.
 *
 * The pin is read per-handshake via [pinProvider] so pairing/unpairing takes
 * effect immediately without rebinding the server socket (rebinding changes the
 * port and leaves a stale mDNS record behind).
 */
class PinnedTrustManager(private val pinProvider: () -> ByteArray?) : X509TrustManager {
    @Volatile
    var lastPeerDer: ByteArray? = null
        private set

    override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) =
        check(chain)

    override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) =
        check(chain)

    private fun check(chain: Array<X509Certificate>) {
        val leaf = chain.firstOrNull() ?: throw CertificateException("no peer certificate")
        val der = leaf.encoded
        lastPeerDer = der
        val pinned = pinProvider()
        if (pinned != null && !der.contentEquals(pinned)) {
            throw CertificateException("peer certificate does not match pinned identity")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** TLS server socket presenting [identity], requiring a client certificate. */
class TlsServer(identity: Identity, pinProvider: () -> ByteArray?) {
    private val context: SSLContext

    init {
        val ks = KeyStore.getInstance("PKCS12")
        ks.load(null, null)
        ks.setKeyEntry("ecosystem", identity.privateKey, CharArray(0),
            arrayOf(identity.certificate))
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, CharArray(0))
        context = SSLContext.getInstance("TLS")
        context.init(kmf.keyManagers, arrayOf(PinnedTrustManager(pinProvider)), null)
    }

    /** Bound on an ephemeral port; read the port from [SSLServerSocket.getLocalPort]. */
    fun listen(): SSLServerSocket =
        (context.serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {
            // No client certificate: the Mac proves itself with an HMAC
            // challenge-response instead (see PairingSecret).
            needClientAuth = false
            wantClientAuth = false
        }
}
