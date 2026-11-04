import 'dart:async';
import 'dart:ui';

import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';

import 'l10n/app_localizations.dart';
import 'models/home_category.dart';
import 'providers/settings_provider.dart';
import 'screens/browser_screen.dart';
import 'screens/device_mode_screen.dart';
import 'screens/duplicate_files_screen.dart';
import 'screens/home_screen.dart';
import 'screens/media_category_screen.dart';
import 'screens/permissions_screen.dart';
import 'screens/recent_files_screen.dart';
import 'screens/recycle_bin_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/apps_screen.dart';
import 'screens/cloud_screen.dart';
import 'screens/global_search_screen.dart';
import 'screens/network_access_screen.dart';
import 'screens/remote_screen.dart';
import 'screens/storage_analysis_screen.dart';
import 'screens/app_lock_screen.dart';
import 'screens/clean_center_screen.dart';
import 'screens/privacy_screen.dart';
import 'screens/receive_share_screen.dart';
import 'screens/temp_cleaner_screen.dart';
import 'screens/tv_home_screen.dart';
import 'screens/usb_storage_screen.dart';
import 'screens/vault_screen.dart';
import 'services/auth_service.dart';
import 'services/category_size_service.dart';
import 'services/media_service.dart';
import 'services/platform_service.dart';
import 'services/update_service.dart';
import 'theme/app_theme.dart';
import 'utils/app_paths.dart';
import 'utils/debug_log.dart';
import 'utils/tv_ui.dart';
import 'widgets/update_dialog.dart';

/// Kök navigator (açılışta güncelleme diyaloğu için).
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Beklenmeyen hataları yutmadan kaydet; kırmızı ekranı azalt.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logSwallowed('FlutterError', details.exception);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logSwallowed('PlatformDispatcher', error);
    return true; // işlendi — uygulama düşmesin
  };

  final settings = await SettingsProvider.load();
  // TV algılamasını açılışta çöz: auto modda TvUi / tema senkron kalsın.
  await PlatformService.isTv();
  runZonedGuarded(
    () {
      runApp(
        ChangeNotifierProvider.value(
          value: settings,
          child: const MakayApp(),
        ),
      );
    },
    (error, stack) {
      logSwallowed('Zone', error);
      if (kDebugMode) {
        debugPrint('$error\n$stack');
      }
    },
  );
}

class MakayApp extends StatefulWidget {
  const MakayApp({super.key});

  @override
  State<MakayApp> createState() => _MakayAppState();
}

class _MakayAppState extends State<MakayApp> with WidgetsBindingObserver {
  /// Uygulama yaşam döngüsünde yalnızca bir kez sorgulanır.
  static bool _updateChecked = false;

  /// Rota geri alındığında (ana ekrana dönüş dâhil) kart boyutlarını tazeler.
  final _popRefresh = _PopRefreshObserver();

  /// Uygulama ön plana döndüğünde (dışarıda yapılan indirmeler vb.) tazeler.
  final _resumeRefresh = _ResumeRefreshObserver();

  /// Sürüm seçimi + izin onayı yeni tamamlandı mı?
  bool _setupDone = false;

  /// Uygulama kilidi kapısı (A4).
  bool _lockChecked = false;
  bool _showLock = false;

  /// Sistem paylaşımı kaydetme ekranı açık mı (yinelenmeyi önler).
  bool _shareScreenOpen = false;

  /// Kilit/kurulum bitene kadar bekletilen paylaşım dosyaları.
  List<SharedInboxFile>? _deferredShare;

