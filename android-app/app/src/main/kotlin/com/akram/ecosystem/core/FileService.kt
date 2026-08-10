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
            .filterNot { it.name.startsWith(".") }
            .sortedWith(compareBy({ !it.isDirectory }, { it.name.lowercase() }))
            .map {
                FsEntry(
                    isDir = it.isDirectory,
                    mtimeMillis = it.lastModified(),
                    name = it.name,
                    size = if (it.isDirectory) 0 else it.length())
            }

    /**
     * Recursively collects files whose extension matches [extensions], reporting
     * each one's path relative to [path]. Skips hidden folders and app-private
     * Android/data & Android/obb (huge, unreadable, and never interesting).
     */
    fun search(
        path: String,
        extensions: Set<String>,
        maxDepth: Int = 8,
        maxResults: Int = 4000,
    ): List<FsEntry> {
        val base = resolve(path)
        val results = mutableListOf<FsEntry>()
        fun walk(dir: File, depth: Int, prefix: String) {
            if (depth > maxDepth || results.size >= maxResults) return
            val children = dir.listFiles() ?: return
            for (child in children) {
                if (results.size >= maxResults) return
                if (child.name.startsWith(".")) continue
                val rel = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
                if (child.isDirectory) {
                    if (rel == "Android/data" || rel == "Android/obb") continue
                    walk(child, depth + 1, rel)
                } else if (child.extension.lowercase() in extensions) {
                    results += FsEntry(
                        isDir = false,
                        mtimeMillis = child.lastModified(),
                        name = child.name,
                        relPath = rel,
                        size = child.length())
                }
            }
        }
        walk(base, 0, "")
        return results.sortedByDescending { it.mtimeMillis }
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
