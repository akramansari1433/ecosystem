package com.akram.ecosystem.core

import java.security.cert.CertificateException
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class IdentityTest {
    @Test
    fun createsSelfSignedEcCertAndReloadsIdentically() {
        val dir = createTempDirectory("ecosys-identity").toFile()
        val first = Identity.loadOrCreate(dir)

        assertEquals("EC", first.certificate.publicKey.algorithm)
        assertTrue(first.certificate.subjectX500Principal.name.contains("Ecosystem-Android"))
        assertEquals(
            first.certificate.subjectX500Principal, first.certificate.issuerX500Principal)
        first.certificate.checkValidity() // valid now
        assertNotNull(first.privateKey)

        val second = Identity.loadOrCreate(dir)
        assertArrayEquals(first.certDer, second.certDer)
    }

    @Test
    fun distinctDirectoriesYieldDistinctCerts() {
        val a = Identity.loadOrCreate(createTempDirectory("ecosys-a").toFile())
        val b = Identity.loadOrCreate(createTempDirectory("ecosys-b").toFile())
        assertTrue(!a.certDer.contentEquals(b.certDer))
    }
}

class PinnedTrustManagerTest {
    private val identA = Identity.loadOrCreate(createTempDirectory("ecosys-ta").toFile())
    private val identB = Identity.loadOrCreate(createTempDirectory("ecosys-tb").toFile())

    @Test
    fun unpinnedAcceptsAnyAndRecordsLeaf() {
        val tm = PinnedTrustManager { null }
        tm.checkClientTrusted(arrayOf(identA.certificate), "EC")
        assertArrayEquals(identA.certDer, tm.lastPeerDer)
    }

    @Test
    fun pinnedAcceptsExactMatch() {
        val tm = PinnedTrustManager { identA.certDer }
        tm.checkClientTrusted(arrayOf(identA.certificate), "EC")
        assertArrayEquals(identA.certDer, tm.lastPeerDer)
    }

    @Test
    fun pinnedRejectsMismatch() {
        val tm = PinnedTrustManager { identA.certDer }
        assertThrows(CertificateException::class.java) {
            tm.checkClientTrusted(arrayOf(identB.certificate), "EC")
        }
    }

    @Test
    fun pinChangeAppliesToNextHandshakeWithoutRebind() {
        var pin: ByteArray? = null
        val tm = PinnedTrustManager { pin }
        tm.checkClientTrusted(arrayOf(identB.certificate), "EC") // unpaired: anyone
        pin = identA.certDer // pairing completed
        assertThrows(CertificateException::class.java) {
            tm.checkClientTrusted(arrayOf(identB.certificate), "EC")
        }
        tm.checkClientTrusted(arrayOf(identA.certificate), "EC") // pinned peer OK
    }

    @Test
    fun emptyChainRejected() {
        val tm = PinnedTrustManager { null }
        assertThrows(CertificateException::class.java) {
            tm.checkClientTrusted(emptyArray(), "EC")
        }
    }
}
