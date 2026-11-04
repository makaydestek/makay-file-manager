import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/file_entry.dart';
import '../providers/settings_provider.dart';
import '../services/bookmark_service.dart';
import '../services/browser_tab_store.dart';
import '../services/category_size_service.dart';
import '../services/clipboard_manager.dart';
import '../services/file_service.dart';
import '../utils/file_opener.dart';
import '../utils/folder_watcher.dart';
import '../widgets/app_drawer.dart';
import '../widgets/folder_tree_panel.dart';
import '../widgets/path_chips.dart';
import '../widgets/root_header.dart';
import 'archive_screen.dart';
import 'browser/browser_body.dart';
import 'browser/browser_file_actions.dart';
import 'browser/browser_row_menu.dart';

/// Önizleme uzantıları ve dosya açma mantığı [FileOpener]'da ortaktır
/// (tarayıcı + cihaz geneli arama); buraya tekrar tanımlanmaz.

/// Dosya tarayıcı ekranı: liste, sıralama, arama, dosya işlemleri.
///
/// Başlık çubuğu tek satırdır; altında tıklanabilir yol chip'leri (PathChips)
/// derin klasörlerde yön duygusu verir. Üst klasörler ayrıca sistem geri oku
/// ve tablette klasör ağacıyla gezilir.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({
    super.key,
    required this.title,
    required this.rootPath,
    this.showHomeShortcut = true,
    this.showRootDrawer = false,
  });

  final String title;

  /// Gezinilecek başlangıç dizini (null ise desteklenmeyen platform).
  final String? rootPath;

  /// Taşma menüsünde "Ana ekrana dön" kısayolu gösterilsin mi.
  final bool showHomeShortcut;

  /// Kök seviye (Ana bellek / kategori kökleri) mi?
  ///
  /// Kök seviyede referans uygulamadaki gibi hamburger menü (çekmece) ve
  /// app bar altında yol/kullanım satırı gösterilir; alt klasörlere girişte
  /// geri ok korunur.
  final bool showRootDrawer;

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen>
    with WidgetsBindingObserver, BrowserFileActions<BrowserScreen> {
  static const _service = FileService();

  /// Çekmeceyi (hamburger menü) açmak için.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  late String _path;
  List<FileEntry> _entries = [];
  bool _loading = true;

  /// Klasör başına doğrudan çocuk sayısı (yol → adet).
  ///
  /// Her yüklemede sıfırlanır; sayılar arka planda toplanır, gelince
  /// satırda "N öğe" olarak görünür. Sayılamayan klasörlerde null tutulur
  /// ve satır yalnız "Klasör" yazar.
  Map<String, int?> _childCounts = {};

  /// Sayım üst sınırı ("9999+" gösterilir).
  static const int _countCap = 9999;

  // Sıralama.
  bool _sortByName = true;
  bool _sortDescending = false;

  // Arama.
  bool _searchActive = false;
  final _searchController = TextEditingController();
  String _query = '';

  // Çoklu seçim.
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  /// İşlem sonrası geçici vurgu (yeni/kopyalanan dosya noktası).
  final Set<String> _highlighted = {};

  /// Depolama kökü (yol chip'leri için).
  static const _storageRoot = '/storage/emulated/0';

  /// Canlı klasör izleyici (ekle/sil → sessiz yenileme).
  late final FolderWatcher _watcher = FolderWatcher(
    onChanged: _onFolderChanged,
  );

  /// Çakışan yüklemelerde bayat sonucu yok saymak için.
  int _loadGen = 0;

  /// İzleyici tetiklemelerinde ana sayfa kartlarını da tazele.
  bool _sizesDirty = false;
  Timer? _sizeRefreshTimer;

  // --- BrowserFileActions host ---

  @override
  String get browserPath => _path;

  @override
  FileService get browserService => _service;

  @override
  Set<String> get browserSelected => _selected;

  @override
  Set<String> get browserHighlighted => _highlighted;

  @override
  List<FileEntry> get browserEntries => _entries;

  @override
  Future<void> browserReload({
    bool quiet = false,
    bool preserveSelection = false,
  }) =>
      _load(quiet: quiet, preserveSelection: preserveSelection);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _path = widget.rootPath ?? '';
    BookmarkStore.load();
    _load();
    _startWatching();
  }

  String get _chipRoot {
    if (_path.startsWith(_storageRoot)) return _storageRoot;
    return widget.rootPath ?? _path;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watcher.dispose();
    _sizeRefreshTimer?.cancel();
    _searchController.dispose();
    if (_sizesDirty) {
      unawaited(CategorySizeService.invalidate());
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Başka uygulamadan indirme/silme sonrası öne gelince liste hemen tazelenir.
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_load(quiet: true));
    }
  }

  void _startWatching() {
    if (_path.isEmpty) {
      _watcher.stop();
      return;
    }
    // İndirilenler alt klasörleri de yakalansın; yoklama watch kaçaklarını örter.
    _watcher.start([_path], recursive: true);
  }

  void _onFolderChanged() {
    if (!mounted) return;
    // Liste hemen (debounce zaten FolderWatcher'da); kart boyutları
    // indirme sırasında her olayda ağır tarama yapmasın diye kısılır.
    unawaited(_load(quiet: true, preserveSelection: true));
    _scheduleSizeRefresh();
  }

  void _scheduleSizeRefresh() {
    _sizesDirty = true;
    _sizeRefreshTimer ??= Timer(const Duration(seconds: 2), () {
      _sizeRefreshTimer = null;
      _sizesDirty = false;
      unawaited(CategorySizeService.invalidate());
    });
  }

  /// [quiet]: spinner göstermeden arka planda yeniler (canlı izleme).
  /// [preserveSelection]: izleyici yenilemesinde seçimi korur.
  Future<void> _load({
    bool quiet = false,
    bool preserveSelection = false,
  }) async {
    if (_path.isEmpty) {
      setState(() => _loading = false);
      return;
    }
    final gen = ++_loadGen;
    final showSpinner = !quiet || _entries.isEmpty;
    if (showSpinner) {
      setState(() {
        _loading = true;
        // İçerik yenilendi; eski adetler bayat olabilir.
        _childCounts = {};
      });
    }
    final showHidden =
        context.read<SettingsProvider>().showHiddenFiles;
    var entries = await _service.listDirectory(_path, showHidden: showHidden);
    entries = _sort(entries);
    if (!mounted || gen != _loadGen) return;
    final keep = preserveSelection
        ? _selected.intersection({for (final e in entries) e.path})
        : <String>{};
    setState(() {
      _entries = entries;
      _loading = false;
      if (preserveSelection) {
        _selected
          ..clear()
          ..addAll(keep);
      } else {
        _selected.clear();
      }
      if (!showSpinner) {
        // Sessiz yenilemede de adetler bayat kalmasın.
        _childCounts = {};
      }
    });
    // Adetler liste görünürken arka planda toplanır (satır "N öğe" yazar).
    _loadChildCounts(entries, showHidden: showHidden);
  }

  /// Klasörlerin doğrudan çocuk sayılarını arka planda toplar.
  ///
  /// Erişilemeyen klasörlerde (izin vb.) sayı null kalır. Gizli (nokta)
  /// girdiler, listeyle aynı kural gereği sayılmaz.
  Future<void> _loadChildCounts(
    List<FileEntry> entries, {
    required bool showHidden,
  }) async {
    for (final e in entries) {
      if (!e.isDirectory) continue;
      int? count;
      try {
        var n = 0;
        await for (final child in Directory(e.path).list(followLinks: false)) {
          // Uri'de klasörler sondaki boş segmentle biter; ad son dolu segment.
          final segments = child.uri.pathSegments;
          var i = segments.length - 1;
          while (i >= 0 && segments[i].isEmpty) {
            i--;
          }
          final name = i >= 0 ? segments[i] : '';
          if (!showHidden && name.startsWith('.')) continue;
          if (++n > _countCap) break;
        }
        count = n;
      } catch (_) {
        count = null;
      }
      if (!mounted) return;
      setState(() => _childCounts[e.path] = count);
    }
  }

  List<FileEntry> _sort(List<FileEntry> entries) {
    int cmp(FileEntry a, FileEntry b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final r = switch ((_sortByName, _sortDescending)) {
        (true, false) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        (true, true) => b.name.toLowerCase().compareTo(a.name.toLowerCase()),
        (false, false) => a.modified.compareTo(b.modified),
        (false, true) => b.modified.compareTo(a.modified),
      };
      return r;
    }

    return List.of(entries)..sort(cmp);
  }

  List<FileEntry> get _visible {
    if (_query.isEmpty) return _entries;
    final q = _query.toLowerCase();
    return _entries.where((e) => e.name.toLowerCase().contains(q)).toList();
  }

  void _toggleSelect(FileEntry e) {
    setState(() {
      if (!_selected.remove(e.path)) _selected.add(e.path);
    });
  }

  Future<void> _open(FileEntry e) async {
    if (_selecting) {
      _toggleSelect(e);
      return;
    }
    if (e.isDirectory) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BrowserScreen(
            title: e.name,
            rootPath: e.path,
            showHomeShortcut: widget.showHomeShortcut,
          ),
        ),
      );
      if (mounted) _load();
    } else {
      _openPreview(e);
    }
  }

  /// Klasörü yeni sekmede açar (MiXplorer tarzı).
  void _openInNewTab(FileEntry e) {
    if (!e.isDirectory) return;
    BrowserTabStore.open(title: e.name, path: e.path);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BrowserScreen(
          title: e.name,
          rootPath: e.path,
          showHomeShortcut: widget.showHomeShortcut,
        ),
      ),
    );
  }

  /// Dosya türüne göre yerleşik önizleme [FileOpener] ile açılır;
  /// desteklenmeyen türde bilgi diyaloğu gösterilir.
  void _openPreview(FileEntry e) {
    FileOpener.openFile(context, e, onUnsupported: () => showInfo(e));
  }

  /// Arşiv dosyasını arşiv görüntüleyici ekranında açar.
  void _openArchive(FileEntry e) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ArchiveScreen(archivePath: e.path),
      ),
    );
  }

  /// Yol chip'inden veya kısayoldan klasöre git.
  void _navigateToPath(String path) {
    if (path == _path || path.isEmpty) return;
    final sep = Platform.pathSeparator;
    final i = path.lastIndexOf(sep);
    final name = i >= 0 ? path.substring(i + 1) : path;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => BrowserScreen(
          title: name.isEmpty ? path : name,
          rootPath: path,
          showHomeShortcut: widget.showHomeShortcut,
          showRootDrawer: path == _storageRoot || path == widget.rootPath,
        ),
      ),
    );
  }

  /// Satır menüsü: bilgi, metin/hex/SQLite açma, kasaya taşıma.
  void _rowMenu(FileEntry e) {
    showBrowserRowMenu(
      hostContext: context,
      entry: e,
      onInfo: () => showInfo(e),
      onOpenInNewTab: () => _openInNewTab(e),
      onCopyOrCut: ({required bool cut}) =>
          copySelectionToClipboard([e], cut: cut),
      onDelete: () => deleteEntries([e]),
      onOpenArchive: () => _openArchive(e),
      onCompress: () => compressToZip([e]),
      onAddToVault: () => addToVault(e),
      onChmod: () => chmodDialog(e),
    );
  }

  Future<void> _pickSort() async {
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => SimpleDialog(
          title: const Text('Sırala'),
          children: [
            RadioGroup<bool>(
              groupValue: _sortByName,
              onChanged: (v) {
                if (v != null) {
                  setDialogState(() => _sortByName = v);
                  setState(() => _entries = _sort(_entries));
                }
              },
              child: Column(
                children: [
                  const RadioListTile<bool>(title: Text('Ad'), value: true),
                  const RadioListTile<bool>(
                      title: Text('Değiştirilme tarihi'), value: false),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Azalan'),
              value: _sortDescending,
              onChanged: (v) {
                setDialogState(() => _sortDescending = v);
                setState(() => _entries = _sort(_entries));
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) => buildBrowserBody(
        context: context,
        rootPath: widget.rootPath,
        path: _path,
        loading: _loading,
        query: _query,
        visible: _visible,
        selected: _selected,
        selecting: _selecting,
        highlighted: _highlighted,
        childCounts: _childCounts,
        countCap: _countCap,
        onRefresh: _load,
        onOpen: _open,
        onToggleSelect: _toggleSelect,
        onRowMenu: _rowMenu,
      );

  @override
  Widget build(BuildContext context) {
    final clipboard = ListenableBuilder(
      listenable: ClipboardManager.instance,
      builder: (context, _) => const SizedBox.shrink(),
    );

    return Scaffold(
      key: _scaffoldKey,
      // Kök seviyede referans uygulamadaki gibi çekmece (hamburger) menüsü.
      drawer: widget.showRootDrawer ? const AppDrawer() : null,
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(_selected.clear),
              )
            : (widget.showRootDrawer
                ? IconButton(
                    icon: const Icon(Icons.menu_rounded),
                    tooltip: 'Menü',
                    onPressed: () => _scaffoldKey.currentState?.openDrawer(),
                  )
                : null),
        title: _selecting
            ? Text('${_selected.length} seçili')
            : (_searchActive
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    style: const TextStyle(color: Colors.black87),
                    decoration: const InputDecoration(
                      hintText: 'Ara…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  )
                : Text(widget.title)),
        actions: [
          if (!_selecting) ...[
            IconButton(
              icon: Icon(_searchActive ? Icons.close_rounded : Icons.search),
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
              onPressed: _pickSort,
              tooltip: 'Sırala',
            ),
            IconButton(
              // Liste ↔ Izgara: seçim kalıcıdır (SettingsProvider).
              icon: Icon(
                context.select<SettingsProvider, String>(
                          (s) => s.browserViewMode) ==
                      'grid'
                  ? Icons.view_list_rounded
                  : Icons.grid_view_rounded,
              ),
              tooltip: context.select<SettingsProvider, String>(
                        (s) => s.browserViewMode) ==
                    'grid'
                  ? 'Liste görünümü'
                  : 'Izgara görünümü',
              onPressed: () {
                final settings = context.read<SettingsProvider>();
                settings.browserViewMode =
                    settings.browserViewMode == 'grid' ? 'list' : 'grid';
              },
            ),
            if (!ClipboardManager.instance.isEmpty && !_searchActive)
              IconButton(
                icon: const Icon(Icons.paste_rounded),
                onPressed: paste,
                tooltip: 'Yapıştır',
              ),
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'new_folder':
                    newFolder();
                  case 'refresh':
                    _load();
                  case 'home':
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  case 'select_all':
                    setState(() {
                      _selected
                        ..clear()
                        ..addAll(_visible.map((e) => e.path));
                    });
                  case 'toggle_hidden':
                    final s = context.read<SettingsProvider>();
                    s.showHiddenFiles = !s.showHiddenFiles;
                    _load();
                }
              },
              itemBuilder: (context) {
                final s = context.read<SettingsProvider>();
                return [
                  const PopupMenuItem(
                      value: 'new_folder', child: Text('Yeni klasör')),
                  const PopupMenuItem(
                      value: 'select_all', child: Text('Tümünü seç')),
                  const PopupMenuItem(value: 'refresh', child: Text('Yenile')),
                  if (s.showHideToggleMenu)
                    PopupMenuItem(
                      value: 'toggle_hidden',
                      child: Text(
                        s.showHiddenFiles
                            ? 'Gizli dosyaları gizle'
                            : 'Gizli dosyaları göster',
                      ),
                    ),
                  if (widget.showHomeShortcut)
                    const PopupMenuItem(
                        value: 'home', child: Text('Ana ekrana dön')),
                ];
              },
            ),
          ] else ...[
            IconButton(
              icon: Icon(
                _selected.length == _visible.length && _visible.isNotEmpty
                    ? Icons.deselect_rounded
                    : Icons.select_all_rounded,
              ),
              tooltip: _selected.length == _visible.length && _visible.isNotEmpty
                  ? 'Seçimi kaldır'
                  : 'Tümünü seç',
              onPressed: () {
                setState(() {
                  if (_selected.length == _visible.length) {
                    _selected.clear();
                  } else {
                    _selected
                      ..clear()
                      ..addAll(_visible.map((e) => e.path));
                  }
                });
              },
            ),
            IconButton(
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => copySelectionToClipboard(
                _entries.where((e) => _selected.contains(e.path)).toList(),
                cut: false,
              ),
              tooltip: 'Kopyala',
            ),
            IconButton(
              icon: const Icon(Icons.content_cut_rounded),
              onPressed: () => copySelectionToClipboard(
                _entries.where((e) => _selected.contains(e.path)).toList(),
                cut: true,
              ),
              tooltip: 'Taşı',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded),
              onPressed: deleteSelected,
              tooltip: 'Sil',
            ),
            IconButton(
              icon: const Icon(Icons.share_rounded),
              onPressed: shareSelected,
              tooltip: 'Paylaş',
            ),
            IconButton(
              icon: const Icon(Icons.archive_outlined),
              onPressed: compressSelected,
              tooltip: 'Arşive ekle',
            ),
            IconButton(
              icon: const Icon(Icons.drive_file_rename_outline_rounded),
              onPressed: _selected.length == 1
                  ? () => rename(_entries
                      .where((e) => _selected.contains(e.path))
                      .first)
                  : null,
              tooltip: 'Yeniden adlandır',
            ),
            IconButton(
              icon: const Icon(Icons.info_outline_rounded),
              onPressed: _selected.length == 1
                  ? () => showInfo(_entries
                      .where((e) => _selected.contains(e.path))
                      .first)
                  : null,
              tooltip: 'Bilgi',
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          // Yer tutucu: ListenableBuilder'ı gövdede tutmak için.
          Offstage(child: clipboard),
          // Açık sekmeler şeridi.
          ValueListenableBuilder<List<BrowserTab>>(
            valueListenable: BrowserTabStore.tabs,
            builder: (context, tabs, _) {
              if (tabs.isEmpty) return const SizedBox.shrink();
              return SizedBox(
                height: 40,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: tabs.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 4),
                  itemBuilder: (context, i) {
                    final t = tabs[i];
                    final selected = t.path == _path ||
                        t.id == BrowserTabStore.activeId;
                    return InputChip(
                      selected: selected,
                      label: Text(t.title, maxLines: 1),
                      onSelected: (_) {
                        BrowserTabStore.select(t.id);
                        if (t.path == _path) return;
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) => BrowserScreen(
                              title: t.title,
                              rootPath: t.path,
                              showHomeShortcut: widget.showHomeShortcut,
                            ),
                          ),
                        );
                      },
                      onDeleted: () => BrowserTabStore.close(t.id),
                    );
                  },
                ),
              );
            },
          ),
          // Kök seviye: yol göstergesi + "KULLANILAN %x" rozeti.
          if (widget.showRootDrawer) const RootHeader(),
          // Derin klasörlerde tıklanabilir yol chip'leri.
          if (_path.isNotEmpty && _path != _chipRoot)
            PathChips(
              rootPath: _chipRoot,
              currentPath: _path,
              onNavigate: _navigateToPath,
            ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final settings = context.watch<SettingsProvider>();
                final minW = settings.dualPaneMinWidth.toDouble();
                final dual = widget.rootPath != null &&
                    (settings.forceDualPane ||
                        constraints.maxWidth >= minW);
                if (!dual) {
                  return _buildBody(context);
                }
                // Dar telefonda zorla çift bölmede ağaç daraltılır.
                final treeW = constraints.maxWidth < 720 ? 160.0 : 280.0;
                return Row(
                  children: [
                    SizedBox(
                      width: treeW,
                      child: FolderTreePanel(
                        rootPath: widget.rootPath!,
                        currentPath: _path,
                        onSelected: (path) {
                          if (path == _path) return;
                          final sep = '/';
                          final i = path.lastIndexOf(sep);
                          final name =
                              i >= 0 ? path.substring(i + 1) : path;
                          Navigator.of(context).pushReplacement(
                            MaterialPageRoute(
                              builder: (_) => BrowserScreen(
                                title: name.isEmpty ? path : name,
                                rootPath: path,
                                showHomeShortcut: widget.showHomeShortcut,
                              ),
                            ),
                          );
                        },
                        // Çift panel: listeden ağaç düğümüne sürükle →
                        // kopyala/taşı (ayar veya sor).
                        onDrop: dropToFolder,
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: _buildBody(context)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
