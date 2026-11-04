import 'dart:convert';
import 'dart:io';

import 'package:ftpconnect/ftpconnect.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_store.dart';

/// Uzak FTP/SFTP/SMB/WebDAV konumu (kullanıcının kaydettiği bağlantı).
class RemoteLocation {
  RemoteLocation({
    required this.name,
    required this.host,
    this.type = 'ftp',
    this.port = 21,
    this.username = 'anonymous',
    this.password = '',
    this.startPath = '/',
    this.share = '',
  });

  /// Bağlantı türü: 'ftp', 'sftp' (SSH), 'smb' veya 'webdav'.
  /// 'webdav' türünde [host] alanı tam adresi (örn. https://sunucu/dav) tutar.
  final String type;

  final String name;
  final String host;
  final int port;
  final String username;
  final String password;
  final String startPath;

  /// SMB paylaşım adı (yalnızca 'smb' türünde; ör. 'Paylasim' veya 'C$').
  final String share;

  bool get isSftp => type == 'sftp';
  bool get isSmb => type == 'smb';
  bool get isWebDav => type == 'webdav';

  /// Türkçe tür etiketi.
  String get typeLabel => switch (type) {
        'sftp' => 'SFTP',
        'smb' => 'SMB',
        'webdav' => 'WebDAV',
        _ => 'FTP',
      };

  /// Şema / yol / port içeren yapıştırmalardan yalnız host adı.
  ///
  /// Örn. `smb://192.168.1.5/share` → `192.168.1.5`
  String get cleanHost {
    if (isWebDav) return host.trim();
    return FtpClientService.stripHost(host);
  }

  /// Yapıştırmadan çıkarılan port (yoksa [port]).
  int get effectivePort {
    if (isWebDav) return port;
    final parsed = FtpClientService.parseHostPort(host);
    return parsed.$2 ?? port;
  }

  /// SharedPreferences'a yazılacak meta (şifre hariç).
  Map<String, Object?> toJson({bool includePassword = false}) => {
        'name': name,
        'host': host,
        'type': type,
        'port': port,
        'username': username,
        if (includePassword) 'password': password,
        'startPath': startPath,
        'share': share,
      };

  /// Şifre deposu anahtarı (tür+host+port+kullanıcı+paylaşım+ad).
  String get secretKey =>
      'remote|$type|$host|$port|$username|$share|$name';

  factory RemoteLocation.fromJson(Map<String, Object?> json) => RemoteLocation(
        name: (json['name'] as String?) ?? '',
        host: (json['host'] as String?) ?? '',
        type: (json['type'] as String?) ?? 'ftp',
        port: (json['port'] as num?)?.toInt() ?? 21,
        username: (json['username'] as String?) ?? 'anonymous',
        password: (json['password'] as String?) ?? '',
        startPath: (json['startPath'] as String?) ?? '/',
        share: (json['share'] as String?) ?? '',
      );

  /// Alanları güncelleyerek kopya üretir (düzenleme / yeniden adlandırma).
  RemoteLocation copyWith({
    String? name,
    String? host,
    String? type,
    int? port,
    String? username,
    String? password,
    String? startPath,
    String? share,
  }) =>
      RemoteLocation(
        name: name ?? this.name,
        host: host ?? this.host,
        type: type ?? this.type,
        port: port ?? this.port,
        username: username ?? this.username,
        password: password ?? this.password,
        startPath: startPath ?? this.startPath,
        share: share ?? this.share,
      );
}

/// Uzak konum listesinin kalıcı saklayıcısı.
///
/// Meta veri SharedPreferences'ta; parolalar [SecureStore] içinde tutulur.
class RemoteLocationStore {
  static const _key = 'remote_locations';
  static const _secretsKey = 'remote_location_secrets_v1';

  static Future<List<RemoteLocation>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<Object?>;
      final secrets = await _loadSecrets();
      var migrated = false;
      final out = <RemoteLocation>[];
      for (final item in list.whereType<Map>()) {
        final map = Map<String, Object?>.from(item);
        final loc = RemoteLocation.fromJson(map);
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
        // Prefs'ten düz metin şifreleri temizle.
        await save(out);
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<RemoteLocation> locations) async {
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

/// FTP istemcisi sarmalayıcısı: bağlantı testi, dizin listeleme, indirme.
class FtpClientService {
  const FtpClientService();

  FTPConnect _connect(RemoteLocation loc) {
    final user =
        loc.username.trim().isEmpty ? 'anonymous' : loc.username.trim();
    final pass = loc.username.trim().isEmpty && loc.password.isEmpty
        ? 'guest@'
        : loc.password;
    return FTPConnect(
      loc.cleanHost,
      port: loc.effectivePort,
      user: user,
      pass: pass,
      timeout: 12,
      // LIST her FTP sunucusunda çalışır (MLSD her yerde yok).
      listCommand: ListCommand.list,
    );
  }

  /// Kullanıcı `ftp://host:21/path` yapıştırırsa host (+isteğe bağlı port).
  static String stripHost(String raw) => parseHostPort(raw).$1;

  static (String, int?) parseHostPort(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return ('', null);
    final uri = Uri.tryParse(t);
    if (uri != null && uri.hasScheme && uri.host.isNotEmpty) {
      return (uri.host, uri.hasPort ? uri.port : null);
    }
    for (final p in [
      'ftp://',
      'ftps://',
      'sftp://',
      'smb://',
      'cifs://',
      'http://',
      'https://',
    ]) {
      if (t.toLowerCase().startsWith(p)) {
        t = t.substring(p.length);
        break;
      }
    }
    final at = t.lastIndexOf('@');
    if (at >= 0) t = t.substring(at + 1);
    final slash = t.indexOf('/');
    if (slash >= 0) t = t.substring(0, slash);
    final colon = t.lastIndexOf(':');
    if (colon >= 0) {
      final port = int.tryParse(t.substring(colon + 1));
      if (port != null) return (t.substring(0, colon), port);
    }
    return (t, null);
  }

  Future<void> test(RemoteLocation loc) async {
    final ftp = _connect(loc);
    await ftp.connect();
    await ftp.disconnect();
  }

  Future<List<FTPEntry>> list(RemoteLocation loc, String path) async {
    final ftp = _connect(loc);
    await ftp.connect();
    try {
      return await ftp.listDirectoryContent(path);
    } finally {
      await ftp.disconnect();
    }
  }

  Future<void> download(
    RemoteLocation loc,
    String remotePath,
    File target,
  ) async {
    final ftp = _connect(loc);
    await ftp.connect();
    try {
      await ftp.downloadFile(remotePath, target);
    } finally {
      await ftp.disconnect();
    }
  }

  Future<void> upload(
    RemoteLocation loc,
    File source,
    String remotePath,
  ) async {
    final ftp = _connect(loc);
    await ftp.connect();
    try {
      await ftp.uploadFile(source, sRemoteName: remotePath);
    } finally {
      await ftp.disconnect();
    }
  }
}
