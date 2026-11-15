import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/l10n/app_localizations.dart';
import 'package:makay_file_manager/providers/settings_provider.dart';
import 'package:makay_file_manager/screens/settings_screen.dart';

/// Ayarlar → Hakkında bölümü Makay ekosistemiyle uyumlu yapıdadır:
/// uygulama adı + sürüm, Geliştirici bilgisi ve telif satırı tek kartta.
void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('Hakkında kartı ekosistem yapısını gösterir', (tester) async {
    final settings = await SettingsProvider.load();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: const SettingsScreen(),
            // SettingsScreen başlığı AppLocalizations okur.
            locale: const Locale('tr'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Hakkında bölümü ayarlar listesinin en üstündedir; kaydırmadan görünür.
    final about = find.text('Makay Dosya Yöneticisi');
    expect(about, findsOneWidget);

    // Başlık emoji önekli ('ℹ️ Hakkında').
    expect(find.textContaining('Hakkında'), findsWidgets);
    expect(about, findsOneWidget);
    expect(find.textContaining('Sürüm:'), findsOneWidget);
    expect(find.text('Geliştirici'), findsOneWidget);
    expect(
      find.textContaining('Murat AKAY tarafından yapılmıştır'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Tüm hakları saklıdır'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Sideload / yerel dağıtım'),
      findsOneWidget,
    );
  });
}
