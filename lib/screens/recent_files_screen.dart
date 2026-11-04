import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/file_entry.dart';
import '../providers/settings_provider.dart';
import '../services/category_size_service.dart';
import '../services/clipboard_manager.dart';
import '../services/file_service.dart';
import '../services/recycle_bin_service.dart';
import '../utils/app_paths.dart';
import '../utils/debug_log.dart';
import '../utils/formats.dart';
import '../utils/folder_watcher.dart';
import '../services/recent_seen_store.dart';
import '../utils/file_opener.dart' show kAudioExts, kImageExts, kVideoExts;
import '../widgets/tv_focusable.dart';
import 'image_viewer_screen.dart';
import 'media_viewer_screen.dart';

/// Son değiştirilen dosya.
class RecentFile {
  RecentFile({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
  });

  final String path;
  final String name;
  final int size;
  final DateTime modified;

  factory RecentFile.fromMap(Map<String, Object?> map) => RecentFile(
        path: '${map['path']}',
        name: '${map['name']}',
        size: (map['size'] as num?)?.toInt() ?? 0,
        modified: DateTime.fromMillisecondsSinceEpoch(
            (map['modified'] as num?)?.toInt() ?? 0),
      );
}

/// "Yeni Dosyalar" ekranı: son 7 günde değişen dosyalar, büyükten küçüğe.
///
/// Tarama izolatta yapılır; kullanıcı "…" yer tutucusu görür ve sonuç
/// "(Tarih • Boyut)" biçimiyle listelenir.
class RecentFilesScreen extends StatefulWidget {
  const RecentFilesScreen({super.key, this.root});

  /// Tarama kökü; verilmezse platforma göre seçilir (testlerde verilir).
  final String? root;

  @override
  State<RecentFilesScreen> createState() => _RecentFilesScreenState();
}

