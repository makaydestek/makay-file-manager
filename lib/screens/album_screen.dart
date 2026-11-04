import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:share_plus/share_plus.dart';

import '../models/file_entry.dart';
import '../services/clipboard_manager.dart';
import '../services/media_service.dart';
import '../utils/debug_log.dart';
import '../utils/formats.dart';
import '../widgets/tv_focusable.dart';
import 'image_viewer_screen.dart';
import 'media_viewer_screen.dart';

/// Bir albümün içindeki medya öğelerinin ızgarası.
///
/// Uzun basarak çoklu seçim yapılabilir; seçilen öğeler **Kopyala / Taşı /
/// Sil / Paylaş** işlemleriyle yönetilir. Kopyalanan/taşınan öğeler
/// uygulama genelindeki panoya düşer ve klasör tarayıcısındaki "Yapıştır"
/// ile hedefe alınır.
class AlbumScreen extends StatefulWidget {
  const AlbumScreen({
    super.key,
    required this.albumId,
    required this.title,
    this.categoryId = '',
    this.isVideo = false,
  });

  final String albumId;
  final String title;

  /// Medya kategorisi (images / videos / audio): Resimler ekranında yalnız
  /// resimler, Videolar ekranında yalnız videolar listelenir.
  final String categoryId;
  final bool isVideo;

  @override
  State<AlbumScreen> createState() => _AlbumScreenState();
}

/// Albüm içi sıralama modları (referans uygulamadaki sıralama menüsü).
enum _SortMode {
  dateDesc('Tarih (Yeni → Eski)'),
  dateAsc('Tarih (Eski → Yeni)'),
  nameAsc('Ada göre (A → Z)'),
  nameDesc('Ada göre (Z → A)'),
  sizeDesc('Boyut (Büyük → Küçük)');

  const _SortMode(this.label);
  final String label;
}

/// Albüm içi tarih filtresi (referans uygulamadaki filtreleme).
enum _DateFilter {
  all('Tümü'),
  today('Bugün'),
  week('Son 7 gün'),
  month('Son 30 gün'),
  custom('Özel aralık…');

  const _DateFilter(this.label);
  final String label;
}

class _AlbumScreenState extends State<AlbumScreen> {
  static const _service = MediaService();
  static const _pageSize = 200;

  final List<AssetEntity> _assets = [];
  final Set<String> _selected = {};
  final _searchController = TextEditingController();
  bool _loading = true;
  bool _hasMore = true;
  bool _working = false;
  bool _searchActive = false;
  String _query = '';
  int _gridColumns = 3;

  // Sıralama ve filtre (menülerden seçilir; varsayılan tarih ↓).
  _SortMode _sort = _SortMode.dateDesc;
  _DateFilter _dateFilter = _DateFilter.all;
  DateTimeRange? _customRange;
  String _typeFilter = '';
  List<AssetEntity>? _visibleCache;

  /// Herhangi bir filtre aktif mi (filtre ikonu vurgusu için).
  bool get _filtering =>
      _dateFilter != _DateFilter.all ||
      _typeFilter.isNotEmpty ||
      _query.trim().isNotEmpty;

  /// Ada göre sıralama için başlıklar (asset kimliği → dosya adı).
  static final Map<String, String> _titleCache = {};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _loadPage();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadPage() async {
    final page = await _service.assets(
      widget.albumId,
      categoryId: widget.categoryId,
      offset: _assets.length,
      size: _pageSize,
    );
    if (!mounted) return;
    setState(() {
      _assets.addAll(page);
      _hasMore = page.length >= _pageSize;
      _loading = false;
      _visibleCache = null;
    });
    // Boyutlar arka planda çözülür; başlıktaki "Toplam" hazır oldukça
    // tazelenir (ana iş parçacığı dosya boyutu okumak için durmaz).
    unawaited(MediaService.resolveSizes(page).then((_) {
      if (mounted) setState(() => _visibleCache = null);
    }));
  }

  /// Albümün toplam öğesi ve boyutu (başlık altında özet).
  int get _totalCount => _assets.length;

  /// Filtre+ sıralama uygulanmış görünür liste (önbellekli).
  List<AssetEntity> get _visible => _visibleCache ??= _computeVisible();

