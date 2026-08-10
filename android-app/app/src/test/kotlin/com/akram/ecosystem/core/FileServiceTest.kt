package com.akram.ecosystem.core

import java.io.File
import kotlin.io.path.createTempDirectory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class FileServiceTest {
    private val root: File = createTempDirectory("ecosys-fs").toFile().canonicalFile
    private val service = FileService(root)

    private fun seed() {
        File(root, "DCIM/Camera").mkdirs()
        File(root, "DCIM/pic.jpg").writeText("hello camera")
        File(root, "notes.txt").writeText("hi")
    }

    @Test
    fun listsEntriesSortedDirsFirst() {
        seed()
        val entries = service.list(root.path + "/DCIM")
        assertEquals(listOf("Camera", "pic.jpg"), entries.map { it.name })
        assertTrue(entries[0].isDir)
        assertEquals(12L, entries[1].size)
    }

    @Test
    fun listRootViaItsOwnPath() {
        seed()
        val names = service.list(root.path).map { it.name }
        assertEquals(listOf("DCIM", "notes.txt"), names)
    }

    @Test
    fun rejectsPathTraversal() {
        seed()
        assertThrows(FileService.PathViolationException::class.java) {
            service.list(root.path + "/DCIM/../..")
        }
        assertThrows(FileService.PathViolationException::class.java) {
            service.resolve("/etc/passwd")
        }
    }

    @Test
    fun downloadTokensAreSingleUse() {
        seed()
        val ready = service.prepareDownload(root.path + "/DCIM/pic.jpg")
        assertEquals(12L, ready.size)
        assertNotNull(service.takeDownload(ready.token))
        assertNull(service.takeDownload(ready.token))
    }

    @Test
    fun uploadTokensResolveDestination() {
        val token = service.prepareUpload(root.path + "/Download/new.bin", 42L)
        val pending = service.takeUpload(token)
        assertNotNull(pending)
        assertEquals(42L, pending!!.size)
        assertTrue(pending.dest.path.endsWith("Download/new.bin"))
        assertNull(service.takeUpload(token))
    }

    @Test
    fun uploadRejectsTraversalDestination() {
        assertThrows(FileService.PathViolationException::class.java) {
            service.prepareUpload(root.path + "/../evil.bin", 1L)
        }
    }
}
