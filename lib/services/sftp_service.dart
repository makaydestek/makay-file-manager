import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'remote_service.dart';
import 'secure_store.dart';

/// Sunucu anahtarı (host key) parmak izi kaydı — TOFU (trust-on-first-use).
///
/// İlk bağlantıda parmak izi şifreli depoya yazılır; sonraki bağlantılarda
/// eşleşmezse bağlantı reddedilir (MITM yakalanır). Eskiden doğrulama
/// tamamen kapalıydı (`disableHostkeyVerification: true`) ve saldırgan kendi
/// anahtarını sunarak kullanıcı adını/parolasını ve tüm dosyaları çalabiliyordu.
class SftpHostKeyStore {
  SftpHostKeyStore._();

  static const _storeKey = 'sftp.hostkeys.v1';
  static Map<String, String>? _cache;

  static Future<void> forget(String host, int port) async {
    final map = Map<String, String>.from(await _load());
    map.remove(_key(host, port));
    _cache = map;
    await SecureStore.write(_storeKey, jsonEncode(map));
  }

  static String _key(String host, int port) => '$host:$port';

  static Future<Map<String, String>> _load() async {
    final cached = _cache;
    if (cached != null) return cached;
    var map = <String, String>{};
    try {
      final raw = await SecureStore.read(_storeKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          map = decoded.map((k, v) => MapEntry('$k', '$v'));
        }
      }
    } catch (_) {
      map = {};
    }
    _cache = map;
    return map;
  }

  /// El sıkışmadaki parmak izini denetler. İlk görüşte kaydeder ve kabul
  /// eder; bilinen bir anahtar değiştiyse **false** döner (bağlantı düşer).
  static Future<bool> verify(
      String host, int port, String type, Uint8List fingerprintBytes) async {
    final presented = utf8.decode(fingerprintBytes, allowMalformed: true);
    final map = await _load();
    final k = _key(host, port);
    final known = map[k];
    if (known == null) {
      map[k] = '$type|$presented';
      _cache = map;
      try {
        await SecureStore.write(_storeKey, jsonEncode(map));
      } catch (_) {
        // Depolama hatası TOFU'yu bozmasın; bu bağlantı yine de kabul edilir.
      }
      return true;
    }
    if (known == '$type|$presented' || known == presented) return true;
    return false;
  }
}

/// Sunucu anahtarı değiştiği için bağlantı reddedildi (MITM şüphesi).
class SftpHostKeyMismatchException implements Exception {
  const SftpHostKeyMismatchException(this.host, this.port);

  final String host;
  final int port;

  @override
  String toString() =>
      'SFTP sunucu anahtarı değişmiş olabilir ($host:$port). Başka bir ağda '
      'sunucu yeniden kurulduysa anahtar kaydını silip yeniden bağlanın.';
}

/// Uzak bir SSH sunucusunda SFTP oturumu (dartssh2).
class SftpSession {
  SftpSession._(this._client, this._sftp, this.location);

  final SSHClient _client;
  final SftpClient _sftp;
  final RemoteLocation location;

  /// Bağlanır ve SFTP alt sistemini başlatır.
  static Future<SftpSession> connect(RemoteLocation loc) async {
    final socket = await SSHSocket.connect(
      loc.cleanHost,
      loc.effectivePort,
      timeout: const Duration(seconds: 15),
    );
    var hostKeyRejected = false;
    final client = SSHClient(
      socket,
      username: loc.username,
      onPasswordRequest: () => loc.password,
      // Anahtar imzası doğrulanır + TOFU parmak izi pinlemesi uygulanır.
      onVerifyHostKey: (type, fingerprint) async {
        final ok = await SftpHostKeyStore.verify(
            loc.cleanHost, loc.effectivePort, type, fingerprint);
        hostKeyRejected = !ok;
        return ok;
      },
      handshakeTimeout: const Duration(seconds: 25),
    );
    try {
      // El sıkışma + kimlik doğrulama tamamlanana kadar bekle.
      await client.authenticated.timeout(const Duration(seconds: 25));
    } catch (e) {
      client.close();
      if (hostKeyRejected) {
        throw SftpHostKeyMismatchException(loc.cleanHost, loc.effectivePort);
      }
      rethrow;
    }
    final sftp = await client.sftp();
    return SftpSession._(client, sftp, loc);
  }

  Future<List<SftpEntry>> list(String path) async {
    final names = await _sftp.listdir(path);
    final entries = names
        .where((n) => n.filename != '.' && n.filename != '..')
        .map((n) => SftpEntry(
              name: n.filename,
              isDir: n.attr.isDirectory,
              size: n.attr.size ?? 0,
              modified: n.attr.modifyTime != null
                  ? DateTime.fromMillisecondsSinceEpoch(n.attr.modifyTime! * 1000)
                  : null,
            ))
        .toList();
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  Future<void> download(String remotePath, File target) async {
    final file = await _sftp.open(
      remotePath,
      mode: SftpFileOpenMode.read,
    );
    try {
      await file.downloadToRandomAccess(await target.open(mode: FileMode.write));
    } finally {
      await file.close();
    }
  }

  /// Dosyayı belleğe indirir (küçük resim önizlemesi için).
  Future<Uint8List> downloadBytes(String remotePath) async {
    final file = await _sftp.open(
      remotePath,
      mode: SftpFileOpenMode.read,
    );
    try {
      return await file.readBytes();
    } finally {
      await file.close();
    }
  }

  Future<void> close() async {
    _client.close();
    await _client.done;
  }
}

/// Uzak dizin girişi (SFTP listeleme için).
class SftpEntry {
  SftpEntry({
    required this.name,
    required this.isDir,
    this.size = 0,
    this.modified,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}
