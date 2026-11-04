import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/ftp_server.dart';

/// Mini FTP sunucusu için uçtan uca protokol testi:
/// USER/PASS, PWD, PASV, LIST ve RETR komutlarını gerçek soket üzerinden sınar.
void main() {
  late Directory root;
  late MiniFtpServer server;
  late int port;
  late int ftpsPort;

  setUpAll(() async {
    // Geçici kök dizin + örnek dosya.
    root = Directory.systemTemp.createTempSync('makay_ftp_root_');
    File('${root.path}${Platform.pathSeparator}hello.txt')
        .writeAsStringSync('merhaba makay');
    Directory('${root.path}${Platform.pathSeparator}klasor').createSync();

    // Port **0** verilir: işletim sistemi gerçekten boş olan iki portu tahsis
    // eder ve gerçek değerler `boundPort` / `boundTlsPort` okunur.
    //
    // Eski yaklaşım (sonra kapatılan "probe" soketleriyle port arayıp hemen
    // ardından yeniden bağlanmak) CI'da flaky idi: boş bulunan port seçildikle
    // bağlanılacak kadar arasında başkasınca alınabiliyordu (TOCTOU), port
    // `loopbackIPv4`'te aranıp sunucu `anyIPv4`'e bağlandığı için arayüz
    // uyuşmazlığı olabiliyordu, ayrıca kapatılan soket az önce dinlediği port
    // üzerinden geri verilebiliyordu (aynı port iki kez). Port 0 kullanıldığında
    // bunların hiçbiri mümkündür değil: port artık seçilmez, tahsis edilir.
    server = MiniFtpServer(
      rootPath: root.path,
      port: 0,
      tlsPort: 0,
      username: 'android',
      password: 'sifre123',
      // Yalnızca loopback: dinleyici dışarıdan erişilemez; testin konuşmadığı
      // bir arayüze gelen bağlantı ya da tarama el sıkışmayı bozamaz.
      bindAddress: InternetAddress.loopbackIPv4,
    );
    await server.start();
    port = server.boundPort;
    ftpsPort = server.boundTlsPort;
    expect(server.running, isTrue, reason: 'FTP kontrol portu dinlemiyor');
  });

  tearDownAll(() async {
    await server.stop();
    root.deleteSync(recursive: true);
  });

  test('Sunucu açılış karşılığı verir', () async {
    final c = await _FtpTestClient.connect(port);
    final greeting = await c.readReply();
    expect(greeting, startsWith('220'));
    await c.send('QUIT');
    await c.close();
  });

  test('Yanlış şifre reddedilir, doğru şifre kabul edilir', () async {
    final c = await _FtpTestClient.connect(port);
    await c.readReply(); // 220
    await c.send('USER android');
    expect(await c.readReply(), startsWith('331'));
    await c.send('PASS yanlis');
    expect(await c.readReply(), startsWith('530'));
    await c.send('PASS sifre123');
    expect(await c.readReply(), startsWith('230'));
    await c.send('QUIT');
    await c.close();
  });

  test('Kimlik doğrulamadan komut reddedilir', () async {
    final c = await _FtpTestClient.connect(port);
    await c.readReply(); // 220
    await c.send('PWD');
    expect(await c.readReply(), startsWith('530'));
    await c.close();
  });

  test('FTPS: şifreli portta TLS el sıkışması + giriş çalışır', () async {
    final c = await _FtpTestClient.connectTls(ftpsPort);
    expect(await c.readReply(), startsWith('220'));
    await c.send('USER android');
    await c.readReply();
    await c.send('PASS sifre123');
    expect(await c.readReply(), startsWith('230'));
    await c.send('PBSZ 0');
    expect(await c.readReply(), startsWith('200'));
    await c.send('PROT P');
    expect(await c.readReply(), startsWith('200'));
    await c.send('PWD');
    expect(await c.readReply(), contains('"/"'));
    await c.send('QUIT');
    await c.close();
  });

  test('Açık portta PROT P reddedilir', () async {
    final c = await _FtpTestClient.connect(port);
    await c.readReply(); // 220
    await c.send('USER android');
    await c.readReply();
    await c.send('PASS sifre123');
    await c.readReply();
    await c.send('PROT P');
    expect(await c.readReply(), startsWith('536'));
    await c.send('QUIT');
    await c.close();
  });

  test('PWD, CWD, LIST ve RETR çalışır', () async {
    final c = await _FtpTestClient.connect(port);
    await c.readReply(); // 220
    await c.send('USER android');
    await c.readReply();
    await c.send('PASS sifre123');
    expect(await c.readReply(), startsWith('230'));

    // PWD → kök
    await c.send('PWD');
    expect(await c.readReply(), contains('"/"'));

    // PASV + LIST
    final dataPort = await c.passive();
    final data = await Socket.connect(InternetAddress.loopbackIPv4, dataPort);
    await c.send('LIST');
    expect(await c.readReply(), startsWith('150'));
    final listing = await utf8.decoder.bind(data).join();
    expect(listing, contains('hello.txt'));
    expect(listing, contains('klasor'));
    expect(await c.readReply(), startsWith('226'));

    // PASV + RETR
    final dataPort2 = await c.passive();
    final data2 = await Socket.connect(InternetAddress.loopbackIPv4, dataPort2);
    await c.send('RETR hello.txt');
    expect(await c.readReply(), startsWith('150'));
    final bytes = <int>[];
    await for (final chunk in data2) {
      bytes.addAll(chunk as List<int>);
    }
    expect(utf8.decode(bytes), 'merhaba makay');
    expect(await c.readReply(), startsWith('226'));

    // MKD + CWD
    await c.send('MKD yeni');
    expect(await c.readReply(), startsWith('257'));
    await c.send('CWD yeni');
    expect(await c.readReply(), startsWith('250'));
    await c.send('PWD');
    expect(await c.readReply(), contains('"/yeni"'));

    // İç içe göreli CWD (Windows Explorer her klasörde bunu yapar).
    await c.send('MKD alt');
    expect(await c.readReply(), startsWith('257'));
    await c.send('CWD alt');
    expect(await c.readReply(), startsWith('250'));
    await c.send('PWD');
    expect(await c.readReply(), contains('"/yeni/alt"'));

    await c.send('QUIT');
    expect(await c.readReply(), startsWith('221'));
    await c.close();
  });

  test('EPSV veri bağlantısı kurulur', () async {
    final c = await _FtpTestClient.connect(port);
    await c.readReply();
    await c.send('USER android');
    await c.readReply();
    await c.send('PASS sifre123');
    expect(await c.readReply(), startsWith('230'));

    await c.send('EPSV');
    final epsv = await c.readReply();
    expect(epsv, startsWith('229'));
    final match = RegExp(r'\|\|\|(\d+)\|').firstMatch(epsv)!;
    final dataPort = int.parse(match.group(1)!);
    final data = await Socket.connect(InternetAddress.loopbackIPv4, dataPort);
    await c.send('NLST');
    expect(await c.readReply(), startsWith('150'));
    final listing = await utf8.decoder.bind(data).join();
    expect(listing, contains('hello.txt'));
    expect(await c.readReply(), startsWith('226'));
    await c.send('QUIT');
    await c.close();
  });
}

