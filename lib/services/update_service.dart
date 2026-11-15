import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  final String version;
  final int size;
  final String sha256;
  final String url;
  final String notes;
}

/// Otomatik güncelleme servisi — Makay Cleaner ile aynı mantık.
///
/// Kontrol native tarafta ([AppUpdateRepository]):
/// 1) GitHub API `releases/latest`
/// 2) Atom `releases.atom` (API 403 yedek)
/// 3) HTML `/releases/latest`
///
/// İndirme + SHA doğrulama + kurulum Dart tarafında kalır.
class UpdateService {
  const UpdateService._();

  static const String _owner = 'makaydestek';
  static const String _repo = 'makay-file-manager';

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  static const MethodChannel _channel =
      MethodChannel('com.makay.filemanager/platform');

  /// GitHub indirme yönlendirmeleri tarayıcı UA ister; aksi halde 404 HTML döner.
  static const Map<String, String> _webHeaders = {
    'Accept': 'application/octet-stream,*/*',
    'User-Agent': 'MakayFileManager-Updater',
  };

  /// Yeni sürüm varsa [UpdateInfo], yoksa null.
  /// Ağ hataları exception fırlatır — manuel kontrol mesaj gösterir;
  /// açılış kontrolü hatayı yutar (Cleaner ile aynı).
  static Future<UpdateInfo?> check() async {
    if (!_supported) return null;
    try {
      final raw = await _channel.invokeMethod<dynamic>('checkForUpdate');
      if (raw == null) return null;
      if (raw is! Map) {
        throw StateError('Beklenmeyen güncelleme yanıtı');
      }
      final map = Map<String, dynamic>.from(raw);
      final version = '${map['version'] ?? ''}'.trim();
      final url = '${map['url'] ?? ''}'.trim();
      final sha = '${map['sha256'] ?? ''}'.trim().toLowerCase();
      if (version.isEmpty || url.isEmpty) return null;
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(sha)) {
        throw StateError(
          'Yeni sürüm $version bulundu fakat SHA-256 özeti okunamadı.',
        );
      }
      if (!_isTrustedDownloadUrl(url)) {
        throw StateError(
          'Güncelleme adresi güvenilir değil. Yalnızca resmi GitHub Releases kabul edilir.',
        );
      }
      final size = (map['size'] as num?)?.toInt() ?? 0;
      var notes = '${map['notes'] ?? ''}'.trim();
      if (notes.toLowerCase() == 'null') notes = '';
      return UpdateInfo(
        version: version,
        size: size < 0 ? 0 : size,
        sha256: sha,
        url: url,
        notes: notes,
      );
    } on PlatformException catch (e) {
      final msg = (e.message ?? e.code).trim();
      throw StateError(msg.isEmpty ? 'Güncelleme kontrolü başarısız' : msg);
    }
  }

  static bool _isTrustedDownloadUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme.toLowerCase() != 'https') return false;
    final host = uri.host.toLowerCase();
    final path = uri.path.toLowerCase();
    final expected = '/$_owner/$_repo/releases/download/';
    if (host == 'github.com') return path.startsWith(expected);
    return host == 'objects.githubusercontent.com' ||
        host == 'release-assets.githubusercontent.com' ||
        host == 'github-releases.githubusercontent.com';
  }

  static Future<File> download(
    UpdateInfo info,
    void Function(int received, int total) onProgress,
  ) async {
    if (!_isTrustedDownloadUrl(info.url)) {
      throw StateError(
        'Güncelleme adresi güvenilir değil. Yalnızca resmi GitHub Releases kabul edilir.',
      );
    }
    final dir = await getApplicationSupportDirectory();
    final out = File('${dir.path}/makay-update.apk');
    if (await out.exists()) await out.delete();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30)
      ..idleTimeout = const Duration(seconds: 60);
    try {
      final req = await client.getUrl(Uri.parse(info.url));
      _webHeaders.forEach((k, v) => req.headers.set(k, v));
      req.followRedirects = true;
      final resp = await req.close().timeout(const Duration(seconds: 45));
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

  static Future<bool> verifySha256(File file, String expected) async {
    final want = expected.trim().toLowerCase();
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(want)) return false;
    if (!await file.exists()) return false;
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString().toLowerCase() == want;
  }

  @visibleForTesting
  static bool isNewerVersion(String remote, String current) {
    final r = remote
        .trim()
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[.\-_]'))
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final c = current
        .trim()
        .replaceFirst(RegExp(r'^[vV]'), '')
        .split(RegExp(r'[.\-_]'))
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final n = r.length > c.length ? r.length : c.length;
    for (var i = 0; i < n; i++) {
      final a = i < r.length ? r[i] : 0;
      final b = i < c.length ? c[i] : 0;
      if (a != b) return a > b;
    }
    return false;
  }

  @visibleForTesting
  static String tagFromLocation(String loc) {
    if (loc.isEmpty) return '';
    final uri = Uri.tryParse(loc);
    final path = uri?.path ?? loc;
    final m = RegExp(r'/releases/tag/(v?[\d.]+)').firstMatch(path);
    if (m == null) return '';
    final t = m.group(1)!.trim();
    if (t.startsWith('v') || t.startsWith('V')) return t.substring(1);
    return t;
  }

  @visibleForTesting
  static String stripV(String tag) {
    final t = tag.trim();
    if (t.startsWith('v') || t.startsWith('V')) return t.substring(1);
    return t;
  }

  @visibleForTesting
  static String parseLatestTagFromAtom(String xml) {
    final link = RegExp(
      r'rel="alternate"[^>]*href="[^"]*/releases/tag/(v?[\d.]+)"'
      r'|href="[^"]*/releases/tag/(v?[\d.]+)"[^>]*rel="alternate"',
    ).firstMatch(xml);
    if (link != null) {
      return stripV(link.group(1) ?? link.group(2) ?? '');
    }
    final id = RegExp(r'<id>[^<]*/(?:releases/tag/)?(v?[\d.]+)</id>')
        .firstMatch(xml);
    if (id != null) return stripV(id.group(1)!);
    final title = RegExp(r'<title>\s*(v?[\d.]+)\s*</title>').firstMatch(xml);
    if (title != null) return stripV(title.group(1)!);
    return '';
  }

  static Future<void> install(File file) async {
    await _channel.invokeMethod('installApk', {'path': file.path});
  }
}