  /// İlk açılış akışı tamam mı? (sürüm seçimi ve izinler)
  static bool _isSetupComplete(SettingsProvider s) =>
      s.deviceModeChosen && s.permissionsOnboarded;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addObserver(_resumeRefresh);
    // Sistem "Paylaş" → uygulama (SEND / SEND_MULTIPLE).
    PlatformService.ensureSharedFilesHandler();
    PlatformService.onSharedFiles = _onSharedFiles;
    // Her açılışta GitHub depoda yeni sürüm sorgulanır (A15/A17).
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      _setupDone = _isSetupComplete(context.read<SettingsProvider>());
      _checkUpdate();
      await _checkLockGate();
      await _openPendingShare();
    });
  }

  @override
  void dispose() {
    if (PlatformService.onSharedFiles == _onSharedFiles) {
      PlatformService.onSharedFiles = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.removeObserver(_resumeRefresh);
    super.dispose();
  }

  Future<void> _onSharedFiles(List<SharedInboxFile> files) async {
    await _openShareScreen(files);
  }

  Future<void> _openPendingShare() async {
    final files = await PlatformService.takeSharedFiles();
    final merged = <SharedInboxFile>[];
    void addAll(Iterable<SharedInboxFile>? list) {
      if (list == null) return;
      for (final f in list) {
        if (merged.any((e) => e.path == f.path)) continue;
        merged.add(f);
      }
    }

    addAll(_deferredShare);
    addAll(files);
    _deferredShare = null;
    if (merged.isEmpty) return;
    await _openShareScreen(merged);
  }

  Future<void> _openShareScreen(List<SharedInboxFile> hint) async {
    if (hint.isEmpty || _shareScreenOpen) return;
    // Kilit kontrolü bitmeden veya kilit açıkken ertele.
    if (!_lockChecked || _showLock) {
      _deferredShare = hint;
      return;
    }
    // Canlı bildirimde native kuyruğu da tüket.
    final pending = await PlatformService.takeSharedFiles();
    final files = <SharedInboxFile>[
      ...hint,
      if (pending != null)
        for (final f in pending)
          if (!hint.any((h) => h.path == f.path)) f,
    ];
    if (files.isEmpty) return;
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      _deferredShare = files;
      return;
    }
    _shareScreenOpen = true;
    _deferredShare = null;
    try {
      await nav.push(
        MaterialPageRoute<void>(
          builder: (_) => ReceiveShareScreen(files: files),
        ),
      );
    } finally {
      _shareScreenOpen = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      AuthService.onPaused();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_onResumeLock());
    }
  }

  Future<void> _checkLockGate() async {
    final need = await AuthService.needsLockGate();
    if (!mounted) return;
    setState(() {
      _lockChecked = true;
      _showLock = need;
    });
  }

  Future<void> _onResumeLock() async {
    final need = await AuthService.shouldLockOnResume();
    if (!mounted) return;
    if (need) setState(() => _showLock = true);
  }

  Future<void> _checkUpdate() async {
    if (_updateChecked) return;
    if (!mounted) return;
    // Sürüm seçimi / izin onayı bitmeden güncelleme sorma.
    if (!_isSetupComplete(context.read<SettingsProvider>())) return;
    _updateChecked = true;
    try {
      final info = await UpdateService.check();
      if (info == null || !mounted) return;
      // Navigator her zaman kökte yaşar; taze context kullan.
      final ctx = rootNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      // ignore: use_build_context_synchronously — GlobalKey context'i taze
      // okundu ve mounted ile doğrulandı; asla ana akışı bozmaz.
      await showUpdateDialog(ctx, info);
    } catch (_) {
      // Güncelleme sorgusu asla ana akışı bozmamalı.
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // İlk açılış akışı (seçim + izinler) bittikten sonra ertelenen
    // güncelleme kontrolünü çalıştır.
    if (_isSetupComplete(settings) && !_setupDone) {
      _setupDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
    }
    // Material You: Android 12+ dinamik sistem rengi (kullanıcı kapatabilir).
    if (!settings.dynamicColor) {
      return _app(settings, null);
    }
    return DynamicColorBuilder(
      // Not: dynamic_color paketi kendi ColorScheme tipini döndürür; tip
      // çakışmasını önlemek için yalnız seed rengi alınır.
      builder: (lightDynamic, darkDynamic) => _app(
        settings,
        (light: lightDynamic?.primary, dark: darkDynamic?.primary),
      ),
    );
  }

  Widget _app(SettingsProvider settings, ({Color? light, Color? dark})? seed) {
    // TV sürümünde (veya auto + TV cihaz) tüm ekranlarda D-pad odak halkası.
    final tvFocus = TvUi.enabledFor(settings);
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      theme: AppTheme.light(
        dynamicSeed: seed?.light,
        appearance: settings.appearance,
        tvFocus: tvFocus,
      ),
      darkTheme: AppTheme.dark(
        dynamicSeed: seed?.dark,
        appearance: settings.appearance,
        tvFocus: tvFocus,
      ),
      themeMode: settings.themeMode,
      locale: const Locale('tr'),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      onGenerateRoute: _onGenerateRoute,
      navigatorObservers: [_popRefresh],
      initialRoute: '/',
      // "Büyük & Okunaklı" görünüm yazıları büyütür. Bu sürümde fontSize'lar
      // ThemeData'da taşınmadığı için büyüme, sistem ölçeği **korunarak**
      // (erişilebilirlik ayarı ezilmez) yalnızca katsayıyla çarpılan
      // `textScaler` üzerinden uygulanır.
      // Uygulama kilidi açıkken tüm rotaların üstüne kilit ekranı gelir.
      builder: (context, child) {
        Widget content = child ?? const SizedBox.shrink();
        final factor = settings.appearance.fontSizeFactor;
        if (factor != 1.0) {
          final media = MediaQuery.of(context);
          content = MediaQuery(
            data: media.copyWith(
              textScaler:
                  TextScaler.linear(media.textScaler.scale(1.0) * factor),
            ),
            child: content,
          );
        }
        if (!_lockChecked) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (_showLock) {
          return AppLockScreen(
            onUnlocked: () {
              if (!mounted) return;
              setState(() => _showLock = false);
              // Kilit sırasında ertelenen sistem paylaşımını aç.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                unawaited(_openPendingShare());
              });
            },
          );
        }
        return content;
      },
    );
  }
}

