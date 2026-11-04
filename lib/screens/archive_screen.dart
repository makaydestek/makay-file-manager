import 'dart:io';

import 'package:archive/archive.dart' show ArchiveException;
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../services/archive_service.dart';
import '../services/transfer.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../widgets/tv_focusable.dart';
import 'image_viewer_screen.dart';
import 'text_editor_screen.dart';

/// Dosya türüne göre önizleme destekli uzantılar (arşiv içi dosyalar için).
const _kImageExts = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic', 'heif', 'tif',
  'tiff'
};
const _kTextExts = {
  'txt', 'md', 'log', 'csv', 'json', 'xml', 'yaml', 'yml', 'ini', 'conf',
  'cfg', 'toml', 'html', 'css', 'js', 'dart', 'kt', 'java', 'py', 'sh', 'bat',
  'gradle', 'properties', 'env', 'srt', 'vtt'
};

/// Arşiv görüntüleyici ekranı: arşiv içinde klasör ağacına gezinme,
/// tekil/tüm çıkarma ve arşiv bilgileri.
///
/// Ekran bir arşiv dosyasıyla açılır; `Navigator.push(MaterialPageRoute(...))`
/// ile kullanılır.
class ArchiveScreen extends StatefulWidget {
  const ArchiveScreen({super.key, required this.archivePath});

  /// Açılacak arşiv dosyasının yolu.
  final String archivePath;

  @override
  State<ArchiveScreen> createState() => _ArchiveScreenState();
}

class _ArchiveScreenState extends State<ArchiveScreen> {
  static const _service = ArchiveService();

  List<ArchiveEntryInfo> _entries = [];
  String _currentPath = '';
  bool _loading = true;
  String? _error;
  bool _working = false;
  String? _password;

  String get _fileName =>
      widget.archivePath.split(Platform.pathSeparator).last;

  /// Gerçek (sentetik olmayan) girdiler.
  List<ArchiveEntryInfo> get _realEntries =>
      _entries.where((e) => !e.isVirtual).toList();

  int get _totalSize => _realEntries.fold(
      0, (sum, e) => e.isDirectory ? sum : sum + e.uncompressedSize);

