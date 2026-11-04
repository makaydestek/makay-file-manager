import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../utils/debug_log.dart';
import '../utils/formats.dart';
import '../services/category_size_service.dart';
import '../services/heavy_scan.dart';

/// Geçici dosyalar ekranı: uygulama önbelleği, küçük resim (.thumbnails)
/// önbelleği ve .tmp/.part gibi yarıda kalmış dosyaların temizliği.
class TempCleanerScreen extends StatefulWidget {
  const TempCleanerScreen({super.key});

  @override
  State<TempCleanerScreen> createState() => _TempCleanerScreenState();
}

/// Bulunan tek bir geçici dosya.
class _TempItem {
  _TempItem(this.file, this.size);

  final File file;
  final int size;
}

class _TempCleanerScreenState extends State<TempCleanerScreen> {
  bool _loading = true;
  bool _working = false;
  int _cacheSize = 0;
  int _thumbSize = 0;
  final List<_TempItem> _temps = [];

  static const List<String> _tempSuffixes = [
    '.tmp',
    '.temp',
    '.part',
    '.crdownload',
    '.download',
    '.log',
    '.bak',
    '.ytdl',
  ];

  static const String _androidRoot = '/storage/emulated/0';

  @override
  void initState() {
    super.initState();
    _scan();
  }

  int get _tempTotal =>
      _temps.fold(0, (sum, item) => sum + item.size);

  int get _grandTotal => _cacheSize + _thumbSize + _tempTotal;

