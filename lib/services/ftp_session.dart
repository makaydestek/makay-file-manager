import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ftpconnect/ftpconnect.dart';

import 'remote_service.dart';

/// Kalıcı FTP oturumu — F Dosya Yöneticisi tarzı hızlı/stabil gezinme.
///
/// Kritik noktalar (F-FM ile aynı mantık):
/// 1. Kontrol kanalı açık kalır (her klasörde yeniden LOGIN yok).
/// 2. Tüm komutlar **tek kuyrukta** (küçük resim RETR ile LIST çakışmaz).
/// 3. PASV adresi 0.0.0.0 / yanlış IP ise kontrol bağlantı host'u kullanılır.
/// 4. MLSD → LIST yedeği; `total` ve bozuk satırlar atlanır.
/// 5. Dizin listesi kısa süreli önbellekte tutulur (geri navigasyon anında).
class FtpSession {
  FtpSession._(this._socket, this._iterator, this.location, this._peerHost);

  final Socket _socket;
  final StreamIterator<List<int>> _iterator;
  final RemoteLocation location;

  /// Kontrol soketinin bağlandığı gerçek IP/host (PASV düzeltmesi için).
  final String _peerHost;

  var _remainder = <int>[];
  String _cwd = '';
  bool _closed = false;

  /// Komut sırası — FTP tek kanallıdır; paralel RETR/LIST bozar.
  Future<void> _chain = Future.value();

  /// Yol → liste önbelleği (geri/ileri gezinmeyi hızlandırır).
  final _listCache = HashMap<String, List<FTPEntry>>();

  /// Önbellek üst sınırı: oturum saatlerce açık kalırsa binlerce klasörün
  /// listesi bellekte birikmesin (LRU benzeri basit tahliye).
  static const int _maxCachedDirs = 60;

