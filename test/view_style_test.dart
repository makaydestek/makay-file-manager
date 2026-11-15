import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/providers/settings_provider.dart';
import 'package:makay_file_manager/screens/home_screen.dart';
import 'package:makay_file_manager/services/category_size_service.dart';
import 'package:makay_file_manager/theme/app_theme.dart';

/// Görünüm düzeni ayarı (dikey/yatay sütun sayısı) ve
/// kategori başlık altı boyut etiketinin gösterimi.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Ana ekran ızgarası `GridView` değil, `CustomScrollView` içindeki
  /// `SliverGrid`'dir; sütun sayısı oradan okunur.
  int columns(WidgetTester tester) {
    final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    return delegate.crossAxisCount;
  }

  Future<SettingsProvider> pumpHome(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
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

  /// Arka plan boyut hesabının bitmesini bekler (yarış durumunu önler).
  Future<void> settleSizes(WidgetTester tester) async {
    for (var i = 0; i < 400 && CategorySizeService.running; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(CategorySizeService.running, isFalse);
  }

  testWidgets('Otomatik modda genişliğe göre sütun seçilir (800 px → 4)',
      (tester) async {
    await pumpHome(tester, const Size(800, 600));
    expect(columns(tester), 4);
  });

  testWidgets('Dengeli (dikey 3 / yatay 4) düzeni uygulanır', (tester) async {
    final settings = await pumpHome(tester, const Size(400, 800)); // dikey
    expect(columns(tester), 3, reason: 'varsayılan genişlik dikeyyken 3 sütun');

    settings.viewStyle = 'medium';
    await tester.pump();
    expect(columns(tester), 3);

    tester.view.physicalSize = const Size(800, 400); // yatay
    await tester.pump();
    expect(columns(tester), 4, reason: 'yatayda 4 sütun');
  });

  testWidgets('Büyük kartlar (dikey 2 / yatay 3) düzeni uygulanır',
      (tester) async {
    final settings = await pumpHome(tester, const Size(400, 800));
    settings.viewStyle = 'large';
    await tester.pump();
    expect(columns(tester), 2);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    expect(columns(tester), 3);
  });

  testWidgets('Sıkışık (dikey 4 / yatay 6) düzeni uygulanır', (tester) async {
    final settings = await pumpHome(tester, const Size(400, 800));
    settings.viewStyle = 'small';
    await tester.pump();
    expect(columns(tester), 4);

    tester.view.physicalSize = const Size(800, 400);
    await tester.pump();
    expect(columns(tester), 6);
  });

  testWidgets('Kategori boyutu başlığın altında görünür', (tester) async {
    await pumpHome(tester, const Size(400, 800));
    await settleSizes(tester);
    expect(find.text('64 GB / 128 GB'), findsNothing);

    CategorySizeService.labels.value = const {
      'internal': '64 GB / 128 GB',
      'images': '1,2 GB',
      'recent': '300 KB',
    };
    addTearDown(() => CategorySizeService.labels.value = const {});
    await tester.pump();

    expect(find.text('64 GB / 128 GB'), findsOneWidget);
    expect(find.text('1,2 GB'), findsOneWidget);
    expect(find.text('300 KB'), findsOneWidget);
  });
}
