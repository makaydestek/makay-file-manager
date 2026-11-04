import 'dart:io';

import 'package:flutter/material.dart';

import '../services/heavy_scan.dart';
import '../services/platform_service.dart';
import '../utils/formats.dart';
import '../widgets/apk_install_dialog.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_icon.dart';
import '../widgets/tv_focusable.dart';

/// Uygulamalar ekranı: Tümü / İndirilenler (APK'lar) / Dahili (sistem).
///
/// **"TÜMÜ" her zaman en önde ve varsayılan sekmedir** — ekran hangi
/// yoldan (ana ekran kartı, çekmece, `/apps/system`) açılırsa açılsın
/// ilk görülen sekme budur.
class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key, this.initialIndex = 0});

  /// Açılışta gösterilecek sekme (0: tümü, 1: indirilenler, 2: dahili).
  final int initialIndex;

  @override
  State<AppsScreen> createState() => _AppsScreenState();
}

class _AppsScreenState extends State<AppsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final TabController _tabController;

  List<InstalledApp> _apps = [];
  List<File> _apkFiles = [];
  bool _loading = true;
  bool _sortDesc = true;
  bool _showSystemApps = true;

  /// StorageStats izni yoksa boyutlar yalnız base.apk kadar görünür;
  /// kullanıcı Ayarlar → Kullanım erişimi ile tam boyutları alır.
  bool _usageAccess = true;

  @override
  void initState() {
    super.initState();
    final initial =
        widget.initialIndex < 0 ? 0 : (widget.initialIndex > 2 ? 2 : widget.initialIndex);
    _tabController = TabController(length: 3, vsync: this, initialIndex: initial);
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  /// Ayarlar → Kullanım erişimi'nden dönülünce boyutlar tazelensin.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !_loading) _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // `installedApps` hata/desteklenmeyen durumda `const []` döndürür;
    // sabit liste `sort` ile değiştirilemediği için MUTLAKA kopyalanır.
    final apps = List<InstalledApp>.of(await PlatformService.installedApps());
    final apks = await _downloadedApks();
    final usage = await PlatformService.hasUsageAccess();
    apps.sort((a, b) =>
        _sortDesc ? b.size.compareTo(a.size) : a.size.compareTo(b.size));
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _apkFiles = apks;
      _usageAccess = usage;
      _loading = false;
    });
  }

  /// Download klasöründeki APK dosyaları ("İndirilenler" sekmesi).
  Future<List<File>> _downloadedApks() async {
    if (!Platform.isAndroid) return const [];
    try {
      final paths = await HeavyScan.downloadApkPaths();
      return [for (final p in paths) File(p)];
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Uygulamalar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            onPressed: () => showSearch(
              context: context,
              delegate: _AppSearchDelegate(_apps),
            ),
          ),
          IconButton(
            icon: Icon(_showSystemApps
                ? Icons.visibility_rounded
                : Icons.visibility_off_rounded),
            onPressed: () =>
                setState(() => _showSystemApps = !_showSystemApps),
            tooltip: _showSystemApps
                ? 'Sistem uygulamalarını gizle'
                : 'Sistem uygulamalarını göster',
          ),
          IconButton(
            icon: const Icon(Icons.sort_rounded),
            onPressed: () {
              setState(() {
                _sortDesc = !_sortDesc;
                _apps.sort((a, b) => _sortDesc
                    ? b.size.compareTo(a.size)
                    : a.size.compareTo(b.size));
              });
            },
            tooltip: 'Boyuta göre sırala',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          // "TÜMÜ" her zaman en başta ve varsayılan sekmedir.
          tabs: const [
            Tab(text: 'TÜMÜ'),
            Tab(text: 'İNDİRİLENLER'),
            Tab(text: 'DAHİLİ'),
          ],
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (!_usageAccess) _usageAccessBanner(),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _appsList(_apps, 'Yüklü uygulama bulunamadı'),
                      _downloadsTab(),
                      _appsList(
                        _apps.where((a) => a.isSystem).toList(growable: false),
                        'Cihazla gelen uygulama bulunamadı',
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// Boyutlar yalnız base.apk kadar görünüyor: tam boyut (uygulama +
  /// veri) için Ayarlar → Kullanım erişimi izni gerekir.
  ///
  /// Bazı cihazlarda (MIUI vb.) ayar doğrudan açılmaz ya da "erişim
  /// reddedildi" diyaloğu çıkar; bu yüzden tek tuş yerine adım adım rehber
  /// gösterilir: hem Kullanım erişimi listesi hem de (Android 13+
  /// kısıtlı ayarlar için) Uygulama bilgisi sayfası açılır.
  Widget _usageAccessBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.info_outline_rounded, color: scheme.primary),
        title: const Text('Uygulama boyutları eksik görünüyor'),
        subtitle: const Text(
            'Tam boyut için izin vermek adına dokunun.'),
        trailing: const Icon(Icons.chevron_right_rounded),
        onTap: _onUsageBannerTap,
      ),
    );
  }

  /// Banner'a dokununca önce izin durumu doğrulanır: izin zaten verilmişse
  /// rehber yerine liste yenilenip kullanıcıya onay verilir; izin yoksa
  /// adım adım rehber açılır.
  Future<void> _onUsageBannerTap() async {
    final messenger = ScaffoldMessenger.of(context);
    final granted = await PlatformService.hasUsageAccess();
    if (!mounted) return;
    if (granted) {
      setState(() => _usageAccess = true);
      messenger.showSnackBar(const SnackBar(
        content: Text('Kullanım erişimi verildi — boyutlar yenileniyor.'),
      ));
      _load();
      return;
    }
    _showUsageGuide();
  }

  /// Kullanım erişimi izni için adım adım rehber.
  ///
  /// Sideload + Android 13+: anahtar "Kısıtlanmış ayar tarafından
  /// kontrol ediliyor" diye gri kalır. Önce Uygulama bilgisi → ⋮ →
  /// "Kısıtlı ayarlara izin ver" şarttır; sonra kullanım erişimi açılır.
  /// Play Store dışı kurulumlarda bu sistem kısıtı uygulamadan kaldırılamaz.
  void _showUsageGuide() {
    // pop sonrası geri bildirim için messenger'ı önceden al.
    final messenger = ScaffoldMessenger.of(context);
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kullanım erişimi izni'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Tam boyut (uygulama + veri) için kullanım erişimi gerekir. '
                'Anahtar gri / "kısıtlanmış ayar" yazıyorsa önce Adım 1 '
                'zorunludur — aksi halde anahtar açılmaz.',
              ),
              SizedBox(height: 12),
              Text(
                'Adım 1 — Kısıtlı ayarlara izin ver',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '• "Uygulama bilgisini aç" deyin\n'
                '• Sağ üst ⋮ menüsünden "Kısıtlı ayarlara izin ver"\n'
                '• İstenirse kilit / biyometri ile onaylayın\n'
                '• Menü yoksa (bazı MIUI): İzinler → Kullanım erişimi',
              ),
              SizedBox(height: 12),
              Text(
                'Adım 2 — Kullanım erişimini aç',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(
                '• "Kullanım erişimi" deyin\n'
                '• "Uygulama kullanım verilerine erişim izin ver" anahtarını açın\n'
                '• Uygulamaya dönün — boyutlar yenilenir',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          // Birincil CTA: kısıtlı ayar kilidini kaldırmak (Android 13+).
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              final ok = await PlatformService.openAppSettings();
              if (!ok) {
                messenger.showSnackBar(const SnackBar(
                  content: Text(
                      'Sayfa açılamadı — Ayarlar → Uygulamalar → Makay '
                      'Dosya Yöneticisi yolunu elle izleyin.'),
                ));
              } else {
                messenger.showSnackBar(const SnackBar(
                  content: Text(
                      '⋮ menüsünden "Kısıtlı ayarlara izin ver" deyin, '
                      'sonra tekrar "Kullanım erişimi"ne dönün.'),
                  duration: Duration(seconds: 6),
                ));
              }
            },
            child: const Text('1. Uygulama bilgisini aç'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final ok = await PlatformService.openUsageAccessSettings();
              if (!ok) {
                messenger.showSnackBar(const SnackBar(
                  content: Text(
                      'Kullanım erişimi sayfası açılamadı — Ayarlar → '
                      'Uygulamalar → Kullanım erişimi yolunu elle izleyin.'),
                ));
              }
            },
            child: const Text('2. Kullanım erişimi'),
          ),
        ],
      ),
    );
  }

  /// İndirilenler: Download klasöründeki APK'lar.
  Widget _downloadsTab() {
    if (_apkFiles.isEmpty) {
      return const Center(child: Text('İndirilmiş APK bulunamadı'));
    }
    return ListView.builder(
      itemCount: _apkFiles.length,
      itemBuilder: (context, index) {
        final file = _apkFiles[index];
        final name = file.uri.pathSegments.isEmpty
            ? file.path.split(Platform.pathSeparator).last
            : file.uri.pathSegments[file.uri.pathSegments.length - 1];
        final size = file.lengthSync();
        return TvFocusable(
          autofocus: index == 0,
          onActivate: () => showApkInstallDialog(context, file),
          scale: 1.02,
          child: ListTile(
            leading:
                const Icon(Icons.android_rounded, color: Color(0xFF43A047)),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(Formats.size(size)),
            // APK'ya dokununca bilgi yerine Kur/Güncelle ekranı açılır.
            onTap: () => showApkInstallDialog(context, file),
          ),
        );
      },
    );
  }

  /// Yüklenmiş uygulama listesi (TÜMÜ ve DAHİLİ sekmeleri paylaşır).
  Widget _appsList(List<InstalledApp> apps, String emptyMessage) {
    // _showSystemApps false olduğunda system uygulamalarını gizle.
    final visibleApps = _showSystemApps
        ? apps
        : apps.where((a) => !a.isSystem).toList(growable: false);

    if (visibleApps.isEmpty) {
      return Center(
        child: Text(emptyMessage),
      );
    }
    return ListView.builder(
      itemCount: visibleApps.length,
      itemBuilder: (context, index) {
        final app = visibleApps[index];
        return TvFocusable(
          autofocus: index == 0,
          onActivate: () => _appActions(app),
          scale: 1.02,
          child: ListTile(
            leading: AppIcon(app),
            title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(app.packageName),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  app.size > 0 ? Formats.size(app.size) : '—',
                  style:
                      TextStyle(color: Theme.of(context).colorScheme.primary),
                ),
                if (app.versionName.isNotEmpty)
                  Text(app.versionName,
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
            onTap: () => _appActions(app),
          ),
        );
      },
    );
  }

  /// Uygulama işlemleri: APK yedekleme + sistem ayarları.
  Future<void> _appActions(InstalledApp app) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: AppIcon(app, size: 32),
              title: Text(app.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${app.packageName} • ${app.versionName}'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.save_alt_rounded),
              title: const Text('APK\'yı yedekle'),
              subtitle: const Text('Kurulum APK\'sını Download klasörüne kopyalar'),
              enabled: app.sourceDir.isNotEmpty,
              onTap: () => Navigator.pop(context, 'backup'),
            ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title: const Text('Uygulama bilgisi'),
              onTap: () => Navigator.pop(context, 'info'),
            ),
          ],
        ),
      ),
    );
    if (action == 'backup') _backupApk(app);
    if (action == 'info') _showAppInfo(app);
  }

  /// Kurulum APK'sı `Download/<ad>-<sürüm>.apk` olarak kopyalanır.
  Future<void> _backupApk(InstalledApp app) async {
    if (app.sourceDir.isEmpty) return;
    setState(() => _loading = true);
    try {
      final source = File(app.sourceDir);
      if (!await source.exists()) throw 'APK kaynağı bulunamadı';
      final dir = Directory('/storage/emulated/0/Download');
      await dir.create(recursive: true);
      final safeName = app.name.replaceAll(RegExp(r'[^\p{L}\p{N} ._-]', unicode: true), '_');
      final dest =
          '${dir.path}${Platform.pathSeparator}$safeName-${app.versionName}.apk';
      await source.copy(dest);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedeklendi: $dest')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yedeklenemedi: $e')),
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showAppInfo(InstalledApp app) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(app.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Paket: ${app.packageName}'),
            Text('Sürüm: ${app.versionName}'),
            Text('Tür: ${app.isSystem ? 'Dahili (sistem)' : 'Yüklü'}'),
            Text('Boyut: ${app.size > 0 ? Formats.size(app.size) : 'Bilinmiyor'}'),
            const SizedBox(height: 8),
            SelectableText('APK: ${app.sourceDir}'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }
}

class _AppSearchDelegate extends SearchDelegate<String> {
  _AppSearchDelegate(this.apps);

  final List<InstalledApp> apps;

  @override
  List<Widget>? buildActions(BuildContext context) => [
        IconButton(
          icon: const Icon(Icons.clear),
          onPressed: () => query = '',
        ),
      ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
        icon: const Icon(Icons.arrow_back),
        onPressed: () => close(context, ''),
      );

  @override
  Widget buildResults(BuildContext context) => _buildList();

  @override
  Widget buildSuggestions(BuildContext context) => _buildList();

  Widget _buildList() {
    final q = query.toLowerCase();
    final results = apps
        .where((a) =>
            a.name.toLowerCase().contains(q) ||
            a.packageName.toLowerCase().contains(q))
        .toList();
    return ListView.builder(
      itemCount: results.length,
      itemBuilder: (context, index) {
        final app = results[index];
        return ListTile(
          leading: AppIcon(app),
          title: Text(app.name),
          subtitle: Text(app.packageName),
          trailing: Text(app.size > 0 ? Formats.size(app.size) : '—'),
        );
      },
    );
  }
}
