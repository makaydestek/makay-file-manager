import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/media_service.dart';
import '../widgets/app_drawer.dart';
import '../widgets/tv_focusable.dart';
import 'album_screen.dart';

/// Kategori ekranı: albüm ızgarası (Görüntüler/Videolar) veya listesi (Ses).
///
/// Referans uygulamadaki "Görüntüler" ve "Videolar" ekranlarının karşılığı.
/// AppBar: Ara / Sırala / Izgara-Liste / ⋮ (F Dosya Yöneticisi tarzı).
class MediaCategoryScreen extends StatefulWidget {
  const MediaCategoryScreen({
    super.key,
    required this.categoryId,
    required this.title,
  });

  final String categoryId; // images / videos / audio
  final String title;

  @override
  State<MediaCategoryScreen> createState() => _MediaCategoryScreenState();
}

enum _AlbumSort {
  nameAsc('Ada göre (A → Z)'),
  nameDesc('Ada göre (Z → A)'),
  countDesc('Adet (Çok → Az)'),
  countAsc('Adet (Az → Çok)');

  const _AlbumSort(this.label);
  final String label;
}

class _MediaCategoryScreenState extends State<MediaCategoryScreen> {
  static const _service = MediaService();

  final _scaffoldKey = GlobalKey<ScaffoldState>();
  final _searchController = TextEditingController();

  List<MediaAlbum>? _albums;
  bool _denied = false;
  bool _searchActive = false;
  String _query = '';
  _AlbumSort _sort = _AlbumSort.nameAsc;
  /// Görüntü/video varsayılanı ızgara; ses her zaman liste.
  late bool _grid = widget.categoryId != 'audio';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool fresh = false}) async {
    final allowed = await _service.ensurePermission();
    if (!allowed) {
      if (mounted) setState(() => _denied = true);
      return;
    }
    // Aşağı kaydırmada önbellekler tazelenir: MediaStore'a sonradan eklenen
    // dosyalar, değişen adetler ve "Tüm Dosyalar" adı böylece yansır.
    // Albümden dönüldüğünde önbellek korunur (silme işleminde servis kendi
    // kayıtlarını zaten temizler) — liste taraması tekrarlanmaz.
    if (fresh) MediaService.clearCache();
    final albums = await _service.albums(widget.categoryId);
    if (!mounted) return;
    setState(() => _albums = albums);
  }

  List<MediaAlbum> get _visible {
    var list = List<MediaAlbum>.of(_albums ?? const []);
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((a) => a.name.toLowerCase().contains(q)).toList();
    }
    switch (_sort) {
      case _AlbumSort.nameAsc:
        list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      case _AlbumSort.nameDesc:
        list.sort((a, b) => b.name.toLowerCase().compareTo(a.name.toLowerCase()));
      case _AlbumSort.countDesc:
        list.sort((a, b) => b.count.compareTo(a.count));
      case _AlbumSort.countAsc:
        list.sort((a, b) => a.count.compareTo(b.count));
    }
    return list;
  }

  void _pickSort() {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final mode in _AlbumSort.values)
              ListTile(
                title: Text(mode.label),
                trailing: _sort == mode
                    ? Icon(Icons.check_rounded,
                        color: Theme.of(context).colorScheme.primary)
                    : null,
                onTap: () {
                  Navigator.pop(context);
                  setState(() => _sort = mode);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final albums = _albums;
    return Scaffold(
      key: _scaffoldKey,
      drawer: const AppDrawer(),
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.menu_rounded),
          tooltip: 'Menü',
          onPressed: () => _scaffoldKey.currentState?.openDrawer(),
        ),
        title: _searchActive
            ? TextField(
                controller: _searchController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Albüm ara…',
                  border: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _query = v),
              )
            : Text(widget.title),
        actions: [
          IconButton(
            icon: Icon(_searchActive ? Icons.close_rounded : Icons.search),
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
            tooltip: 'Sırala',
            onPressed: _pickSort,
          ),
          if (widget.categoryId != 'audio')
            IconButton(
              icon: Icon(
                _grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
              ),
              tooltip: _grid ? 'Liste görünümü' : 'Izgara görünümü',
              onPressed: () => setState(() => _grid = !_grid),
            ),
          PopupMenuButton<String>(
            tooltip: 'Diğer',
            onSelected: (value) {
              switch (value) {
                case 'refresh':
                  _load(fresh: true);
                case 'settings':
                  Navigator.of(context).pushNamed('/settings');
                case 'home':
                  Navigator.of(context).popUntil((r) => r.isFirst);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'refresh', child: Text('Yenile')),
              PopupMenuItem(value: 'settings', child: Text('Ayarlar')),
              PopupMenuItem(value: 'home', child: Text('Ana ekran')),
            ],
          ),
        ],
      ),
      body: _denied
          ? _PermissionBody(onRetry: () {
              setState(() => _denied = false);
              _load();
            })
          : albums == null
              ? const Center(child: CircularProgressIndicator())
              : albums.isEmpty
                  ? const Center(child: Text('Öğe bulunamadı'))
                  : RefreshIndicator(
                      // Aşağı kaydırma: önbelleklerle birlikte tam yenileme.
                      onRefresh: () => _load(fresh: true),
                      child: _visible.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 120),
                                Center(child: Text('Eşleşen albüm yok')),
                              ],
                            )
                          : _grid
                              ? _albumGrid()
                              : _audioList(),
                    ),
    );
  }

  /// Liste görünümü (ses varsayılanı; görüntü/videoda da kullanılabilir).
  Widget _audioList() {
    final albums = _visible;
    return ListView.builder(
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return TvFocusable(
          autofocus: index == 0,
          onActivate: () => _openAlbum(album),
          scale: 1.02,
          child: ListTile(
            leading: _AlbumThumb(
              album: album,
              categoryId: widget.categoryId,
              size: 56,
              rounded: 4,
            ),
            title: Text(album.name),
            trailing: Text('(${album.count})'),
            onTap: () => _openAlbum(album),
          ),
        );
      },
    );
  }

  /// Görüntüler/Videolar: kare ızgara — referans "Görüntüler" ekranı.
  Widget _albumGrid() {
    final albums = _visible;
    return GridView.builder(
      padding: const EdgeInsets.all(8),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 0.78,
      ),
      itemCount: albums.length,
      itemBuilder: (context, index) {
        final album = albums[index];
        return TvFocusable(
          autofocus: index == 0,
          onActivate: () => _openAlbum(album),
          borderRadius: 8,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openAlbum(album),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _AlbumThumb(
                          album: album,
                          categoryId: widget.categoryId,
                          size: 300,
                        ),
                        if (widget.categoryId == 'videos')
                          const Center(
                            child: Icon(Icons.play_circle_fill_rounded,
                                color: Colors.white70, size: 42),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '${album.name} (${album.count})',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openAlbum(MediaAlbum album) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AlbumScreen(
          albumId: album.id,
          title: album.name,
          categoryId: widget.categoryId,
          isVideo: widget.categoryId == 'videos',
        ),
      ),
    );
    // Albümde silme/kopyalama yapılmış olabilir: adetler ve kapaklar
    // tazelensin (üstelik "Tüm Dosyalar" adı da yeniden adlandırılır).
    if (mounted) _load();
  }
}