  /// Bağlanır, oturumu hazırlar (UTF-8, binary).
  static Future<FtpSession> connect(RemoteLocation loc) async {
    final user =
        loc.username.trim().isEmpty ? 'anonymous' : loc.username.trim();
    final pass = loc.username.trim().isEmpty && loc.password.isEmpty
        ? 'guest@'
        : loc.password;
    final host = loc.cleanHost;
    final socket = await Socket.connect(
      host,
      loc.effectivePort,
      timeout: const Duration(seconds: 15),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final peer = socket.remoteAddress.address;
    final session = FtpSession._(
      socket,
      StreamIterator<List<int>>(socket),
      loc,
      peer.isNotEmpty ? peer : host,
    );
    try {
      await session._readReply(); // 220
      await session._command('USER $user');
      final passReply = await session._command('PASS $pass');
      if (passReply.code >= 400) {
        throw FTPConnectException('FTP giriş başarısız', passReply.message);
      }
      try {
        await session._command('OPTS UTF8 ON');
      } catch (_) {}
      await session._command('TYPE I');
      final start = loc.startPath.trim().isEmpty ? '/' : loc.startPath.trim();
      await session._cwdTo(start);
      return session;
    } catch (e) {
      session.destroy();
      rethrow;
    }
  }

  /// Dizin içeriğini listeler. [forceRefresh] true ise önbellek yok sayılır.
  Future<List<FTPEntry>> list(String path, {bool forceRefresh = false}) {
    return _serialized(() async {
      final key = _normalizePath(path);
      if (!forceRefresh) {
        final cached = _listCache[key];
        if (cached != null) return List<FTPEntry>.of(cached);
      }
      await _cwdTo(key);
      List<FTPEntry> entries = const [];
      try {
        final raw = await _dataTransfer('MLSD');
        entries = _withoutDots(_parseLines(raw, preferMlsd: true));
      } catch (_) {
        entries = const [];
      }
      if (entries.isEmpty) {
        final raw = await _dataTransfer('LIST');
        entries = _withoutDots(_parseLines(raw, preferMlsd: false));
      }
      _listCache[key] = entries;
      if (_listCache.length > _maxCachedDirs) {
        _listCache.remove(_listCache.keys.first);
      }
      return List<FTPEntry>.of(entries);
    });
  }

  /// Önbelleği temizler (Yenile).
  void invalidateCache([String? path]) {
    if (path == null) {
      _listCache.clear();
    } else {
      _listCache.remove(_normalizePath(path));
    }
  }

  Future<void> download(String remotePath, File target) {
    return _serialized(() async {
      final (dir, name) = _split(remotePath);
      await _cwdTo(dir);
      await target.parent.create(recursive: true);
      final sink = target.openWrite();
      try {
        await _dataTransferStream('RETR $name', (chunk) => sink.add(chunk));
      } finally {
        await sink.flush();
        await sink.close();
      }
    });
  }

  Future<Uint8List> downloadBytes(String remotePath) {
    return _serialized(() async {
      final (dir, name) = _split(remotePath);
      await _cwdTo(dir);
      final builder = BytesBuilder(copy: false);
      await _dataTransferStream('RETR $name', builder.add);
      return builder.takeBytes();
    });
  }

  Future<void> close() async {
    if (_closed) return;
    try {
      await _serialized(() => _command('QUIT'))
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
    destroy();
  }

  void destroy() {
    _closed = true;
    _listCache.clear();
    try {
      _socket.destroy();
    } catch (_) {}
  }

  Future<T> _serialized<T>(Future<T> Function() op) {
    final result = Completer<T>();
    // Önceki hata kuyruğu kilitlemesin (F-FM: komutlar sırayla akar).
    _chain = _chain.catchError((_) {}).then((_) async {
      try {
        _ensureOpen();
        result.complete(await op());
      } catch (e, st) {
        if (!result.isCompleted) result.completeError(e, st);
      }
    });
    return result.future;
  }

  void _ensureOpen() {
    if (_closed) throw FTPConnectException('FTP oturumu kapalı');
  }

  Future<void> _cwdTo(String path) async {
    final normalized = _normalizePath(path);
    if (normalized == _cwd) return;

    var r = await _command('CWD $normalized');
    if (r.code < 400) {
      _cwd = normalized;
      return;
    }

    r = await _command('CWD /');
    if (r.code >= 400) {
      throw FTPConnectException('Kök dizine geçilemedi', r.message);
    }
    _cwd = '/';
    if (normalized == '/') return;

    for (final seg in normalized.split('/').where((s) => s.isNotEmpty)) {
      r = await _command('CWD $seg');
      if (r.code >= 400) {
        throw FTPConnectException('Klasöre girilemedi: $seg', r.message);
      }
      _cwd = _cwd == '/' ? '/$seg' : '$_cwd/$seg';
    }
  }

  static String _normalizePath(String path) {
    var p = path.replaceAll('\\', '/').trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.contains('//')) {
      p = p.replaceAll('//', '/');
    }
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static (String dir, String name) _split(String remotePath) {
    final p = _normalizePath(remotePath);
    final i = p.lastIndexOf('/');
    if (i <= 0) return ('/', p.replaceAll('/', ''));
    final dir = p.substring(0, i);
    final name = p.substring(i + 1);
    return (dir.isEmpty ? '/' : dir, name);
  }

  List<FTPEntry> _withoutDots(List<FTPEntry> entries) => entries
      .where((e) {
        final n = e.name.trim();
        if (n.isEmpty || n == '.' || n == '..') return false;
        // MLSD cdir/pdir bazen isim olarak yol bırakır.
        if (n == './' || n == '../') return false;
        return true;
      })
      .toList(growable: false);

  List<FTPEntry> _parseLines(List<int> raw, {required bool preferMlsd}) {
    final text = _decodeListing(raw);
    final out = <FTPEntry>[];
    for (final line in text.split('\n')) {
      final t = line.replaceAll('\r', '').trim();
      if (t.isEmpty) continue;
      if (t.toLowerCase().startsWith('total ')) continue;
      try {
        if (preferMlsd && t.contains(';') && t.contains('=')) {
          // type=cdir / pdir atla
          final lower = t.toLowerCase();
          if (lower.contains('type=cdir') || lower.contains('type=pdir')) {
            continue;
          }
          out.add(FTPEntry.parse(t, ListCommand.mlsd));
        } else {
          out.add(_parseListLine(t));
        }
      } catch (_) {
        // Bozuk satır atlanır — tüm klasör boş kalmaz.
      }
    }
    return out;
  }

  FTPEntry _parseListLine(String line) {
    try {
      return FTPEntry.parse(line, ListCommand.list);
    } catch (_) {
      final m = RegExp(
        r'^([-ld])\S{9}\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(.+?\d{2}:\d{2}|\w{3}\s+\d+\s+\d{4})\s+(.+)$',
      ).firstMatch(line);
      if (m != null) {
        final isDir = m.group(1) == 'd';
        final size = int.tryParse(m.group(2)!) ?? 0;
        final name = m.group(4)!;
        final fake = isDir
            ? 'type=dir;size=$size; $name'
            : 'type=file;size=$size; $name';
        return FTPEntry.parse(fake, ListCommand.mlsd);
      }
      return FTPEntry.parse(line, ListCommand.nlst);
    }
  }

  String _decodeListing(List<int> raw) {
    try {
      return utf8.decode(raw, allowMalformed: true);
    } catch (_) {
      return latin1.decode(raw, allowInvalid: true);
    }
  }

  Future<List<int>> _dataTransfer(String command) async {
    final builder = BytesBuilder(copy: false);
    await _dataTransferStream(command, builder.add);
    return builder.takeBytes();
  }

  Future<void> _dataTransferStream(
    String command,
    void Function(List<int> chunk) onChunk,
  ) async {
    // EPSV dene; olmazsa PASV.
    String dataHost = _peerHost;
    late int dataPort;
    var pasv = await _command('EPSV');
    if (pasv.code < 400) {
      final m = RegExp(r'\|\|\|(\d+)\|').firstMatch(pasv.message);
      if (m == null) {
        throw FTPConnectException('EPSV yanıtı çözülemedi', pasv.message);
      }
      dataPort = int.parse(m.group(1)!);
    } else {
      pasv = await _command('PASV');
      if (pasv.code >= 400) {
        throw FTPConnectException('PASV başarısız', pasv.message);
      }
      final parsed = _parsePasv(pasv.message);
      dataPort = parsed.$2;
      dataHost = _fixPasvHost(parsed.$1);
    }

    final data = await Socket.connect(
      dataHost,
      dataPort,
      timeout: const Duration(seconds: 25),
    );
    try {
      _socket.write('$command\r\n');
      await _socket.flush();
      final start = await _readReply();
      if (start.code != 125 && start.code != 150 && start.code >= 400) {
        throw FTPConnectException('Veri kanalı reddedildi', start.message);
      }
      await for (final chunk in data) {
        onChunk(chunk);
      }
      if (start.code == 125 || start.code == 150) {
        final done = await _readReply();
        if (done.code >= 400) {
          throw FTPConnectException('Aktarım hatası', done.message);
        }
      }
    } finally {
      data.destroy();
    }
  }

  /// Veri bağlantısı **her zaman** kontrol bağlantısının gerçek eşine gider.
  ///
  /// Sunucunun PASV/EPSV'de bildirdiği adres yalnızca bilgi olarak okunur:
  /// kötü niyetli/ele geçirilmiş bir sunucu veri kanalını üçüncü taraf bir
  /// adrese yönlendirip SSRF/bounce yapabiliyordu. Yerel NAT ya da 0.0.0.0
  /// döndüren NAS'lar bu sayede de zaten çalışır.
  String _fixPasvHost(String pasvHost) => _peerHost;

  static (String, int) _parsePasv(String message) {
    final m =
        RegExp(r'(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)').firstMatch(message);
    if (m == null) {
      throw FTPConnectException('PASV yanıtı çözülemedi', message);
    }
    final host = '${m.group(1)}.${m.group(2)}.${m.group(3)}.${m.group(4)}';
    final port = int.parse(m.group(5)!) * 256 + int.parse(m.group(6)!);
    return (host, port);
  }

  Future<_FtpReply> _command(String cmd) async {
    _socket.write('$cmd\r\n');
    await _socket.flush();
    return _readReply();
  }

  Future<_FtpReply> _readReply() async {
    final lines = <String>[];
    while (true) {
      final line = await _readLine();
      if (line.length < 3) continue;
      lines.add(line);
      final code = int.tryParse(line.substring(0, 3));
      if (code == null) continue;
      if (line.length >= 4 && line[3] == '-') continue;
      return _FtpReply(code, lines.join('\n'));
    }
  }

  Future<String> _readLine() async {
    while (true) {
      final nl = _remainder.indexOf(10); // \n
      if (nl >= 0) {
        final lineBytes = _remainder.sublist(0, nl);
        _remainder = _remainder.sublist(nl + 1);
        return latin1
            .decode(lineBytes, allowInvalid: true)
            .replaceAll('\r', '');
      }
      if (!await _iterator.moveNext().timeout(
            const Duration(seconds: 30),
            onTimeout: () => throw TimeoutException('FTP yanıt zaman aşımı'),
          )) {
        throw FTPConnectException('FTP bağlantısı kapandı');
      }
      // Tek geçişte ekleme (her okumada tüm tamponun kopyalanmasını önler).
      if (_remainder.isEmpty) {
        _remainder = List<int>.of(_iterator.current);
      } else {
        _remainder.addAll(_iterator.current);
      }
    }
  }
}

class _FtpReply {
  _FtpReply(this.code, this.message);
  final int code;
  final String message;
}