class _RecentFilesScreenState extends State<RecentFilesScreen>
    with WidgetsBindingObserver {
  List<RecentFile>? _files;

  /// Çoklu seçim: seçilen dosya yolları (uzun basma ile).
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;
  bool _working = false;

  /// Listelenen dosyaların toplam boyutu (özet satırı için).
  int get _totalBytes =>
      (_files ?? const <RecentFile>[])
          .fold<int>(0, (sum, f) => sum + f.size);

  /// Kullanıcı listeyi "Temizle" ile boşalttı mı?
  ///
  /// Tarama gerçekten boş döndüğü ile kullanıcının temizlediği ayrı mesajlar
  /// gösterir; dosyalar hiçbir durumda silinmez.
  bool _cleared = false;

  /// Canlı izleme: sıcak klasörler + debounce (F Dosya Yöneticisi hissi).
  late final FolderWatcher _watcher = FolderWatcher(
    onChanged: _onStorageChanged,
    // Tam cihaz taraması ağır; biraz daha birleştirerek çift tarama önlenir.
    debounce: const Duration(milliseconds: 900),
    settleFollowUp: const Duration(milliseconds: 1800),
    pollInterval: const Duration(seconds: 4),
  );

  int _loadGen = 0;
  bool _sizesDirty = false;
  Timer? _sizeRefreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
    _startWatching();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watcher.dispose();
    _sizeRefreshTimer?.cancel();
    if (_sizesDirty) {
      unawaited(CategorySizeService.invalidate());
    }
    super.dispose();
  }

  /// Uygulama öne çıkınca tarama yenilenir: kullanıcı buradan başka bir
  /// ekranı (dosya düzenleyici vb.) açıp dosyayı silebilir ya da
  /// değiştirebilir; liste eski boyutu göstermeye devam etmemeli.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(_load(preserveSelection: true));
    }
  }

  String get _scanRoot =>
      widget.root ?? AppPaths.scanRoot;

  void _startWatching() {
    final root = _scanRoot;
    final sep = Platform.pathSeparator;
    // Yeni dosyaların çoğu bu klasörlere düşer; kökün tamamını recursive
    // izlemek pahalı ve gürültülüdür.
    const hot = [
      'Download',
      'Downloads',
      'Documents',
      'DCIM',
      'Pictures',
      'Movies',
      'Music',
      'WhatsApp',
      'Telegram',
    ];
    final paths = <String>[
      for (final name in hot)
        if (Directory('$root$sep$name').existsSync()) '$root$sep$name',
    ];
    // Test / özel kök: sıcak klasör yoksa kökü izle.
    if (paths.isEmpty) paths.add(root);
    _watcher.start(paths, recursive: true);
  }

  void _onStorageChanged() {
    if (!mounted || _working) return;
    unawaited(_load(preserveSelection: true));
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

  Future<void> _load({bool preserveSelection = false}) async {
    final root = _scanRoot;
    final gen = ++_loadGen;

    // İzolat, kapanış (closure) gönderilmeden başlatılır: test/sanal alan
    // gibi özel Zone'larda `Isolate.run` gönderilemez nesne hatası verir.
    final port = ReceivePort();
    try {
      await Isolate.spawn(
        _scanIsolateEntry,
        _ScanRequest(root: root, limit: 500, reply: port.sendPort),
      );
      final raw = await port.first as List<Map<String, Object?>>;
      if (!mounted || gen != _loadGen) return;
      final scanned = raw.map(RecentFile.fromMap).toList();
      // Geçmişi temizlenenler ("okunmuş") tekrar listelenmez — e-posta
      // okundu/okunmadı mantığı. Yalnızca sonradan eklenen/değişen dosyalar
      // burada kalır.
      final seen = await RecentSeenStore.load();
      if (!mounted || gen != _loadGen) return;
      final files = scanned
          .where((f) =>
              !seen.contains(RecentSeenStore.keyOf(f.path, f.modified)))
          .toList(growable: false);
      final keep = preserveSelection
          ? _selected.intersection({for (final f in files) f.path})
          : <String>{};
      setState(() {
        _files = files;
        if (preserveSelection) {
          _selected
            ..clear()
            ..addAll(keep);
        } else {
          // Seçim, taze listeyle tutarsız kalmasın diye sıfırlanır.
          _selected.clear();
        }
        // `_cleared` bilinçli olarak SIFIRLANMAZ: aşağı kaydırmak taramayı
        // yeniler ama geçmişi geri getirmez; "Tüm geçmişi tekrar göster"
        // düğmesi bu yüzden yenilemeden sonra da ekranda kalır.
      });
    } catch (_) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _files = const []);
    } finally {
      port.close();
    }
  }

  /// Temizle butonu: tek dokunuşla listeyi boşaltır.
  ///
  /// **Dosyalar silinmez** — yalnızca o an listelenenler "görüldü" olarak
  /// işaretlenir ve bir daha listelenmez. Cihaza sonradan eklenen (ya da
  /// değiştirilen) dosyalar yine burada belirir. Onay diyaloğu yoktur:
  /// işlem geri alınamaz bir veri kaybı değildir.
  Future<void> _clearList() async {
    await RecentSeenStore.markSeen(
      (_files ?? const <RecentFile>[])
          .map((f) => RecentSeenStore.keyOf(f.path, f.modified)),
    );
    if (!mounted) return;
    setState(() {
      _files = const [];
      _cleared = true;
      _selected.clear();
    });
    // "Temizleme" yalnız listeyi boşaltır ama Ana Sayfa'daki "Yeni Dosyalar"
    // kartındaki boyutun da bunu izlemesi gerekir: invalidate önbelleği
    // silip kendiliğinden taze hesap da tetikler.
    await CategorySizeService.invalidate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Liste temizlendi — dosyalarınız silinmedi')),
    );
  }

  /// "Tüm geçmişi tekrar göster": temizleme ("görüldü") işaretlerini siler ve
  /// listeyi geri getirir.
  ///
  /// Dosyalara yine dokunulmaz; yalnızca okundu işareti kalkar. Aşağı
  /// kaydırmak bunu yapmaz — o yalnızca taramayı yeniler (yeni/değişen
  /// dosyalar gelir, temizlenenler gelmez).
  Future<void> _restoreHistory() async {
    await RecentSeenStore.forgetAll();
    if (!mounted) return;
    // Geçmiş geri geldi: Ana Sayfa'daki "Yeni Dosyalar" boyutu da tazelenir.
    await CategorySizeService.invalidate();
    if (!mounted) return;
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    final hasFiles = files != null && files.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => setState(_selected.clear),
              )
            : null,
        title: Text(_selecting ? '${_selected.length} seçili' : 'Yeni Dosyalar'),
        // Toplam özet: listedeki dosya sayısı + toplam boyut.
        bottom: (_selecting || !hasFiles)
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(22),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '${files.length} dosya • Toplam ${Formats.size(_totalBytes)}',
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
                // Dar ekranda taşmayı önlemek için kalan işlemler menüde.
                PopupMenuButton<String>(
                  tooltip: 'Daha fazla',
                  enabled: !_working,
                  onSelected: (value) {
                    switch (value) {
                      case 'share':
                        _shareSelected();
                      case 'rename':
                        _renameSelected();
                      case 'info':
                        _showInfoSelected();
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                        value: 'share', child: Text('Paylaş')),
                    PopupMenuItem(
                      value: 'rename',
                      enabled: _selected.length == 1,
                      child: const Text('Yeniden adlandır'),
                    ),
                    PopupMenuItem(
                      value: 'info',
                      enabled: _selected.length == 1,
                      child: const Text('Bilgi'),
                    ),
                  ],
                ),
              ]
            : [
                // Yalnızca liste doluyken anlamlı; dosyalara dokunulmaz.
                if (hasFiles)
                  IconButton(
                    icon: const Icon(Icons.cleaning_services_rounded),
                    tooltip: 'Temizle',
                    onPressed: _clearList,
                  ),
              ],
      ),
      body: files == null
          ? const Center(child: CircularProgressIndicator())
          : hasFiles
              ? RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    physics: const AlwaysScrollableScrollPhysics(),
                    itemCount: files.length,
                    itemBuilder: (context, index) =>
                        _row(context, files[index], autofocus: index == 0),
                  ),
                )
              : _emptyState(),
    );
  }

  // -------------------------------------------------------------------------
  // Dosya işlemleri (kopyala / taşı / sil / paylaş)
  // -------------------------------------------------------------------------

  /// Seçili dosyalar için tarayıcıyla aynı [FileEntry] biçimini üretir.
  List<FileEntry> get _selectedEntries => (_files ?? const <RecentFile>[])
      .where((f) => _selected.contains(f.path))
      .map((f) => FileEntry(
            name: f.name,
            path: f.path,
            isDirectory: false,
            size: f.size,
            modified: f.modified,
          ))
      .toList(growable: false);

  /// Seçilenleri uygulama panosuna alır; hedef klasörde "Yapıştır" ile
  /// taşınır/kopyalanır.
  Future<void> _copyOrCut({required bool cut}) async {
    final entries = _selectedEntries;
    if (entries.isEmpty) return;
    if (cut) {
      ClipboardManager.instance.cut(entries);
    } else {
      ClipboardManager.instance.copy(entries);
    }
    if (!mounted) return;
    setState(_selected.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${entries.length} öğe ${cut ? 'taşınmak' : 'kopyalanmak'} üzere '
          'alındı — hedef klasörde "Yapıştır"a dokunun',
        ),
      ),
    );
  }

  /// Seçili dosyaları geri dönüşüm kutusuna taşır ya da kalıcı siler.
  Future<void> _deleteSelected() async {
    final entries = _selectedEntries;
    if (entries.isEmpty || _working) return;
    final useBin = _recycleBinEnabled();
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(useBin ? 'Geri dönüşüm kutusuna taşı' : 'Kalıcı sil'),
            content: Text('${entries.length} dosya '
                '${useBin ? 'geri dönüşüm kutusuna taşınacak' : 'kalıcı olarak silinecek'}.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('İptal'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(useBin ? 'Taşı' : 'Sil'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _working = true);
    if (useBin) {
      // Manifest mevcut kutu içeriğiyle birleştirilmeli (yoksa ezilirdi).
      await RecycleBinService.instance.load();
    }
    var done = 0;
    for (final entry in entries) {
      try {
        if (useBin) {
          await RecycleBinService.instance.moveToRecycle(entry);
        } else {
          await const FileService().deleteEntry(entry.path);
        }
        done++;
      } catch (e) {
        logSwallowed('yeni dosyalar: silme', e);
      }
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _selected.clear();
      _files = (_files ?? const <RecentFile>[])
          .where((f) => !entries.any((e) => e.path == f.path))
          .toList(growable: false);
    });
    // Ana Sayfa'daki "Yeni Dosyalar" boyutu silinen dosyaları izlemeli.
    await CategorySizeService.invalidate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$done dosya ${useBin ? 'geri dönüşüm kutusuna taşındı' : 'silindi'}')),
    );
  }

  /// Seçili dosyaları sistem paylaşım sayfasıyla paylaşır.
  Future<void> _shareSelected() async {
    final entries = _selectedEntries;
    if (entries.isEmpty) return;
    setState(_selected.clear);
    await SharePlus.instance.share(
      ShareParams(files: [for (final e in entries) XFile(e.path)]),
    );
  }

  /// Tek dosyayı yeniden adlandırır ("Düzelt"); liste ve kategori boyutları
  /// işlem sonunda tazelenir.
  Future<void> _renameSelected() async {
    final entries = _selectedEntries;
    if (entries.length != 1) return;
    final entry = entries.first;
    final controller = TextEditingController(text: entry.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeniden adlandır'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Yeni ad'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == entry.name) return;
    try {
      await const FileService().rename(entry.path, newName);
    } catch (e) {
      logSwallowed('yeni dosyalar: yeniden adlandırma', e);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Yeniden adlandırılamadı: $e')));
      }
      return;
    }
    if (!mounted) return;
    setState(_selected.clear);
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Yeniden adlandırıldı: $newName')));
  }

  /// Tek dosyanın bilgi diyaloğu (boyut, tarih, konum).
  void _showInfoSelected() {
    final entries = _selectedEntries;
    if (entries.length != 1) return;
    final entry = entries.first;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.name, maxLines: 2, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Boyut: ${Formats.size(entry.size)}'),
            Text('Değiştirilme: ${Formats.date(entry.modified)}'),
            const SizedBox(height: 8),
            SelectableText('Konum: ${entry.path}'),
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

  /// Ayarlar okunabilirse geri dönüşüm tercihi, değilse varsayılan (kutu).
  ///
  /// Ekran testlerinde Provider atası bulunmayabilir; bu durumda sessizce
  /// varsayılana düşülür.
  bool _recycleBinEnabled() {
    try {
      return context.read<SettingsProvider>().recycleBinDefault;
    } catch (_) {
      return true;
    }
  }

  void _toggleSelect(RecentFile f) {
    setState(() {
      if (!_selected.remove(f.path)) _selected.add(f.path);
    });
  }

  /// Liste boşken: kaydırarak yenilemeye izin veren kaydırılabilir boş ekran.
  ///
  /// Temizleme sonrası (`_cleared`) "Tüm geçmişi tekrar göster" düğmesi de
  /// çıkar; aşağı kaydırmak bunu **yapmaz**. İkisi ayrıdır:
  ///
  /// * **Aşağı kaydırma** → tarama yenilenir; yalnızca sonradan eklenen ya da
  ///   değiştirilen dosyalar gelir, temizlenenler gelmez.
  /// * **Düğme** → `RecentSeenStore.forgetAll` ile okundu işaretleri silinir,
  ///   liste baştan dolar.
  Widget _emptyState() {
    final message = _cleared
        ? 'Geçmişiniz temizlendi.\n'
            'Cihaza eklenen yeni dosyalar burada belirir.'
        : 'Son 7 günde değişen yeni dosya yok.\n'
            'Cihaza yeni dosya eklendiğinde burada görünecek.';
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(height: MediaQuery.sizeOf(context).height * 0.2),
          Text(
            message,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.outline,
                  height: 1.5,
                ),
          ),
          if (_cleared) ...[
            const SizedBox(height: 20),
            Center(
              child: OutlinedButton.icon(
                onPressed: _restoreHistory,
                icon: const Icon(Icons.history_rounded),
                label: const Text('Tüm geçmişi tekrar göster'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, RecentFile f, {bool autofocus = false}) {
    final ext =
        f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
    final icon = switch (ext) {
      _ when kImageExts.contains(ext) => Icons.image_rounded,
      _ when kVideoExts.contains(ext) => Icons.video_file_rounded,
      _ when kAudioExts.contains(ext) => Icons.audio_file_rounded,
      'apk' => Icons.android_rounded,
      'pdf' => Icons.picture_as_pdf_rounded,
      'zip' ||
      'rar' ||
      '7z' =>
        Icons.folder_zip_rounded,
      _ => Icons.insert_drive_file_rounded,
    };
    final selected = _selected.contains(f.path);
    void activate() => _selecting ? _toggleSelect(f) : _open(f);
    return TvFocusable(
      autofocus: autofocus,
      onActivate: activate,
      scale: 1.02,
      child: ListTile(
        selected: selected,
        selectedTileColor:
            Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
        leading: Icon(icon, size: 32, color: const Color(0xFF00897B)),
        title: Text(f.name, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '(${Formats.date(f.modified)} • ${Formats.size(f.size)})',
          maxLines: 1,
        ),
        trailing: _selecting
            ? Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              )
            : null,
        onTap: activate,
        onLongPress: () => _toggleSelect(f),
      ),
    );
  }

  /// Desteklenen türde önizleme; desteklenmeyen türde bilgi diyaloğu.
  ///
  /// Görüntüleyiciden **dönünce liste yeniden taranır**: kullanıcı içerik
  /// ekranından dosyayı silebilir ya da değiştirebilir (boyut 0 B / yeni
  /// boyut olur); liste bayat değeri göstermeye devam etmemeli.
  Future<void> _open(RecentFile f) async {
    final ext =
        f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
    final file = File(f.path);
    if (kImageExts.contains(ext)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => ImageViewerScreen(file: file, title: f.name)),
      );
    } else if (kVideoExts.contains(ext)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => MediaViewerScreen(file: file, isVideo: true)),
      );
    } else if (kAudioExts.contains(ext)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => MediaViewerScreen(file: file, isVideo: false)),
      );
    } else {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(f.name, maxLines: 2, overflow: TextOverflow.ellipsis),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Boyut: ${Formats.size(f.size)}'),
              Text('Değiştirilme: ${Formats.date(f.modified)}'),
              const SizedBox(height: 8),
              SelectableText('Konum: ${f.path}'),
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
    // Görünürken silinmiş/değiştirilmiş dosyalar için taze liste.
    if (mounted) await _load();
  }
}

