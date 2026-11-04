import 'package:flutter/material.dart';

import '../screens/browser_screen.dart';
import '../services/bookmark_service.dart';
import '../services/category_size_service.dart';
import '../services/recycle_bin_service.dart';
import '../theme/app_theme.dart';
import '../utils/debug_log.dart';
import '../utils/formats.dart';

/// Referans uygulamadaki yan çekmece (drawer) menüsü.
class AppDrawer extends StatefulWidget {
  const AppDrawer({super.key});

  @override
  State<AppDrawer> createState() => _AppDrawerState();
}

class _AppDrawerState extends State<AppDrawer> {
  int _recycleSize = 0;

  @override
  void initState() {
    super.initState();
    _loadRecycle();
    BookmarkStore.load();
  }

  Future<void> _loadRecycle() async {
    try {
      await RecycleBinService.instance.load();
      final total = RecycleBinService.instance.totalSize;
      if (mounted) setState(() => _recycleSize = total);
    } catch (e) {
      logSwallowed('çekmece: geri dönüşüm boyutu', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _DrawerItem(
                    icon: Icons.home_rounded,
                    title: 'Ana Ekran',
                    onTap: () =>
                        Navigator.of(context).pushReplacementNamed('/'),
                  ),
                  _DrawerItem(
                    icon: Icons.search_rounded,
                    title: 'Ara',
                    // Cihaz geneli arama (dosya + medya + uygulama).
                    onTap: () =>
                        Navigator.of(context).pushNamed('/search'),
                  ),
                  // Ana bellek: kullanılan/toplam değerini arka planda gelir.
                  ValueListenableBuilder<Map<String, String>>(
                    valueListenable: CategorySizeService.labels,
                    builder: (context, sizes, _) => _DrawerItem(
                      icon: Icons.storage_rounded,
                      title: 'Ana bellek',
                      trailing: sizes['internal'] == null
                          ? null
                          : Text(sizes['internal']!),
                      onTap: () =>
                          Navigator.of(context).pushNamed('/browse/internal'),
                    ),
                  ),
                  const Divider(),
                  _DrawerItem(
                    icon: Icons.delete_sweep_rounded,
                    title: 'Geri Dönüşüm Kutusu',
                    trailing: Text(Formats.size(_recycleSize)),
                    onTap: () => Navigator.of(context).pushNamed('/recycle'),
                  ),
                  ValueListenableBuilder<List<Bookmark>>(
                    valueListenable: BookmarkStore.list,
                    builder: (context, bookmarks, _) {
                      if (bookmarks.isEmpty) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Divider(),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                            child: Text(
                              'Yer imleri',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    fontWeight: FontWeight.bold,
                                  ),
                            ),
                          ),
                          ReorderableListView.builder(
                            shrinkWrap: true,
                            physics: const NeverScrollableScrollPhysics(),
                            buildDefaultDragHandles: false,
                            itemCount: bookmarks.length,
                            onReorderItem: BookmarkStore.reorder,
                            itemBuilder: (context, index) {
                              final b = bookmarks[index];
                              return ListTile(
                                key: ValueKey(b.path),
                                leading: ReorderableDragStartListener(
                                  index: index,
                                  child: Icon(
                                    Icons.bookmark_rounded,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                title: Text(b.name),
                                trailing: IconButton(
                                  icon: const Icon(Icons.close_rounded, size: 18),
                                  tooltip: 'Kaldır',
                                  onPressed: () =>
                                      BookmarkStore.remove(b.path),
                                ),
                                onTap: () {
                                  Navigator.of(context).pop();
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => BrowserScreen(
                                        title: b.name,
                                        rootPath: b.path,
                                      ),
                                    ),
                                  );
                                },
                              );
                            },
                          ),
                        ],
                      );
                    },
                  ),
                  const Divider(),
                  _DrawerItem(
                    icon: Icons.schedule_rounded,
                    title: 'Yeni Dosyalar',
                    onTap: () => Navigator.of(context).pushNamed('/recent'),
                  ),
                  _DrawerItem(
                    icon: Icons.description_rounded,
                    title: 'Belgeler',
                    onTap: () =>
                        Navigator.of(context).pushNamed('/browse/documents'),
                  ),
                  _DrawerItem(
                    icon: Icons.video_library_rounded,
                    title: 'Videolar',
                    onTap: () => Navigator.of(context).pushNamed('/browse/videos'),
                  ),
                  _DrawerItem(
                    icon: Icons.music_note_rounded,
                    title: 'Ses',
                    onTap: () => Navigator.of(context).pushNamed('/browse/audio'),
                  ),
                  _DrawerItem(
                    icon: Icons.image_rounded,
                    title: 'Resimler',
                    onTap: () =>
                        Navigator.of(context).pushNamed('/browse/images'),
                  ),
                  _DrawerItem(
                    icon: Icons.folder_zip_rounded,
                    title: 'İndirilenler',
                    onTap: () =>
                        Navigator.of(context).pushNamed('/browse/downloads'),
                  ),
                  const Divider(),
                  // Ana ekran kartlarıyla aynı bölümler — tek listede.
                  _DrawerItem(
                    icon: Icons.pie_chart_rounded,
                    title: 'Bellek Analizi',
                    onTap: () => Navigator.of(context).pushNamed('/analysis'),
                  ),
                  _DrawerItem(
                    icon: Icons.apps_rounded,
                    title: 'Uygulamalar',
                    onTap: () => Navigator.of(context).pushNamed('/apps'),
                  ),
                  _DrawerItem(
                    icon: Icons.cleaning_services_rounded,
                    title: 'Temizlik merkezi',
                    onTap: () => Navigator.of(context).pushNamed('/clean'),
                  ),
                  _DrawerItem(
                    icon: Icons.lock_outline_rounded,
                    title: 'Kasa',
                    onTap: () => Navigator.of(context).pushNamed('/vault'),
                  ),
                  _DrawerItem(
                    icon: Icons.sd_card_rounded,
                    title: 'USB / SD Kart',
                    onTap: () => Navigator.of(context).pushNamed('/usb'),
                  ),
                  _DrawerItem(
                    icon: Icons.copy_all_rounded,
                    title: 'Mükerrer dosyalar',
                    onTap: () =>
                        Navigator.of(context).pushNamed('/duplicates'),
                  ),
                  _DrawerItem(
                    icon: Icons.privacy_tip_rounded,
                    title: 'Gizlilik',
                    onTap: () =>
                        Navigator.of(context).pushNamed('/privacy'),
                  ),
                  const Divider(),
                  _DrawerItem(
                    icon: Icons.desktop_windows_rounded,
                    title: 'Uzak',
                    onTap: () => Navigator.of(context).pushNamed('/remote'),
                  ),
                  _DrawerItem(
                    icon: Icons.devices_rounded,
                    title: 'Ağdan erişim',
                    onTap: () => Navigator.of(context).pushNamed('/network'),
                  ),
                  const Divider(),
                  _DrawerItem(
                    icon: Icons.settings_rounded,
                    title: 'Ayarlar',
                    onTap: () => Navigator.of(context).pushNamed('/settings'),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Alt bilgi: uygulama künyesi (reklamsız, tüm özellikler ücretsiz).
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Makay Dosya Yöneticisi\nReklamsız • Tüm özellikler ücretsiz',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppTheme.accent,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerItem extends StatelessWidget {
  const _DrawerItem({
    required this.icon,
    required this.title,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final Widget? trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Theme.of(context).colorScheme.primary),
      title: Text(title),
      trailing: trailing,
      onTap: onTap,
    );
  }
}
