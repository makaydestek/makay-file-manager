package com.makay.makay_file_manager

import android.app.usage.StorageStatsManager
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.StatFs
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/// Makay Dosya Yöneticisi ana aktivitesi.
///
/// Ek olarak uygulama genelinde kullanılan platform kanallarını sunar:
///  - Depolama bilgisi (StatFs): toplam/boş bayt  → Bellek Analizi (A4)
///  - Yüklü uygulamalar (liste, ikon, boyut)     → Uygulamalar ekranı (A6)
///
/// **ANR notu**: uygulama listesi ve ikon üretimi ağır işlerdir (paket başına
/// binder çağrısı + bitmap rasterleştirme + PNG sıkıştırma). Bunlar eskiden
/// platform kanalı işleyicisinde, yani Android ana iş parçacığında çalışıyor
/// ve ana ekran her açıldığında "yanıt vermiyor (Bekle)" diyaloğuna yol
/// açıyordu. Artık [_bg] iş parçacığında çalışır; sonuç ana iş parçacığına
/// `result.success` ile geri verilir.
///
/// **Biyometri**: `local_auth` için [FlutterFragmentActivity] gerekir.
class MainActivity : FlutterFragmentActivity() {

    private val channelName = "com.makay.filemanager/platform"

    /// Ağır paket kanalı işleri için tek iş parçacıklı yürütücü.
    private val _bg: ExecutorService = Executors.newSingleThreadExecutor()

    /// Sonuçları ana iş parçacığına döndürmek için.
    private val _main = Handler(Looper.getMainLooper())

    /// Medya izni istek kodu.
    private val REQ_MEDIA = 4201

    /// Ana ekran klasör kısayolundan gelen gezinme yolu (tek seferlik).
    private var launchBrowsePath: String? = null

    /// Sistem "Paylaş" menüsünden gelen dosyalar (tek seferlik; Flutter alır).
    private var pendingSharedFiles: List<Map<String, Any?>>? = null

