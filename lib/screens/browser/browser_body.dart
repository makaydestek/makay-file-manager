import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/file_entry.dart';
import '../../providers/settings_provider.dart';
import '../../utils/formats.dart';
import '../../widgets/file_thumbnail.dart';
import '../../widgets/tv_focusable.dart';

/// Klasör satır altı metni: adet biliniyorsa "N öğe", değilse "Klasör".
String browserFolderSubtitle(
  FileEntry e, {
  required Map<String, int?> childCounts,
  required int countCap,
}) {
  final n = childCounts[e.path];
  if (n == null) return 'Klasör';
  return n > countCap ? '$countCap+ öğe' : '$n öğe';
}

/// Küçük resim + işlem sonrası mavi nokta.
Widget browserLeadingThumb(
  BuildContext context,
  FileEntry e, {
  required Set<String> highlighted,
}) {
  final thumb = SizedBox(
    width: 40,
    height: 40,
    child: FileThumbnail(entry: e, size: 40),
  );
  if (!highlighted.contains(e.path)) return thumb;
  return Stack(
    clipBehavior: Clip.none,
    children: [
      thumb,
      Positioned(
        right: -2,
        top: -2,
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.primary,
            shape: BoxShape.circle,
            border: Border.all(
              color: Theme.of(context).colorScheme.surface,
              width: 1.5,
            ),
          ),
        ),
      ),
    ],
  );
}

/// Liste / ızgara gövdesi (boş / yükleniyor / platform uyarısı dahil).
Widget buildBrowserBody({
  required BuildContext context,
  required String? rootPath,
  required String path,
  required bool loading,
  required String query,
  required List<FileEntry> visible,
  required Set<String> selected,
  required bool selecting,
  required Set<String> highlighted,
  required Map<String, int?> childCounts,
  required int countCap,
  required Future<void> Function() onRefresh,
  required void Function(FileEntry) onOpen,
  required void Function(FileEntry) onToggleSelect,
  required void Function(FileEntry) onRowMenu,
}) {
  final datePattern =
      context.select<SettingsProvider, String>((s) => s.datePattern);
  if (rootPath == null || path.isEmpty) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Text(
          'Bu platformda dosya erişimi desteklenmiyor.\n'
          'Android cihazda tam işlevsellik sunulur.',
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
  if (loading) return const Center(child: CircularProgressIndicator());
  if (visible.isEmpty) {
    return Center(
      child: Text(
        query.isEmpty ? 'Boş Klasör' : 'Sonuç bulunamadı',
        style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: Theme.of(context).colorScheme.outline,
            ),
      ),
    );
  }
  return RefreshIndicator(
    onRefresh: onRefresh,
    child: context.select<SettingsProvider, String>(
              (s) => s.browserViewMode) ==
          'grid'
        ? buildBrowserGrid(
            context,
            visible,
            datePattern,
            selected: selected,
            selecting: selecting,
            childCounts: childCounts,
            countCap: countCap,
            onOpen: onOpen,
            onToggleSelect: onToggleSelect,
          )
        : buildBrowserList(
            context,
            visible,
            datePattern,
            selected: selected,
            selecting: selecting,
            highlighted: highlighted,
            childCounts: childCounts,
            countCap: countCap,
            onOpen: onOpen,
            onToggleSelect: onToggleSelect,
            onRowMenu: onRowMenu,
          ),
  );
}

