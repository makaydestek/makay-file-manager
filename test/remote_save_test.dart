import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/screens/remote_screen.dart';
import 'package:makay_file_manager/services/remote_service.dart';

/// Uzak ekranı: form doğrulama → Kaydet → kalıcı saklama zinciri.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('FTP formu kaydediliyor ve listeye + depoya yazılıyor',
      (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(
      const MaterialApp(home: RemoteScreen()),
    );
    await tester.pumpAndSettle();

    // FAB → tür seçimi.
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('FTP'), findsOneWidget);
    await tester.tap(find.text('FTP'));
    await tester.pumpAndSettle();

    // Form dolduruluyor.
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Sunucu (host / IP)'),
        '192.168.1.50');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Kullanıcı adı'), 'makay');
    await tester.enterText(find.widgetWithText(TextFormField, 'Şifre'), 'sifre');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    // 1) Diyalog kapandı mı?
    expect(find.text('FTP konumu ekle'), findsNothing,
        reason: 'Kaydet diyalogu kapatmalı');

    // 2) Liste yeni kaydı gösteriyor mu?
    expect(find.text('192.168.1.50'), findsOneWidget,
        reason: 'Kayıt listeye eklenmeli');

    // 3) SharedPreferences meta yazıldı; şifre düz metin olmamalı.
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('remote_locations');
    expect(raw, isNotNull, reason: 'remote_locations anahtarı yazılmalı');
    expect(raw, contains('192.168.1.50'));
    expect(raw, isNot(contains('"password":"sifre"')),
        reason: 'şifre SecureStore\'da olmalı, prefs\'te değil');

    // 4) Store.load() geri okuyabiliyor mu? (asıl kalıcılık kontrolü)
    final loaded = await RemoteLocationStore.load();
    expect(loaded, hasLength(1), reason: 'Store.load() kaydı geri okumalı');
    expect(loaded.first.host, '192.168.1.50');
    expect(loaded.first.username, 'makay');
    expect(loaded.first.password, 'sifre');
  });

  testWidgets('Eksik sunucu adresi ile Kaydet basılamaz (validasyon)',
      (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(home: RemoteScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('FTP'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    // Hata mesajı görünmeli, diyalog kapanmamalı.
    expect(find.text('Sunucu adresi gerekli'), findsOneWidget);
    expect(find.text('FTP konumu ekle'), findsOneWidget);
  });

  testWidgets('URL girilen WebDAV formu kaydedilebiliyor', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const MaterialApp(home: RemoteScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WebDAV / Nextcloud'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Adres (URL)'),
        'https://nextcloud.ornek.com/remote.php/dav/files/kullanici');
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Kullanıcı adı'), 'kullanici');
    await tester.enterText(find.widgetWithText(TextFormField, 'Şifre'), 'p1');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('WebDAV konumu ekle'), findsNothing);
    final loaded = await RemoteLocationStore.load();
    expect(loaded, hasLength(1));
    expect(loaded.first.type, 'webdav');
    expect(loaded.first.host, startsWith('https://'));
  });

  testWidgets('Kayıtlı FTP adı yeniden adlandırılabiliyor', (tester) async {
    SharedPreferences.setMockInitialValues({
      'remote_locations':
          '[{"name":"EskiAd","host":"10.0.0.1","type":"ftp","port":21,'
          '"username":"u","password":"p","startPath":"/","share":""}]',
    });

    await tester.pumpWidget(const MaterialApp(home: RemoteScreen()));
    await tester.pumpAndSettle();
    expect(find.text('EskiAd'), findsOneWidget);

    await tester.tap(find.byTooltip('Düzenle / sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Yeniden adlandır'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.widgetWithText(TextField, 'Bağlantı adı'), 'YeniAd');
    await tester.tap(find.widgetWithText(FilledButton, 'Kaydet'));
    await tester.pumpAndSettle();

    expect(find.text('YeniAd'), findsOneWidget);
    expect(find.text('EskiAd'), findsNothing);
    final loaded = await RemoteLocationStore.load();
    expect(loaded.single.name, 'YeniAd');
    expect(loaded.single.host, '10.0.0.1');
  });

  testWidgets('FTP düzenle formu alanları günceller', (tester) async {
    SharedPreferences.setMockInitialValues({
      'remote_locations':
          '[{"name":"NAS","host":"192.168.1.1","type":"ftp","port":21,'
          '"username":"u","password":"p","startPath":"/","share":""}]',
    });

    await tester.pumpWidget(const MaterialApp(home: RemoteScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Düzenle / sil'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Düzenle'));
    await tester.pumpAndSettle();

    expect(find.text('FTP konumunu düzenle'), findsOneWidget);
    await tester.enterText(
        find.widgetWithText(TextFormField, 'Bağlantı adı'), 'Ev NAS');
    await tester.tap(find.widgetWithText(FilledButton, 'Güncelle'));
    await tester.pumpAndSettle();

    expect(find.text('Ev NAS'), findsOneWidget);
    final loaded = await RemoteLocationStore.load();
    expect(loaded.single.name, 'Ev NAS');
    expect(loaded.single.host, '192.168.1.1');
  });
}
