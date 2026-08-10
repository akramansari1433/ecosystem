package com.akram.ecosystem.core

import java.io.File
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * Pure file-side logic for the fs.* protocol (docs/protocol.md §8): listing,
 * path confinement to [root], and single-use transfer tokens.
 */
class FileService(private val root: File) {
    class PathViolationException(path: String) :
        Exception("path escapes the shared root: $path")

    data class DownloadReady(val token: String, val size: Long)
    data class PendingUpload(val dest: File, val size: Long)

    private val downloads = ConcurrentHashMap<String, File>()
    private val uploads = ConcurrentHashMap<String, PendingUpload>()

    /** Canonicalizes [path] and enforces that it stays under the root. */
    fun resolve(path: String): File {
        val canonical = File(path).canonicalFile
        val rootCanonical = root.canonicalFile
        if (canonical != rootCanonical &&
            !canonical.path.startsWith(rootCanonical.path + File.separator)
        ) {
            throw PathViolationException(path)
        }
        return canonical
    }

    fun list(path: String): List<FsEntry> =
        (resolve(path).listFiles() ?: emptyArray())
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            .map {
                FsEntry(
                    isDir = it.isDirectory,
                    mtimeMillis = it.lastModified(),
                    name = it.name,
                    size = if (it.isDirectory) 0 else it.length())
            }

    fun prepareDownload(path: String): DownloadReady {
        val file = resolve(path)
        val token = UUID.randomUUID().toString()
        downloads[token] = file
        return DownloadReady(token, file.length())
    }

    fun prepareUpload(destPath: String, size: Long): String {
        val dest = resolve(destPath)
        val token = UUID.randomUUID().toString()
        uploads[token] = PendingUpload(dest, size)
        return token
    }

    fun takeDownload(token: String): File? = downloads.remove(token)

    fun takeUpload(token: String): PendingUpload? = uploads.remove(token)
}