/// Basit FTP istemcisi (test amaçlı).
class _FtpTestClient {
  _FtpTestClient._(Socket socket) : _socket = socket {
    final lines = socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    _sub = lines.listen((line) {
      if (_waiters.isNotEmpty) {
        _waiters.removeAt(0).complete(line);
      } else {
        _queue.add(line);
      }
    });
  }

  final Socket _socket;
  final _queue = <String>[];
  final _waiters = <Completer<String>>[];
  StreamSubscription<String>? _sub;

  static Future<_FtpTestClient> connect(int port) async {
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, port);
    return _FtpTestClient._(socket);
  }

  /// Şifreli (implicit TLS) bağlantı kurar; kendi kendine imzalı
  /// sertifika test ortamında göz ardı edilir.
  static Future<_FtpTestClient> connectTls(int port) async {
    final socket = await SecureSocket.connect(
      InternetAddress.loopbackIPv4,
      port,
      onBadCertificate: (_) => true,
    );
    return _FtpTestClient._(socket);
  }

  Future<String> readReply() {
    if (_queue.isNotEmpty) return Future.value(_queue.removeAt(0));
    final c = Completer<String>();
    _waiters.add(c);
    return c.future.timeout(const Duration(seconds: 8));
  }

  Future<void> send(String command) async {
    _socket.write('$command\r\n');
    await _socket.flush();
  }

  /// PASV komutu gönderir, veri portunu döndürür.
  Future<int> passive() async {
    await send('PASV');
    final reply = await readReply();
    expect(reply, startsWith('227'));
    final match = RegExp(r'\((\d+),(\d+),(\d+),(\d+),(\d+),(\d+)\)')
        .firstMatch(reply)!;
    final p1 = int.parse(match.group(5)!);
    final p2 = int.parse(match.group(6)!);
    return (p1 << 8) | p2;
  }

  Future<void> close() async {
    await _sub?.cancel();
    _socket.destroy();
  }
}
