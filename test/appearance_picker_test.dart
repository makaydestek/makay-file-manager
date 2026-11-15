import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/l10n/app_localizations.dart';
import 'package:makay_file_manager/providers/settings_provider.dart';
import 'package:makay_file_manager/screens/settings_screen.dart';
import 'package:makay_file_manager/theme/app_appearance.dart';

/// Ayarlar → "Görünüm": önizlemeli seçim diyaloğu açılır, seçim
/// kalıcılaştırılır ve liste alt başlığı anında güncellenir.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<SettingsProvider> pumpSettings(WidgetTester tester) async {
    final settings = await SettingsProvider.load();
    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settings,
        // SettingsScreen başlığı AppLocalizations okur; üretimde MaterialApp'e
        // verilen delegate testte de sağlanmazsa null çöker.
        child: const MaterialApp(
          home: SettingsScreen(),
          locale: Locale('tr'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return settings;
  }

  testWidgets('Görünüm satırı Tema\'nın altında görünür', (tester) async {
    await pumpSettings(tester);

    expect(find.text('Görünüm'), findsOneWidget);
    // Varsayılan: Klasik — açıklama satırda görünür.
    expect(find.textContaining('Klasik'), findsWidgets);
    // Satır gerçekten görünür durumda olmalı (kaydırma gerekmiyor).
    expect(find.widgetWithText(ListTile, 'Görünüm'), findsOneWidget);
  });

  testWidgets('Seçim diyaloğu her preset\'i önizlemeyle sunar', (tester) async {
    await pumpSettings(tester);

    // 'Görünüm' satırı (tam metin) — 'Görünüm düzeni' ile karışmasın.
    final row = find.widgetWithText(ListTile, 'Görünüm');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(find.text('Görünüm seçin'), findsOneWidget);
    for (final a in AppAppearance.values) {
      expect(find.text(a.label), findsOneWidget, reason: a.label);
      expect(find.text(a.description), findsOneWidget, reason: a.label);
    }
    // Her satırda canlı önizleme (kart içinde ikon) vardır.
    expect(find.byIcon(Icons.folder_rounded),
        findsNWidgets(AppAppearance.values.length));

    // Diyalog kapatılmaz, seçim yapılır.
    await tester.tap(find.text('Vazgeç'));
    await tester.pumpAndSettle();
    final settings = await SharedPreferences.getInstance();
    expect(settings.getString('appearance'), isNull,
        reason: 'vazgeçilen seçim kaydedilmemeli');
  });

  testWidgets('Seçilen görünüm kalıcılaşır ve alt başlık güncellenir',
      (tester) async {
    final provider = await pumpSettings(tester);
    expect(provider.appearance, AppAppearance.klasik);

    final row = find.widgetWithText(ListTile, 'Görünüm');
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Canlı & Yuvarlak'));
    await tester.pumpAndSettle();

    expect(find.text('Görünüm seçin'), findsNothing, reason: 'diyalog kapanır');
    expect(provider.appearance, AppAppearance.canli);
    expect(find.textContaining('Canlı & Yuvarlak'), findsWidgets,
        reason: 'liste alt başlığı yeni görünümü göstermeli');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('appearance'), 'canli',
        reason: 'tercih kalıcı olmalı');
  });
}
