import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/screens/lan_scan_screen.dart';
import 'package:makay_file_manager/screens/remote_screen.dart';
import 'package:makay_file_manager/services/ftp_server.dart';
import 'package:makay_file_manager/services/remote_service.dart';
import 'package:makay_file_manager/services/smb_server.dart';

/// Uzak ekranı — bağlantı türlerinin uçtan uca ("Test et" → "Kaydet")
/// kontrolü.
///
/// FTP ve SMB için gömülü sunucular gerçekten başlatılır; kullanıcıyla
/// birebir aynı akış denenir. SFTP/WebDAV için ulaşılamayan sunucu
/// senaryosuyla hata yolunun da formu kapatmadığı doğrulanır.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory ftpRoot;
  late MiniFtpServer ftpServer;
  late int ftpPort;
  late Directory smbRoot;
  late MiniSmbServer smbServer;
  late int smbPort;

  setUpAll(() async {
    ftpRoot = Directory.systemTemp.createTempSync('remote_e2e_ftp_');
    File('${ftpRoot.path}${Platform.pathSeparator}ornek.txt')
        .writeAsStringSync('merhaba makay');
    Directory('${ftpRoot.path}${Platform.pathSeparator}klasor').createSync();
    // Port **0**: işletim sistemi gerçekten boş bir port tahsis eder ve gerçek
    // değer `boundPort`'tan okunur. "Boş port bul → soketi kapat → hemen
    // bağlan" yaklaşımı yarışa açıktır (TOCTOU) ve test dosyaları paralel
    // koştuğu için başka bir dosya tam o portu alabilir.
    ftpServer = MiniFtpServer(
      rootPath: ftpRoot.path,
      port: 0,
      enableTls: false,
      username: 'makay',
      password: 'sifre123',
    );
    await ftpServer.start();
    ftpPort = ftpServer.boundPort;

    smbRoot = Directory.systemTemp.createTempSync('remote_e2e_smb_');
    File('${smbRoot.path}${Platform.pathSeparator}paylasilan.txt')
        .writeAsStringSync('smb içerik');
    // Port **0** — bkz. yukarıdaki FTP açıklaması.
    smbServer = MiniSmbServer(
      rootPath: smbRoot.path,
      port: 0,
      username: 'makay',
      password: 'sifre123',
    );
    await smbServer.start();
    smbPort = smbServer.boundPort;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  tearDownAll(() async {
    await ftpServer.stop();
    await smbServer.stop();
    if (ftpRoot.existsSync()) ftpRoot.deleteSync(recursive: true);
    if (smbRoot.existsSync()) smbRoot.deleteSync(recursive: true);
  });

  Future<void> openForm(WidgetTester tester, String typeLabel) async {
    await tester.pumpWidget(const MaterialApp(home: RemoteScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(typeLabel));
    await tester.pumpAndSettle();
  }

  Future<void> field(WidgetTester tester, String label, String value) async {
    await tester.enterText(find.widgetWithText(TextFormField, label), value);
    await tester.pump();
  }

  /// "Test et" sonucunu gerçek (ağ) zamanında bekler.
  Future<String> awaitTest(WidgetTester tester) async {
    for (var i = 0; i < 300; i++) {
      await tester
          .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 50));
      if (find.textContaining('Bağlantı başarılı').evaluate().isNotEmpty) {
        return 'ok';
      }
      if (find.textContaining('Bağlantı başarısız').evaluate().isNotEmpty) {
        return 'fail';
      }
      if (i % 40 == 0) {
        // ignore: avoid_print
        print('  ...bekleme adımı $i');
      }
    }
    return 'timeout';
  }

  Future<void> saveAndVerify(
    WidgetTester tester, {
    required String listLabel,
    required String type,
  }) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();
    expect(find.text('$type konumu ekle'), findsNothing,
        reason: 'Kaydet diyalogu kapatmalı');
    expect(find.text(listLabel), findsOneWidget,
        reason: 'Kayıt ana listede görünmeli');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('remote_locations'), contains(listLabel));
    final loaded = await RemoteLocationStore.load();
    expect(loaded, hasLength(1));
    expect(loaded.first.type, type);
  }

  testWidgets('FTP: Test et başarılı → Kaydet → kayıt kalıcı', (tester) async {
    await openForm(tester, 'FTP');
    await field(tester, 'Sunucu (host / IP)', '127.0.0.1');
    await field(tester, 'Port', '$ftpPort');
    await field(tester, 'Bağlantı adı', 'Yerel FTP');
    await field(tester, 'Kullanıcı adı', 'makay');
    await field(tester, 'Şifre', 'sifre123');

    await tester.tap(find.widgetWithText(TextButton, 'Test et'));
    final result = await awaitTest(tester);
    expect(result, 'ok', reason: 'FTP bağlantı testi başarılı olmalı');

    await saveAndVerify(tester, listLabel: 'Yerel FTP', type: 'ftp');
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('SMB: Test et başarılı → Kaydet → kayıt kalıcı', (tester) async {
    await openForm(tester, 'SMB');
    await field(tester, 'Sunucu (host / IP)', '127.0.0.1');
    await field(tester, 'Port', '$smbPort');
    await field(tester, 'Bağlantı adı', 'Yerel SMB');
    await field(tester, 'Paylaşım adı', 'makay');
    await field(tester, 'Kullanıcı adı', 'makay');
    await field(tester, 'Şifre', 'sifre123');

    await tester.tap(find.widgetWithText(TextButton, 'Test et'));
    final result = await awaitTest(tester);
    expect(result, 'ok', reason: 'SMB bağlantı testi başarılı olmalı');

    await saveAndVerify(tester, listLabel: 'Yerel SMB', type: 'smb');
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('SFTP: ulaşılamayan sunucu hata verir, Kaydet çalışır',
      (tester) async {
    await openForm(tester, 'SFTP');
    // Not: test gövdesinde gerçek ağ I/O'su beklenemez (sahte zaman alanı);
    // hiçbir dinleyicinin olmadığı bilinen kapalı port kullanılır.
    const closedPort = 1;

    await field(tester, 'Sunucu (host / IP)', '127.0.0.1');
    await field(tester, 'Port', '$closedPort');
    await field(tester, 'Bağlantı adı', 'SFTP Sunucu');
    await field(tester, 'Kullanıcı adı', 'root');
    await field(tester, 'Şifre', 'x');

    await tester.tap(find.widgetWithText(TextButton, 'Test et'));
    final result = await awaitTest(tester);
    expect(result, 'fail', reason: 'Başarısız test okunabilir hata vermeli');

    await saveAndVerify(tester, listLabel: 'SFTP Sunucu', type: 'sftp');
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('WebDAV: şemasız adres normalize edilir, hata sonrası Kaydet',
      (tester) async {
    await openForm(tester, 'WebDAV');
    // Test gövdesinde gerçek ağ I/O'su beklenemez → kapalı port sabit.
    const closedPort = 1;

    // Şema yazılmamış adres: uygulama https:// ekleyerek denemeli.
    await field(tester, 'Adres (URL)', '127.0.0.1:$closedPort/dav');
    await field(tester, 'Bağlantı adı', 'WebDAV Sunucu');
    await field(tester, 'Kullanıcı adı', 'user');
    await field(tester, 'Şifre', 'pw');

    await tester.tap(find.widgetWithText(TextButton, 'Test et'));
    final result = await awaitTest(tester);
    expect(result, 'fail', reason: 'Başarısız test hata mesajı göstermeli');

    await saveAndVerify(tester,
        listLabel: 'WebDAV Sunucu', type: 'webdav');
  }, timeout: const Timeout(Duration(seconds: 120)));

  testWidgets('Yerel Ağ akışı: tarama sonucundaki konum KAYDEDİLİR',
      (tester) async {
    // Regresyon testi: "Yerel Ağ" akışında konum, tarama ekranınca
    // döndürülüyordu ama `_persist` hiç çağrılmıyordu → kullanıcı "Kaydet"
    // dese bile bağlantı kaydedilmiyor ve listeye hiç gelmiyordu.
    await tester.pumpWidget(const MaterialApp(home: RemoteScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yerel Ağ'));
    // Tarama ekranı ilerleme animasyonu gösterir → pumpAndSettle asla
    // "settle" olmaz; sınırlı pump ile yerleşim beklenir.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(LanScanScreen), findsOneWidget,
        reason: 'Tarama ekranı açılmış olmalı');

    // Form onaylanıp konum döndürülmüş gibi davranılır: tarama ekranı
    // `pop(loc)` ile kapanır (ağ taraması test ortamında gerçek async I/O
    // beklemediği için _subnet null kalır; akışın kaydetme kısmını bu
    // test etkilemez).
    final state =
        tester.state<State<LanScanScreen>>(find.byType(LanScanScreen));
    Navigator.of(state.context).pop(RemoteLocation(
      name: 'SMB 192.168.1.5',
      host: '192.168.1.5',
      type: 'smb',
      port: 445,
      share: 'Paylasim',
    ));
    // Sınırlı pump: geri dönüş animasyonu bitsin ama snackbar'ın otomatik
    // kaybolması (4 sn) için zaman ilerlemesin.
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.byType(LanScanScreen), findsNothing,
        reason: 'Tarama ekranı kapanmış olmalı');
    expect(find.text('SMB 192.168.1.5'), findsOneWidget,
        reason: 'Konum ana listede görünmeli');
    expect(find.textContaining('kaydedildi'), findsOneWidget,
        reason: 'Kullanıcıya başarı geri bildirimi gösterilmeli');

    final loaded = await RemoteLocationStore.load();
    expect(loaded, hasLength(1),
        reason:
            'Taramadan eklenen konum KALICI olarak kaydedilmeli (persist)');
    expect(loaded.first.type, 'smb');
    expect(loaded.first.share, 'Paylasim');
  });
}
