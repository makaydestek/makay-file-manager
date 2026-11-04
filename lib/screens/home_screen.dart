import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/home_category.dart';
import '../providers/settings_provider.dart';
import '../services/bookmark_service.dart';
import '../services/category_size_service.dart';
import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_drawer.dart';
import 'browser_screen.dart';
import 'home_categories_screen.dart';

/// Uygulama ana ekranı: referans uygulamadaki kategori ızgarası.
///
/// Her kategori başlığının altında içeriğin toplam boyutu (veya kayıt
/// sayısı) gösterilir; değerler arka planda hesaplanır ve önbelleklenir.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    // Kategori boyutları arka planda hesaplanır; önbellek varsa anında görünür.
    CategorySizeService.refresh();
    BookmarkStore.load();
    // Ana ekran klasör kısayolundan gelen yol.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openLaunchPath());
  }

  Future<void> _openLaunchPath() async {
    final path = await PlatformService.takeLaunchBrowsePath();
    if (!mounted || path == null || path.isEmpty) return;
    final parts =
        path.split(RegExp(r'[/\\]')).where((p) => p.isNotEmpty).toList();
    final name = parts.isEmpty ? path : parts.last;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrowserScreen(title: name, rootPath: path),
      ),
    );
  }

  Future<void> _refresh({bool force = false}) =>
      CategorySizeService.refresh(force: force);

  /// Seçili görünüm düzenine göre sütun sayısı.
  ///
  /// `auto` modu cihaz genişliğine göre davranır; diğerleri kullanıcının
  /// seçtiği dikey/yatay sütun sayılarını uygular.
  static int _columnsFor(String viewStyle, BoxConstraints constraints) {
    if (viewStyle != 'auto') {
      final portrait = constraints.maxHeight >= constraints.maxWidth;
      return switch (viewStyle) {
        'large' => portrait ? 2 : 3,
        'medium' => portrait ? 3 : 4,
        'small' => portrait ? 4 : 6,
        _ => 3,
      };
    }
    // Otomatik: geniş telefon → 3, tablet → 4, çok geniş → 5 sütun.
    return switch (constraints.maxWidth) {
      > 1000 => 5,
      > 600 => 4,
      _ => 3,
    };
  }

  @override
  Widget build(BuildContext context) {
    // Tazelik artık build yaşam döngüsüne bağlı DEĞİLDİR: rota geri
    // alındığında ve uygulama ön plana döndüğünde `main.dart` içindeki
    // gözlemciler yenileme tetikler; dosya işlemleri `invalidate`
    // aracılığıyla kendiliğinden yeniden hesaplatır. Bu çağrı yalnız
    // ilk çerçeve ve döndürme gibi durumlar için güvenlik ağıdır; önbellek
    // tazeyse yalnızca prefs okur ve hemen döner.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) CategorySizeService.refresh();
    });
    // Ayar değiştiğinde ızgara anında yeniden kurulur (watch → rebuild).
    final settings = context.watch<SettingsProvider>();
    final viewStyle = settings.viewStyle;
    // Kullanıcının gizlediği kartlar ızgaraya hiç girmez.
    final categories = kHomeCategories
        .where((c) => settings.isCategoryVisible(c.id))
        .toList(growable: false);
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Makay Dosya Yöneticisi'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search_rounded),
            tooltip: 'Ara',
            // Cihaz geneli arama: dosya + medya + uygulama.
            onPressed: () => Navigator.of(context).pushNamed('/search'),
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'settings':
                  Navigator.of(context).pushNamed('/settings');
                case 'home_categories':
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const HomeCategoriesScreen(),
                    ),
                  );
                case 'analysis':
                  Navigator.of(context).pushNamed('/analysis');
                case 'refresh':
                  _refresh(force: true);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Boyutlar yenileniyor…')),
                  );
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: 'home_categories', child: Text('Kartları göster / gizle')),
              PopupMenuItem(value: 'settings', child: Text('Ayarlar')),
              PopupMenuItem(value: 'analysis', child: Text('Analiz et')),
              PopupMenuItem(value: 'refresh', child: Text('Yenile')),
            ],
          ),
        ],
      ),
      // Görünüm preset'i ana ekranda gradyan zemin çizebilir (bkz.
      // AppAppearance.backgroundGradient); preset düz zemin seçtiyse
      // gradient null olur ve hiçbir şey değişmez.
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient(
            settings.appearance,
            Theme.of(context).brightness,
          ),
        ),
        child: categories.isEmpty
            ? _AllHidden(onOpen: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const HomeCategoriesScreen(),
                  ),
                ))
            : LayoutBuilder(
              builder: (context, constraints) {
                final columns = _columnsFor(viewStyle, constraints);
                return RefreshIndicator(
                  onRefresh: () => _refresh(force: true),
                  child: CustomScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      ValueListenableBuilder<List<Bookmark>>(
                        valueListenable: BookmarkStore.list,
                        builder: (context, bookmarks, _) {
                          if (bookmarks.isEmpty) {
                            return const SliverToBoxAdapter(
                                child: SizedBox.shrink());
                          }
                          return SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Yer imleri',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleSmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: Theme.of(context)
                                              .colorScheme
                                              .primary,
                                        ),
                                  ),
                                  const SizedBox(height: 8),
                                  SizedBox(
                                    height: 40,
                                    child: ReorderableListView.builder(
                                      scrollDirection: Axis.horizontal,
                                      buildDefaultDragHandles: false,
                                      onReorderItem: BookmarkStore.reorder,
                                      itemCount: bookmarks.length,
                                      itemBuilder: (context, index) {
                                        final b = bookmarks[index];
                                        return Padding(
                                          key: ValueKey(b.path),
                                          padding:
                                              const EdgeInsets.only(right: 8),
                                          child: ReorderableDelayedDragStartListener(
                                            index: index,
                                            child: ActionChip(
                                              avatar: const Icon(
                                                  Icons.bookmark_rounded,
                                                  size: 18),
                                              label: Text(b.name),
                                              onPressed: () {
                                                Navigator.of(context).push(
                                                  MaterialPageRoute(
                                                    builder: (_) =>
                                                        BrowserScreen(
                                                      title: b.name,
                                                      rootPath: b.path,
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                      ValueListenableBuilder<Map<String, String>>(
                        valueListenable: CategorySizeService.labels,
                        builder: (context, sizes, _) => SliverPadding(
                          padding: const EdgeInsets.all(12),
                          sliver: SliverGrid(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: columns,
                              mainAxisSpacing: 8,
                              crossAxisSpacing: 8,
                              childAspectRatio: 0.88,
                            ),
                            delegate: SliverChildBuilderDelegate(
                              (context, index) => _CategoryTile(
                                category: categories[index],
                                label: sizes[categories[index].id],
                              ),
                              childCount: categories.length,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
      ),
    );
  }
}

/// Tüm kartlar gizlendiğinde gösterilen bilgi ekranı.
class _AllHidden extends StatelessWidget {
  const _AllHidden({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.visibility_off_rounded,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              'Tüm kartlar gizlendi',
              style: theme.textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 6),
            Text(
              'Göstermek istediğiniz kartları seçin.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onOpen,
              icon: const Icon(Icons.tune_rounded),
              label: const Text('Kartları göster / gizle'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CategoryTile extends StatelessWidget {
  const _CategoryTile({required this.category, this.label});

  final HomeCategory category;

  /// Başlık altındaki özet metin (ör. "1,5 GB"); null ise gösterilmez.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final labelStyle = Theme.of(context).textTheme.labelSmall?.copyWith(
          height: 1.1,
          color: Theme.of(context).colorScheme.outline,
        );
    // Yüklenirken ana bellek için yer tutucu metin.
    final fallback = category.id == 'internal' ? 'Depolama alanı' : null;
    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          final route = category.route;
          if (route != null) {
            Navigator.of(context).pushNamed(route);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(6),
          // Kart içeriği taşmasın: sığmazsa hafifçe küçülür.
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(11),
                  decoration: BoxDecoration(
                    color: category.color.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(category.icon, size: 28, color: category.color),
                ),
                const SizedBox(height: 8),
                Text(
                  category.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        height: 1.15,
                        color: isDark ? Colors.white : Colors.black87,
                      ),
                ),
                if (label != null || fallback != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    label ?? fallback!,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: labelStyle,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
