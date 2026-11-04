import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/file_entry.dart';
import '../../providers/settings_provider.dart';
import '../../services/archive_service.dart';
import '../../services/bookmark_service.dart';
import '../../services/platform_service.dart';
import '../../utils/file_opener.dart';
import '../../widgets/apk_install_dialog.dart';
import '../hex_viewer_screen.dart';
import '../sqlite_viewer_screen.dart';
import '../text_editor_screen.dart';

/// Satır menüsü: bilgi, kopyala/taşı/sil, metin/hex/SQLite, kasaya taşıma.
void showBrowserRowMenu({
  required BuildContext hostContext,
  required FileEntry entry,
  required VoidCallback onInfo,
  required VoidCallback onOpenInNewTab,
  required void Function({required bool cut}) onCopyOrCut,
  required VoidCallback onDelete,
  required VoidCallback onOpenArchive,
  required VoidCallback onCompress,
  required VoidCallback onAddToVault,
  required VoidCallback onChmod,
}) {
  final e = entry;
  final ext =
      e.name.contains('.') ? e.name.split('.').last.toLowerCase() : '';
  final useBin = hostContext.read<SettingsProvider>().recycleBinDefault;
  showModalBottomSheet<void>(
    context: hostContext,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: const Text('Bilgi'),
            onTap: () {
              Navigator.pop(context);
              onInfo();
            },
          ),
          if (e.isDirectory)
            ListTile(
              leading: const Icon(Icons.tab_rounded),
              title: const Text('Yeni sekmede aç'),
              subtitle: const Text('Aynı anda birden fazla klasör'),
              onTap: () {
                Navigator.pop(context);
                onOpenInNewTab();
              },
            ),
          ListTile(
            leading: const Icon(Icons.copy_rounded),
            title: const Text('Kopyala'),
            subtitle: const Text('Hedef klasörde "Yapıştır" ile bırakılır'),
            onTap: () {
              Navigator.pop(context);
              onCopyOrCut(cut: false);
            },
          ),
          ListTile(
            leading: const Icon(Icons.content_cut_rounded),
            title: const Text('Taşı'),
            subtitle: const Text('Hedef klasörde "Yapıştır" ile taşınır'),
            onTap: () {
              Navigator.pop(context);
              onCopyOrCut(cut: true);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded),
            title: const Text('Sil'),
            subtitle: Text(
              useBin
                  ? 'Geri dönüşüm kutusuna taşır'
                  : 'Kalıcı olarak siler',
            ),
            onTap: () {
              Navigator.pop(context);
              onDelete();
            },
          ),
          if (!e.isDirectory && ext == 'apk')
            ListTile(
              leading: const Icon(Icons.android_rounded),
              title: const Text('Kur / Güncelle'),
              subtitle: const Text('Android kurucusunu açar'),
              onTap: () {
                Navigator.pop(context);
                showApkInstallDialog(hostContext, File(e.path));
              },
            ),
          if (!e.isDirectory && ArchiveService.isArchive(e.name))
            ListTile(
              leading: const Icon(Icons.folder_zip_outlined),
              title: const Text('Arşivi görüntüle'),
              subtitle: const Text('İçeriği gezin, çıkar'),
              onTap: () {
                Navigator.pop(context);
                onOpenArchive();
              },
            ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('Buraya sıkıştır'),
            subtitle: const Text('ZIP arşivi oluşturur (hedef sorulur)'),
            onTap: () {
              Navigator.pop(context);
              onCompress();
            },
          ),
          if (e.isDirectory &&
              hostContext.read<SettingsProvider>().showBookmarkMenu)
            ListTile(
              leading: Icon(
                BookmarkStore.contains(e.path)
                    ? Icons.bookmark_rounded
                    : Icons.bookmark_border_rounded,
              ),
              title: Text(
                BookmarkStore.contains(e.path)
                    ? 'Yer iminden çıkar'
                    : 'Yer imine ekle',
              ),
              onTap: () async {
                Navigator.pop(context);
                final messenger = ScaffoldMessenger.of(hostContext);
                final added = await BookmarkStore.toggle(
                  path: e.path,
                  name: e.name,
                );
                if (!hostContext.mounted) return;
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      added
                          ? '"${e.name}" yer imlerine eklendi'
                          : '"${e.name}" yer iminden çıkarıldı',
                    ),
                  ),
                );
              },
            ),
          if (e.isDirectory &&
              hostContext.read<SettingsProvider>().showAddToHomeMenu)
            ListTile(
              leading: const Icon(Icons.add_to_home_screen_rounded),
              title: const Text('Ana ekrana ekle'),
              subtitle: const Text('Cihaz ana ekranına klasör kısayolu'),
              onTap: () async {
                Navigator.pop(context);
                final messenger = ScaffoldMessenger.of(hostContext);
                final ok = await PlatformService.pinShortcut(
                  path: e.path,
                  label: e.name,
                );
                if (!hostContext.mounted) return;
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      ok
                          ? 'Kısayol isteği gönderildi'
                          : 'Kısayol eklenemedi',
                    ),
                  ),
                );
              },
            ),
          if (!e.isDirectory &&
              hostContext.read<SettingsProvider>().showOpenWithMenu)
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: const Text('Farklı aç'),
              subtitle: const Text('Başka bir uygulamayla aç'),
              onTap: () async {
                Navigator.pop(context);
                final messenger = ScaffoldMessenger.of(hostContext);
                final ok = await PlatformService.openWith(path: e.path);
                if (!hostContext.mounted || ok) return;
                messenger.showSnackBar(
                  const SnackBar(content: Text('Dosya açılamadı')),
                );
              },
            ),
          if (!e.isDirectory && kTextExts.contains(ext))
            ListTile(
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('Metin olarak aç'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(hostContext).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        TextEditorScreen(file: File(e.path), title: e.name),
                  ),
                );
              },
            ),
          if (!e.isDirectory)
            ListTile(
              leading: const Icon(Icons.data_object_rounded),
              title: const Text('Hex görüntüle'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(hostContext).push(
                  MaterialPageRoute(
                    builder: (_) =>
                        HexViewerScreen(file: File(e.path), title: e.name),
                  ),
                );
              },
            ),
          if (!e.isDirectory && kSqliteExts.contains(ext))
            ListTile(
              leading: const Icon(Icons.table_chart_rounded),
              title: const Text('SQLite tablolarını görüntüle'),
              onTap: () {
                Navigator.pop(context);
                Navigator.of(hostContext).push(
                  MaterialPageRoute(
                    builder: (_) => SqliteViewerScreen(
                        file: File(e.path), title: e.name),
                  ),
                );
              },
            ),
          if (!e.isDirectory)
            ListTile(
              leading: const Icon(Icons.lock_outline_rounded),
              title: const Text('Kasaya taşı'),
              subtitle: const Text('PIN ile şifrelenir, kasa dışında saklanır'),
              onTap: () {
                Navigator.pop(context);
                onAddToVault();
              },
            ),
          ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('İzinleri değiştir (chmod)'),
            subtitle: const Text('Root\'lu cihazlarda dosya izinleri'),
            onTap: () {
              Navigator.pop(context);
              onChmod();
            },
          ),
        ],
      ),
    ),
  );
}