/// Rota geri alındığında (ana ekrana dönüş dâhil) kategori boyutlarını tazeler.
///
/// **Neden gerekli:** ana ekranın `build`'i üstüne ekran açılıp kapanınca
/// yeniden çalışmaz; `initState` ise oturumda yalnız bir kez koşar. Eskiden
/// bu yüzden dosya işlemleri / temizleme sonrası kartlar uygulama
/// kapatılıp açılana kadar bayat değer gösterirdi.
class _PopRefreshObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // İndirilenler / Yeni Dosyalar gibi ekranlardan dönüşte kartlar
    // önbellek "taze" diye bayat kalmasın — zorunlu yenile.
    unawaited(CategorySizeService.refresh(force: true));
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    unawaited(CategorySizeService.refresh(force: true));
  }
}

/// Uygulama ön plana döndüğünde kategori boyutlarını tazeler.
///
/// İndirme gibi **başka uygulamalarca** yapılan değişiklikler invalidate
/// edilemez; kartların tazeliği ancak uygulamaya geri dönülürken
/// ([CategorySizeService.refreshOnResume]) sağlanır.
class _ResumeRefreshObserver with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(CategorySizeService.refreshOnResume());
    }
  }
}

/// Kategori için kök yolu hazırlayıp tarayıcıyı açar (desteklenmiyorsa uyarı).
class _BrowseLauncher extends StatelessWidget {
  const _BrowseLauncher({required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context) {
    final category = kHomeCategories.where((c) => c.id == categoryId).firstOrNull;
    // Medya kategorileri (Görüntüler/Videolar/Ses) mobilde MediaStore ile
    // taranır; diğer platformlarda klasik dosya tarayıcısı kullanılır.
    if (MediaService.supported &&
        const {'images', 'videos', 'audio'}.contains(categoryId)) {
      return MediaCategoryScreen(
        categoryId: categoryId,
        title: category?.title ?? 'Medya',
      );
    }
    return FutureBuilder<String?>(
      future: AppPaths.byCategory(categoryId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return BrowserScreen(
          title: category?.title ?? 'Dosyalar',
          rootPath: snapshot.data,
          // Kategori kökleri (Ana bellek, İndirilenler, ...) referans
          // uygulamadaki gibi hamburger menü + üst satır ile açılır.
          showRootDrawer: true,
        );
      },
    );
  }
}

/// Ana ekran seçici: TV modu ayarı + cihaz algılama (A11).
class _HomeLauncher extends StatelessWidget {
  const _HomeLauncher();

