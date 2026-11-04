import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'ftp_tls_cert.dart';

import '../utils/debug_log.dart';

/// Makay Dosya Yöneticisi — gömülü mini FTP sunucusu.
///
/// Saf Dart soket implementasyonu; PASV/EPSV (pasif) ve PORT (aktif) destekli.
/// Ek olarak FTPS (implicit TLS) portu sunar: [tlsPort] üzerinde her
/// bağlantı şifreli kurulur (FTPS istemcileri için).
class MiniFtpServer {
  MiniFtpServer({
    required this.rootPath,
    this.port = 2121,
    this.tlsPort = 2123,
    this.enableTls = true,
    required this.username,
    required this.password,
    this.showHidden = false,
    this.readOnly = false,
    this.bindAddress,
  });

  /// Sunucunun kök dizini (yalnızca bu ağaç görünür).
  final String rootPath;
  final int port;

  /// Şifreli (implicit TLS / FTPS) portu.
  final int tlsPort;
  final bool enableTls;

  final String username;
  final String password;
  final bool showHidden;

  /// true ise STOR/DELE/MKD/RMD/RNFR gibi yazma komutları 550 ile reddedilir.
  final bool readOnly;

  /// Sunucunun bağlanacağı arayüz.
  ///
  /// Varsayılan `null` → `anyIPv4`, yani her arayüzde dinler (üretim
  /// davranışı). Testler yalnızca loopback üzerinden konuşur; loopback'e
  /// bağlanmak dışarıdan gelebilecek port taraması ya da el sıkışmadan
  /// koparmaları tamamen dışarıda bırakır.
  final InternetAddress? bindAddress;

  InternetAddress get _bind => bindAddress ?? InternetAddress.anyIPv4;

  /// Gömülü sertifika bağlamı (tek örnek).
  static final SecurityContext _tlsContext = () {
    final ctx = SecurityContext();
    ctx.useCertificateChainBytes(utf8.encode(kFtpsCertificatePem));
    ctx.usePrivateKeyBytes(utf8.encode(kFtpsPrivateKeyPem));
    return ctx;
  }();

  bool get running => _control != null || _tlsControl != null;
  ServerSocket? _control;
  ServerSocket? _tlsControl;

  /// Kontrol portunun gerçekten dinlendiği port.
  ///
  /// Yapıcıya `0` verilirse işletim sistemi boş bir port tahsis eder. Bu,
  /// "önce boş port bulup sonra bağlanmak" yaklaşımındaki yarışı (TOCTOU)
  /// tamamen ortadan kaldırır: port artık seçilmez, **tahsis edilir**.
  int get boundPort => _control?.port ?? port;

  /// FTPS portunun gerçekten dinlendiği port; `tlsPort` `0` verilmişse
  /// tahsis edilen port.
  int get boundTlsPort => _tlsControl?.port ?? tlsPort;
  final _log = StreamController<String>.broadcast();
  final _random = Random();

  /// Sunucu günlüğü (ekranda gösterilir).
  Stream<String> get log => _log.stream;

  /// [body] içinde kurulan dinleyicilerden gelen, `onError`'a ulaşmayan geç
  /// soket hatalarını yutar ve günlüğe yazar.
  void _guardListener(void Function() body) {
    runZonedGuarded<void>(body, (Object e, StackTrace s) {
      _log.add('Dinleyici hatası (yutuldu): $e');
    });
  }

  Future<void> start() async {
    if (running) return;
    final control = await ServerSocket.bind(_bind, port);
    _control = control;
    _log.add('FTP sunucusu başladı: port ${control.port}');
    _guardListener(() {
      control.listen(
        (socket) => unawaited(_handleClient(socket)),
        onError: (Object e) => _log.add('FTP dinleyici hatası: $e'),
      );
    });
    if (enableTls) {
      try {
        final tls = await ServerSocket.bind(_bind, tlsPort);
        _tlsControl = tls;
        _log.add('FTPS sunucusu başladı: port ${tls.port} (şifreli)');
        _guardListener(() {
          tls.listen(
            (socket) => unawaited(_handleTlsClient(socket)),
            onError: (Object e) => _log.add('FTPS dinleyici hatası: $e'),
          );
        });
      } catch (e) {
        _log.add('FTPS başlatılamadı: $e');
      }
    }
  }

  Future<void> stop() async {
    await _control?.close();
    _control = null;
    await _tlsControl?.close();
    _tlsControl = null;
    _log.add('Sunucu durdu.');
  }

