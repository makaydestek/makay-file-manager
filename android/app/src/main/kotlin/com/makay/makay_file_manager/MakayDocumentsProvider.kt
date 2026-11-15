package com.makay.makay_file_manager

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.database.Cursor
import android.database.MatrixCursor
import android.graphics.Point
import android.os.CancellationSignal
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.os.StatFs
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import android.webkit.MimeTypeMap
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Sistem dosya seçici / "Dışa aktar → Kaydet" için Storage Access Framework
 * sağlayıcısı (F Dosya Yöneticisi tarzı).
 *
 * Diğer uygulamalar [Intent.ACTION_CREATE_DOCUMENT] veya
 * [Intent.ACTION_OPEN_DOCUMENT] açtığında bu uygulama depolama kökü olarak
 * listelenir; kullanıcı klasör seçip Kaydet dediğinde [createDocument] +
 * [openDocument] ile dosya ilgili konuma yazılır.
 */
class MakayDocumentsProvider : DocumentsProvider() {

    override fun onCreate(): Boolean = true

    override fun queryRoots(projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_ROOT_PROJECTION)
        val appName = context?.getString(R.string.app_documents_root_title)
            ?: "Makay Dosya Yöneticisi"
        val base = storageRoot() ?: return result

        val free = try {
            StatFs(base.absolutePath).availableBytes
        } catch (_: Exception) {
            -1L
        }
        val flags = Root.FLAG_LOCAL_ONLY or
            Root.FLAG_SUPPORTS_CREATE or
            Root.FLAG_SUPPORTS_IS_CHILD