/// Albüm küçük resmi; alınamazsa tür ikonu gösterir.
class _AlbumThumb extends StatelessWidget {
  const _AlbumThumb({
    required this.album,
    required this.categoryId,
    required this.size,
    this.rounded = 8,
  });

  final MediaAlbum album;

  /// Küçük resmin ait olduğu kategori (karışık albümlerde kapak da süzülür).
  final String categoryId;
  final double size;
  final double rounded;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _thumbFuture(album, categoryId),
      builder: (context, snapshot) {
        final data = snapshot.data;
        if (data != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(rounded),
            child: Image.memory(data, fit: BoxFit.cover),
          );
        }
        final fallback = switch (categoryId) {
          'videos' => Icons.videocam_rounded,
          'audio' => Icons.audiotrack_rounded,
          _ => Icons.photo_rounded,
        };
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(rounded),
          ),
          child: Icon(fallback, size: 28),
        );
      },
    );
  }

  static Future<Uint8List?> _thumbFuture(MediaAlbum album, String categoryId) {
    final cacheKey = '$categoryId|${album.id}';
    final cached = MediaService.cachedThumb(cacheKey);
    if (cached != null) return Future.value(cached);
    return () async {
      final allowed = await const MediaService().ensurePermission();
      if (!allowed) return null;
      final assets = await const MediaService()
          .assets(album.id, categoryId: categoryId, size: 1);
      if (assets.isEmpty) return null;
      final data = await const MediaService().thumbnail(assets.first);
      MediaService.cacheThumb(cacheKey, data);
      return data;
    }();
  }
}

class _PermissionBody extends StatelessWidget {
  const _PermissionBody({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.perm_media_rounded, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              'Medya dosyalarına erişim izni gerekli.\n'
              'Görüntüler, videolar ve ses dosyalarını göstermek için '
              'izin verin.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('İzin ver')),
          ],
        ),
      ),
    );
  }
}
