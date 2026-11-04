import 'package:flutter/material.dart';

import '../models/file_entry.dart';
import '../services/analysis_service.dart';
import '../services/platform_service.dart';
import '../utils/formats.dart';
import '../utils/text_utils.dart';
import '../widgets/app_drawer.dart';
import '../widgets/app_icon.dart';
import '../widgets/pie_chart.dart';
import 'apps_screen.dart';
import 'large_files_screen.dart';

/// Bellek Analizi ekranı — referans uygulamanın analiz ekranının karşılığı.
class StorageAnalysisScreen extends StatefulWidget {
  const StorageAnalysisScreen({super.key});

  @override
  State<StorageAnalysisScreen> createState() => _StorageAnalysisScreenState();
}

class _StorageAnalysisScreenState extends State<StorageAnalysisScreen> {
  static const _analysis = AnalysisService();

  /// Çekmeceyi (hamburger menü) açmak için.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Referans analiz ekranındaki kategori sırası (2'li satırlar hâlinde:
  /// Görüntüler|Ses, Videolar|Belgeler, Arşivler|Diğerleri).
  static const List<String> _kBreakdownOrder = [
    'Resimler',
    'Ses',
    'Videolar',
    'Belgeler',
    'Arşivler',
    'Diğerleri',
  ];

  /// Kategori adı gösterimi: referans ekranda "Resimler" → "Görüntüler".
  static String _label(String key) => key == 'Resimler' ? 'Görüntüler' : key;

  /// "Büyük dosyalar" başlığındaki toplamın hesaplandığı üst sınır.
  ///
  /// Tarama tüm diski özyinelemeli gezer; sınırsız yapılsaydı ekran
  /// dakikalarca açılmayı beklerdi. Bu yüzden başlıktaki rakam yalnızca
  /// [kLargeSample] dosyalık örneğin toplamıdır ve alt başlıkta böyle
  /// belirtilir — eskiden sınırsız bir "gerçek toplam" izlenimi veriyordu.
  static const int kLargeSample = 2000;

  ({int total, int free})? _storage;
  Map<String, int> _breakdown = {};
  List<InstalledApp> _topApps = [];
  int _appsTotalSize = 0;
  List<FileEntry> _largeFiles = [];
  int _largeTotal = 0;
  int _cache = 0;

  /// İlk kartlar (depolama) gelene kadar tam spinner; sonra kartlar
  /// progressive dolar (büyük dosya / önbellek arka planda).
  bool _bootLoading = true;
  bool _breakdownLoading = true;
  bool _appsLoading = true;
  bool _largeLoading = true;
  bool _cacheLoading = true;

  /// Kısa ömürlü bellek önbelleği: aynı oturumda sayfa yeniden açılınca
  /// anında gösterilir, arka planda yenilenir.
  static DateTime? _cacheAt;
  static ({int total, int free})? _cachedStorage;
  static Map<String, int>? _cachedBreakdown;
  static List<InstalledApp>? _cachedTopApps;
  static int? _cachedAppsTotal;
  static List<FileEntry>? _cachedLarge;
  static int? _cachedLargeTotal;
  static int? _cachedCacheBytes;
  static const _cacheTtl = Duration(minutes: 3);

  @override
  void initState() {
    super.initState();
    _hydrateFromCache();
    _load();
  }

  void _hydrateFromCache() {
    final at = _cacheAt;
    if (at == null || DateTime.now().difference(at) > _cacheTtl) return;
    _storage = _cachedStorage;
    _breakdown = _cachedBreakdown ?? {};
    _topApps = _cachedTopApps ?? const [];
    _appsTotalSize = _cachedAppsTotal ?? 0;
    _largeFiles = _cachedLarge ?? const [];
    _largeTotal = _cachedLargeTotal ?? 0;
    _cache = _cachedCacheBytes ?? 0;
    _bootLoading = _storage == null;
    _breakdownLoading = _cachedBreakdown == null;
    _appsLoading = _cachedTopApps == null;
    _largeLoading = _cachedLarge == null;
    _cacheLoading = _cachedCacheBytes == null;
  }