  Future<void> _handleTlsClient(Socket raw) async {
    try {
      final secure = await SecureSocket.secureServer(raw, _tlsContext);
      await _handleClient(secure, secureConnection: true);
    } catch (e) {
      _log.add('TLS el sıkışması başarısız: $e');
      raw.destroy();
    }
  }

  Future<void> _handleClient(Socket socket,
      {bool secureConnection = false}) async {
    final session = _FtpSession(socket, this, isSecure: secureConnection);
    try {
      await session.run();
    } catch (_) {
      // Oturum hataları yutulur; bağlantı kapanır.
    } finally {
      socket.destroy();
    }
  }

  String resolve(String virtualPath) {
    var p = virtualPath.replaceAll('\\', '/');
    if (!p.startsWith('/')) p = '/$p';
    final segments = <String>[];
    for (final seg in p.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') {
        if (segments.isNotEmpty) segments.removeLast();
        continue;
      }
      segments.add(seg);
    }
    final joined = segments.join(Platform.pathSeparator);
    return joined.isEmpty
        ? rootPath
        : '$rootPath${Platform.pathSeparator}$joined';
  }

  /// İstemciye gösterilecek sanal yol ("/", "/DCIM").
  String toVirtual(String fsPath) {
    if (fsPath == rootPath) return '/';
    final rel = fsPath.startsWith(rootPath)
        ? fsPath.substring(rootPath.length).replaceAll('\\', '/')
        : '/';
    return rel.startsWith('/') ? rel : '/$rel';
  }

  /// Dinamik PASV veri portu (kontrol portunun 1–38 üstü).
  int pickDataPort() => boundPort + 1 + _random.nextInt(38);
}

/// Tek istemci oturumu.
class _FtpSession {
  _FtpSession(this.socket, this.server, {this.isSecure = false});

  final Socket socket;
  final MiniFtpServer server;

  /// Bağlantı şifreli mi (implicit TLS / FTPS portu).
  final bool isSecure;

  /// PROT P sonrası veri bağlantıları da TLS ile mi kurulacak.
  bool protPrivate = false;

  String? user;
  bool authed = false;
  String cwd = '/';

  /// Aktif (PORT) veri hedefi; PASV kullanılmıyorsa istemci adresi.
  InternetAddress? _portHost;
  int? _portPort;

  ServerSocket? dataServer;
  Socket? dataSocket;
  Completer<Socket>? _dataReady;