        result.newRow().apply {
            add(Root.COLUMN_ROOT_ID, ROOT_ID)
            add(Root.COLUMN_DOCUMENT_ID, docIdForFile(base))
            add(Root.COLUMN_TITLE, appName)
            add(Root.COLUMN_SUMMARY, base.absolutePath)
            add(Root.COLUMN_FLAGS, flags)
            add(Root.COLUMN_ICON, R.mipmap.ic_launcher)
            add(Root.COLUMN_MIME_TYPES, "*/*")
            if (free >= 0) add(Root.COLUMN_AVAILABLE_BYTES, free)
        }
        return result
    }

    override fun queryDocument(documentId: String, projection: Array<out String>?): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        includeFile(result, fileForDocId(documentId))
        return result
    }

    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val result = MatrixCursor(projection ?: DEFAULT_DOCUMENT_PROJECTION)
        val parent = fileForDocId(parentDocumentId)
        if (!parent.isDirectory) return result
        val children = parent.listFiles() ?: return result
        // Klasörler önce, sonra ada göre.
        children.sortedWith(
            compareBy<File> { !it.isDirectory }.thenBy { it.name.lowercase() },
        ).forEach { child ->
            // Geçici / sistem gürültüsünü azalt (gizli dosyalar hariç tutulmaz).
            if (child.name == "." || child.name == "..") return@forEach
            includeFile(result, child)
        }
        return result
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val file = fileForDocId(documentId)
        if (!file.exists() && mode.contains("w")) {
            file.parentFile?.mkdirs()
            if (!file.createNewFile()) {
                throw FileNotFoundException("Dosya açılamadı: $documentId")
            }
        }
        val accessMode = ParcelFileDescriptor.parseMode(mode)
        return ParcelFileDescriptor.open(file, accessMode)
    }

    override fun openDocumentThumbnail(
        documentId: String,
        sizeHint: Point,
        signal: CancellationSignal?,
    ): AssetFileDescriptor? {
        // Küçük görseller için doğrudan dosya; diğer MIME'lerde yok sayılır.
        val file = fileForDocId(documentId)
        val mime = mimeTypeFor(file)
        if (!mime.startsWith("image/")) return null
        val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        return AssetFileDescriptor(pfd, 0, AssetFileDescriptor.UNKNOWN_LENGTH)
    }

    /**
     * Kaydet / dışa aktar: seçilen klasörde yeni dosya (veya klasör) oluşturur.
     */
    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        val parent = fileForDocId(parentDocumentId)
        if (!parent.isDirectory || !parent.canWrite()) {
            throw FileNotFoundException("Yazılamayan klasör: $parentDocumentId")
        }
        val safeName = sanitizeDisplayName(displayName)
        val isDir = mimeType == Document.MIME_TYPE_DIR
        var target = File(parent, safeName)

        // Çakışmada (1), (2)… — sistem CREATE_DOCUMENT davranışı.
        if (target.exists()) {
            target = uniqueChild(parent, safeName, isDir)
        }

        val ok = try {
            if (isDir) {
                target.mkdirs()
            } else {
                target.parentFile?.mkdirs()
                target.createNewFile()
            }
        } catch (e: IOException) {
            throw FileNotFoundException(
                "Oluşturulamadı ($safeName): ${e.message}",
            )
        }
        if (!ok && !target.exists()) {
            throw FileNotFoundException("Oluşturulamadı: $safeName")
        }
        target.setWritable(true, false)
        target.setReadable(true, false)
        return docIdForFile(target)
    }

    override fun deleteDocument(documentId: String) {
        val file = fileForDocId(documentId)
        if (!deleteRecursively(file)) {
            throw FileNotFoundException("Silinemedi: $documentId")
        }
    }

    override fun renameDocument(documentId: String, displayName: String): String {
        val file = fileForDocId(documentId)
        val parent = file.parentFile
            ?: throw FileNotFoundException("Üst klasör yok: $documentId")
        val safeName = sanitizeDisplayName(displayName)
        var dest = File(parent, safeName)
        if (dest.exists()) {
            dest = uniqueChild(parent, safeName, file.isDirectory)
        }
        if (!file.renameTo(dest)) {
            throw FileNotFoundException("Yeniden adlandırılamadı: $documentId")
        }
        return docIdForFile(dest)
    }

    override fun isChildDocument(parentDocumentId: String, documentId: String): Boolean {
        return try {
            val parent = fileForDocId(parentDocumentId).canonicalFile
            val child = fileForDocId(documentId).canonicalFile
            var walk: File? = child
            while (walk != null) {
                if (walk == parent) return true
                walk = walk.parentFile
            }
            false
        } catch (_: Exception) {
            false
        }
    }

    override fun getDocumentType(documentId: String): String {
        return mimeTypeFor(fileForDocId(documentId))
    }

    // --- yardımcılar -------------------------------------------------------

    private fun storageRoot(): File? {
        val base = Environment.getExternalStorageDirectory() ?: return null
        return if (base.exists()) base else null
    }

    private fun docIdForFile(file: File): String {
        val root = storageRoot()?.canonicalFile
            ?: throw FileNotFoundException("Depolama kökü yok")
        val canonical = try {
            file.canonicalFile
        } catch (_: IOException) {
            file.absoluteFile
        }
        if (canonical == root) return "$ROOT_ID:"
        val rootPath = root.path
        val path = canonical.path
        if (!path.startsWith(rootPath)) {
            throw FileNotFoundException("Kök dışında: $path")
        }
        var rel = path.substring(rootPath.length)
        if (rel.startsWith(File.separator)) rel = rel.substring(1)
        // SAF belge kimliklerinde ayırıcı her zaman '/' 
        rel = rel.replace(File.separatorChar, '/')
        return "$ROOT_ID:$rel"
    }

    private fun fileForDocId(documentId: String): File {
        val root = storageRoot()
            ?: throw FileNotFoundException("Depolama kökü yok")
        if (documentId == ROOT_ID || documentId == "$ROOT_ID:") {
            return root
        }
        if (!documentId.startsWith("$ROOT_ID:")) {
            throw FileNotFoundException("Geçersiz belge: $documentId")
        }
        val rel = documentId.substring(ROOT_ID.length + 1)
            .replace('/', File.separatorChar)
            .trimStart(File.separatorChar)
        if (rel.isEmpty()) return root
        // Path traversal engeli.
        if (rel.contains("..")) {
            throw SecurityException("Geçersiz yol: $documentId")
        }
        val file = File(root, rel)
        val canonical = try {
            file.canonicalFile
        } catch (_: IOException) {
            file.absoluteFile
        }
        val rootCanon = root.canonicalFile
        if (canonical != rootCanon &&
            !canonical.path.startsWith(rootCanon.path + File.separator)
        ) {
            throw SecurityException("Kök dışı erişim: $documentId")
        }
        return file
    }

    private fun includeFile(result: MatrixCursor, file: File) {
        if (!file.exists()) return
        var flags = 0
        if (file.isDirectory) {
            if (file.canWrite()) {
                flags = flags or Document.FLAG_DIR_SUPPORTS_CREATE
            }
            flags = flags or Document.FLAG_SUPPORTS_DELETE or
                Document.FLAG_SUPPORTS_RENAME or
                Document.FLAG_SUPPORTS_WRITE
        } else {
            if (file.canWrite()) {
                flags = flags or Document.FLAG_SUPPORTS_WRITE or
                    Document.FLAG_SUPPORTS_DELETE or
                    Document.FLAG_SUPPORTS_RENAME
            }
            val mime = mimeTypeFor(file)
            if (mime.startsWith("image/")) {
                flags = flags or Document.FLAG_SUPPORTS_THUMBNAIL
            }
        }
        val mime = mimeTypeFor(file)
        val isRoot = try {
            file.canonicalFile == storageRoot()?.canonicalFile
        } catch (_: Exception) {
            false
        }
        result.newRow().apply {
            add(Document.COLUMN_DOCUMENT_ID, docIdForFile(file))
            add(
                Document.COLUMN_DISPLAY_NAME,
                if (isRoot) ROOT_DISPLAY else file.name.ifEmpty { ROOT_DISPLAY },
            )
            add(Document.COLUMN_MIME_TYPE, mime)
            add(Document.COLUMN_FLAGS, flags)
            add(Document.COLUMN_SIZE, if (file.isFile) file.length() else 0L)
            add(Document.COLUMN_LAST_MODIFIED, file.lastModified())
            add(Document.COLUMN_ICON, null)
        }
    }

    private fun mimeTypeFor(file: File): String {
        if (file.isDirectory) return Document.MIME_TYPE_DIR
        val name = file.name
        val dot = name.lastIndexOf('.')
        if (dot >= 0 && dot < name.length - 1) {
            val ext = name.substring(dot + 1).lowercase()
            val mapped = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            if (!mapped.isNullOrBlank()) return mapped
        }
        return "application/octet-stream"
    }

    private fun sanitizeDisplayName(name: String): String {
        var n = name.trim()
        if (n.isEmpty()) n = "adsiz"
        // Windows/Android yasak karakterler.
        n = n.replace(Regex("""[\\/:*?"<>|\u0000]"""), "_")
        if (n == "." || n == "..") n = "_$n"
        return n
    }

    private fun uniqueChild(parent: File, name: String, isDir: Boolean): File {
        val dot = name.lastIndexOf('.')
        val hasExt = !isDir && dot > 0
        val base = if (hasExt) name.substring(0, dot) else name
        val ext = if (hasExt) name.substring(dot) else ""
        var i = 1
        while (true) {
            val candidate = File(parent, "$base ($i)$ext")
            if (!candidate.exists()) return candidate
            i++
            if (i > 10_000) return File(parent, "$base-${System.currentTimeMillis()}$ext")
        }
    }

    private fun deleteRecursively(file: File): Boolean {
        if (file.isDirectory) {
            file.listFiles()?.forEach { child ->
                if (!deleteRecursively(child)) return false
            }
        }
        return file.delete() || !file.exists()
    }

    companion object {
        const val ROOT_ID = "primary"
        private const val ROOT_DISPLAY = "Dahili depolama"

        private val DEFAULT_ROOT_PROJECTION = arrayOf(
            Root.COLUMN_ROOT_ID,
            Root.COLUMN_FLAGS,
            Root.COLUMN_ICON,
            Root.COLUMN_TITLE,
            Root.COLUMN_SUMMARY,
            Root.COLUMN_DOCUMENT_ID,
            Root.COLUMN_AVAILABLE_BYTES,
            Root.COLUMN_MIME_TYPES,
        )

        private val DEFAULT_DOCUMENT_PROJECTION = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_FLAGS,
            Document.COLUMN_SIZE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_ICON,
        )

        /** Diğer uygulamalara verilecek content URI yetkilisi. */
        fun authority(context: Context): String =
            "${context.packageName}.documents"

        fun rootUri(context: Context) =
            DocumentsContract.buildRootUri(authority(context), ROOT_ID)
    }
}
