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

  testWidgets('TV formunda yön tuşları alanlar arası geçer', (tester) async {
    final settings = await loadSettings(tvMode: 'tv');
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                TvTextFormField(
                  focusNode: a,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: 'Alan A'),
                ),
                TvTextFormField(
                  focusNode: b,
                  decoration: const InputDecoration(labelText: 'Alan B'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // TvTextFormField yön yakalayıcısını post-frame bağlar.
    await tester.pump();
    expect(a.hasFocus, isTrue);
    expect(a.onKeyEvent, isNotNull,
        reason: 'TV yön tuşu yakalayıcısı FocusNode\'a bağlanmalı');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(b.hasFocus, isTrue, reason: 'aşağı sonraki alana geçmeli');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(a.hasFocus, isTrue, reason: 'yukarı önceki alana dönmeli');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(b.hasFocus, isTrue, reason: 'ileri (sağ) sonraki alana geçmeli');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(a.hasFocus, isTrue, reason: 'geri (sol) önceki alana dönmeli');
  });
}