    /// Flutter tarafına canlı paylaşım bildirimi için kanal referansı.
    private var platformChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        captureBrowsePath(intent)
        captureSharedIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        captureBrowsePath(intent)
        captureSharedIntent(intent)
    }

    private fun captureBrowsePath(intent: Intent?) {
        val path = intent?.getStringExtra(EXTRA_BROWSE_PATH)
        if (!path.isNullOrBlank()) launchBrowsePath = path
    }

    /// ACTION_SEND / SEND_MULTIPLE içeriğini önbelleğe kopyalayıp bekletir.
    private fun captureSharedIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action ?: return
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) {
            return
        }
        // Ağır kopyalama ana iş parçacığını kilitlemesin.
        _bg.execute {
            val files = resolveSharedFiles(intent)
            if (files.isEmpty()) return@execute
            _main.post {
                // takeSharedFiles temizleyene kadar beklet; dinleyici varsa uyar.
                pendingSharedFiles = files
                platformChannel?.invokeMethod("onSharedFiles", files)
            }
        }
    }

    /// Paylaşılan URI / metni uygulama önbelleğine yazar.
    private fun resolveSharedFiles(intent: Intent): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val dir = File(cacheDir, "shared_inbox").apply {
            if (!exists()) mkdirs()
            // Eski kalıntıları temizle (önceki paylaşım oturumu).
            listFiles()?.forEach { it.delete() }
        }
        when (intent.action) {
            Intent.ACTION_SEND -> {
                val uri = shareStreamUri(intent)
                if (uri != null) {
                    copySharedUri(uri, intent.type, dir)?.let { out.add(it) }
                } else {
                    val text = intent.getStringExtra(Intent.EXTRA_TEXT)
                    if (!text.isNullOrBlank()) {
                        saveSharedText(text, dir)?.let { out.add(it) }
                    }
                }
            }
            Intent.ACTION_SEND_MULTIPLE -> {
                val uris = shareStreamUris(intent)
                for (uri in uris) {
                    copySharedUri(uri, intent.type, dir)?.let { out.add(it) }
                }
            }
        }
        return out
    }

    @Suppress("DEPRECATION")
    private fun shareStreamUri(intent: Intent): Uri? {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri
        }
    }

    @Suppress("DEPRECATION")
    private fun shareStreamUris(intent: Intent): List<Uri> {
        val list = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM)
        }
        return list?.filterNotNull() ?: emptyList()
    }

    private fun copySharedUri(
        uri: Uri,
        fallbackMime: String?,
        dir: File,
    ): Map<String, Any?>? {
        return try {
            // Paylaşan uygulamanın verdiği okuma iznini kalıcılaştır.
            try {
                contentResolver.takePersistableUriPermission(
                    uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                )
            } catch (_: Exception) {
                // Geçici grant'ler için normal; yok say.
            }
            val displayName = queryDisplayName(uri)
                ?: "paylasim_${System.currentTimeMillis()}"
            val safeName = sanitizeFileName(displayName)
            val dest = uniqueFile(dir, safeName)
            contentResolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            val mime = contentResolver.getType(uri)
                ?: fallbackMime
                ?: mimeFromPath(dest.name)
                ?: "*/*"
            mapOf(
                "path" to dest.absolutePath,
                "name" to dest.name,
                "mime" to mime,
                "size" to dest.length()
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun saveSharedText(text: String, dir: File): Map<String, Any?>? {
        return try {
            val dest = uniqueFile(dir, "paylasilan_metin.txt")
            dest.writeText(text)
            mapOf(
                "path" to dest.absolutePath,
                "name" to dest.name,
                "mime" to "text/plain",
                "size" to dest.length()
            )
        } catch (e: Exception) {
            null
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        if (uri.scheme == "file") {
            return uri.lastPathSegment
        }
        return try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (idx >= 0) cursor.getString(idx) else null
                    } else null
                }
                ?: uri.lastPathSegment
        } catch (e: Exception) {
            uri.lastPathSegment
        }
    }

    private fun sanitizeFileName(name: String): String {
        val cleaned = name.replace(Regex("""[\\/:*?"<>|]"""), "_").trim()
        return cleaned.ifEmpty { "paylasim_${System.currentTimeMillis()}" }
    }

    private fun uniqueFile(dir: File, name: String): File {
        var candidate = File(dir, name)
        if (!candidate.exists()) return candidate
        val dot = name.lastIndexOf('.')
        val base = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var i = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base ($i)$ext")
            i++
        }
        return candidate
    }

    /// Klasörü launcher'a sabit kısayol olarak ister.
    private fun pinFolderShortcut(path: String, label: String): Boolean {
        val sm = getSystemService(android.content.pm.ShortcutManager::class.java)
            ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !sm.isRequestPinShortcutSupported) {
            return false
        }
        val id = "folder_" + path.hashCode().toUInt().toString()
        val shortcutIntent = Intent(this, MainActivity::class.java).apply {
            action = Intent.ACTION_VIEW
            putExtra(EXTRA_BROWSE_PATH, path)
            flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val info = android.content.pm.ShortcutInfo.Builder(this, id)
            .setShortLabel(label.take(24).ifEmpty { "Klasör" })
            .setLongLabel(label.take(48).ifEmpty { "Klasör" })
            .setIcon(
                android.graphics.drawable.Icon.createWithResource(
                    this, android.R.drawable.ic_menu_agenda
                )
            )
            .setIntent(shortcutIntent)
            .build()
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            sm.requestPinShortcut(info, null)
        } else {
            @Suppress("DEPRECATION")
            val add = Intent("com.android.launcher.action.INSTALL_SHORTCUT").apply {
                putExtra(Intent.EXTRA_SHORTCUT_INTENT, shortcutIntent)
                putExtra(Intent.EXTRA_SHORTCUT_NAME, label.take(24))
                putExtra(
                    Intent.EXTRA_SHORTCUT_ICON_RESOURCE,
                    Intent.ShortcutIconResource.fromContext(
                        this@MainActivity, android.R.drawable.ic_menu_agenda
                    )
                )
            }
            sendBroadcast(add)
            true
        }
    }

    companion object {
        const val EXTRA_BROWSE_PATH = "browse_path"
    }

    /// Ağır kanal çağrısını arka planda çalıştırıp sonucu ana iş parçacığında
    /// teslim eder. Platform kanalı işleyicisi ana iş parçacığında döndüğü için
    /// [result.success] yalnızca oradan çağrılmalıdır.
    private fun <T> runBackground(result: MethodChannel.Result, work: () -> T) {
        _bg.execute {
            var value: Any? = null
            var failure: Exception? = null
            try {
                value = work()
            } catch (e: Exception) {
                failure = e
            }
            _main.post {
                val err = failure
                if (err != null) result.error("platform_error", err.message, null)
                else result.success(value)
            }
        }
    }

    /// Android 11+ "tüm dosyalara erişim" verildi mi?
    private fun hasAllFilesAccess(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()

    /// Granüler medya (Android 13+) veya READ_EXTERNAL_STORAGE (eski) verildi mi?
    private fun hasMediaPermissions(): Boolean {
        val granted = { p: String ->
            androidx.core.content.ContextCompat.checkSelfPermission(this, p) ==
                android.content.pm.PackageManager.PERMISSION_GRANTED
        }
        return if (Build.VERSION.SDK_INT >= 33) {
            granted(android.Manifest.permission.READ_MEDIA_IMAGES) &&
                granted(android.Manifest.permission.READ_MEDIA_VIDEO) &&
                granted(android.Manifest.permission.READ_MEDIA_AUDIO)
        } else {
            granted(android.Manifest.permission.READ_EXTERNAL_STORAGE)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        platformChannel = channel
        channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getStorageInfo" -> {
                        try {
                            val stat = StatFs(Environment.getExternalStorageDirectory().path)
                            result.success(
                                mapOf(
                                    "total" to stat.totalBytes,
                                    "free" to stat.freeBytes
                                )
                            )
                        } catch (e: Exception) {
                            result.error("storage_error", e.message, null)
                        }
                    }

                    "getInstalledApps" -> {
                        // Ağır iş: ana iş parçacığında kalırsa ANR olur.
                        // İkon YOK — listeler görünür oldukça tek tek istenir.
                        runBackground(result) { installedApps() }
                    }

                    "hasUsageAccess" -> {
                        // StorageStats yalnız bu izinle tüm paketler için okunur.
                        try {
                            result.success(hasUsageAccess())
                        } catch (e: Exception) {
                            result.error("usage_error", e.message, null)
                        }
                    }

                    "openUsageAccessSettings" -> {
                        // Önce bu uygulamanın kullanım erişimi detayına derin
                        // bağlantı; başarısızsa genel liste. Android 13+
                        // sideload'da anahtar "kısıtlı ayar" ile kilitliyse
                        // kullanıcı önce uygulama bilgisinden izin açmalı.
                        try {
                            val detail = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).apply {
                                data = android.net.Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(detail)
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(
                                    Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                )
                                result.success(true)
                            } catch (e2: Exception) {
                                try {
                                    startActivity(Intent(Settings.ACTION_SETTINGS))
                                    result.success(true)
                                } catch (e3: Exception) {
                                    result.error("settings_error", e3.message, null)
                                }
                            }
                        }
                    }

                    "openAppSettings" -> {
                        // Android 13+ "kısıtlı ayarlar": sideload edilmiş
                        // uygulamalara özel erişim (kullanım erişimi) ANCAK
                        // Uygulama bilgisindeki ⋮ menüsünden verilir. Kullanıcıyı
                        // doğrudan o sayfaya götürürüz.
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                                    android.net.Uri.parse("package:$packageName")
                                )
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_SETTINGS))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("settings_error", e2.message, null)
                            }
                        }
                    }

                    "canRequestPackageInstalls" -> {
                        // APK kurulumu için "bilinmeyen kaynaklar" izni durumu
                        // (Android 8 altı her zaman izinli sayılır).
                        try {
                            val ok = Build.VERSION.SDK_INT < Build.VERSION_CODES.O ||
                                packageManager.canRequestPackageInstalls()
                            result.success(ok)
                        } catch (e: Exception) {
                            result.error("install_error", e.message, null)
                        }
                    }

                    "openInstallUnknownSources" -> {
                        // Yalnız bu paket için "Bilinmeyen kaynaklar" ekranı;
                        // açılamazsa genel güvenlik ayarlarına düşülür.
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                    android.net.Uri.parse("package:$packageName")
                                )
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_SECURITY_SETTINGS))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }

                    "getApkInfo" -> {
                        // İndirilenler'de APK'ya dokununca kurulum öncesi bilgi.
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.error("not_found", "APK yolu boş", null)
                        } else {
                            runBackground(result) { apkInfo(path) }
                        }
                    }

                    "getAppIcon" -> {
                        // Tek uygulamanın ikonu (liste ekranı tembel yükler).
                        val pkg = call.argument<String>("packageName")
                        runBackground(result) {
                            appIconPng(pkg ?: return@runBackground null)
                        }
                    }

                    "getVideoThumbnail" -> {
                        // Video liste/ızgara önizlemesi: ilk kare JPEG.
                        val path = call.argument<String>("path")
                        if (path.isNullOrEmpty()) {
                            result.success(null)
                        } else {
                            runBackground(result) { videoThumbnailJpeg(path) }
                        }
                    }

                    "renderPdfPage" -> {
                        // Dahili PDF görüntüleyici: PdfRenderer ile sayfa → JPEG.
                        val path = call.argument<String>("path")
                        val pageIndex = call.argument<Int>("page") ?: 0
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path gerekli", null)
                        } else {
                            runBackground(result) { renderPdfPageJpeg(path, pageIndex) }
                        }
                    }

                    "listNativeArchive" -> {
                        val path = call.argument<String>("path")
                        val password = call.argument<String>("password")
                        if (path.isNullOrEmpty()) {
                            result.error("bad_args", "path gerekli", null)
                        } else {
                            runBackground(result) {
                                NativeArchive.listEntries(path, password)
                            }
                        }
                    }

                    "extractNativeArchive" -> {
                        val path = call.argument<String>("path")
                        val destDir = call.argument<String>("destDir")
                        val password = call.argument<String>("password")
                        val entryName = call.argument<String>("entryName")
                        if (path.isNullOrEmpty() || destDir.isNullOrEmpty()) {
                            result.error("bad_args", "path ve destDir gerekli", null)
                        } else {
                            runBackground(result) {
                                NativeArchive.extractAll(path, destDir, password, entryName)
                            }
                        }
                    }

                    "isTv" -> {
                        // Android TV: leanback veya dokunmatik ekran yok.
                        val pm = packageManager
                        val isTv =
                            pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_LEANBACK) ||
                            !pm.hasSystemFeature(android.content.pm.PackageManager.FEATURE_TOUCHSCREEN)
                        result.success(isTv)
                    }

                    "openDefaultAppsSettings" -> {
                        // Ayarlar → Varsayılan uygulamalar (A15).
                        try {
                            startActivity(Intent(Settings.ACTION_MANAGE_DEFAULT_APPS_SETTINGS))
                            result.success(true)
                        } catch (e: Exception) {
                            try {
                                startActivity(Intent(Settings.ACTION_SETTINGS))
                                result.success(true)
                            } catch (e2: Exception) {
                                result.error("settings_error", e2.message, null)
                            }
                        }
                    }

                    "checkPermissions" -> {
                        // İlk açılış izin onayı (A18): durumu bildir.
                        try {
                            result.success(
                                mapOf(
                                    "allFiles" to hasAllFilesAccess(),
                                    "media" to hasMediaPermissions()
                                )
                            )
                        } catch (e: Exception) {
                            result.error("perm_error", e.message, null)
                        }
                    }

                    "requestAllFilesAccess" -> {
                        // "Tüm dosyalara erişim" yalnızca sistem ayar ekranından
                        // verilebilir; kullanıcıyı o ekrana yönlendiriyoruz.
                        try {
                            startActivity(
                                Intent(
                                    Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    android.net.Uri.parse("package:$packageName")
                                )
                            )
                        } catch (e: Exception) {
                            startActivity(
                                Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION)
                            )
                        }
                        result.success(hasAllFilesAccess())
                    }

                    "requestMediaPermissions" -> {
                        // Android 13+ granüler medya, alt sürümlerde READ_EXTERNAL_STORAGE.
                        try {
                            val perms = if (Build.VERSION.SDK_INT >= 33) {
                                arrayOf(
                                    android.Manifest.permission.READ_MEDIA_IMAGES,
                                    android.Manifest.permission.READ_MEDIA_VIDEO,
                                    android.Manifest.permission.READ_MEDIA_AUDIO
                                )
                            } else {
                                arrayOf(android.Manifest.permission.READ_EXTERNAL_STORAGE)
                            }
                            requestPermissions(perms, REQ_MEDIA)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("perm_error", e.message, null)
                        }
                    }

                    "getStorageVolumes" -> {
                        // USB OTG / SD kart algılama: silinabilir birimler.
                        try {
                            result.success(storageVolumes())
                        } catch (e: Exception) {
                            result.error("volumes_error", e.message, null)
                        }
                    }

                    "installApk" -> {
                        // Otomatik güncelleme: indirilen APK'yı kur (A15).
                        val path = call.argument<String>("path")
                        val file = if (path != null) java.io.File(path) else null
                        if (file == null || !file.exists()) {
                            result.error("not_found", "APK dosyası bulunamadı", null)
                        } else {
                            try {
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    this, "$packageName.fileprovider", file
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/vnd.android.package-archive")
                                    addFlags(
                                        Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                        Intent.FLAG_ACTIVITY_NEW_TASK
                                    )
                                }
                                startActivity(intent)
                                result.success(true)
                            } catch (e: Exception) {
                                result.error("install_error", e.message, null)
                            }
                        }
                    }

                    "openWith" -> {
                        // Dosya yolu veya content:// URI ile sistem "Farklı aç".
                        // Medya oynatıcı codec uyumsuzluğunda yedek yol budur.
                        val path = call.argument<String>("path")
                        val uriArg = call.argument<String>("uri")
                        try {
                            val uri: android.net.Uri
                            val mime: String
                            if (!uriArg.isNullOrBlank()) {
                                uri = android.net.Uri.parse(uriArg)
                                mime = contentResolver.getType(uri)
                                    ?: mimeFromPath(uriArg)
                                    ?: mimeFromPath(path)
                                    ?: "*/*"
                            } else {
                                val file = if (path != null) java.io.File(path) else null
                                if (file == null || !file.exists() || file.isDirectory) {
                                    result.error("not_found", "Dosya bulunamadı", null)
                                    return@setMethodCallHandler
                                }
                                uri = androidx.core.content.FileProvider.getUriForFile(
                                    this, "$packageName.fileprovider", file
                                )
                                mime = mimeFromPath(file.name) ?: "*/*"
                            }
                            val view = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, mime)
                                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                // Chooser hedeflerine URI izninin geçmesi için.
                                clipData = android.content.ClipData.newRawUri("", uri)
                            }
                            startActivity(Intent.createChooser(view, "Farklı aç"))
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("open_error", e.message, null)
                        }
                    }

                    "pinShortcut" -> {
                        // Klasörü ana ekrana sabit kısayol olarak ekle.
                        val path = call.argument<String>("path")
                        val label = call.argument<String>("label") ?: "Klasör"
                        if (path.isNullOrBlank()) {
                            result.error("bad_args", "Yol gerekli", null)
                        } else {
                            try {
                                result.success(pinFolderShortcut(path, label))
                            } catch (e: Exception) {
                                result.error("shortcut_error", e.message, null)
                            }
                        }
                    }

                    "takeLaunchBrowsePath" -> {
                        // Ana ekran kısayolundan gelen yol (bir kez okunur).
                        val path = launchBrowsePath
                        launchBrowsePath = null
                        result.success(path)
                    }

                    "takeSharedFiles" -> {
                        // Sistem paylaşımından gelen dosyalar (bir kez okunur).
                        val files = pendingSharedFiles
                        pendingSharedFiles = null
                        result.success(files)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    /// Yüklü uygulamalar: ad, paket adı, sürüm, sistem uygulaması mı,
    /// boyut (StorageStats; izin yoksa -1) ve APK kaynak yolu.
    ///
    /// **İkon bilerek dönülmez**: ikon üretmek bitmap rasterleştirme + PNG
    /// sıkıştırmadır ve yüzlerce uygulamada onlarca saniye sürerdi. İkonlar
    /// `getAppIcon` ile tek tek, ekranda görünür oldukça istenir.
    private fun installedApps(): List<Map<String, Any?>> {
        val pm = packageManager
        val packages = pm.getInstalledPackages(0)
        return packages.mapNotNull { pi ->
            val ai = pi.applicationInfo ?: return@mapNotNull null
            mapOf(
                "name" to pm.getApplicationLabel(ai).toString(),
                "packageName" to pi.packageName,
                "versionName" to (pi.versionName ?: ""),
                "isSystem" to ((ai.flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                "size" to packageSize(pi.packageName, ai.uid, ai.sourceDir ?: ""),
                // APK yedekleme: kurulum APK'sının gerçek yolu.
                "sourceDir" to (ai.sourceDir ?: "")
            )
        }
    }

    /// Tek bir uygulamanın ikonu (PNG baytları); bulunamazsa null.
    private fun appIconPng(packageName: String): ByteArray? {
        return try {
            val pm = packageManager
            iconPng(pm.getApplicationIcon(pm.getApplicationInfo(packageName, 0)))
        } catch (e: PackageManager.NameNotFoundException) {
            null
        } catch (e: Exception) {
            null
        }
    }

    /// PDF sayfasını JPEG olarak döndürür (`pageCount` + `bytes`).
    ///
    /// Android `PdfRenderer` kullanır; harici native bağımlılık yoktur
    /// (Windows birim testleri / CI bozulmaz).
    private fun renderPdfPageJpeg(path: String, pageIndex: Int): Map<String, Any?>? {
        return try {
            val file = java.io.File(path)
            if (!file.exists()) return null
            val pfd = android.os.ParcelFileDescriptor.open(
                file, android.os.ParcelFileDescriptor.MODE_READ_ONLY
            )
            // PdfRenderer kapanınca PFD'yi de kapatır.
            android.graphics.pdf.PdfRenderer(pfd).use { renderer ->
                val count = renderer.pageCount
                if (count <= 0) {
                    return@use mapOf<String, Any?>("pageCount" to 0, "bytes" to null)
                }
                val idx = pageIndex.coerceIn(0, count - 1)
                renderer.openPage(idx).use { page ->
                    val targetW = 1080
                    val scale = targetW.toFloat() / page.width.coerceAtLeast(1)
                    val w = (page.width * scale).toInt().coerceAtLeast(1)
                    val h = (page.height * scale).toInt().coerceAtLeast(1)
                    val bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                    bitmap.eraseColor(android.graphics.Color.WHITE)
                    page.render(
                        bitmap,
                        null,
                        null,
                        android.graphics.pdf.PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY
                    )
                    val stream = ByteArrayOutputStream()
                    bitmap.compress(Bitmap.CompressFormat.JPEG, 85, stream)
                    bitmap.recycle()
                    mapOf(
                        "pageCount" to count,
                        "page" to idx,
                        "bytes" to stream.toByteArray()
                    )
                }
            }
        } catch (e: Exception) {
            null
        }
    }

    /// Videonun ilk karesini ~256px JPEG olarak döndürür (önizleme).
    ///
    /// `MediaMetadataRetriever` dosyanın ilk senkron karesini verir; büyük
    /// videolarda bile tek kare okunduğu için hızlıdır. Okunamazsa null
    /// döner ve arayüz ikon geri düşmesi yapar.
    private fun videoThumbnailJpeg(path: String): ByteArray? {
        val retriever = android.media.MediaMetadataRetriever()
        return try {
            retriever.setDataSource(path)
            val frame = retriever.getFrameAtTime(
                0,
                android.media.MediaMetadataRetriever.OPTION_CLOSEST_SYNC
            ) ?: return null
            val maxDim = 256
            val scale = minOf(
                maxDim.toFloat() / frame.width.coerceAtLeast(1),
                maxDim.toFloat() / frame.height.coerceAtLeast(1),
                1f
            )
            val w = (frame.width * scale).toInt().coerceAtLeast(1)
            val h = (frame.height * scale).toInt().coerceAtLeast(1)
            val small = android.graphics.Bitmap.createScaledBitmap(frame, w, h, true)
            val out = java.io.ByteArrayOutputStream()
            small.compress(android.graphics.Bitmap.CompressFormat.JPEG, 78, out)
            out.toByteArray()
        } catch (e: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
            }
        }
    }

    /// Uzantıdan MIME türü (sistem oynatıcısı / Farklı aç için).
    private fun mimeFromPath(path: String?): String? {
        if (path.isNullOrBlank()) return null
        val name = path.substringAfterLast('/').substringAfterLast('\\')
        val ext = name.substringAfterLast('.', "").lowercase()
        if (ext.isEmpty() || ext == name.lowercase()) return null
        return android.webkit.MimeTypeMap.getSingleton()
            .getMimeTypeFromExtension(ext)
            ?: when (ext) {
                "mkv" -> "video/x-matroska"
                "ts" -> "video/mp2t"
                "m4v" -> "video/x-m4v"
                "flac" -> "audio/flac"
                "opus" -> "audio/opus"
                "wma" -> "audio/x-ms-wma"
                else -> null
            }
    }

    /// Bağlı depolama birimleri (USB OTG / SD kart / dahili).
    ///
    /// `isRemovable` true olanlar harici (OTG/SD) olarak işaretlenir; Android 9
    /// ve öncesinde `getStorageVolumes()` API 21+ olduğundan her sürümde çalışır.
    private fun storageVolumes(): List<Map<String, Any?>> {
        val sm = getSystemService(Context.STORAGE_SERVICE)
            as android.os.storage.StorageManager
        return sm.storageVolumes.map { vol ->
            val state = try { vol.state } catch (e: Exception) { "" }
            val dir = try { vol.directory?.path ?: "" } catch (e: Exception) { "" }
            mapOf(
                "description" to (vol.getDescription(this) ?: ""),
                "isRemovable" to vol.isRemovable,
                "isEmulated" to vol.isEmulated,
                "state" to state,
                "path" to dir
            )
        }
    }

    override fun onDestroy() {
        _bg.shutdownNow()
        super.onDestroy()
    }

    /// Paket boyutu (API 26+).
    ///
    /// [hasUsageAccess] yoksa yalnızca KENDİ paketimizin boyutu okunabilir;
    /// diğer paketler SecurityException fırlatır. Bu durumda -1 yerine
    /// kurulum APK'sı (base.apk) boyutu döner: ana ekran kartı "0" ya da
    /// yalnız kendi uygulamanın boyutunu göstermez. Tam boyut (app + data)
    /// için kullanıcının Ayarlar → Kullanım erişimi'nden izin vermesi gerekir.
    private fun packageSize(packageName: String, uid: Int, sourceDir: String): Long {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val statsManager =
                    getSystemService(Context.STORAGE_STATS_SERVICE) as StorageStatsManager
                // Varsayılan depolama birimi: 00000000-0000-0000-0000-000000000000
                val defaultUuid = java.util.UUID(0L, 0L)
                val stats = statsManager
                    .queryStatsForPackage(defaultUuid, packageName, Process.myUserHandle())
                return stats.appBytes + stats.dataBytes
            } catch (e: Exception) {
                // İzin yok: aşağıda APK boyutuna düşülür.
            }
        }
        return try {
            if (sourceDir.isEmpty()) -1L else java.io.File(sourceDir).length().coerceAtLeast(-1L)
        } catch (e: Exception) {
            -1L
        }
    }

    /// "Kullanım erişimi" (PACKAGE_USAGE_STATS) izni verildi mi?
    private fun hasUsageAccess(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return true
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE)
                as android.app.AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                appOps.unsafeCheckOpNoThrow(
                    android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(), packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    android.app.AppOpsManager.OPSTR_GET_USAGE_STATS,
                    Process.myUid(), packageName
                )
            }
            mode == android.app.AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }

    /// APK dosyasının paket bilgileri (kurulum diyaloğu için).
    ///
    /// [PackageManager.getPackageArchiveInfo] yalnız dosyadan okur; kurulu
    /// sürümle karşılaştırılarak "Kur" mu "Güncelle" mi gösterilir anlaşılır.
    private fun apkInfo(path: String): Map<String, Any?>? {
        val file = java.io.File(path)
        if (!file.exists()) return null
        val pm = packageManager
        val archive = pm.getPackageArchiveInfo(path, 0) ?: return null
        val ai = archive.applicationInfo
        // Etiket/ikon arşivden okunabilmesi için kaynak yolları dosyaya çevrilir.
        ai?.sourceDir = path
        ai?.publicSourceDir = path
        val label = ai?.let { pm.getApplicationLabel(it).toString() } ?: archive.packageName
        val installed = try {
            pm.getPackageInfo(archive.packageName, 0)
        } catch (e: Exception) {
            null
        }
        return mapOf(
            "name" to label,
            "packageName" to archive.packageName,
            "versionName" to (archive.versionName ?: ""),
            "versionCode" to versionCodeOf(archive),
            "installed" to (installed != null),
            "installedVersionName" to (installed?.versionName ?: ""),
            "installedVersionCode" to (installed?.let { versionCodeOf(it) } ?: -1L),
            "size" to file.length()
        )
    }

    /// PackageInfo sürüm numarası (API 28'de longVersionCode'a geçildi).
    private fun versionCodeOf(info: android.content.pm.PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) info.longVersionCode
        else @Suppress("DEPRECATION") info.versionCode.toLong()

    private fun iconPng(drawable: Drawable): ByteArray {
        val bitmap = drawableToBitmap(drawable)
        val stream = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 70, stream)
        return stream.toByteArray()
    }

    private fun drawableToBitmap(drawable: Drawable): Bitmap {
        if (drawable is BitmapDrawable && drawable.bitmap != null) {
            return drawable.bitmap
        }
        val width = drawable.intrinsicWidth.coerceAtLeast(1)
        val height = drawable.intrinsicHeight.coerceAtLeast(1)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        drawable.setBounds(0, 0, canvas.width, canvas.height)
        drawable.draw(canvas)
        return bitmap
    }
}
