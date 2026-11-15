import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/remote_service.dart';
import 'package:makay_file_manager/services/sftp_service.dart';
import 'package:makay_file_manager/services/webdav_service.dart';

void main() {
  /// Gerçekten boş bir port bulur; `(adres, port)` döndürür.
  ///
  /// Port **`127.0.0.2`** arayüzünde aranır ve istemci de **aynı adrese**
  /// bağlanır; bu, gerçek bir hatayı kapatır. Eski sürümde port
  /// `127.0.0.1` üzerinde aranıyor, soket kapatılıp hemen bağlanıyordu.
  /// Aradaki boşlukta başka bir test dosyası o portu **tahsis edebiliyordu**
  /// (test dosyaları paralel koşar) — ve bu depoda tam olarak oluyordu:
  /// `ftp_server_test.dart` FTPS dinleyicisini az önce boşalan porta açıyor,
  /// buradan yapılan TLS bağlantısı FTP sunucusunda
  /// `SocketException: Broken pipe` üretip FTP testini CI'da düşürüyordu.
  ///
  /// `127.0.0.2` kullanıldığında `127.0.0.1` üzerinde dinleyen hiçbir
  /// sunucuya rastlanamaz, dolayısıyla bağlantı gerçekten reddedilir.
  Future<(InternetAddress, int)> closedPort() async {
    InternetAddress addr;
    ServerSocket probe;
    try {
      addr = InternetAddress('127.0.0.2');
      probe = await ServerSocket.bind(addr, 0);
    } catch (_) {
      // Bazı ortamlarda 127.0.0.2 yoktur; loopback'e düşülür.
      addr = InternetAddress.loopbackIPv4;
      probe = await ServerSocket.bind(addr, 0);
    }
    final port = probe.port;
    await probe.close();
    return (addr, port);
  }

  test('SFTP: kapalı portta kaç saniyede hata verir', () async {
    final (host, port) = await closedPort();
    final sw = Stopwatch()..start();
    Object? err;
    try {
      await SftpSession.connect(RemoteLocation(
        name: 'x',
        host: host.address,
        type: 'sftp',
        port: port,
        username: 'root',
        password: 'x',
      ));
    } catch (e) {
      err = e;
    }
    // ignore: avoid_print
    print('SFTP sonucu=${err.runtimeType} süre=${sw.elapsedMilliseconds}ms '
        'mesaj=$err');
    expect(err, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('WebDAV: kapalı portta kaç saniyede hata verir', () async {
    final (host, port) = await closedPort();
    final sw = Stopwatch()..start();
    Object? err;
    try {
      await const WebDavService().list(CloudLocation(
        name: 'x',
        provider: 'WebDAV',
        url: 'https://${host.address}:$port/dav',
        username: 'u',
        password: 'p',
      ));
    } catch (e) {
      err = e;
    }
    // ignore: avoid_print
    print('WebDAV sonucu=${err.runtimeType} süre=${sw.elapsedMilliseconds}ms '
        'mesaj=$err');
    expect(err, isNotNull);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('WebDAV normalizeUrl davranisi', () {
    expect(WebDavService.normalizeUrl('next.site.com/dav'),
        'https://next.site.com/dav');
    expect(WebDavService.normalizeUrl('https://x.com/dav/'), 'https://x.com/dav');
    // Düz http, Basic Auth sızmasın diye HTTPS'e yükseltilir.
    expect(WebDavService.normalizeUrl('  http://y.com  '), 'https://y.com');
    // Loopback (yerel test sunucusu) http olarak kalır.
    expect(WebDavService.normalizeUrl('http://127.0.0.1:8080/dav'),
        'http://127.0.0.1:8080/dav');
    expect(WebDavService.normalizeUrl('http://localhost:8080/dav'),
        'http://localhost:8080/dav');
  });
}