  List<AssetEntity> _computeVisible() {
    var list = _assets;
    final from = _filterFrom;
    final to = _filterTo;
    if (from != null || to != null) {
      list = list.where((a) {
        final t = a.createDateTime;
        if (from != null && t.isBefore(from)) return false;
        if (to != null && !t.isBefore(to)) return false;
        return true;
      }).toList();
    }
    if (_typeFilter.isNotEmpty) {
      list = list.where((a) => _extOf(a) == _typeFilter).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((a) => _nameOf(a).toLowerCase().contains(q)).toList();
    }
    list = List<AssetEntity>.of(list);
    switch (_sort) {
      case _SortMode.dateDesc:
        list.sort((a, b) => b.createDateTime.compareTo(a.createDateTime));
      case _SortMode.dateAsc:
        list.sort((a, b) => a.createDateTime.compareTo(b.createDateTime));
      case _SortMode.nameAsc:
        list.sort((a, b) => _nameOf(a).toLowerCase().compareTo(_nameOf(b).toLowerCase()));
      case _SortMode.nameDesc:
        list.sort((a, b) => _nameOf(b).toLowerCase().compareTo(_nameOf(a).toLowerCase()));
      case _SortMode.sizeDesc:
        list.sort((a, b) =>
            MediaService.sizeOf(b).compareTo(MediaService.sizeOf(a)));
    }
    return list;
  }

  /// Ada göre sıralama için dosya adı (önbellek; yoksa kimlik kullanılır).
  String _nameOf(AssetEntity a) => _titleCache[a.id] ?? a.id;

  /// Seçilen tarih filtresinin başlangıcı (null = Tümü).
  DateTime? get _filterFrom {
    switch (_dateFilter) {
      case _DateFilter.all:
        return null;
      case _DateFilter.today:
        final now = DateTime.now();
        return DateTime(now.year, now.month, now.day);
      case _DateFilter.week:
        return DateTime.now().subtract(const Duration(days: 7));
      case _DateFilter.month:
        return DateTime.now().subtract(const Duration(days: 30));
      case _DateFilter.custom:
        return _customRange?.start;
    }
  }

  /// Seçilen tarih filtresinin bitişi (null = sınırsız).
  DateTime? get _filterTo {
    if (_dateFilter == _DateFilter.custom && _customRange != null) {
      // Seçilen bitiş gününün tamamı dâhil edilir.
      return _customRange!.end.add(const Duration(days: 1));
    }
    return null;
  }

