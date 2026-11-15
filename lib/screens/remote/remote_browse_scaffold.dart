import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../models/remote_item.dart';
import '../../services/remote_browse_prefs.dart';
import '../../services/remote_download.dart';
import '../../services/remote_preview.dart';
import '../../utils/formats.dart';
import '../../widgets/remote_thumb.dart';

/// Protokol ekranlarının bağladığı ortak uzak gezinme yüzeyi.
///
/// F Dosya Yöneticisi tarzı: sıralama, liste/ızgara, arama, önizleme,
/// indirme menüsü, breadcrumb, üst klasör.
class RemoteBrowseScaffold extends StatefulWidget {
  const RemoteBrowseScaffold({
    super.key,
    required this.title,
    required this.subtitleIcon,
    required this.pathLabel,
    required this.crumbs,
    required this.canGoUp,
    required this.locationKey,
    required this.items,
    required this.loading,
    required this.error,
    required this.onRefresh,
    required this.onOpenDir,
    required this.onGoUp,
    required this.onCrumb,
    required this.download,
    this.fetchBytes,
    this.networkUrlFor,
    this.httpHeaders,
    this.extraActions = const [],
    this.extraMenuItems,
  });

  final String title;
  final IconData subtitleIcon;

  /// AppBar altındaki kısa yol metni (SMB UNC vb.).
  final String pathLabel;

  /// Breadcrumb parçaları: (etiket, mutlak yol).
  final List<(String label, String path)> crumbs;

  final bool canGoUp;
  final String locationKey;
  final List<RemoteItem> items;
  final bool loading;
  final String? error;
  final Future<void> Function() onRefresh;
  final void Function(RemoteItem item) onOpenDir;
  final VoidCallback onGoUp;
  final void Function(String path) onCrumb;

  /// Dosyayı yerel hedefe indirir.
  final Future<void> Function(RemoteItem item, File target) download;

  /// Küçük resim / önizleme için bayt indirme (isteğe bağlı).
  final Future<Uint8List> Function(RemoteItem item)? fetchBytes;

  /// WebDAV gibi doğrudan ağ URL'si (önizleme için).
  final Uri? Function(RemoteItem item)? networkUrlFor;
  final Map<String, String>? httpHeaders;

  /// AppBar ekstra aksiyonları (SMB yükle/yeni klasör).
  final List<Widget> extraActions;

  /// Satır menüsüne protokole özel ek öğeler (yeniden adlandır / sil).
  final List<Widget> Function(
    BuildContext context,
    RemoteItem item,
    void Function() close,
  )? extraMenuItems;

  @override
  State<RemoteBrowseScaffold> createState() => _RemoteBrowseScaffoldState();
}