/// İzolata gönderilecek tarama isteği (yalnızca gönderilebilir alanlar).
class _ScanRequest {
  const _ScanRequest({
    required this.root,
    required this.limit,
    required this.reply,
  });

  final String root;
  final int limit;
  final SendPort reply;
}

/// İzolat giriş noktası: kapanış yerine üst düzey fonksiyon kullanılır.
void _scanIsolateEntry(_ScanRequest req) {
  try {
    req.reply
        .send(_scanRecent(req.root, limit: req.limit, maxEntries: 60000));
  } catch (_) {
    req.reply.send(const <Map<String, Object?>>[]);
  }
}

/// İzolat içinde çalışan tarama: son 7 günde değişen dosyalar.
List<Map<String, Object?>> _scanRecent(String root,
    {int limit = 500, int maxEntries = 60000}) {
  final cutoff = DateTime.now().subtract(const Duration(days: 7));
  final found = <Map<String, Object?>>[];
  var visited = 0;
  final stack = <String>[root];
  while (stack.isNotEmpty && visited < maxEntries) {
    final path = stack.removeLast();
    List<FileSystemEntity> items;
    try {
      items = Directory(path).listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in items) {
      if (++visited >= maxEntries) break;
      if (e is Directory) {
        // uri.pathSegments.last dizinlerde boş döner; ad yoldan alınır.
        final name = _nameOf(e.path);
        if (name.isEmpty || name.startsWith('.')) continue;
        if (name == 'Android' || name == 'LOST.DIR') continue;
        stack.add(e.path);
      } else if (e is File) {
        try {
          final stat = e.statSync();
          if (!stat.modified.isAfter(cutoff)) continue;
          found.add({
            'path': e.path,
            'name': _nameOf(e.path),
            'size': stat.size,
            'modified': stat.modified.millisecondsSinceEpoch,
          });
        } catch (e) {
          logSwallowed('son dosyalar: stat', e);
        }
      }
    }
  }
  found.sort((a, b) => (b['modified'] as num).compareTo(a['modified'] as num));
  return found.length > limit ? found.sublist(0, limit) : found;
}

/// Yolun son ögesi (dosya/dizin adı); ayraç farklarını yutar.
String _nameOf(String path) {
  final sep = Platform.pathSeparator;
  final normalized = sep == '/' ? path : path.replaceAll('/', sep);
  final parts = normalized.split(sep);
  for (var i = parts.length - 1; i >= 0; i--) {
    if (parts[i].isNotEmpty) return parts[i];
  }
  return '';
}
