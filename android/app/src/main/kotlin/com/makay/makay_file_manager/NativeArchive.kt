package com.makay.makay_file_manager

import com.github.junrar.Archive
import com.github.junrar.rarfile.FileHeader
import org.apache.commons.compress.archivers.sevenz.SevenZArchiveEntry
import org.apache.commons.compress.archivers.sevenz.SevenZFile
import java.io.File
import java.io.FileOutputStream

/**
 * RAR (junrar) ve 7Z (commons-compress) listeleme / çıkarma.
 *
 * Zip-Slip: çıktı yolu hedef klasörün dışına çıkamaz.
 */
object NativeArchive {

    fun listEntries(path: String, password: String?): List<Map<String, Any?>> {
        val lower = path.lowercase()
        return when {
            lower.endsWith(".rar") -> listRar(path, password)
            lower.endsWith(".7z") -> listSevenZ(path, password)
            else -> throw IllegalArgumentException("Desteklenmeyen biçim")
        }
    }

    fun extractAll(
        path: String,
        destDir: String,
        password: String?,
        entryName: String?,
    ): Int {
        val lower = path.lowercase()
        return when {
            lower.endsWith(".rar") -> extractRar(path, destDir, password, entryName)
            lower.endsWith(".7z") -> extractSevenZ(path, destDir, password, entryName)
            else -> throw IllegalArgumentException("Desteklenmeyen biçim")
        }
    }

    // ------------------------------------------------------------------ RAR --

    private fun openRar(path: String, password: String?): Archive {
        val file = File(path)
        return if (password.isNullOrEmpty()) Archive(file) else Archive(file, password)
    }

    private fun listRar(path: String, password: String?): List<Map<String, Any?>> {
        openRar(path, password).use { archive ->
            val out = ArrayList<Map<String, Any?>>()
            var header: FileHeader? = archive.nextFileHeader()
            while (header != null) {
                val name = (header.fileName ?: "").replace('\\', '/').trim('/')
                if (name.isNotEmpty()) {
                    out.add(
                        mapOf(
                            "name" to name,
                            "isDirectory" to header.isDirectory,
                            "uncompressedSize" to header.fullUnpackSize,
                            "compressedSize" to header.fullPackSize,
                        )
                    )
                }
                header = archive.nextFileHeader()
            }
            return out
        }
    }

    private fun extractRar(
        path: String,
        destDir: String,
        password: String?,
        entryName: String?,
    ): Int {
        val dest = File(destDir)
        dest.mkdirs()
        val destAbs = dest.canonicalPath
        var written = 0
        openRar(path, password).use { archive ->
            var header: FileHeader? = archive.nextFileHeader()
            while (header != null) {
                val name = (header.fileName ?: "").replace('\\', '/').trim('/')
                val wanted = entryName?.replace('\\', '/')?.trim('/')
                val match = when {
                    wanted == null || wanted.isEmpty() -> true
                    name == wanted -> true
                    name.startsWith("$wanted/") -> true
                    else -> false
                }
                if (match && name.isNotEmpty()) {
                    val target = safeTarget(destAbs, name)
                    if (header.isDirectory) {
                        File(target).mkdirs()
                    } else {
                        File(target).parentFile?.mkdirs()
                        FileOutputStream(target).use { out ->
                            archive.extractFile(header, out)
                        }
                        written++
                    }
                }
                header = archive.nextFileHeader()
            }
        }
        return written
    }

    // ------------------------------------------------------------------ 7Z --

    private fun openSevenZ(path: String, password: String?): SevenZFile {
        val builder = SevenZFile.builder().setFile(File(path))
        if (!password.isNullOrEmpty()) {
            builder.setPassword(password.toCharArray())
        }
        return builder.get()
    }

    private fun listSevenZ(path: String, password: String?): List<Map<String, Any?>> {
        openSevenZ(path, password).use { archive ->
            val out = ArrayList<Map<String, Any?>>()
            var entry: SevenZArchiveEntry? = archive.nextEntry
            while (entry != null) {
                val name = entry.name?.replace('\\', '/')?.trim('/') ?: ""
                if (name.isNotEmpty()) {
                    out.add(
                        mapOf(
                            "name" to name,
                            "isDirectory" to entry.isDirectory,
                            "uncompressedSize" to entry.size,
                            "compressedSize" to entry.size,
                        )
                    )
                }
                entry = archive.nextEntry
            }
            return out
        }
    }

    private fun extractSevenZ(
        path: String,
        destDir: String,
        password: String?,
        entryName: String?,
    ): Int {
        val dest = File(destDir)
        dest.mkdirs()
        val destAbs = dest.canonicalPath
        var written = 0
        openSevenZ(path, password).use { archive ->
            var entry: SevenZArchiveEntry? = archive.nextEntry
            while (entry != null) {
                val name = entry.name?.replace('\\', '/')?.trim('/') ?: ""
                val wanted = entryName?.replace('\\', '/')?.trim('/')
                val match = when {
                    wanted == null || wanted.isEmpty() -> true
                    name == wanted -> true
                    name.startsWith("$wanted/") -> true
                    else -> false
                }
                if (match && name.isNotEmpty()) {
                    val target = safeTarget(destAbs, name)
                    if (entry.isDirectory) {
                        File(target).mkdirs()
                    } else {
                        File(target).parentFile?.mkdirs()
                        FileOutputStream(target).use { out ->
                            val buf = ByteArray(64 * 1024)
                            while (true) {
                                val n = archive.read(buf)
                                if (n <= 0) break
                                out.write(buf, 0, n)
                            }
                        }
                        written++
                    }
                }
                entry = archive.nextEntry
            }
        }
        return written
    }

    private fun safeTarget(destAbs: String, entryName: String): String {
        if (entryName.startsWith("/") || entryName.contains("..")) {
            throw SecurityException("Güvenlik ihlali: $entryName")
        }
        val target = File(destAbs, entryName).canonicalPath
        if (target != destAbs && !target.startsWith(destAbs + File.separator)) {
            throw SecurityException("Güvenlik ihlali: $entryName")
        }
        return target
    }
}