class _RemoteBrowseScaffoldState extends State<RemoteBrowseScaffold> {
  final _prefs = RemoteBrowsePrefs();
  final _searchController = TextEditingController();
  bool _prefsReady = false;
  bool _searchActive = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _prefs.load().then((_) {
      if (mounted) setState(() => _prefsReady = true);
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<RemoteItem> get _visible {
    final sorted = _prefsReady ? _prefs.sort(widget.items) : widget.items;
    return _prefs.filter(sorted, _query);
  }

  Future<void> _preview(RemoteItem item) async {
    await RemotePreview.open(
      context,
      fileName: item.name,
      locationKey: widget.locationKey,
      remotePath: item.remotePath,
      transfer: (target) => widget.download(item, target),
      transferBytes: widget.fetchBytes != null && item.isImage
          ? () => widget.fetchBytes!(item)
          : null,
      networkUrl: widget.networkUrlFor?.call(item),
      httpHeaders: widget.httpHeaders,
    );
  }

  Future<void> _download(RemoteItem item) async {
    await RemoteDownload.run(
      context,
      fileName: item.name,
      transfer: (target, token) => widget.download(item, target),
    );
  }

  void _open(RemoteItem item) {
    if (item.isDir) {
      widget.onOpenDir(item);
      return;
    }
    if (RemotePreview.isPreviewable(item.name)) {
      _preview(item);
    } else {
      _download(item);
    }
  }

  Future<void> _showInfo(RemoteItem item) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.isDir ? 'Tür: Klasör' : 'Tür: Dosya'),
            if (!item.isDir) Text('Boyut: ${Formats.size(item.size)}'),
            if (item.modified != null)
              Text('Değiştirilme: ${Formats.date(item.modified!)}'),
            const SizedBox(height: 8),
            SelectableText(item.remotePath,
                style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  Future<void> _entryMenu(RemoteItem item) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) {
        void close() => Navigator.pop(ctx);
        return SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: RemoteThumb(
                    item: item,
                    locationKey: widget.locationKey,
                    fetchBytes: widget.fetchBytes != null && item.isImage
                        ? () => widget.fetchBytes!(item)
                        : null,
                  ),
                  title: Text(item.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(
                    item.isDir
                        ? 'Klasör'
                        : '${Formats.size(item.size)}'
                            '${item.modified != null ? ' • ${Formats.date(item.modified!)}' : ''}',
                  ),
                ),
                const Divider(height: 1),
                if (item.isDir)
                  ListTile(
                    leading: const Icon(Icons.folder_open_rounded),
                    title: const Text('Aç'),
                    onTap: () {
                      close();
                      widget.onOpenDir(item);
                    },
                  ),
                if (!item.isDir && RemotePreview.isPreviewable(item.name))
                  ListTile(
                    leading: Icon(
                      item.isImage
                          ? Icons.image_rounded
                          : item.isVideo
                              ? Icons.play_circle_outline_rounded
                              : Icons.audiotrack_rounded,
                    ),
                    title: const Text('Önizle / Oynat'),
                    onTap: () {
                      close();
                      _preview(item);
                    },
                  ),
                if (!item.isDir)
                  ListTile(
                    leading: const Icon(Icons.download_rounded),
                    title: const Text('İndirilenler\'e indir'),
                    onTap: () {
                      close();
                      _download(item);
                    },
                  ),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('Bilgi'),
                  onTap: () {
                    close();
                    _showInfo(item);
                  },
                ),
                if (widget.extraMenuItems != null)
                  ...widget.extraMenuItems!(ctx, item, close),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickSort() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setSheet) {
            Future<void> apply({
              RemoteSortBy? by,
              bool? desc,
              bool? foldersFirst,
              String? viewMode,
            }) async {
              setSheet(() {
                if (by != null) _prefs.sortBy = by;
                if (desc != null) _prefs.sortDesc = desc;
                if (foldersFirst != null) _prefs.foldersFirst = foldersFirst;
                if (viewMode != null) _prefs.viewMode = viewMode;
              });
              setState(() {});
              await _prefs.save();
            }

            Widget sortTile(RemoteSortBy by, String label, IconData icon) {
              final selected = _prefs.sortBy == by;
              return ListTile(
                leading: Icon(icon),
                title: Text(label),
                trailing: selected
                    ? Icon(
                        _prefs.sortDesc
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                        color: Theme.of(context).colorScheme.primary,
                      )
                    : null,
                selected: selected,
                onTap: () {
                  if (selected) {
                    apply(desc: !_prefs.sortDesc);
                  } else {
                    apply(by: by, desc: false);
                  }
                },
              );
            }

            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                      child: Text(
                        'Sıralama ve görünüm',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    sortTile(RemoteSortBy.name, 'Ada göre',
                        Icons.sort_by_alpha_rounded),
                    sortTile(RemoteSortBy.date, 'Değiştirilme tarihine göre',
                        Icons.schedule_rounded),
                    sortTile(RemoteSortBy.size, 'Boyuta göre',
                        Icons.data_usage_rounded),
                    sortTile(RemoteSortBy.type, 'Türe göre',
                        Icons.category_rounded),
                    const Divider(),
                    SwitchListTile(
                      secondary: const Icon(Icons.folder_rounded),
                      title: const Text('Klasörler önce'),
                      value: _prefs.foldersFirst,
                      onChanged: (v) => apply(foldersFirst: v),
                    ),
                    SwitchListTile(
                      secondary: Icon(
                        _prefs.sortDesc
                            ? Icons.arrow_downward_rounded
                            : Icons.arrow_upward_rounded,
                      ),
                      title: Text(_prefs.sortDesc ? 'Azalan' : 'Artan'),
                      value: _prefs.sortDesc,
                      onChanged: (v) => apply(desc: v),
                    ),
                    const Divider(),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
                      child: Text(
                        'Görünüm',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'list',
                            icon: Icon(Icons.view_list_rounded),
                            label: Text('Liste'),
                          ),
                          ButtonSegment(
                            value: 'grid',
                            icon: Icon(Icons.grid_view_rounded),
                            label: Text('Izgara'),
                          ),
                        ],
                        selected: {_prefs.viewMode},
                        onSelectionChanged: (s) => apply(viewMode: s.first),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible;

    return Scaffold(
      appBar: AppBar(
        title: _searchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Bu klasörde ara…',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : Text(widget.title),
        actions: [
          IconButton(
            icon: Icon(_searchActive ? Icons.close_rounded : Icons.search_rounded),
            tooltip: _searchActive ? 'Aramayı kapat' : 'Ara',
            onPressed: () {
              setState(() {
                _searchActive = !_searchActive;
                if (!_searchActive) {
                  _searchController.clear();
                  _query = '';
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.sort_rounded),
            tooltip: 'Sırala / Görünüm',
            onPressed: _pickSort,
          ),
          IconButton(
            icon: Icon(
              _prefs.isGrid
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded,
            ),
            tooltip: _prefs.isGrid ? 'Liste görünümü' : 'Izgara görünümü',
            onPressed: () async {
              setState(() => _prefs.toggleViewMode());
              await _prefs.save();
            },
          ),
          ...widget.extraActions,
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: widget.loading ? null : widget.onRefresh,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Icon(widget.subtitleIcon, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: widget.crumbs.isEmpty
                      ? Text(
                          widget.pathLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (var i = 0; i < widget.crumbs.length; i++)
                                _crumb(
                                  theme,
                                  widget.crumbs[i].$1,
                                  widget.crumbs[i].$2,
                                  isRoot: i == 0,
                                ),
                            ],
                          ),
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: widget.loading && widget.items.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : widget.error != null && widget.items.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.error_outline_rounded,
                            size: 48, color: Colors.redAccent),
                        const SizedBox(height: 12),
                        Text(widget.error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: widget.onRefresh,
                          child: const Text('Tekrar dene'),
                        ),
                        if (widget.canGoUp) ...[
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: widget.onGoUp,
                            child: const Text('Üst klasöre dön'),
                          ),
                        ],
                      ],
                    ),
                  ),
                )
              : Stack(
                  children: [
                    RefreshIndicator(
                      onRefresh: widget.onRefresh,
                      child: visible.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                if (widget.canGoUp)
                                  ListTile(
                                    leading: const Icon(
                                        Icons.drive_folder_upload_rounded),
                                    title: const Text('Üst klasör'),
                                    onTap: widget.onGoUp,
                                  ),
                                const SizedBox(height: 80),
                                Center(
                                  child: Text(
                                    _query.isEmpty
                                        ? 'Bu dizin boş'
                                        : 'Sonuç bulunamadı',
                                  ),
                                ),
                              ],
                            )
                          : _prefs.isGrid
                              ? _buildGrid(theme, visible)
                              : _buildList(theme, visible),
                    ),
                    // Klasör geçişinde eski içerik kaybolunca ince yükleme şeridi.
                    if (widget.loading && widget.items.isNotEmpty)
                      const Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: LinearProgressIndicator(minHeight: 2),
                      ),
                  ],
                ),
    );
  }

  Widget _crumb(ThemeData theme, String label, String path,
      {bool isRoot = false}) {
    final isLast =
        widget.crumbs.isNotEmpty && widget.crumbs.last.$2 == path;
    return InkWell(
      onTap: () => widget.onCrumb(path),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          isRoot && (label.isEmpty || label == '/') ? '/' : label,
          style: TextStyle(
            fontWeight: isLast ? FontWeight.bold : FontWeight.normal,
            color: isLast
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }

  Widget _buildList(ThemeData theme, List<RemoteItem> visible) {
    final showUp = widget.canGoUp;
    return ListView.builder(
      itemCount: visible.length + (showUp ? 1 : 0),
      itemBuilder: (context, index) {
        if (showUp && index == 0) {
          return ListTile(
            leading: const Icon(Icons.drive_folder_upload_rounded),
            title: const Text('Üst klasör'),
            onTap: widget.onGoUp,
          );
        }
        final e = visible[showUp ? index - 1 : index];
        return ListTile(
          leading: RemoteThumb(
            item: e,
            locationKey: widget.locationKey,
            fetchBytes: widget.fetchBytes != null && e.isImage
                ? () => widget.fetchBytes!(e)
                : null,
          ),
          title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(e.isDir ? 'Klasör' : Formats.size(e.size)),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (e.modified != null)
                Text(
                  Formats.date(e.modified!),
                  style: theme.textTheme.bodySmall,
                ),
              IconButton(
                icon: const Icon(Icons.more_vert_rounded),
                onPressed: () => _entryMenu(e),
              ),
            ],
          ),
          onTap: () => _open(e),
          onLongPress: () => _entryMenu(e),
        );
      },
    );
  }

  Widget _buildGrid(ThemeData theme, List<RemoteItem> visible) {
    final showUp = widget.canGoUp;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemCount: visible.length + (showUp ? 1 : 0),
      itemBuilder: (context, index) {
        if (showUp && index == 0) {
          return InkWell(
            onTap: widget.onGoUp,
            borderRadius: BorderRadius.circular(12),
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Center(
                      child: Icon(Icons.drive_folder_upload_rounded, size: 40),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Üst klasör',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          );
        }
        final e = visible[showUp ? index - 1 : index];
        return InkWell(
          onTap: () => _open(e),
          onLongPress: () => _entryMenu(e),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            children: [
              Expanded(
                child: RemoteThumb(
                  item: e,
                  locationKey: widget.locationKey,
                  fill: true,
                  fetchBytes: widget.fetchBytes != null && e.isImage
                      ? () => widget.fetchBytes!(e)
                      : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                e.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        );
      },
    );
  }
}
