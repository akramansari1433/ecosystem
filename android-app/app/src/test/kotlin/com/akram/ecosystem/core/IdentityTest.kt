package com.akram.ecosystem.core

import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
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
