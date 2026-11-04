import 'dart:io';

import 'package:dartssh2/dartssh2.dart';

import 'remote_service.dart';

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
    final client = SSHClient(
      socket,
      username: loc.username,
      onPasswordRequest: () => loc.password,
      // Yerel ağ kullanımı: sunucu anahtarı doğrulaması atlanır.
      disableHostkeyVerification: true,
      handshakeTimeout: const Duration(seconds: 15),
    );
    // El sıkışma + kimlik doğrulama tamamlanana kadar bekle.
    await client.authenticated.timeout(const Duration(seconds: 25));
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
