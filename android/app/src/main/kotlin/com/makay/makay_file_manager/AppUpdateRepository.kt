package com.makay.makay_file_manager

import android.content.Context
import android.content.pm.PackageManager
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.Locale
import java.util.regex.Pattern

/**
 * Makay Cleaner [AppUpdateRepository] ile aynı mantık:
 * GitHub Releases API → (başarısızsa) Atom/HTML → sürüm karşılaştır →
 * APK + SHA-256 → güvenilir URL.
 *
 * Kaynak: https://github.com/makaydestek/makay-file-manager/releases
 */
class AppUpdateRepository(context: Context) {

    private val appContext = context.applicationContext

    private val owner = OWNER
    private val repo = REPO
    private val apiLatest = "https://api.github.com/repos/$owner/$repo/releases/latest"
    private val atomUrl = "https://github.com/$owner/$repo/releases.atom"
    private val htmlLatest = "https://github.com/$owner/$repo/releases/latest"

    private val versionName: String by lazy {
        try {
            val pi = appContext.packageManager.getPackageInfo(appContext.packageName, 0)
            pi.versionName?.trim().orEmpty()
        } catch (_: PackageManager.NameNotFoundException) {
            ""
        }
    }

    private val userAgent: String
        get() = "MakayFileManager/${versionName.ifBlank { "1.0" }}"

    /**
     * Yeni sürüm yoksa null.
     * Ağ / API hatalarında exception — çağıran (manuel kontrol) mesajı gösterir;
     * açılış kontrolü hatayı yutar (Cleaner ile aynı).
     */
    fun checkForUpdate(): Map<String, Any?>? {
        val release = fetchLatestRelease()
        if (release.optBoolean("draft") || release.optBoolean("prerelease")) return null

        val tag = release.optString("tag_name", "")
        val remoteVersion = normalizeVersion(tag)
        if (remoteVersion.isBlank()) return null
        if (compareVersions(remoteVersion, versionName) <= 0) return null

        val assets = release.optJSONArray("assets")
        var apkName = ""
        var apkUrl = ""
        var apkSize = 0L
        var apkDigest: String? = null

        if (assets != null) {
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                val name = a.optString("name", "")
                val url = a.optString("browser_download_url", "")
                if (!name.endsWith(".apk", true) || url.isBlank() || url == "null") continue
                if (name.contains("mapping", ignoreCase = true)) continue
                val preferred = name.startsWith("MakayFileManager", true)
                if (apkUrl.isBlank() || preferred) {
                    apkName = name
                    apkUrl = url
                    apkSize = a.optLong("size", 0L)
                    apkDigest = a.optString("digest", "")
                        .takeIf { it.isNotBlank() && it != "null" }
                    if (preferred) break
                }
            }
        }

        // Atom/HTML yolunda asset listesi olmayabilir — sabit kalıp.
        if (apkUrl.isBlank()) {
            apkName = "MakayFileManager-$remoteVersion.apk"
            apkUrl = "https://github.com/$owner/$repo/releases/download/$remoteVersion/$apkName"
        }

        if (!isTrustedGitHubReleaseUrl(apkUrl)) {
            error("Güncelleme adresi güvenilir değil. Yalnızca resmi GitHub Releases kabul edilir.")
        }

        val expectedSha = normalizeUpdateSha(
            resolveExpectedSha256(release, apkName, apkDigest, remoteVersion)
        ) ?: error(
            "Yeni sürüm $remoteVersion bulundu fakat SHA-256 özeti okunamadı. " +
                "Release’te .apk.sha256 asset’ini kontrol edin."
        )