  /// Sıralama değişti: ada göre için başlıklar, boyut için bayt boyutları
  /// önce çözülür; menü seçimi bekletir ve hazır olunca liste yeniden çizilir.
  Future<void> _changeSort(_SortMode mode) async {
    if (mode == _sort) return;
    setState(() {
      _sort = mode;
      _working = true;
    });
    try {
      if (mode == _SortMode.nameAsc || mode == _SortMode.nameDesc) {
        await _ensureTitles();
      } else if (mode == _SortMode.sizeDesc) {
        await MediaService.resolveSizes(_assets);
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  /// Albümdeki tüm başlıkların bir kez çözülmesi (ada göre sıralama için).
  Future<void> _ensureTitles() async {
    for (final a in _assets) {
      if (_titleCache.containsKey(a.id)) continue;
      try {
        _titleCache[a.id] = await a.titleAsync;
      } catch (e) {
        logSwallowed('albüm: başlık sıralama', e);
        _titleCache[a.id] = a.id;
      }
    }
  }

  /// Filtre menüsü seçimi: tarih grubu ya da dosya türü grubu.
  void _onFilterSelected(Object value) {
    if (value is _DateFilter) {
      unawaited(_changeDateFilter(value));
    } else if (value is String) {
      setState(() {
        _typeFilter = value;
        _visibleCache = null;
      });
    }
  }

  /// Tarih filtresi: "Özel aralık…" seçilirse aralık seçici açılır;
  /// seçim iptal edilirse önceki filtre korunur.
  Future<void> _changeDateFilter(_DateFilter filter) async {
    if (filter == _DateFilter.custom) {
      final now = DateTime.now();
      final range = await showDateRangePicker(
        context: context,
        firstDate: DateTime(now.year - 5),
        lastDate: now,
        initialDateRange: _customRange,
      );
      if (range == null || !mounted) return;
      setState(() {
        _dateFilter = _DateFilter.custom;
        _customRange = range;
        _visibleCache = null;
      });
      return;
    }
    setState(() {
      _dateFilter = filter;
      _visibleCache = null;
    });
  }

  /// Dosya uzantısı (tür filtresi için): MIME tipi Android'de senkron
  /// gelir; yoksa başlık önbelleğindeki dosya adına düşülür.
  String _extOf(AssetEntity a) {
    const mimeExt = <String, String>{
      'image/jpeg': 'jpg',
      'video/quicktime': 'mov',
      'video/x-matroska': 'mkv',
      'video/x-msvideo': 'avi',
      'audio/mpeg': 'mp3',
      'audio/mp4': 'm4a',
      'audio/x-wav': 'wav',
      'audio/x-ms-wma': 'wma',
    };
    final mime = a.mimeType?.toLowerCase();
    if (mime != null && mime.isNotEmpty) {
      return mimeExt[mime] ?? mime.split('/').last;
    }
    final name = _nameOf(a);
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot >= name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  /// Albümde görünen uzantılar (tür filtresi menüsü).
  List<String> _knownExtensions() {
    final out = <String>{};
    for (final a in _assets) {
      final e = _extOf(a);
      if (e.isNotEmpty) out.add(e);
    }
    return out.toList()..sort();
  }

  /// Menüde gösterilecek kısa tarih (12.3.2026).
  static String _dateLabel(DateTime d) => '${d.day}.${d.month}.${d.year}';

  int get _totalBytes => MediaService.totalSizeOf(_visible);

  void _toggleSelect(AssetEntity asset) {
    setState(() {
      if (!_selected.remove(asset.id)) _selected.add(asset.id);
    });
  }

  List<AssetEntity> get _selectedAssets =>
      _assets.where((a) => _selected.contains(a.id)).toList(growable: false);

  /// Kategori: video / ses / resim (isVideo yalnız videolar için true gelir;
  /// ses ekranında false olduğu için kategoriId esas alınır).
  bool get _isVideoCat =>
      widget.categoryId == 'videos' || widget.isVideo;
  bool get _isAudioCat => widget.categoryId == 'audio';

  /// Öğeye göre yerleşik görüntüleyici açılır (resim / video / ses).
  ///
  /// Büyük videolarda dosya çözümü zaman alabilir; ilerleme göstergesi
  /// sunulur. Ses albümünde artık resim görüntüleyiciye düşülmez — medya
  /// oynatıcı + content:// yedeği kullanılır (F Dosya Yöneticisi uyumu).
  Future<void> _openAsset(AssetEntity asset) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    _showProgress();
    try {
      final openAsVideo = _isVideoCat ||
          (!_isAudioCat && asset.type == AssetType.video);
      final openAsAudio = _isAudioCat ||
          (!_isVideoCat && asset.type == AssetType.audio);

      if (openAsVideo || openAsAudio) {
        final resolved = await _resolveMedia(asset);
        var title = _titleCache[asset.id] ?? '';
        if (title.isEmpty) {
          try {
            title = await asset.titleAsync;
            _titleCache[asset.id] = title;
          } catch (e) {
            logSwallowed('albüm: başlık', e);
          }
        }
        _hideProgress();
        if (resolved.file == null && resolved.uri == null) {
          messenger.showSnackBar(SnackBar(
            content: Text(openAsVideo
                ? 'Video açılamadı: dosyaya erişilemedi'
                : 'Ses açılamadı: dosyaya erişilemedi'),
          ));
          return;
        }
        await navigator.push(
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              file: resolved.file,
              contentUri: resolved.uri,
              isVideo: openAsVideo,
              title: title,
            ),
          ),
        );
        return;
      }

      // Resim (veya bilinmeyen → görüntüleyici).
      File? file;
      try {
        file = await asset.file;
        if (file != null && !await file.exists()) file = null;
      } catch (_) {
        file = null;
      }
      Uint8List? bytes;
      if (file == null) {
        bytes = await asset
            .thumbnailDataWithSize(const ThumbnailSize(2048, 2048));
      }
      _hideProgress();
      if (file == null && bytes == null) {
        messenger.showSnackBar(const SnackBar(
          content: Text('Resim açılamadı: dosyaya erişilemedi'),
        ));
        return;
      }
      var title = '';
      try {
        title = await asset.titleAsync;
      } catch (e) {
        logSwallowed('albüm: başlık', e);
      }
      await navigator.push(
        MaterialPageRoute(
          builder: (_) => file != null
              ? ImageViewerScreen(file: file, title: title)
              : ImageViewerScreen(bytes: bytes, title: title),
        ),
      );
    } catch (e) {
      _hideProgress();
      messenger.showSnackBar(
        SnackBar(content: Text('Açılamadı: $e')),
      );
    }
  }

  /// Medya dosyası + isteğe bağlı content:// URI.
  ///
  /// Android'de [AssetEntity.getMediaUrl] ExoPlayer için tercih edilir;
  /// dosya yolu tarayıcı/yedek ve "Farklı aç" için tutulur.
  Future<({File? file, Uri? uri})> _resolveMedia(AssetEntity asset) async {
    File? f;
    try {
      f = await asset.file;
      if (f != null && !await f.exists()) f = null;
    } catch (_) {
      f = null;
    }
    if (f == null) {
      try {
        f = await asset.originFile;
        if (f != null && !await f.exists()) f = null;
      } catch (_) {
        f = null;
      }
    }
    Uri? uri;
    try {
      final url = await asset.getMediaUrl();
      if (url != null && url.isNotEmpty) {
        uri = Uri.tryParse(url);
      }
    } catch (e) {
      logSwallowed('albüm: mediaUrl', e);
    }
    return (file: f, uri: uri);
  }

  // -------------------------------------------------------------------------
  // Dosya işlemleri (kopyala / taşı / sil / paylaş)
  // -------------------------------------------------------------------------

  /// Seçili varlıkların gerçek dosyalarını çözer; erişilemeyenler atlanır.
  Future<List<FileEntry>> _resolveSelectedEntries() async {
    final entries = <FileEntry>[];
    for (final asset in _selectedAssets) {
      File? file;
      try {
        file = await asset.file;
        if (file != null && !await file.exists()) file = null;
      } catch (_) {
        file = null;
      }
      if (file == null) continue;
      final sep = Platform.pathSeparator;
      final name = file.path.split(sep).last;
      entries.add(FileEntry(
        name: name,
        path: file.path,
        isDirectory: false,
        // photo_manager'ın `size` değeri pikseldir; bayt boyutu önbellekten
        // alınır (albüm açılırken arka planda çözülmüştür).
        size: MediaService.sizeOf(asset),
        modified: asset.createDateTime,
      ));
    }
    return entries;
  }

  /// Seçilenleri uygulama panosuna alır; hedef klasörde "Yapıştır" ile
  /// taşınır/kopyalanır (tarayıcı ekranındaki pan ile aynı).
  Future<void> _copyOrCut({required bool cut}) async {
    if (_working) return;
    setState(() => _working = true);
    final entries = await _resolveSelectedEntries();
    if (!mounted) return;
    setState(() => _working = false);
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dosya çözülemedi — öğeler seçilemedi')),
      );
      return;
    }
    if (cut) {
      ClipboardManager.instance.cut(entries);
    } else {
      ClipboardManager.instance.copy(entries);
    }
    setState(_selected.clear);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          cut
              ? '${entries.length} öğe taşınmak üzere alındı — hedef klasörde '
                  '"Yapıştır"a dokunun'
              : '${entries.length} öğe kopyalanmak üzere alındı — hedef '
                  'klasörde "Yapıştır"a dokunun',
        ),
      ),
    );
  }

  /// Seçili varlıkları MediaStore'dan siler (onay diyaloğu ile).
  Future<void> _deleteSelected() async {
    final ids = _selected.toList(growable: false);
    if (ids.isEmpty || _working) return;
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Sil'),
            content: Text('${ids.length} medya dosyası silinecek. '
                'Bu işlem geri alınamaz.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('İptal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Sil'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _working = true);
    final ok = await _service.deleteAssets(ids);
    if (!mounted) return;
    setState(() {
      _working = false;
      _selected.clear();
      _assets.removeWhere((a) => ids.contains(a.id));
      // Silme sonrası liste yeniden okunur (MediaStore sayaçları tazelensin).
      if (_assets.isEmpty) _hasMore = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ok ? 'Silindi: ${ids.length} öğe' : 'Silinemedi')),
    );
    if (mounted) setState(() => _visibleCache = null);
  }

  /// Seçili dosyaları sistem paylaşım sayfasıyla paylaşır.
  Future<void> _shareSelected() async {
    if (_working) return;
    setState(() => _working = true);
    final entries = await _resolveSelectedEntries();
    if (!mounted) return;
    setState(() => _working = false);
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paylaşılacak dosya çözülemedi')),
      );
      return;
    }
    setState(_selected.clear);
    await SharePlus.instance.share(
      ShareParams(files: [for (final e in entries) XFile(e.path)]),
    );
  }

  bool _progressOpen = false;

  void _showProgress() {
    if (_progressOpen || !mounted) return;
    _progressOpen = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    ).whenComplete(() => _progressOpen = false);
  }

  void _hideProgress() {
    if (!_progressOpen || !mounted) return;
    _progressOpen = false;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(_selected.clear),
              )
            : null,
        title: _selecting
            ? Text('${_selected.length} seçili')
            : (_searchActive
                ? TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Dosya ara…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() {
                      _query = v;
                      _visibleCache = null;
                    }),
                  )
                : Text(widget.title)),
        // Toplam özet: görünür öğe sayısı + toplam boyut (filtre/arama
        // uygulandığında "görünür / toplam" olarak yazılır).
        bottom: _selecting
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    _assets.isEmpty && !_hasMore
                        ? 'Öğe yok'
                        : '${_visible.length == _totalCount ? '' : '${_visible.length}/'}'
                            '$_totalCount öğe • Toplam '
                            '${Formats.size(_totalBytes)}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
        actions: _selecting
            ? [
                IconButton(
                  icon: const Icon(Icons.copy_rounded),
                  tooltip: 'Kopyala',
                  onPressed: _working ? null : () => _copyOrCut(cut: false),
                ),
                IconButton(
                  icon: const Icon(Icons.content_cut_rounded),
                  tooltip: 'Taşı',
                  onPressed: _working ? null : () => _copyOrCut(cut: true),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline_rounded),
                  tooltip: 'Sil',
                  onPressed: _working ? null : _deleteSelected,
                ),
                IconButton(
                  icon: const Icon(Icons.share_rounded),
                  tooltip: 'Paylaş',
                  onPressed: _working ? null : _shareSelected,
                ),
              ]
            : [
                IconButton(
                  icon: Icon(
                      _searchActive ? Icons.close_rounded : Icons.search),
                  tooltip: _searchActive ? 'Aramayı kapat' : 'Ara',
                  onPressed: () {
                    setState(() {
                      _searchActive = !_searchActive;
                      if (!_searchActive) {
                        _searchController.clear();
                        _query = '';
                        _visibleCache = null;
                      }
                    });
                  },
                ),
                // Sıralama menüsü (referans uygulamadaki gibi).
                PopupMenuButton<_SortMode>(
                  icon: const Icon(Icons.sort_rounded),
                  tooltip: 'Sırala',
                  onSelected: _changeSort,
                  itemBuilder: (context) => [
                    for (final mode in _SortMode.values)
                      PopupMenuItem<_SortMode>(
                        value: mode,
                        child: _MenuLabel(
                          label: mode.label,
                          selected: _sort == mode,
                        ),
                      ),
                  ],
                ),
                IconButton(
                  icon: Icon(_gridColumns >= 4
                      ? Icons.view_list_rounded
                      : Icons.grid_view_rounded),
                  tooltip: 'Izgara yoğunluğu',
                  onPressed: () {
                    setState(() {
                      _gridColumns = switch (_gridColumns) {
                        2 => 3,
                        3 => 4,
                        _ => 2,
                      };
                    });
                  },
                ),
                // Filtre menüsü: tarih aralığı + dosya türü.
                PopupMenuButton<Object>(
                  icon: Icon(
                    Icons.filter_alt_rounded,
                    color: _filtering
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  tooltip: 'Filtrele',
                  onSelected: _onFilterSelected,
                  itemBuilder: (context) => [
                    for (final f in _DateFilter.values)
                      PopupMenuItem<Object>(
                        value: f,
                        child: _MenuLabel(
                          label: f == _DateFilter.custom &&
                                  _customRange != null
                              ? 'Özel aralık: '
                                  '${_dateLabel(_customRange!.start)} – '
                                  '${_dateLabel(_customRange!.end)}'
                              : f.label,
                          selected: _dateFilter == f,
                        ),
                      ),
                    const PopupMenuDivider(),
                    PopupMenuItem<Object>(
                      enabled: false,
                      child: Text(
                        'Dosya türü',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ),
                    PopupMenuItem<Object>(
                      value: '',
                      child: _MenuLabel(
                        label: 'Tümü',
                        selected: _typeFilter.isEmpty,
                      ),
                    ),
                    for (final e in _knownExtensions())
                      PopupMenuItem<Object>(
                        value: e,
                        child: _MenuLabel(
                          label: e.toUpperCase(),
                          selected: _typeFilter == e,
                        ),
                      ),
                  ],
                ),
                PopupMenuButton<String>(
                  tooltip: 'Diğer',
                  onSelected: (value) async {
                    switch (value) {
                      case 'refresh':
                        setState(() {
                          _assets.clear();
                          _hasMore = true;
                          _loading = true;
                          _visibleCache = null;
                        });
                        MediaService.clearCache();
                        await _loadPage();
                      case 'select_all':
                        setState(() {
                          _selected
                            ..clear()
                            ..addAll(_visible.map((a) => a.id));
                        });
                      case 'settings':
                        Navigator.of(context).pushNamed('/settings');
                    }
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                        value: 'select_all', child: Text('Tümünü seç')),
                    PopupMenuItem(value: 'refresh', child: Text('Yenile')),
                    PopupMenuItem(value: 'settings', child: Text('Ayarlar')),
                  ],
                ),
              ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: _gridColumns,
                mainAxisSpacing: 4,
                crossAxisSpacing: 4,
              ),
              itemCount: _visible.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, index) {
                if (index >= _visible.length) {
                  _loadPage();
                  return const Center(
                      child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ));
                }
                final asset = _visible[index];
                final selected = _selected.contains(asset.id);
                void activate() => _selecting
                    ? _toggleSelect(asset)
                    : _openAsset(asset);
                return TvFocusable(
                  autofocus: index == 0,
                  onActivate: activate,
                  borderRadius: 6,
                  child: InkWell(
                    onTap: activate,
                    onLongPress: () => _toggleSelect(asset),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _AssetThumb(asset: asset),
                        if (_isVideoCat)
                          const Center(
                            child: Icon(Icons.play_circle_fill_rounded,
                                color: Colors.white70, size: 36),
                          )
                        else if (_isAudioCat)
                          const Center(
                            child: Icon(Icons.music_note_rounded,
                                color: Colors.white70, size: 36),
                          ),
                        if (selected)
                          Container(
                            color: Theme.of(context)
                                .colorScheme
                                .primary
                                .withValues(alpha: 0.35),
                            alignment: Alignment.topRight,
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.check_circle_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Menü satırı: seçili ise yanında ✓ bulunan etiket.
class _MenuLabel extends StatelessWidget {
  const _MenuLabel({required this.label, required this.selected});

  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (selected)
          Icon(Icons.check_rounded,
              size: 18, color: Theme.of(context).colorScheme.primary)
        else
          const SizedBox(width: 18),
        const SizedBox(width: 8),
        Text(label),
      ],
    );
  }
}

class _AssetThumb extends StatelessWidget {
  const _AssetThumb({required this.asset});

  final AssetEntity asset;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: asset.thumbnailDataWithSize(const ThumbnailSize(300, 300)),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data == null) {
          return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest);
        }
        return Image.memory(data, fit: BoxFit.cover);
      },
    );
  }
}