  int get _fileCount => _realEntries.where((e) => !e.isDirectory).length;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<String?> _askPassword() async {
    final c = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Şifreli arşiv'),
        content: TextField(
          controller: c,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Şifre',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text),
            child: const Text('Aç'),
          ),
        ],
      ),
    );
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service.listEntries(
        widget.archivePath,
        password: _password,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _currentPath = '';
        _loading = false;
      });
    } catch (err) {
      if (!mounted) return;
      if (ArchiveService.isPasswordError(err) ||
          (err is ArchiveException &&
              err.message.toLowerCase().contains('password'))) {
        final pw = await _askPassword();
        if (pw != null && pw.isNotEmpty && mounted) {
          setState(() => _password = pw);
          await _load();
          return;
        }
      }
      if (!mounted) return;
      setState(() {
        _error = err is ArchiveServiceException
            ? err.message
            : 'Arşiv okunamadı. Dosya bozuk, şifreli ya da desteklenmeyen '
                'bir formatta olabilir.';
        _loading = false;
      });
    }
  }

  /// Bulunulan klasörün altındaki girdiler (klasörler önce, A-Z).
  List<ArchiveEntryInfo> get _children {
    final list =
        _entries.where((e) => e.parentPath == _currentPath).toList();
    int compare(ArchiveEntryInfo a, ArchiveEntryInfo b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.baseName.toLowerCase().compareTo(b.baseName.toLowerCase());
    }

    return list..sort(compare);
  }

  int _childCountOf(String folder) =>
      _entries.where((e) => e.parentPath == folder).length;

  // -------------------------------------------------------------------------
  // Çıkarıcılar
  // -------------------------------------------------------------------------

  /// "Tümünü çıkar": arşiv, arşivin yanındaki aynı adlı klasöre çıkarılır;
  /// ilerleme çubuklu bir diyalog gösterilir.
  Future<void> _extractAll() async {
    if (_working) return;
    final destDir = ArchiveService.uniquePath(
        ArchiveService.defaultExtractDirFor(widget.archivePath));
    final total = _realEntries.length;
    final progress = ValueNotifier<double>(0);
    final progressText = ValueNotifier<String>('0 / $total');
    final cancelToken = CancelToken();
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: const Text('Çıkarılıyor…'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ValueListenableBuilder<double>(
                valueListenable: progress,
                builder: (context, value, _) => LinearProgressIndicator(
                  value: total == 0 ? null : value,
                ),
              ),
              const SizedBox(height: 12),
              ValueListenableBuilder<String>(
                valueListenable: progressText,
                builder: (context, value, _) => Text(value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => cancelToken.cancel(),
              child: const Text('İptal'),
            ),
          ],
        ),
      ),
    );
    setState(() => _working = true);
    var written = 0;
    try {
      written = await _service.extractAll(
        archivePath: widget.archivePath,
        destDir: destDir,
        totalEntries: total,
        cancelToken: cancelToken,
        password: _password,
        onProgress: (done, count) {
          progress.value = count > 0 ? done / count : 0;
          progressText.value = count > 0 ? '$done / $count' : '$done';
        },
      );
    } on TransferCancelled {
      if (!mounted) return;
      Navigator.of(context).pop();
      setState(() => _working = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Çıkarma iptal edildi — kısmi dosyalar temizlendi'),
        ),
      );
      return;
    } catch (err) {
      if (!mounted) return;
      Navigator.of(context).pop(); // İlerleme diyaloğu.
      setState(() => _working = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageOf(err, 'Çıkarılamadı'))),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(); // İlerleme diyaloğu.
    setState(() => _working = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
            'Çıkarıldı: $written dosya • ${Formats.size(_totalSize)}\n'
            'Konum: $destDir'),
      ),
    );
  }

  /// Tek girdiyi (klasör ise alt ağacıyla) arşivin yanındaki aynı adlı
  /// klasöre çıkarır.
  Future<void> _extractHere(ArchiveEntryInfo entry) async {
    final destDir = ArchiveService.uniquePath(
        ArchiveService.defaultExtractDirFor(widget.archivePath));
    setState(() => _working = true);
    try {
      await _service.extractEntry(
        archivePath: widget.archivePath,
        entryName: entry.name,
        destDir: destDir,
        password: _password,
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageOf(err, 'Çıkarılamadı'))),
      );
      return;
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Çıkarıldı: ${entry.baseName}\nKonum: $destDir'),
      ),
    );
  }

  /// Girdiyi geçici klasöre çıkarır ve dönen dosyaları verir.
  Future<List<File>> _extractToTemp(ArchiveEntryInfo entry) async {
    final tempDir = await Directory.systemTemp.createTemp('makay_arsiv_');
    await _service.extractEntry(
      archivePath: widget.archivePath,
      entryName: entry.name,
      destDir: tempDir.path,
      password: _password,
    );
    final target = File(
        '${tempDir.path}${Platform.pathSeparator}'
        '${entry.name.replaceAll('/', Platform.pathSeparator)}');
    if (target.existsSync()) return [target];
    final dir = Directory(target.path);
    if (dir.existsSync()) {
      return dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .toList();
    }
    return const [];
  }

  /// "Dışa aktar / Paylaş": girdi geçici klasöre çıkarılıp sistem paylaşım
  /// sayfasıyla gönderilir.
  Future<void> _shareEntry(ArchiveEntryInfo entry) async {
    setState(() => _working = true);
    List<File> files;
    try {
      files = await _extractToTemp(entry);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageOf(err, 'Paylaşılamadı'))),
      );
      return;
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (files.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paylaşılacak dosya bulunamadı')),
      );
      return;
    }
    await SharePlus.instance.share(
      ShareParams(files: [for (final f in files) XFile(f.path)]),
    );
  }

  /// Dosyaya dokunulunca çıkarılır ve destekleniyorsa önizleme açılır.
  Future<void> _openEntry(ArchiveEntryInfo entry) async {
    setState(() => _working = true);
    List<File> files;
    try {
      files = await _extractToTemp(entry);
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageOf(err, 'Açılamadı'))),
      );
      return;
    } finally {
      if (mounted) setState(() => _working = false);
    }
    if (files.isEmpty || !mounted) return;
    final file = files.first;
    final dot = entry.baseName.lastIndexOf('.');
    final ext =
        dot > 0 ? entry.baseName.substring(dot + 1).toLowerCase() : '';
    if (_kImageExts.contains(ext)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ImageViewerScreen(file: file, title: entry.baseName),
        ),
      );
    } else if (_kTextExts.contains(ext)) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              TextEditorScreen(file: file, title: entry.baseName),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Önizleme desteklenmiyor. Dosya çıkarıldı:\n${file.path}'),
        ),
      );
    }
  }

  // -------------------------------------------------------------------------
  // Diyaloglar ve menüler
  // -------------------------------------------------------------------------

  void _showEntryInfo(ArchiveEntryInfo entry) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(entry.baseName, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tür: ${entry.isDirectory ? 'Klasör' : 'Dosya'}'),
            Text('Boyut: ${Formats.size(entry.uncompressedSize)}'),
            if (!entry.isDirectory &&
                entry.compressedSize != entry.uncompressedSize)
              Text('Sıkıştırılmış: ${Formats.size(entry.compressedSize)}'),
            if (entry.modificationTime != null)
              Text('Değiştirilme: '
                  '${Formats.date(entry.modificationTime!)}'),
            const SizedBox(height: 8),
            SelectableText('Yol: ${entry.name}'),
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

  void _showArchiveInfo() {
    final format = ArchiveService.formatName(widget.archivePath) ?? 'Bilinmiyor';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Format: $format'),
            Text('Girdi sayısı: ${_realEntries.length}'),
            Text('Dosya sayısı: $_fileCount'),
            Text('Toplam boyut: ${Formats.size(_totalSize)}'),
            const SizedBox(height: 8),
            SelectableText('Konum: ${widget.archivePath}'),
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

  void _entryMenu(ArchiveEntryInfo entry) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.info_outline_rounded),
              title:
                  Text(entry.baseName, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Bilgi'),
              onTap: () {
                Navigator.pop(context);
                _showEntryInfo(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_for_offline_outlined),
              title: const Text('Buraya çıkar'),
              subtitle: const Text('Arşivin yanındaki aynı adlı klasöre'),
              onTap: () {
                Navigator.pop(context);
                _extractHere(entry);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_rounded),
              title: const Text('Dışa aktar / Paylaş'),
              subtitle: const Text('Geçici klasöre çıkarıp paylaş'),
              onTap: () {
                Navigator.pop(context);
                _shareEntry(entry);
              },
            ),
          ],
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Görsel
  // -------------------------------------------------------------------------

  Widget _breadcrumb() {
    final segments = _currentPath.isEmpty
        ? <String>[]
        : _currentPath.split('/');
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox(
        height: 44,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            TextButton.icon(
              icon: const Icon(Icons.folder_zip_rounded, size: 20),
              label: const Text('Arşiv'),
              onPressed: _currentPath.isEmpty
                  ? null
                  : () => setState(() => _currentPath = ''),
            ),
            for (var i = 0; i < segments.length; i++) ...[
              const Icon(Icons.chevron_right_rounded,
                  size: 18, color: Colors.grey),
              TextButton(
                onPressed: () => setState(() =>
                    _currentPath = segments.sublist(0, i + 1).join('/')),
                child: Text(segments[i]),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 56, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              TvFocusable(
                onActivate: _load,
                child: FilledButton.icon(
                  onPressed: _load,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Yeniden dene'),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (_entries.isEmpty) {
      return Center(
        child: Text(
          'Bu arşiv boş.',
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      );
    }
    final children = _children;
    if (children.isEmpty) {
      return Center(
        child: Text(
          'Bu klasör boş.',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      );
    }
    return ListView.builder(
      itemCount: children.length,
      itemBuilder: (context, index) {
        final entry = children[index];
        if (entry.isDirectory) {
          return TvFocusable(
            onActivate: () => setState(() => _currentPath = entry.name),
            child: ListTile(
              leading: Icon(Icons.folder_rounded,
                  color: AppTheme.accent, size: 32),
              title: Text(entry.baseName,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${_childCountOf(entry.name)} öğe'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => setState(() => _currentPath = entry.name),
            ),
          );
        }
        return TvFocusable(
          onActivate: () => _openEntry(entry),
          child: ListTile(
            leading: Icon(_fileIcon(entry.baseName),
                color: Theme.of(context).colorScheme.outline, size: 30),
            title: Text(entry.baseName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(entry.compressedSize != entry.uncompressedSize
                ? '${Formats.size(entry.uncompressedSize)} • sıkıştırılmış '
                    '${Formats.size(entry.compressedSize)}'
                : Formats.size(entry.uncompressedSize)),
            trailing: IconButton(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              tooltip: 'Daha fazla',
              onPressed: () => _entryMenu(entry),
            ),
            onTap: () => _openEntry(entry),
          ),
        );
      },
    );
  }

  static IconData _fileIcon(String name) {
    final dot = name.lastIndexOf('.');
    final ext = dot > 0 ? name.substring(dot + 1).toLowerCase() : '';
    if (_kImageExts.contains(ext)) return Icons.image_outlined;
    if (ext == 'pdf') return Icons.picture_as_pdf_outlined;
    if (ext == 'apk') return Icons.android_outlined;
    if (const {'mp4', 'mkv', 'avi', 'mov', 'webm'}.contains(ext)) {
      return Icons.video_file_outlined;
    }
    if (const {'mp3', 'm4a', 'flac', 'ogg', 'wav'}.contains(ext)) {
      return Icons.audio_file_outlined;
    }
    if (_kTextExts.contains(ext)) return Icons.text_snippet_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _messageOf(Object err, String prefix) {
    final message = switch (err) {
      ArchiveSecurityException(:final message) => message,
      ArchiveServiceException(:final message) => message,
      _ => err.toString(),
    };
    return '$prefix: $message';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_fileName, maxLines: 1, overflow: TextOverflow.ellipsis),
            if (_error == null)
              Text(
                _loading
                    ? 'Listeleniyor…'
                    : '$_fileCount dosya • ${Formats.size(_totalSize)}',
                style: theme.textTheme.bodySmall,
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: _loading ? null : _load,
          ),
          PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'extract_all':
                  _extractAll();
                case 'info':
                  _showArchiveInfo();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                  value: 'extract_all', child: Text('Tümünü çıkar')),
              PopupMenuItem(value: 'info', child: Text('Arşiv bilgileri')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_error == null && !_loading) _breadcrumb(),
          Expanded(child: _body()),
        ],
      ),
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: TvFocusable(
          onActivate:
              _working || _loading || _error != null ? null : _extractAll,
          child: FilledButton.icon(
            onPressed:
                _working || _loading || _error != null ? null : _extractAll,
            icon: const Icon(Icons.folder_zip_rounded),
            label: const Text('TÜMÜNÜ ÇIKAR'),
          ),
        ),
      ),
    );
  }
}
