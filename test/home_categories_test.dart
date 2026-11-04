import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/models/home_category.dart';
import 'package:makay_file_manager/providers/settings_provider.dart';
import 'package:makay_file_manager/screens/home_categories_screen.dart';
import 'package:makay_file_manager/screens/home_screen.dart';
import 'package:makay_file_manager/theme/app_theme.dart';

/// Ana ekran kartlarının gösterilmesi/gizlenmesi (Ayarlar → "Ana ekran
/// kartları" ve ana ekrandaki "Kartları göster / gizle" menüsü).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsProvider> pumpHome(
    WidgetTester tester, {
    Map<String, Object> prefs = const {},
  }) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(prefs);
    final settings = await SettingsProvider.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const HomeScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('Varsayılan olarak tüm kartlar görünür', (tester) async {
    await pumpHome(tester);
    expect(find.text('Kasa'), findsOneWidget);
    expect(find.text('USB / SD'), findsOneWidget);
  });

  testWidgets('Gizlenen kart ana ekrandan kalkar, ayar kalıcıdır',
      (tester) async {
    final settings = await pumpHome(tester);
    settings.setCategoryVisible('vault', false);
    await tester.pump();
    expect(find.text('Kasa'), findsNothing);
    expect(find.text('USB / SD'), findsOneWidget);

    // Ayar yeniden yüklendiğinde de gizli kalmalı.
    final reloaded = await SettingsProvider.load();
    expect(reloaded.isCategoryVisible('vault'), isFalse);
    expect(reloaded.isCategoryVisible('usb'), isTrue);
  });

  testWidgets('Göster/gizle ekranı ana ekrandan açılır ve anahtar çalışır',
      (tester) async {
    await pumpHome(tester);

    // Üç nokta menüsü → "Kartları göster / gizle".
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kartları göster / gizle'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeCategoriesScreen), findsOneWidget);

    // "Kasa" anahtarını kapat.
    await tester.scrollUntilVisible(find.text('Kasa'), 120,
        scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('Kasa'));
    await tester.pumpAndSettle();

    // Ana ekrana dön → kart artık yok.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Kasa'), findsNothing);
  });

  testWidgets('Tüm kartlar gizlenince boş ekran yönlendirmesi çıkar',
      (tester) async {
    final settings = await pumpHome(tester);
    for (final id in [
      for (final c in kHomeCategories) c.id,
    ]) {
      settings.setCategoryVisible(id, false);
    }
    await tester.pumpAndSettle();

    expect(find.text('Tüm kartlar gizlendi'), findsOneWidget);
    expect(find.byType(GridView), findsNothing);

    await tester.tap(find.text('Kartları göster / gizle'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeCategoriesScreen), findsOneWidget);
  });

  testWidgets('Bulut kartı doğrulama tamamlanana kadar hiçbir yerde yok',
      (tester) async {
    await pumpHome(tester);
    expect(find.text('Bulut'), findsNothing);

    // Göster/gizle listesinde de yer almamalı: kullanıcı yanlışlıkla açıp
    // çalışmayan özelliğe düşmesin.
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: await SettingsProvider.load(),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const HomeCategoriesScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Bulut'), findsNothing);

    // Rota/ekran kodu duruyor: geri eklemek tek satır. Modelde cloud yok,
    // kasa/temizlik kartları listede.
    expect(kHomeCategories.any((c) => c.id == 'cloud'), isFalse);
    expect(kHomeCategories.any((c) => c.id == 'vault'), isTrue);
    expect(kHomeCategories.any((c) => c.id == 'clean'), isTrue);
  });

  testWidgets('Tümünü göster sıfırlama düğmesi gizlenenleri geri getirir',
      (tester) async {
    final settings = await pumpHome(
      tester,
      prefs: {'hidden_home_categories': ['vault', 'usb']},
    );
    expect(settings.hiddenHomeCategories, {'vault', 'usb'});

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const HomeCategoriesScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Tümünü göster'));
    await tester.pumpAndSettle();
    expect(settings.hiddenHomeCategories, isEmpty);
  });
}