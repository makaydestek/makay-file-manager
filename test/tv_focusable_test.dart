import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/widgets/tv_focusable.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/providers/settings_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<SettingsProvider> loadSettings({required String tvMode}) async {
    SharedPreferences.setMockInitialValues({'tv_mode': tvMode});
    final s = await SettingsProvider.load();
    s.tvMode = tvMode;
    return s;
  }

  testWidgets('TV kapalıyken sarmalayıcı çocuğu olduğu gibi bırakır',
      (tester) async {
    final settings = await loadSettings(tvMode: 'phone');
    var activated = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: TvFocusable(
              autofocus: true,
              onActivate: () => activated++,
              child: const Text('satir'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('satir'), findsOneWidget);
    // Mobil modda Focus sarmalayıcı yok → OK işlenmez.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(activated, 0);
  });

  testWidgets('TV açıkken OK tuşu onActivate çağırır', (tester) async {
    final settings = await loadSettings(tvMode: 'tv');
    var activated = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: TvFocusable(
              autofocus: true,
              onActivate: () => activated++,
              child: const ListTile(title: Text('Dosya')),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(activated, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(activated, 2);
  });
}