  /// TV algılama sonucu uygulama yaşamı boyunca bir kez çözülür.
  static Future<bool>? _isTv;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    // İlk açılış: sürüm seçimi yapılmadıysa seçim ekranı (A18).
    if (!settings.deviceModeChosen) {
      return const DeviceModeScreen();
    }
    // Sürüm seçiminden sonra gerekli cihaz izinleri istenir (A18).
    if (!settings.permissionsOnboarded) {
      return const PermissionsScreen();
    }
    switch (settings.tvMode) {
      case 'tv':
        return const TvHomeScreen();
      case 'phone':
        return const HomeScreen();
      default:
        _isTv ??= PlatformService.isTv();
        return FutureBuilder<bool>(
          future: _isTv,
          builder: (context, snapshot) => (snapshot.data ?? false)
              ? const TvHomeScreen()
              : const HomeScreen(),
        );
    }
  }
}

/// Basit isimli rota yönlendiricisi.
Route<dynamic> _onGenerateRoute(RouteSettings settings) {
  final name = settings.name ?? '/';

  Widget screen;
  switch (name) {
    case '/':
      screen = const _HomeLauncher();
    case '/settings':
      screen = const SettingsScreen();
    case '/search':
      // Cihaz geneli arama (dosya + medya + uygulama).
      screen = const GlobalSearchScreen();
    case '/analysis':
      screen = const StorageAnalysisScreen();
    case '/apps':
      screen = const AppsScreen();
    case '/apps/system':
      // Dahili (cihazla gelen) uygulamalar sekmesi doğrudan açılır.
      screen = const AppsScreen(initialIndex: 2);
    case '/temp':
      screen = const TempCleanerScreen();
    case '/clean':
      screen = const CleanCenterScreen();
    case '/privacy':
      screen = const PrivacyScreen();
    case '/cloud':
      screen = const CloudScreen();
    case '/remote':
      screen = const RemoteScreen();
    case '/network':
      screen = const NetworkAccessScreen();
    case '/recent':
      // Son 7 günde değişen dosyalar (Yeni Dosyalar kategorisi).
      screen = const RecentFilesScreen();
    case '/recycle':
      screen = const RecycleBinScreen();
    case '/usb':
      // Bağlı USB / SD kart birimleri (OTG algılama).
      screen = const UsbStorageScreen();
    case '/vault':
      // PIN ile korunan şifreli kasa.
      screen = const VaultScreen();
    case '/duplicates':
      // Mükerrer dosya taraması (Geçici Dosyalar ekranından).
      screen = DuplicateFilesScreen(root: AppPaths.scanRoot);
    default:
      // /browse/internal, /browse/images, ... kategori tarayıcıları (A2/A3).
      if (name.startsWith('/browse/')) {
        final id = name.substring('/browse/'.length);
        screen = _BrowseLauncher(categoryId: id);
      } else {
        screen = const Scaffold(
          body: Center(child: Text('Ekran bulunamadı')),
        );
      }
  }
  return MaterialPageRoute(builder: (_) => screen, settings: settings);
}
