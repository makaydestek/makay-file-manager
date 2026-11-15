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

  /// Etkin istemci soketleri — `stop()` bunları da kapatır. Aksi halde
  /// "sunucu durdu" dendikten sonra açık istemciler dosya aktarımına devam
  /// edebiliyordu (hem güvenlik hem kaynak sızıntısı).
  final _clients = <Socket>{};

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
    for (final s in _clients.toList()) {
      try {
        await s.close();
      } catch (_) {}
      try {
        s.destroy();
      } catch (_) {}
    }
    _clients.clear();
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
    _clients.add(socket);
    try {
      await session.run();
    } catch (e) {
      _log.add('Oturum hatası: $e');
    } finally {
      _clients.remove(socket);
      // destroy() RST gönderir; Windows Gezgini bunu "bağlantı sıfırlandı" yapar.
      try {
        await socket.close();
      } catch (_) {
        try {
          socket.destroy();
        } catch (_) {}
      }
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

  /// Başarısız giriş denemesi sayısı (kaba kuvveti yavaşlatmak için).
  int _authFailures = 0;

  /// Azami başarısız deneme; aşan bağlantı kapatılır.
  static const int _maxAuthFailures = 8;

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

  /// Hata sayısına göre artan bekleme (0,5 sn → 5 sn tavan).
  static Duration _authBackoff(int failures) {
    const ceilings = [
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ];
    final i = failures - 1;
    return ceilings[i < ceilings.length ? i : ceilings.length - 1];
  }

  /// Sabit süreli dize karşılaştırması (zamanlama sızıntısını azaltır).
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<bool> _handle(String line) async {
    if (line.isEmpty) return false;
    final space = line.indexOf(' ');
    final cmd = (space == -1 ? line : line.substring(0, space)).toUpperCase();
    final arg = space == -1 ? '' : line.substring(space + 1).trim();
    // Parola asla günlüğe düşmez (ekranda görünen "Sunucu günlüğü" kartı ve
    // omuz üstü izleme/ekran kaydı sızıntısı).
    server._log.add(cmd == 'PASS' ? '> PASS ****' : '> $line');

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
        // Kaba kuvvet koruması: her hatada artan gecikme, eşik aşılınca
        // bağlantı kapatılır. Karşılaştırma sabit sürelidir.
        final ok = _authFailures < _maxAuthFailures &&
            _constantTimeEquals(user ?? '', server.username) &&
            _constantTimeEquals(arg, server.password);
        if (ok) {
          authed = true;
          _authFailures = 0;
          await _reply('230 Giriş başarılı. Hoş geldiniz.');
        } else {
          _authFailures++;
          await _reply('530 Kullanıcı adı veya şifre hatalı.');
          if (_authFailures >= _maxAuthFailures) {
            server._log.add('Çok fazla hatalı giriş — bağlantı kapatıldı.');
            return true;
          }
          await Future<void>.delayed(_authBackoff(_authFailures));
        }
      case 'SYST':
        await _reply('215 UNIX Type: L8');
      case 'FEAT':
        // F Dosya Yöneticisi / Windows Gezgini uyumlu özellik listesi.
        await _reply(
            '211-Features:\r\n'
            ' PASV\r\n'
            ' EPSV\r\n'
            ' PORT\r\n'
            ' UTF8\r\n'
            ' SIZE\r\n'
            ' MDTM\r\n'
            ' REST STREAM\r\n'
            ' TVFS\r\n'
            '211 End');
      case 'HELP':
        await _reply(
            '214-Komutlar:\r\n'
            ' USER PASS PWD CWD CDUP TYPE MODE STRU\r\n'
            ' PASV EPSV PORT LIST NLST RETR STOR APPE\r\n'
            ' DELE MKD RMD SIZE MDTM ALLO REST NOOP QUIT\r\n'
            '214 Yardım sonu');
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
      case 'XCUP':
        final slash = cwd.lastIndexOf('/');
        final parent =
            cwd == '/' || slash <= 0 ? '/' : cwd.substring(0, slash);
        cwd = parent.isEmpty ? '/' : parent;
        await _reply('250 Üst dizine çıkıldı: $cwd');
      case 'TYPE':
        // Her zaman ham bayt (binary) gönderilir; görüntü/video bozulmaz.
        await _reply('200 TYPE ${arg.isEmpty ? 'I' : arg} kabul edildi');
      case 'MODE':
        // Windows / F-FM: yalnızca Stream (S).
        final mode = arg.toUpperCase();
        if (mode.isEmpty || mode == 'S') {
          await _reply('200 MODE S kabul edildi');
        } else {
          await _reply('504 Yalnızca MODE S desteklenir');
        }
      case 'STRU':
        // Windows / F-FM: yalnızca File (F).
        final stru = arg.toUpperCase();
        if (stru.isEmpty || stru == 'F') {
          await _reply('200 STRU F kabul edildi');
        } else {
          await _reply('504 Yalnızca STRU F desteklenir');
        }
      case 'REST':
        // Yeniden başlatma noktası — 0 kabul; kısmi REST şimdilik yok.
        await _reply('350 Restarting at ${arg.isEmpty ? '0' : arg}');
      case 'CLNT':
        await _reply('200 OK');
      case 'PASV':
        await _enterPassive(extended: false);
      case 'EPSV':
        await _enterPassive(extended: true);
      case 'PORT':
        await _enterActive(arg);
      case 'EPRT':
        // IPv6 EPRT nadiren; Windows/F-FM PASV kullanır.
        await _reply('502 EPRT desteklenmiyor — PASV veya PORT kullanın');
      case 'LIST':
      case 'NLST':
        await _doList(arg, nlst: cmd == 'NLST');
      case 'RETR':
        await _doRetrieve(arg);
      case 'STOR':
      case 'APPE':
        if (server.readOnly) {
          await _reply('550 Salt okunur paylaşım — yazma kapalı.');
        } else {
          await _doStore(arg, append: cmd == 'APPE');
        }
      case 'ALLO':
        // Windows Gezgini yüklemeden önce ALLO gönderir; yoksa bazı
        // istemciler aktarımı erken keser.
        await _reply('202 ALLO gerekmiyor');
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
    final cleaned = _ftpName(arg);
    if (cleaned.startsWith('/')) return cleaned;
    if (cwd == '/') return '/$cleaned';
    return '$cwd/$cleaned';
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
    // IIS / F-FM / Windows: veri zaten açıksa 125, değilse 150.
    await _replyTransferReady(
      already: '125 Veri bağlantısı açık; liste gönderiliyor',
      opening: nlst
          ? '150 Dosya listesi gönderiliyor'
          : '150 Liste gönderiliyor',
    );
    final data = await _acceptData();
    if (data == null) {
      await _cleanupTransfer();
      await _reply('425 Veri bağlantısı açılamadı.');
      return;
    }
    dataSocket = null;
    final dirPath = arg.isEmpty
        ? server.resolve(cwd)
        : server.resolve(_absolute(_ftpName(arg)));
    final dir = Directory(dirPath);
    final buffer = StringBuffer();
    try {
      if (dir.existsSync()) {
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
      }
      data.add(utf8.encode(buffer.toString()));
      await data.flush();
      await _gracefulClose(data);
      await _cleanupTransfer();
      await _reply('226 Liste tamamlandı');
    } catch (_) {
      await _forceClose(data);
      await _cleanupTransfer();
      await _reply('550 Liste alınamadı.');
    }
  }

  Future<void> _doRetrieve(String arg) async {
    final name = _ftpName(arg);
    final file = File(server.resolve(_absolute(name)));
    if (!file.existsSync()) {
      await _reply('550 Dosya bulunamadı.');
      return;
    }
    await _replyTransferReady(
      already:
          '125 Veri bağlantısı açık; gönderiliyor (${file.lengthSync()} bayt)',
      opening: '150 Dosya gönderiliyor (${file.lengthSync()} bayt)',
    );
    final data = await _acceptData();
    if (data == null) {
      await _cleanupTransfer();
      await _reply('425 Veri bağlantısı açılamadı.');
      return;
    }
    dataSocket = null;
    try {
      await file.openRead().pipe(data);
      await _gracefulClose(data);
      await _cleanupTransfer();
      await _reply('226 Transfer tamamlandı');
    } catch (e) {
      server._log.add('RETR hata: $e');
      await _forceClose(data);
      await _cleanupTransfer();
      await _reply('426 Transfer kesildi');
    }
  }

  /// Windows Gezgini / F-FM:
  /// - Çoğu zaman: PASV → **veri bağlan** → STOR → **125** → bayt → FIN → 226
  /// - Bazen: PASV → STOR → **150** → veri bağlan → bayt → FIN → 226
  /// Yanlış kod (açık bağlantıda 150) Gezgin'in kopya penceresini hemen kapatır.
  Future<void> _doStore(String arg, {bool append = false}) async {
    final name = _ftpName(arg);
    if (name.isEmpty) {
      await _reply('501 Dosya adı gerekli');
      return;
    }
    final file = File(server.resolve(_absolute(name)));
    try {
      await file.parent.create(recursive: true);
    } catch (e) {
      server._log.add('STOR klasör hata: $e');
      await _cleanupTransfer();
      await _reply('550 Yazılamıyor — klasör oluşturulamadı.');
      return;
    }

    // Yazılabilirlik kontrolü — izin yoksa Windows "hesaplanıyor" deyip kapanır.
    try {
      final probe = File('${file.path}.makay_write_probe');
      await probe.writeAsBytes(const [], flush: true);
      await probe.delete();
    } catch (e) {
      server._log.add('STOR yazma izni yok: ${file.path} ($e)');
      await _cleanupTransfer();
      await _reply(
          '550 Yazma izni yok. Ağdan erişimde "İndirilenler" kökünü seçin '
          'veya uygulamaya tüm dosya erişimi verin.');
      return;
    }

    await _replyTransferReady(
      already: '125 Veri bağlantısı açık; aktarım başlıyor',
      opening: '150 Dosya alınıyor',
    );
    final data = await _acceptData();
    if (data == null) {
      await _cleanupTransfer();
      await _reply('425 Veri bağlantısı açılamadı.');
      return;
    }
    dataSocket = null;

    IOSink? sink;
    try {
      try {
        data.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}
      sink = file.openWrite(
        mode: append ? FileMode.writeOnlyAppend : FileMode.writeOnly,
      );
      await sink.addStream(data);
      await sink.flush();
      await sink.close();
      sink = null;
      await _gracefulClose(data);
      await _cleanupTransfer();
      await _reply('226 Transfer tamamlandı');
      server._log.add('STOR tamam: ${server.toVirtual(file.path)} '
          '(${file.lengthSync()} bayt)');
    } catch (e) {
      server._log.add('STOR hata: $e');
      try {
        await sink?.close();
      } catch (_) {}
      if (!append) {
        try {
          if (file.existsSync()) file.deleteSync();
        } catch (_) {}
      }
      await _forceClose(data);
      await _cleanupTransfer();
      await _reply('426 Transfer kesildi');
    }
  }

  /// Veri soketi PASV sonrası zaten kurulduysa true.
  bool get _dataAlreadyOpen =>
      dataSocket != null || (_dataReady?.isCompleted ?? false);

  Future<void> _replyTransferReady({
    required String already,
    required String opening,
  }) async {
    await _reply(_dataAlreadyOpen ? already : opening);
  }

  /// Windows tırnaklı / ters eğik yolları normalize eder.
  String _ftpName(String raw) {
    var s = raw.trim();
    if (s.length >= 2) {
      final a = s.codeUnitAt(0);
      final b = s.codeUnitAt(s.length - 1);
      // "name" veya 'name'
      if ((a == 0x22 && b == 0x22) || (a == 0x27 && b == 0x27)) {
        s = s.substring(1, s.length - 1);
      }
    }
    return s.replaceAll('\\', '/').trim();
  }

  Future<void> _gracefulClose(Socket data) async {
    try {
      await data.flush();
    } catch (_) {}
    try {
      await data.close();
    } catch (_) {}
  }

  Future<void> _forceClose(Socket data) async {
    try {
      data.destroy();
    } catch (_) {}
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
        return await _maybeWrapTls(raw);
      } catch (_) {
        return null;
      }
    }

    final ready = _dataReady;
    if (ready == null || dataServer == null) return null;
    Socket raw;
    try {
      // Windows Gezgini 150 sonrası bağlanır; 15 sn yetmeyebilir.
      raw = await ready.future.timeout(const Duration(seconds: 30));
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
    // Yalnızca sahiplenilmemiş soketi kapat. Transfer sonrası destroy()
    // Windows Gezgini'nde "bağlantı sıfırlandı" üretir.
    final leftover = dataSocket;
    dataSocket = null;
    if (leftover != null) {
      try {
        await leftover.close();
      } catch (_) {
        try {
          leftover.destroy();
        } catch (_) {}
      }
    }
    _dataReady = null;
    _portHost = null;
    _portPort = null;
  }
}