        val notes = cleanReleaseNotes(release)
        return mapOf(
            "version" to remoteVersion,
            "tag" to tag.ifBlank { remoteVersion },
            "url" to apkUrl,
            "apkName" to apkName,
            "sha256" to expectedSha,
            "size" to apkSize,
            "notes" to notes
        )
    }

    private fun fetchLatestRelease(): JSONObject {
        val errors = mutableListOf<String>()

        // 1) Cleaner ile aynı: GitHub API
        runCatching { fetchLatestReleaseJson() }
            .onSuccess { return it }
            .onFailure { errors.add("API: ${it.message ?: it}") }

        // 2) Atom — kota yok (API 403 yedek)
        runCatching { fetchLatestViaAtom() }
            .onSuccess { return it }
            .onFailure { errors.add("Atom: ${it.message ?: it}") }

        // 3) HTML /releases/latest yönlendirmesi
        runCatching { fetchLatestViaHtmlRedirect() }
            .onSuccess { return it }
            .onFailure { errors.add("HTML: ${it.message ?: it}") }

        error(errors.joinToString(" | ").ifBlank { "Güncelleme kontrolü başarısız" })
    }

    private fun fetchLatestReleaseJson(): JSONObject {
        val conn = (URL(apiLatest).openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 20_000
            instanceFollowRedirects = true
            setRequestProperty("Accept", "application/vnd.github+json")
            setRequestProperty("User-Agent", userAgent)
            setRequestProperty("X-GitHub-Api-Version", "2022-11-28")
        }
        try {
            val code = conn.responseCode
            if (code == 404) error("Henüz GitHub Release yok")
            check(code in 200..299) { "GitHub API $code" }
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            return JSONObject(body)
        } finally {
            conn.disconnect()
        }
    }

    private fun fetchLatestViaAtom(): JSONObject {
        val text = fetchText(atomUrl, accept = "application/atom+xml, application/xml, text/xml, */*")
        val version = parseLatestTagFromAtom(text)
        if (version.isBlank()) error("Atom etiket yok")
        return syntheticRelease(version)
    }

    private fun fetchLatestViaHtmlRedirect(): JSONObject {
        val conn = (URL(htmlLatest).openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 20_000
            instanceFollowRedirects = false
            setRequestProperty("Accept", "text/html,*/*")
            setRequestProperty("User-Agent", userAgent)
        }
        try {
            val code = conn.responseCode
            val loc = conn.getHeaderField("Location").orEmpty()
            var version = tagFromLocation(loc)
            if (version.isBlank() && code in 200..299) {
                val html = conn.inputStream.bufferedReader().use { it.readText() }
                val m = TAG_IN_PATH.matcher(html)
                if (m.find()) version = normalizeVersion(m.group(1))
            }
            if (version.isBlank()) error("HTML etiket yok (HTTP $code)")
            return syntheticRelease(version)
        } finally {
            conn.disconnect()
        }
    }

    private fun syntheticRelease(version: String): JSONObject {
        val apkName = "MakayFileManager-$version.apk"
        val base = "https://github.com/$owner/$repo/releases/download/$version"
        return JSONObject()
            .put("tag_name", version)
            .put("draft", false)
            .put("prerelease", false)
            .put("body", "")
            .put("html_url", "https://github.com/$owner/$repo/releases/tag/$version")
            .put(
                "assets",
                org.json.JSONArray()
                    .put(
                        JSONObject()
                            .put("name", apkName)
                            .put("browser_download_url", "$base/$apkName")
                            .put("size", 0)
                    )
                    .put(
                        JSONObject()
                            .put("name", "$apkName.sha256")
                            .put("browser_download_url", "$base/$apkName.sha256")
                            .put("size", 0)
                    )
            )
    }

    private fun resolveExpectedSha256(
        release: JSONObject,
        apkName: String,
        apkDigest: String?,
        version: String
    ): String? {
        normalizeUpdateSha(
            apkDigest?.removePrefix("sha256:")?.removePrefix("SHA256:")
        )?.let { return it }

        val assets = release.optJSONArray("assets")
        if (assets != null) {
            for (i in 0 until assets.length()) {
                val a = assets.getJSONObject(i)
                val name = a.optString("name", "").lowercase(Locale.US)
                val url = a.optString("browser_download_url", "")
                if (url.isBlank() || url == "null") continue
                if (!(name.endsWith(".sha256") || name == "sha256sums" || name == "checksums.txt")) {
                    continue
                }
                if (!isTrustedGitHubReleaseUrl(url)) continue
                val text = runCatching { fetchText(url) }.getOrNull() ?: continue
                parseSha256Fingerprint(text, apkName)?.let { return it }
            }
        }

        // Sabit kalıp (Atom/HTML)
        val fallback =
            "https://github.com/$owner/$repo/releases/download/$version/MakayFileManager-$version.apk.sha256"
        if (isTrustedGitHubReleaseUrl(fallback)) {
            val text = runCatching { fetchText(fallback) }.getOrNull()
            if (text != null) parseSha256Fingerprint(text, apkName)?.let { return it }
        }

        return parseSha256Fingerprint(cleanReleaseNotes(release), apkName)
    }

    private fun cleanReleaseNotes(release: JSONObject): String {
        if (!release.has("body") || release.isNull("body")) return ""
        val raw = release.optString("body", "").trim()
        if (raw.isEmpty() || raw.equals("null", ignoreCase = true)) return ""
        return raw.take(1200)
    }

    private fun fetchText(url: String, accept: String = "*/*"): String {
        val conn = (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = 12_000
            readTimeout = 30_000
            instanceFollowRedirects = true
            setRequestProperty("User-Agent", userAgent)
            setRequestProperty("Accept", accept)
        }
        try {
            val code = conn.responseCode
            check(code in 200..299) { "HTTP $code" }
            return BufferedReader(InputStreamReader(conn.inputStream)).use { it.readText() }
        } finally {
            conn.disconnect()
        }
    }

    companion object {
        const val OWNER = "makaydestek"
        const val REPO = "makay-file-manager"

        private val TAG_IN_PATH: Pattern =
            Pattern.compile("/releases/tag/(v?[\\d.]+)")

        fun normalizeVersion(raw: String): String =
            raw.trim().removePrefix("v").removePrefix("V").trim()

        fun normalizeUpdateSha(raw: String?): String? =
            raw?.trim()?.lowercase(Locale.US)?.takeIf { it.matches(Regex("[0-9a-f]{64}")) }

        fun compareVersions(a: String, b: String): Int {
            val pa = normalizeVersion(a).split('.', '-', '_').mapNotNull { it.toIntOrNull() }
            val pb = normalizeVersion(b).split('.', '-', '_').mapNotNull { it.toIntOrNull() }
            val n = maxOf(pa.size, pb.size)
            for (i in 0 until n) {
                val x = pa.getOrElse(i) { 0 }
                val y = pb.getOrElse(i) { 0 }
                if (x != y) return x.compareTo(y)
            }
            return 0
        }

        fun tagFromLocation(loc: String): String {
            if (loc.isBlank()) return ""
            val m = TAG_IN_PATH.matcher(loc)
            return if (m.find()) normalizeVersion(m.group(1)) else ""
        }

        fun parseLatestTagFromAtom(xml: String): String {
            val link = Pattern.compile(
                """rel="alternate"[^>]*href="[^"]*/releases/tag/(v?[\d.]+)"|href="[^"]*/releases/tag/(v?[\d.]+)"[^>]*rel="alternate""""
            ).matcher(xml)
            if (link.find()) {
                val g1 = link.group(1)
                val g2 = link.group(2)
                return normalizeVersion(g1 ?: g2 ?: "")
            }
            val id = Pattern.compile(
                """<id>[^<]*/(?:releases/tag/)?(v?[\d.]+)</id>"""
            ).matcher(xml)
            if (id.find()) return normalizeVersion(id.group(1))
            val title = Pattern.compile("""<title>\s*(v?[\d.]+)\s*</title>""").matcher(xml)
            if (title.find()) return normalizeVersion(title.group(1))
            return ""
        }

        fun isTrustedGitHubReleaseUrl(url: String): Boolean {
            val trimmed = url.trim()
            if (!trimmed.startsWith("https://", ignoreCase = true)) return false
            val parsed = runCatching { java.net.URI(trimmed) }.getOrNull() ?: return false
            val host = parsed.host?.lowercase(Locale.US) ?: return false
            val path = parsed.path.orEmpty().lowercase(Locale.US)
            val o = OWNER.lowercase(Locale.US)
            val r = REPO.lowercase(Locale.US)
            return when (host) {
                "github.com" -> path.startsWith("/$o/$r/releases/download/")
                "objects.githubusercontent.com",
                "release-assets.githubusercontent.com",
                "github-releases.githubusercontent.com" -> true
                else -> false
            }
        }

        fun parseSha256Fingerprint(text: String, apkName: String = ""): String? {
            val hex = Regex("""\b([a-fA-F0-9]{64})\b""")
            if (apkName.isNotBlank()) {
                text.lineSequence().forEach { line ->
                    if (line.contains(apkName, ignoreCase = true)) {
                        hex.find(line)?.groupValues?.get(1)?.lowercase(Locale.US)?.let { return it }
                    }
                }
            }
            val labeled = Regex(
                """(?i)(?:sha-?256|checksum)\s*[:=]?\s*([a-fA-F0-9]{64})"""
            ).find(text)
            if (labeled != null) return labeled.groupValues[1].lowercase(Locale.US)
            val all = hex.findAll(text).map { it.groupValues[1].lowercase(Locale.US) }.distinct().toList()
            return all.singleOrNull()
        }
    }
}