/// Satır görünümü: ikon + ad + (tarih • boyut); uzun bas → seçim,
/// sürükle → (tablet) klasör ağacına kopyalama.
Widget buildBrowserList(
  BuildContext context,
  List<FileEntry> visible,
  String datePattern, {
  required Set<String> selected,
  required bool selecting,
  required Set<String> highlighted,
  required Map<String, int?> childCounts,
  required int countCap,
  required void Function(FileEntry) onOpen,
  required void Function(FileEntry) onToggleSelect,
  required void Function(FileEntry) onRowMenu,
}) {
  return ListView.builder(
    itemCount: visible.length,
    itemBuilder: (context, index) {
      final e = visible[index];
      final isSelected = selected.contains(e.path);
      final tile = ListTile(
        selected: isSelected,
        selectedTileColor:
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        // Resim/videoda gerçek küçük resim, klasörde amber klasör + simge,
        // diğerlerinde renkli tip ikonu.
        leading: browserLeadingThumb(context, e, highlighted: highlighted),
        title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        // Referans satır düzeni: klasörde adet ("3 öğe"), dosyada boyut.
        subtitle: Text(
          e.isDirectory
              ? browserFolderSubtitle(
                  e,
                  childCounts: childCounts,
                  countCap: countCap,
                )
              : Formats.size(e.size),
          maxLines: 1,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
        // Sağda tarih + satır menüsü (seçim modunda seçim göstergesi).
        trailing: selecting
            ? Icon(
                isSelected
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                color: isSelected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    Formats.date(e.modified, pattern: datePattern),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline),
                  ),
                  IconButton(
                    icon: const Icon(Icons.more_vert_rounded, size: 20),
                    tooltip: 'Daha fazla',
                    onPressed: () => onRowMenu(e),
                  ),
                ],
              ),
        onTap: () => onOpen(e),
        onLongPress: () => onToggleSelect(e),
      );
      // TV: satır tek odak hedefi + net halka (F Dosya tarzı).
      final focused = TvFocusable(
        autofocus: index == 0,
        onActivate: () => onOpen(e),
        borderRadius: 12,
        scale: 1.02,
        child: tile,
      );
      // Çift panel (tablet): uzun basıp sürükleyerek sol paneldeki
      // klasör ağacına kopyalanır; seçiliyken sürüklenemez.
      if (selecting) return focused;
      return LongPressDraggable<String>(
        data: e.path,
        feedback: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: ListTile(
              dense: true,
              leading: Icon(e.icon, color: e.color, size: 24),
              title: Text(e.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: focused),
        child: focused,
      );
    },
  );
}

/// Izgara görünümü: kare önizleme + ad + boyut; fotoğraf/kamera
/// klasörlerinde dosyalar kendi görselleriyle görünür.
Widget buildBrowserGrid(
  BuildContext context,
  List<FileEntry> visible,
  String datePattern, {
  required Set<String> selected,
  required bool selecting,
  required Map<String, int?> childCounts,
  required int countCap,
  required void Function(FileEntry) onOpen,
  required void Function(FileEntry) onToggleSelect,
}) {
  final width = MediaQuery.sizeOf(context).width;
  final columns = width > 900 ? 5 : (width > 600 ? 4 : 3);
  return GridView.builder(
    padding: const EdgeInsets.all(8),
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: columns,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 0.78,
    ),
    itemCount: visible.length,
    itemBuilder: (context, index) {
      final e = visible[index];
      final isSelected = selected.contains(e.path);
      return TvFocusable(
        autofocus: index == 0,
        onActivate: () => onOpen(e),
        borderRadius: 12,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => onOpen(e),
          onLongPress: () => onToggleSelect(e),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: isSelected
                  ? Border.all(
                      color: Theme.of(context).colorScheme.primary, width: 2)
                  : null,
              color: isSelected
                  ? Theme.of(context)
                      .colorScheme
                      .primary
                      .withValues(alpha: 0.08)
                  : null,
            ),
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Kare önizleme: genişliğe yayılır, en-boy korunur.
                Expanded(
                  child: Center(
                    child: AspectRatio(
                      aspectRatio: 1,
                      child: FileThumbnail(
                        entry: e,
                        size: 120,
                        borderRadius: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  e.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  e.isDirectory
                      ? browserFolderSubtitle(
                          e,
                          childCounts: childCounts,
                          countCap: countCap,
                        )
                      : Formats.size(e.size),
                  maxLines: 1,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.outline,
                      ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}