  Future<void> _scan() async {
    setState(() => _loading = true);
    var cache = 0;
    var thumbs = 0;
    final temps = <_TempItem>[];

    // 1) Uygulama önbelleği (dahili dizin — her platformda; küçük).
    try {
      final tmpPath = (await getTemporaryDirectory()).path;
      cache = await Isolate.run(() {
        var total = 0;
        try {
          for (final e
              in Directory(tmpPath).listSync(recursive: true, followLinks: false)) {
            if (e is File) {
              try {
                total += e.lengthSync();
              } catch (_) {}
            }
          }
        } catch (_) {}
        return total;
      });
    } catch (_) {
      // Dahili önbellek dizini desteklenmeyen platformda/izinde yoktur;
      // önbellek boyutu 0 kalır, temizlik yine de güvenlidir.
    }

    // 2) Genel depolama (yalnızca Android) — ağır tarama izolatta.
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final scanned = await HeavyScan.tempScan(
          androidRoot: _androidRoot,
          suffixes: _tempSuffixes,
        );
        thumbs = scanned.thumbBytes;
        for (final item in scanned.temps) {
          temps.add(_TempItem(File(item.$1), item.$2));
        }
      } catch (e) {
        logSwallowed('temp_cleaner: izolat tarama', e);
      }
    }

    if (!mounted) return;
    setState(() {
      _cacheSize = cache;
      _thumbSize = thumbs;
      _temps
        ..clear()
        ..addAll(temps);
      _loading = false;
    });
  }

  Future<void> _deleteAll(Iterable<File> files) async {
    var freed = 0;
    for (final f in files) {
      try {
        // Boyut silme başarılı olduktan sonra sayılır: kilitli bir dosyanın
        // boyutu "temizlendi" rakamına girerse gösterilen alan gerçekle
        // eşleşmezdi.
        final length = f.lengthSync();
        await f.delete();
        freed += length;
      } catch (_) {
        // Dosya kilitli ya da az önce silinmiş olabilir; temizlik kısmen
        // başarısız sayılır ve kalan dosyalar temizlenmeye devam eder.
      }
    }
    await _scan();
    await CategorySizeService.invalidate();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${Formats.size(freed)} alan temizlendi')),
    );
  }

  Future<void> _clearCache() async {
    setState(() => _working = true);
    try {
      final tmp = await getTemporaryDirectory();
      final files = tmp
          .listSync(followLinks: false)
          .whereType<FileSystemEntity>()
          .toList();
      var freed = 0;
      for (final e in files) {
        try {
          // Boyut yalnızca silme sonrası sayılır (bkz. _deleteAll).
          final length = e is File ? e.lengthSync() : 0;
          await e.delete(recursive: true);
          freed += length;
        } catch (_) {
          // Önbellek girdisi kullanımda ya da az önce kaldırılmış olabilir;
          // temizlik kısmen başarısız sayılır, sonraki tama düzeltir.
        }
      }
      await _scan();
      await CategorySizeService.invalidate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${Formats.size(freed)} önbellek temizlendi')),
        );
      }
    } catch (_) {
      // Desteklenmeyen platform / izin hatası — sessiz geç.
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _clearThumbs() async {
    setState(() => _working = true);
    try {
      final dir = Directory('$_androidRoot/DCIM/.thumbnails');
      var freed = 0;
      if (dir.existsSync()) {
        for (final e in dir.listSync(followLinks: false)) {
          try {
            // Boyut silme sonrası sayılır (bkz. _deleteAll).
            final length = e is File ? e.lengthSync() : 0;
            await e.delete(recursive: true);
            freed += length;
          } catch (_) {
            // Küçük resim dosyası sistem tarafından kullanımda olabilir;
            // erişilemeyen öbek atlanır, diğerleri silinmeye devam eder.
          }
        }
      }
      await _scan();
      await CategorySizeService.invalidate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${Formats.size(freed)} temizlendi')),
        );
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _confirmAndCleanAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tümünü temizle'),
        content: Text(
          'Önbellek, küçük resim önbelleği ve ${_temps.length} geçici dosya '
          'silinecek (${Formats.size(_grandTotal)}). Devam edilsin mi?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Temizle'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working = true);
    try {
      await _clearCache();
      await _clearThumbs();
      await _deleteAll(_temps.map((t) => t.file).toList());
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geçici Dosyalar'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yeniden tara',
            onPressed: _loading ? null : _scan,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(12),
              children: [
                // Özet kartı
                Card(
                  color: theme.colorScheme.primaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Toplam temizlenebilir: ${Formats.size(_grandTotal)}',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 4),
                        Text(
                          'Önbellek ${Formats.size(_cacheSize)} • Küçük resim '
                          '${Formats.size(_thumbSize)} • Geçici dosyalar '
                          '${Formats.size(_tempTotal)}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed:
                              _working || _grandTotal == 0 ? null : _confirmAndCleanAll,
                          icon: const Icon(Icons.cleaning_services_rounded),
                          label: const Text('TEMİZLE'),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                _cleanTile(
                  icon: Icons.cached_rounded,
                  title: 'Uygulama önbelleği',
                  size: _cacheSize,
                  onTap: _cacheSize > 0 && !_working ? _clearCache : null,
                ),
                _cleanTile(
                  icon: Icons.image_rounded,
                  title: 'Küçük resim önbelleği (.thumbnails)',
                  size: _thumbSize,
                  onTap: _thumbSize > 0 && !_working ? _clearThumbs : null,
                ),
                _cleanTile(
                  icon: Icons.timelapse_rounded,
                  title: 'Geçici dosyalar (.tmp, .part vb.)',
                  size: _tempTotal,
                  trailingText: '${_temps.length} dosya',
                  onTap: _temps.isNotEmpty && !_working
                      ? () => _deleteAll(_temps.map((t) => t.file).toList())
                      : null,
                ),
                const SizedBox(height: 4),
                // Mükerrer dosya taraması ayrı ekranda yapılır.
                ListTile(
                  leading: const Icon(Icons.copy_all_rounded),
                  title: const Text('Mükerrer dosyalar'),
                  subtitle:
                      const Text('Aynı içeriğe sahip kopyaları bul ve temizle'),
                  trailing: const Icon(Icons.chevron_right_rounded),
                  onTap: () =>
                      Navigator.of(context).pushNamed('/duplicates'),
                ),
                if (_temps.isNotEmpty) ...[
                  const Divider(),
                  Text('Bulunan geçici dosyalar',
                      style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  for (final item in _temps)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.insert_drive_file_outlined,
                          size: 20),
                      title: Text(
                        item.file.path.split(Platform.pathSeparator).last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.file.parent.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(Formats.size(item.size),
                              style: theme.textTheme.bodySmall),
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 20),
                            tooltip: 'Sil',
                            onPressed:
                                _working ? null : () => _deleteAll([item.file]),
                          ),
                        ],
                      ),
                    ),
                ],
                const SizedBox(height: 24),
              ],
            ),
    );
  }

  Widget _cleanTile({
    required IconData icon,
    required String title,
    required int size,
    required VoidCallback? onTap,
    String? trailingText,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(Formats.size(size)),
      trailing: trailingText != null
          ? Text(trailingText)
          : TextButton(
              onPressed: onTap,
              child: const Text('TEMİZLE'),
            ),
      onTap: onTap,
    );
  }
}