  Future<void> _load({bool force = false}) async {
    if (force) {
      _cacheAt = null;
      if (mounted) {
        setState(() {
          _bootLoading = true;
          _breakdownLoading = true;
          _appsLoading = true;
          _largeLoading = true;
          _cacheLoading = true;
        });
      }
    }

    // 1) Depolama bilgisi — en hızlı; ekranı hemen açar.
    final storage = await PlatformService.storageInfo();
    if (!mounted) return;
    setState(() {
      _storage = storage;
      _bootLoading = false;
    });

    // 2) Kırılım + uygulamalar paralel (birbirine bağımlı değil).
    final breakdownFuture = _analysis.categoryBreakdown();
    final appsFuture = PlatformService.installedApps();

    // Büyük dosya / önbellek daha ağır — ayrı arka plan görevleri.
    final largeFuture = _analysis.largeFiles(limit: kLargeSample);
    final cacheFuture = _analysis.cacheSize();

    await Future.wait([
      breakdownFuture.then((breakdown) {
        if (!mounted) return;
        setState(() {
          _breakdown = breakdown;
          _breakdownLoading = false;
        });
      }),
      appsFuture.then((apps) {
        apps.sort((a, b) => b.size.compareTo(a.size));
        if (!mounted) return;
        setState(() {
          _topApps = apps.take(2).toList();
          _appsTotalSize =
              apps.fold(0, (s, a) => s + (a.size > 0 ? a.size : 0));
          _appsLoading = false;
        });
      }),
      largeFuture.then((large) {
        if (!mounted) return;
        setState(() {
          _largeFiles = large.take(2).toList();
          _largeTotal = large.fold(0, (s, f) => s + f.size);
          _largeLoading = false;
        });
      }),
      cacheFuture.then((cache) {
        if (!mounted) return;
        setState(() {
          _cache = cache;
          _cacheLoading = false;
        });
      }),
    ]);

    if (!mounted) return;
    _cacheAt = DateTime.now();
    _cachedStorage = _storage;
    _cachedBreakdown = Map.of(_breakdown);
    _cachedTopApps = List.of(_topApps);
    _cachedAppsTotal = _appsTotalSize;
    _cachedLarge = List.of(_largeFiles);
    _cachedLargeTotal = _largeTotal;
    _cachedCacheBytes = _cache;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: _scaffoldKey,
      // Referans ekrandaki gibi çekmece (hamburger) menüsü.
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded),
          tooltip: 'Menü',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: const Text('Bellek Analizi'),
        actions: [
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'refresh':
                  _load(force: true);
                case 'settings':
                  Navigator.of(context).pushNamed('/settings');
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'refresh', child: Text('Yenile')),
              PopupMenuItem(value: 'settings', child: Text('Ayarlar')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _load(force: true),
        child: _bootLoading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  _storageCard(theme),
                  const SizedBox(height: 12),
                  _appsCard(theme),
                  const SizedBox(height: 12),
                  _largeFilesCard(theme),
                  const SizedBox(height: 12),
                  _cacheCard(theme),
                  const SizedBox(height: 24),
                ],
              ),
      ),
    );
  }

  /// Kart 1: Ana bellek — kullanım yüzdesi + kategori dağılımı.
  Widget _storageCard(ThemeData theme) {
    final total = _storage?.total ?? 0;
    final free = _storage?.free ?? 0;
    final usedPercent = total > 0 ? ((total - free) / total * 100) : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Ana bellek', style: theme.textTheme.titleLarge),
                Text(
                  'Boş ${Formats.size(free)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Center(
              child: Text(
                '${usedPercent.toStringAsFixed(0)}%',
                style: theme.textTheme.displaySmall
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: total > 0 ? usedPercent / 100 : 0,
                minHeight: 8,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 16),
            if (_breakdownLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              _pieSection(theme),
              const SizedBox(height: 12),
              _breakdownGrid(theme),
            ],
            const Divider(height: 24),
            _moreButton(context, 'DAHA FAZLA', () {
              Navigator.of(context).push(
                MaterialPageRoute(
                    builder: (_) => const LargeFilesScreen(
                        title: 'Depolama dağılımı', showBreakdown: true)),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Pasta grafik (CX tarzı renkli depolama özeti).
  Widget _pieSection(ThemeData theme) {
    const colors = <String, Color>{
      'Resimler': Color(0xFF8E24AA),
      'Videolar': Color(0xFFD32F2F),
      'Ses': Color(0xFF00897B),
      'Belgeler': Color(0xFF1976D2),
      'Arşivler': Color(0xFF6D4C41),
      'Diğerleri': Color(0xFF757575),
    };
    final slices = <PieSlice>[
      for (final k in _kBreakdownOrder)
        if ((_breakdown[k] ?? 0) > 0)
          PieSlice(
            label: _label(k),
            bytes: _breakdown[k]!,
            color: colors[k] ?? Colors.grey,
          ),
    ];
    if (slices.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Dağılım grafiği', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        CategoryPieChart(slices: slices),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () => Navigator.of(context).pushNamed('/clean'),
            icon: const Icon(Icons.cleaning_services_rounded, size: 18),
            label: const Text('Temizlik merkezi'),
          ),
        ),
      ],
    );
  }

  /// Kategori dağılımı: ikon + ad + boyut (2 sütun).
  Widget _breakdownGrid(ThemeData theme) {
    const icons = <String, (IconData, Color)>{
      'Resimler': (Icons.image_rounded, Color(0xFF8E24AA)),
      'Videolar': (Icons.video_library_rounded, Color(0xFFD32F2F)),
      'Ses': (Icons.music_note_rounded, Color(0xFF00897B)),
      'Belgeler': (Icons.description_rounded, Color(0xFF1976D2)),
      'Arşivler': (Icons.folder_zip_rounded, Color(0xFF6D4C41)),
      'Diğerleri': (Icons.more_horiz_rounded, Color(0xFF757575)),
    };
    // Referans ekrandaki sıra: Görüntüler|Ses, Videolar|Belgeler,
    // Arşivler|Diğerleri (bilinmeyen anahtarlar sona eklenir).
    final entries = [
      for (final k in _kBreakdownOrder)
        if (_breakdown.containsKey(k)) MapEntry(k, _breakdown[k]!),
      for (final e in _breakdown.entries)
        if (!_kBreakdownOrder.contains(e.key)) e,
    ];
    return Column(
      children: [
        for (var i = 0; i < entries.length; i += 2)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                for (var j = i; j < i + 2 && j < entries.length; j++) ...[
                  Expanded(
                    child: Builder(builder: (context) {
                      final e = entries[j];
                      final (icon, color) = icons[e.key] ??
                          (Icons.folder_rounded, Colors.grey);
                      return Row(
                        children: [
                          Icon(icon, color: color, size: 20),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(_label(e.key),
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium),
                          ),
                          Text(Formats.size(e.value),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  color: theme.colorScheme.outline)),
                        ],
                      );
                    }),
                  ),
                  if (j == i && j + 1 < entries.length)
                    const SizedBox(width: 16),
                ],
              ],
            ),
          ),
      ],
    );
  }

  /// Kart 2: Uygulamalar — toplam + en büyük iki uygulama.
  Widget _appsCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Uygulamalar', style: theme.textTheme.titleLarge),
                Text(
                  Formats.size(_appsTotalSize),
                  style: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_appsLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              for (final app in _topApps)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: AppIcon(app, size: 32),
                  title: Text(app.name),
                  trailing: Text(
                    app.size > 0 ? Formats.size(app.size) : '—',
                    style: TextStyle(color: theme.colorScheme.primary),
                  ),
                ),
            const Divider(height: 16),
            _moreButton(context, 'DAHA FAZLA', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AppsScreen()),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Kart 3: Büyük dosyalar — 10 MB üzeri.
  Widget _largeFilesCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Büyük dosyalar', style: theme.textTheme.titleLarge),
                _largeLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        Formats.size(_largeTotal),
                        style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold),
                      ),
              ],
            ),
            const SizedBox(height: 4),
            Text("10 MB'dan büyük dosyalar • en büyük "
                "$kLargeSample dosyanın toplamı",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 8),
            if (_largeLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: Center(child: CircularProgressIndicator()),
              )
            else
              for (final f in _largeFiles)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(f.icon, color: f.color),
                  title: Text(f.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(f.path
                      .replaceAll('/storage/emulated/0', '')
                      .ifEmpty('/')),
                  trailing: Text(Formats.size(f.size),
                      style: TextStyle(color: theme.colorScheme.primary)),
                ),
            const Divider(height: 16),
            _moreButton(context, 'DAHA FAZLA', () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LargeFilesScreen()),
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Kart 4: Önbellek dosyaları.
  Widget _cacheCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Ön bellek dosyaları',
                    style: theme.textTheme.titleLarge),
                _cacheLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        Formats.size(_cache),
                        style: theme.textTheme.titleMedium?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold),
                      ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Ön bellek dosyaları, uygulamalar tarafından depolanan '
              'geçici dosyalardır.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
      ),
    );
  }

  Widget _moreButton(BuildContext context, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        width: double.infinity,
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.primary,
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }
}
