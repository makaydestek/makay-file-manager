import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:xml/xml.dart';

import 'secure_store.dart';

/// Bulut konumu (WebDAV tabanlı: Nextcloud, ownCloud, pCloud Drive vb.).
class CloudLocation {
  CloudLocation({
    required this.name,
    required this.provider,
    required this.url,
    required this.username,
    this.password = '',
  });

  final String name;
  final String provider; // Nextcloud / WebDAV / ...
  final String url; // WebDAV kökü, ör. https://nc.ornek.com/remote.php/dav/files/kullanici
  final String username;
  final String password;

  Map<String, Object?> toJson({bool includePassword = false}) => {
        'name': name,
        'provider': provider,
        'url': url,
        'username': username,
        if (includePassword) 'password': password,
      };

  String get secretKey => 'cloud|$provider|$url|$username|$name';

  factory CloudLocation.fromJson(Map<String, Object?> json) => CloudLocation(
        name: (json['name'] as String?) ?? '',
        provider: (json['provider'] as String?) ?? 'WebDAV',
        url: (json['url'] as String?) ?? '',
        username: (json['username'] as String?) ?? '',
        password: (json['password'] as String?) ?? '',
      );

  CloudLocation copyWith({
    String? name,
    String? provider,
    String? url,
    String? username,
    String? password,
  }) =>
      CloudLocation(
        name: name ?? this.name,
        provider: provider ?? this.provider,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
      );
}

/// Bulut konumlarının kalıcı saklayıcısı.
///
/// Meta SharedPreferences'ta; parolalar [SecureStore] içinde.
class CloudLocationStore {
  static const _key = 'cloud_locations';
  static const _secretsKey = 'cloud_location_secrets_v1';

  static Future<List<CloudLocation>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<Object?>;
      final secrets = await _loadSecrets();
      var migrated = false;
      final out = <CloudLocation>[];
      for (final item in list.whereType<Map>()) {
        final map = Map<String, Object?>.from(item);
        final loc = CloudLocation.fromJson(map);
        final legacy = (map['password'] as String?) ?? '';
        final secure = secrets[loc.secretKey] ?? '';
        if (legacy.isNotEmpty && secure.isEmpty) {
          secrets[loc.secretKey] = legacy;
          migrated = true;
        }
        final password = secure.isNotEmpty ? secure : legacy;
        out.add(password == loc.password ? loc : loc.copyWith(password: password));
      }
      if (migrated) {
        await _saveSecrets(secrets);
        await save(out);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<CloudLocation> locations) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(locations.map((e) => e.toJson()).toList()),
    );
    final secrets = <String, String>{
      for (final loc in locations)
        if (loc.password.isNotEmpty) loc.secretKey: loc.password,
    };
    await _saveSecrets(secrets);
  }

  static Future<Map<String, String>> _loadSecrets() async {
    final raw = await SecureStore.read(_secretsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      return {
        for (final e in map.entries)
          if (e.value is String) e.key: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  static Future<void> _saveSecrets(Map<String, String> secrets) async {
    if (secrets.isEmpty) {
      await SecureStore.delete(_secretsKey);
      return;
    }
    await SecureStore.write(_secretsKey, jsonEncode(secrets));
  }
}

/// WebDAV dizin girişi.
class DavEntry {
  DavEntry({required this.name, required this.isDir, this.size = 0});

  final String name;
  final bool isDir;
  final int size;
}

/// Minimal WebDAV istemcisi: PROPFIND ile dizin listeleme.
class WebDavService {
  const WebDavService();

  /// Şema girilmemiş adresleri tam URL'ye çevirir.
  ///
  /// Kullanıcı "next.site.com/remote.php/dav" gibi bir adres yazdığında
  /// `https://` öneki eklenir; sondaki eğik çizgi de kırpılır.
  static String normalizeUrl(String url) {
    var t = url.trim();
    if (t.isEmpty) return t;
    final parsed = Uri.tryParse(t);
    if (parsed == null || !parsed.hasScheme) t = 'https://$t';
    while (t.endsWith('/')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  /// [path] WebDAV köküne göre yol ('/' ile başlar).
  Future<List<DavEntry>> list(
    CloudLocation loc, {
    String path = '/',
  }) async {
    final base = normalizeUrl(loc.url);
    final uri = Uri.parse('$base${path.isEmpty ? '/' : path}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.openUrl('PROPFIND', uri);
      req.headers.set('Depth', '1');
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${loc.username}:${loc.password}'))}',
      );
      req.headers.contentType =
          ContentType('application', 'xml', charset: 'utf-8');
      req.write(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<D:propfind xmlns:D="DAV:">'
        '<D:prop><D:displayname/><D:resourcetype/>'
        '<D:getcontentlength/></D:prop></D:propfind>',
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 207 && resp.statusCode != 200) {
        throw HttpException(
            'Sunucu ${resp.statusCode} yanıtı verdi (y kimlik kontrolü?)');
      }
      return _parse(body, selfName: path == '/' ? '' : path.split('/').last);
    } finally {
      client.close(force: true);
    }
  }

  List<DavEntry> _parse(String body, {String selfName = ''}) {
    final doc = XmlDocument.parse(body);
    final entries = <DavEntry>[];
    for (final response in doc.findAllElements('D:response')) {
      final href = response.getElement('D:href')?.innerText ?? '';
      // propstat > prop
      final prop = response
          .getElement('D:propstat')
          ?.getElement('D:prop');
      if (prop == null) continue;
      final name = prop.getElement('D:displayname')?.innerText ??
          Uri.decodeComponent(href.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '');
      if (name.isEmpty || name == selfName) continue;
      final isDir = prop
              .getElement('D:resourcetype')
              ?.getElement('D:collection') !=
          null;
      final size = int.tryParse(
              prop.getElement('D:getcontentlength')?.innerText ?? '') ??
          0;
      entries.add(DavEntry(name: name, isDir: isDir, size: size));
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  /// [path] dosyasını yerel [target] dosyasına indirir (HTTP GET).
  Future<void> download(
    CloudLocation loc,
    String path,
    File target,
  ) async {
    final base = normalizeUrl(loc.url);
    final uri = Uri.parse('$base${path.isEmpty ? '/' : path}');
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(
        HttpHeaders.authorizationHeader,
        'Basic ${base64Encode(utf8.encode('${loc.username}:${loc.password}'))}',
      );
      final resp = await req.close();
      if (resp.statusCode != 200) {
        throw HttpException('Sunucu ${resp.statusCode} yanıtı verdi');
      }
      await resp.pipe(target.openWrite());
    } finally {
      client.close(force: true);
    }
  }
}
