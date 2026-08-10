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
 */
class PinnedTrustManager(private val pinnedDer: ByteArray?) : X509TrustManager {
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
        if (pinnedDer != null && !der.contentEquals(pinnedDer)) {
            throw CertificateException("peer certificate does not match pinned identity")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
}

/** TLS server socket presenting [identity], requiring a client certificate. */
class TlsServer(identity: Identity, pinnedPeerDer: ByteArray?) {
    private val context: SSLContext

    init {
        val ks = KeyStore.getInstance("PKCS12")
        ks.load(null, null)
        ks.setKeyEntry("ecosystem", identity.privateKey, CharArray(0),
            arrayOf(identity.certificate))
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(ks, CharArray(0))
        context = SSLContext.getInstance("TLS")
        context.init(kmf.keyManagers, arrayOf(PinnedTrustManager(pinnedPeerDer)), null)
    }

    /** Bound on an ephemeral port; read the port from [SSLServerSocket.getLocalPort]. */
    fun listen(): SSLServerSocket =
        (context.serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {
            needClientAuth = true
        }

    companion object {
        /** The peer's leaf certificate DER for an accepted, handshaken socket. */
        fun peerDer(socket: SSLSocket): ByteArray =
            (socket.session.peerCertificates.first() as X509Certificate).encoded
    }
}
