import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// GitHub Releases'taki güncelleme bilgileri.
class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.size,
    required this.sha256,
    required this.url,
    this.notes = '',
  });

  /// Yeni sürüm adı (etiketten, ör. "1.0.3").
  final String version;

  /// APK asset boyutu (bayt).
  final int size;

  /// `.apk.sha256` asset'indeki beklenen SHA256 (yoksa boş).
  final String sha256;

  /// APK indirme adresi (Release asset).
  final String url;

  /// Release notları (`body`).
  final String notes;
}

/// Otomatik güncelleme servisi.
///
/// Her açılışta GitHub **Releases** sayfası sorgulanır:
/// `releases/latest` → etiket sürümle karşılaştırılır → yeni sürüm varsa
/// Release'deki `.apk` asset'i indirilir ve **yanındaki `.apk.sha256`
/// dosyasıyla zorunlu doğrulama** yapılır → Android kurucusu açılır.
/// Ağ hatalarında sessizce vazgeçilir.
class UpdateService {
  const UpdateService._();

  /// Releases API adresi (JSON).
  static const String releasesUrl =
      'https://api.github.com/repos/makaydestek/makay-file-manager/releases/latest';

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static const MethodChannel _channel =
      MethodChannel('com.makay.filemanager/platform');

  static const Map<String, String> _headers = {
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'MakayFileManager-Updater',
  };

  /// Yeni sürüm varsa [UpdateInfo], yoksa veya hata olursa null döner.
  static Future<UpdateInfo?> check() async {
    if (!_supported) return null;
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 8);
      try {
        // 1) releases/latest
        final req = await client.getUrl(Uri.parse(
            '$releasesUrl?t=${DateTime.now().millisecondsSinceEpoch}'));
        _headers.forEach((k, v) => req.headers.set(k, v));
        final resp = await req.close().timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) return null;
        final body = await resp.transform(utf8.decoder).join();
        final map = jsonDecode(body) as Map<String, dynamic>;

        // 2) Etiket → sürüm (baştaki "v" atılır).
        final tag = ((map['tag_name'] as String?) ?? '').trim();
        final version = tag.startsWith('v') || tag.startsWith('V')
            ? tag.substring(1)
            : tag;
        if (version.isEmpty) return null;
        final pkg = await PackageInfo.fromPlatform();
        if (!_isNewer(version, pkg.version)) return null;

        // 3) Asset'ler: .apk + .apk.sha256
        final assets = (map['assets'] as List?) ?? const [];
        Map<String, dynamic>? apkAsset;
        Map<String, dynamic>? shaAsset;
        for (final a in assets) {
          if (a is! Map) continue;
          final name = ((a['name'] as String?) ?? '').toLowerCase();
          if (name.endsWith('.apk.sha256')) {
            shaAsset = Map<String, dynamic>.from(a);
          } else if (name.endsWith('.apk') && apkAsset == null) {
            apkAsset = Map<String, dynamic>.from(a);
          }
        }
        if (apkAsset == null) return null;
        // SHA zorunlu: .apk.sha256 yoksa veya içeriği geçersizse güncelleme sunulmaz.
        if (shaAsset == null) return null;

        // 4) SHA256 yan dosyasının içeriği (küçük metin dosyası).
        final expectedSha = await _fetchSha256(
            client, (shaAsset['browser_download_url'] as String?) ?? '');
        if (expectedSha.isEmpty) return null;

        final apkUrl = (apkAsset['browser_download_url'] as String?) ?? '';
        if (apkUrl.isEmpty) return null;

        return UpdateInfo(
          version: version,
          size: (apkAsset['size'] as num?)?.toInt() ?? 0,
          sha256: expectedSha,
          url: apkUrl,
          notes: ((map['body'] as String?) ?? '').trim(),
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      // Çevrimdışı / yavaş ağ → sessizce vazgeç.
      return null;
    }
  }

  /// `.sha256` asset içeriğinden 64 haneli özeti okur (hata olursa '').
  static Future<String> _fetchSha256(HttpClient client, String url) async {
    if (url.isEmpty) return '';
    try {
      final req = await client.getUrl(Uri.parse(
          '$url?t=${DateTime.now().millisecondsSinceEpoch}'));
      _headers.forEach((k, v) => req.headers.set(k, v));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return '';
      final text = await resp.transform(utf8.decoder).join();
      final token = text.trim().split(RegExp(r'\s+')).first.toLowerCase();
      return RegExp(r'^[0-9a-f]{64}$').hasMatch(token) ? token : '';
    } catch (_) {
      return '';
    }
  }

  /// "1.0.3" > "1.0.2" biçiminde sürüm karşılaştırması.
  static bool _isNewer(String remote, String current) {
    final r = remote.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final c = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final n = r.length > c.length ? r.length : c.length;
    for (var i = 0; i < n; i++) {
      final a = i < r.length ? r[i] : 0;
      final b = i < c.length ? c[i] : 0;
      if (a != b) return a > b;
    }
    return false;
  }

  /// APK'yı indirir; [onProgress] çağrısı (alınan bayt, toplam bayt) verir.
  static Future<File> download(
    UpdateInfo info,
    void Function(int received, int total) onProgress,
  ) async {
    // Not: APK, FileProvider'ın tanıdığı `files/` dizinine yazılır
    // (res/xml/file_paths.xml → <files-path>). `app_flutter` dizini
    // kapsam dışı olduğu için oraya yazılınca kurulum "Failed to find
    // configured root" hatası veriyordu.
    final dir = await getApplicationSupportDirectory();
    final out = File('${dir.path}/makay-update.apk');
    if (await out.exists()) {
      await out.delete();
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(info.url));
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode != 200) {
        throw Exception('İndirme başarısız (HTTP ${resp.statusCode})');
      }
      final total = info.size > 0 ? info.size : resp.contentLength;
      var received = 0;
      final sink = out.openWrite();
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          onProgress(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  /// İndirilen dosyanın SHA256'sı beklenen özetle eşleşiyor mu?
  /// Beklenen özet boşsa veya biçim geçersizse **asla** true dönmez.
  static Future<bool> verifySha256(File file, String expected) async {
    final want = expected.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(want)) return false;
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == want;
  }

  /// Birim testleri için sürüm karşılaştırmasını dışa açar.
  @visibleForTesting
  static bool isNewerVersion(String remote, String current) =>
      _isNewer(remote, current);

  /// Android kurucuyu açar (FileProvider üzerinden).
  static Future<void> install(File file) async {
    await _channel.invokeMethod('installApk', {'path': file.path});
  }
}
