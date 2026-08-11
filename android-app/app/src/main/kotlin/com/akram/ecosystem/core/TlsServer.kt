package com.akram.ecosystem.core

import java.security.KeyStore
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLServerSocket

/**
 * TLS server presenting the phone's certificate. Clients are not asked for a
 * certificate — the Mac authenticates itself with an HMAC challenge-response
 * instead (see [PairingSecret]).
 */
class TlsServer(identity: Identity) {
    private val context: SSLContext = SSLContext.getInstance("TLS").apply {
        val keystore = KeyStore.getInstance("PKCS12").apply {
            load(null, null)
            setKeyEntry("ecosystem", identity.privateKey, CharArray(0),
                arrayOf(identity.certificate))
        }
        val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        kmf.init(keystore, CharArray(0))
        init(kmf.keyManagers, null, null)
    }

    /** Bound on an ephemeral port; read it from [SSLServerSocket.getLocalPort]. */
    fun listen(): SSLServerSocket =
        (context.serverSocketFactory.createServerSocket(0) as SSLServerSocket).apply {
            needClientAuth = false
            wantClientAuth = false
        }
}