  Future<void> run() async {
    await _reply('220 Makay FTP Sunucu hazır');
    final lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final done = await _handle(line.trim());
      if (done) break;
    }
    await _cleanupTransfer();
  }

  Future<void> _reply(String message) async {
    socket.write('$message\r\n');
    // Windows Explorer PASV yanıtını bekler; tamponda kalırsa veri
    // bağlantısı zaman aşımına düşer ("Sunucuyla bağlantı kurulamadı").
    try {
      await socket.flush();
    } catch (_) {}
  }

  Future<bool> _handle(String line) async {
    if (line.isEmpty) return false;
    final space = line.indexOf(' ');
    final cmd = (space == -1 ? line : line.substring(0, space)).toUpperCase();
    final arg = space == -1 ? '' : line.substring(space + 1).trim();
    server._log.add('> $line');

    if (!authed &&
        cmd != 'USER' &&
        cmd != 'PASS' &&
        cmd != 'QUIT' &&
        cmd != 'NOOP') {
      await _reply('530 Lütfen önce giriş yapın.');
      return false;
    }

    switch (cmd) {
      case 'USER':
        user = arg;
        await _reply('331 Kullanıcı adı alındı, şifre bekleniyor');
      case 'PASS':
        if (user == server.username && arg == server.password) {
          authed = true;
          await _reply('230 Giriş başarılı. Hoş geldiniz.');
        } else {
          await _reply('530 Kullanıcı adı veya şifre hatalı.');
        }
      case 'SYST':
        await _reply('215 UNIX Type: L8');
      case 'FEAT':
        await _reply(
            '211-Özellikler:\r\n'
            ' PASV\r\n'
            ' EPSV\r\n'
            ' PORT\r\n'
            ' UTF8\r\n'
            ' SIZE\r\n'
            ' MDTM\r\n'
            ' REST STREAM\r\n'
            '211 Son');
      case 'PWD':
      case 'XPWD':
        await _reply('257 "$cwd" mevcut dizin');
      case 'CWD':
      case 'XCWD':
        // cwd sanal yoldur; toVirtual(cwd) yanlışlıkla kök'e düşürürdü.
        final target =
            server.resolve(arg.startsWith('/') ? arg : '$cwd/$arg');
        if (Directory(target).existsSync()) {
          cwd = server.toVirtual(target);
          await _reply('250 Dizin değiştirildi: $cwd');
        } else {
          await _reply('550 Dizin bulunamadı: $arg');
        }
      case 'CDUP':
        final slash = cwd.lastIndexOf('/');
        final parent =
            cwd == '/' || slash <= 0 ? '/' : cwd.substring(0, slash);
        cwd = parent.isEmpty ? '/' : parent;
        await _reply('250 Üst dizine çıkıldı: $cwd');
      case 'TYPE':
        // Her zaman ham bayt (binary) gönderilir; görüntü/video bozulmaz.
        await _reply('200 TYPE $arg kabul edildi');
      case 'PASV':
        await _enterPassive(extended: false);
      case 'EPSV':
        await _enterPassive(extended: true);
      case 'PORT':
        await _enterActive(arg);
      case 'LIST':
      case 'NLST':
        await _doList(arg, nlst: cmd == 'NLST');
      case 'RETR':
        await _doRetrieve(arg);
      case 'STOR':
        if (server.readOnly) {
          await _reply('550 Salt okunur paylaşım — yazma kapalı.');
        } else {
          await _doStore(arg);
        }
      case 'DELE':
        if (server.readOnly) {
          await _reply('550 Salt okunur paylaşım — silme kapalı.');
          break;
        }
        final f = File(server.resolve(_absolute(arg)));
        if (f.existsSync()) {
          f.deleteSync();
          await _reply('250 Silindi: $arg');
        } else {
          await _reply('550 Dosya bulunamadı.');
        }
      case 'MKD':
      case 'XMKD':
        if (server.readOnly) {
          await _reply('550 Salt okunur paylaşım — klasör oluşturma kapalı.');
          break;
        }
        final d = Directory(server.resolve(_absolute(arg)));
        d.createSync(recursive: true);
        await _reply('257 "${server.toVirtual(d.path)}" oluşturuldu');
      case 'RMD':
      case 'XRMD':
        if (server.readOnly) {
          await _reply('550 Salt okunur paylaşım — klasör silme kapalı.');
          break;
        }
        final rd = Directory(server.resolve(_absolute(arg)));
        if (rd.existsSync()) {
          rd.deleteSync(recursive: true);
          await _reply('250 Klasör silindi.');
        } else {
          await _reply('550 Klasör bulunamadı.');
        }
      case 'SIZE':
        final f = File(server.resolve(_absolute(arg)));
        if (f.existsSync()) {
          await _reply('213 ${f.lengthSync()}');
        } else {
          await _reply('550 Dosya bulunamadı.');
        }
      case 'MDTM':
        final f = File(server.resolve(_absolute(arg)));
        if (f.existsSync()) {
          final t = f.statSync().modified.toUtc();
          final stamp =
              '${t.year}${t.month.toString().padLeft(2, '0')}${t.day.toString().padLeft(2, '0')}'
              '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}${t.second.toString().padLeft(2, '0')}';
          await _reply('213 $stamp');
        } else {
          await _reply('550 Dosya bulunamadı.');
        }
      case 'OPTS':
        await _reply('200 OK');
      case 'AUTH':
        final scheme = arg.toUpperCase();
        if (scheme == 'TLS' || scheme == 'SSL' || scheme == 'TLS-C') {
          await _reply('502 Bu sunucu yalnızca şifreli porttan (FTPS: '
              '${server.boundTlsPort}) bağlantı kabul eder.');
        } else {
          await _reply('504 Desteklenmeyen güvenlik türü: $arg');
        }
      case 'PBSZ':
        await _reply('200 PBSZ=0');
      case 'PROT':
        final mode = arg.toUpperCase();
        if (mode == 'P') {
          if (isSecure) {
            protPrivate = true;
            await _reply('200 PROT P kabul edildi (veri bağlantısı şifreli)');
          } else {
            await _reply(
                '536 PROT P yalnızca şifreli (FTPS) bağlantıda çalışır — '
                'port ${server.boundTlsPort} kullanın');
          }
        } else {
          protPrivate = false;
          await _reply('200 PROT C kabul edildi');
        }
      case 'NOOP':
        await _reply('200 OK');
      case 'QUIT':
        await _reply('221 Görüşürüz');
        return true;
      default:
        await _reply('502 Komut desteklenmiyor: $cmd');
    }
    return false;
  }

  /// PASV/EPSV: önce dinle, sonra yanıtla — aksi halde Windows Explorer
  /// yanıtı alır almaz bağlanır ve yarış yüzünden kopar.
  Future<void> _enterPassive({required bool extended}) async {
    await _cleanupTransfer();
    dataServer = await _bindDataServer();
    final dataPort = dataServer!.port;
    _dataReady = Completer<Socket>();
    dataServer!.listen(
      (s) {
        dataSocket = s;
        final ready = _dataReady;
        if (ready != null && !ready.isCompleted) {
          ready.complete(s);
        }
      },
      onError: (Object e) {
        final ready = _dataReady;
        if (ready != null && !ready.isCompleted) {
          ready.completeError(e);
        }
      },
    );
    if (extended) {
      await _reply('229 Entering Extended Passive Mode (|||$dataPort|)');
      return;
    }
    final host = await _pasvHost();
    final parts = host.split('.');
    if (parts.length != 4) {
      await _reply('425 PASV için IPv4 adresi bulunamadı.');
      await _cleanupTransfer();
      return;
    }
    final p1 = dataPort >> 8;
    final p2 = dataPort & 0xFF;
    await _reply(
        '227 Entering Passive Mode (${parts[0]},${parts[1]},${parts[2]},${parts[3]},$p1,$p2)');
  }

  /// Aktif mod (PORT) — bazı Windows istemcileri PASV başarısız olunca buna düşer.
  Future<void> _enterActive(String arg) async {
    await _cleanupTransfer();
    final parts = arg.split(',');
    if (parts.length != 6) {
      await _reply('501 PORT biçimi hatalı.');
      return;
    }
    try {
      final host = InternetAddress(
          '${parts[0].trim()}.${parts[1].trim()}.${parts[2].trim()}.${parts[3].trim()}');
      final p1 = int.parse(parts[4].trim());
      final p2 = int.parse(parts[5].trim());
      _portHost = host;
      _portPort = (p1 << 8) | p2;
      await _reply('200 PORT komutu başarılı.');
    } catch (_) {
      await _reply('501 PORT adresi çözülemedi.');
    }
  }

  /// PASV'de duyurulacak IPv4: kontrol soketinin gerçek yerel adresi,
  /// yoksa istemciyle aynı alt ağdaki arayüz.
  Future<String> _pasvHost() async {
    final local = socket.address;
    if (!local.isLoopback && local.type == InternetAddressType.IPv4) {
      final a = local.address;
      if (a != '0.0.0.0') return a;
    }
    final remote = socket.remoteAddress;
    if (remote.isLoopback) return '127.0.0.1';
    return _localAddress(preferRemote: remote);
  }

  String _absolute(String arg) {
    if (arg.startsWith('/')) return arg;
    if (cwd == '/') return '/$arg';
    return '$cwd/$arg';
  }

  /// [preferRemote] verilirse aynı /24 alt ağındaki arayüz tercih edilir
  /// (VPN/mobil veri IP'sinin duyurulmasını önler).
  Future<String> _localAddress({InternetAddress? preferRemote}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      final remote = preferRemote?.address;
      String? remotePrefix;
      if (remote != null) {
        final parts = remote.split('.');
        if (parts.length == 4) {
          remotePrefix = '${parts[0]}.${parts[1]}.${parts[2]}.';
        }
      }
      if (remotePrefix != null) {
        for (final i in interfaces) {
          for (final a in i.addresses) {
            if (!a.isLoopback && a.address.startsWith(remotePrefix)) {
              return a.address;
            }
          }
        }
      }
      for (final i in interfaces) {
        final name = i.name.toLowerCase();
        if (name.contains('wlan') ||
            name.contains('wi-fi') ||
            name.contains('eth') ||
            name.contains('en')) {
          for (final a in i.addresses) {
            if (!a.isLoopback) return a.address;
          }
        }
      }
      for (final i in interfaces) {
        for (final a in i.addresses) {
          if (!a.isLoopback) return a.address;
        }
      }
    } catch (e) {
      logSwallowed('ftp: ağ arayüzü', e);
    }
    return '127.0.0.1';
  }

  Future<void> _doList(String arg, {bool nlst = false}) async {
    final data = await _acceptData();
    if (data == null) {
      await _reply('425 Veri bağlantısı açılamadı.');
      return;
    }
    await _reply(
        nlst ? '150 Dosya listesi gönderiliyor' : '150 Liste gönderiliyor');
    final dirPath = arg.isEmpty
        ? server.resolve(cwd)
        : server.resolve(_absolute(arg));
    final dir = Directory(dirPath);
    final buffer = StringBuffer();
    try {
      for (final e in dir.listSync(followLinks: false)) {
        final segments =
            e.uri.pathSegments.where((s) => s.isNotEmpty).toList();
        final name = segments.isEmpty
            ? e.path.split(Platform.pathSeparator).last
            : segments.last;
        if (!server.showHidden && name.startsWith('.')) continue;
        if (nlst) {
          buffer.write('$name\r\n');
        } else {
          final stat = e.statSync();
          final isDir = e is Directory;
          final perms = isDir ? 'drwxr-xr-x' : '-rw-r--r--';
          final date = stat.modified;
          final mon = const [
            'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
            'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
          ][date.month - 1];
          final stamp =
              '$mon ${date.day.toString().padLeft(2, ' ')} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
          buffer.write(
              '$perms 1 owner group ${stat.size.toString().padLeft(12)} $stamp $name\r\n');
        }
      }
      data.add(utf8.encode(buffer.toString()));
    } catch (_) {
      await _reply('550 Liste alınamadı.');
      try {
        await data.close();
      } catch (_) {}
      await _cleanupTransfer();
      return;
    }
    try {
      await data.flush();
      await data.close();
    } catch (_) {}
    await _cleanupTransfer();
    await _reply('226 Liste tamamlandı');
  }

  Future<void> _doRetrieve(String arg) async {
    final file = File(server.resolve(_absolute(arg)));
    if (!file.existsSync()) {
      await _reply('550 Dosya bulunamadı.');
      return;
    }
    final data = await _acceptData();
    if (data == null) {
      await _reply('425 Veri bağlantısı açılamadı.');
      return;
    }
    await _reply('150 Dosya gönderiliyor (${file.lengthSync()} bayt)');
    try {
      await file.openRead().pipe(data);
      await _reply('226 Transfer tamamlandı');
    } catch (_) {
      await _reply('426 Transfer kesildi');
    } finally {
      try {
        await data.close();
      } catch (_) {}
      await _cleanupTransfer();
    }
  }

  Future<void> _doStore(String arg) async {
    final data = await _acceptData();
    if (data == null) {
      await _reply('425 Veri bağlantısı açılamadı.');
      return;
    }
    await _reply('150 Dosya alınıyor');
    final file = File(server.resolve(_absolute(arg)));
    try {
      final sink = file.openWrite();
      await data.listen(sink.add).asFuture();
      await sink.flush();
      await sink.close();
      await _reply('226 Transfer tamamlandı');
    } catch (_) {
      await _reply('426 Transfer kesildi');
    } finally {
      try {
        await data.close();
      } catch (_) {}
      await _cleanupTransfer();
    }
  }

  Future<Socket?> _acceptData() async {
    final activeHost = _portHost;
    final activePort = _portPort;
    if (activeHost != null && activePort != null) {
      _portHost = null;
      _portPort = null;
      try {
        final raw = await Socket.connect(
          activeHost,
          activePort,
          timeout: const Duration(seconds: 15),
        );
        return _maybeWrapTls(raw);
      } catch (_) {
        return null;
      }
    }

    final ready = _dataReady;
    if (ready == null || dataServer == null) return null;
    Socket raw;
    try {
      raw = await ready.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      return null;
    }
    return _maybeWrapTls(raw);
  }

  Future<Socket?> _maybeWrapTls(Socket raw) async {
    if (!protPrivate) return raw;
    try {
      return await SecureSocket.secureServer(raw, MiniFtpServer._tlsContext);
    } catch (_) {
      raw.destroy();
      return null;
    }
  }

  Future<void> _closeDataServer() async {
    try {
      await dataServer?.close();
    } catch (_) {}
    dataServer = null;
  }

  Future<ServerSocket> _bindDataServer() async {
    final bind = server._bind;
    const maxCandidates = 8;
    for (var attempt = 0; attempt < maxCandidates; attempt++) {
      try {
        return await ServerSocket.bind(bind, server.pickDataPort());
      } on SocketException {
        // Bu port dolu — sıradaki adaya geç.
      }
    }
    return ServerSocket.bind(bind, 0);
  }

  Future<void> _cleanupTransfer() async {
    await _closeDataServer();
    try {
      dataSocket?.destroy();
    } catch (_) {}
    dataSocket = null;
    _dataReady = null;
    _portHost = null;
    _portPort = null;
  }
}
