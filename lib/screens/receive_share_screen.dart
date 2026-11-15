import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/file_service.dart';
import '../services/platform_service.dart';
import '../utils/app_paths.dart';
import '../utils/formats.dart';
import '../utils/tv_ui.dart';
import '../widgets/tv_focusable.dart';

/// Sistem "Paylaş / Dışa aktar" menüsünden gelen dosyaları hedef klasöre kaydeder.
///
/// F Dosya Yöneticisi gibi: klasör gezintisi + altta **İptal** / **Kaydet**.
class ReceiveShareScreen extends StatefulWidget {
  const ReceiveShareScreen({super.key, required this.files});

  final List<SharedInboxFile> files;

  @override
  State<ReceiveShareScreen> createState() => _ReceiveShareScreenState();
}

class _ReceiveShareScreenState extends State<ReceiveShareScreen> {
  static const _service = FileService();

  late String _destPath;
  bool _loading = true;
  bool _saving = false;
  List<_FolderRow> _folders = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _openDownloadsOrRoot();
  }

  /// F Dosya Yöneticisi gibi varsayılan: İndirilenler.
  Future<void> _openDownloadsOrRoot() async {
    final downloads = await AppPaths.byCategory('downloads');
    if (downloads != null) {
      final dir = Directory(downloads);
      if (!await dir.exists()) {
        try {
          await dir.create(recursive: true);
        } catch (_) {}
      }
      if (await dir.exists()) {
        await _openDir(downloads);
        return;
      }
    }
    final root = await AppPaths.mainStorage() ?? '/storage/emulated/0';
    await _openDir(root);
  }

  Future<void> _openDir(String path) async {
    setState(() {
      _loading = true;
      _error = null;
      _destPath = path;
    });
    try {
      final entries = await _service.listDirectory(path);
      final folders = entries
          .where((e) => e.isDirectory)
          .map((e) => _FolderRow(name: e.name, path: e.path))
          .toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _folders = const [];
        _loading = false;
        _error = 'Klasör okunamadı: $e';
      });
    }
  }

  Future<void> _goUp() async {
    final parent = Directory(_destPath).parent.path;
    if (parent.isEmpty || parent == _destPath) return;
    final root = await AppPaths.mainStorage() ?? '/storage/emulated/0';
    if (_destPath == root) return;
    await _openDir(parent);
  }

  Future<void> _quickDest(String categoryId) async {
    final path = await AppPaths.byCategory(categoryId);
    if (path == null) return;
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _openDir(path);
  }

  Future<void> _saveHere() async {
    if (_saving || widget.files.isEmpty) return;
    setState(() => _saving = true);
    var ok = 0;
    var fail = 0;
    try {
      final destDir = Directory(_destPath);
      if (!await destDir.exists()) {
        await destDir.create(recursive: true);
      }
      for (final item in widget.files) {
        try {
          final src = File(item.path);
          if (!await src.exists()) {
            fail++;
            continue;
          }
          final target = await _uniqueTarget(_destPath, item.name);
          await src.copy(target);
          ok++;
        } catch (_) {
          fail++;
        }
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
    if (!mounted) return;
    final msg = fail == 0
        ? '$ok dosya kaydedildi'
        : '$ok kaydedildi, $fail başarısız';
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    if (ok > 0 && mounted) Navigator.of(context).pop(true);
  }

  void _cancel() {
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(false);
    } else {
      // Soğuk başlatılmış paylaşım hedefi: uygulamayı kapat → tarayıcıya dön.
      SystemNavigator.pop();
    }
  }

  Future<String> _uniqueTarget(String dir, String name) async {
    var candidate = '$dir${Platform.pathSeparator}$name';
    if (!await File(candidate).exists()) return candidate;
    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';
    var i = 1;
    while (await File(candidate).exists()) {
      candidate = '$dir${Platform.pathSeparator}$base ($i)$ext';
      i++;
    }
    return candidate;
  }

  String get _title {
    final name = _destPath.split(Platform.pathSeparator).last;
    if (name.isEmpty || name == '0') return 'Depolama';
    if (name == 'Download' || name == 'Downloads') return 'İndirilenler';
    return name;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tv = TvUi.enabled(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_title),
        leading: IconButton(
          tooltip: 'Üst klasör',
          onPressed: _loading || _saving ? null : _goUp,
          icon: const Icon(Icons.arrow_upward_rounded),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Material(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${widget.files.length} dosya kaydedilecek',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 56,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.files.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 8),
                      itemBuilder: (context, i) {
                        final f = widget.files[i];
                        return Chip(
                          avatar: const Icon(Icons.insert_drive_file_rounded,
                              size: 18),
                          label: Text(
                            '${f.name} (${Formats.size(f.size)})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _QuickChip(
                  label: 'İndirilenler',
                  icon: Icons.download_rounded,
                  onTap: () => _quickDest('downloads'),
                ),
                _QuickChip(
                  label: 'Resimler',
                  icon: Icons.image_rounded,
                  onTap: () => _quickDest('images'),
                ),
                _QuickChip(
                  label: 'Belgeler',
                  icon: Icons.description_rounded,
                  onTap: () => _quickDest('documents'),
                ),
                _QuickChip(
                  label: 'Müzik',
                  icon: Icons.music_note_rounded,
                  onTap: () => _quickDest('audio'),
                ),
                _QuickChip(
                  label: 'Videolar',
                  icon: Icons.video_library_rounded,
                  onTap: () => _quickDest('videos'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _destPath,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text(_error!))
                    : _folders.isEmpty
                        ? const Center(
                            child: Text('Boş Klasör'),
                          )
                        : ListView.builder(
                            itemCount: _folders.length,
                            itemBuilder: (context, i) {
                              final f = _folders[i];
                              final tile = ListTile(
                                leading: const Icon(Icons.folder_rounded,
                                    color: Color(0xFFF9A825)),
                                title: Text(f.name),
                                onTap: () => _openDir(f.path),
                              );
                              if (!tv) return tile;
                              return TvFocusable(
                                autofocus: i == 0,
                                onActivate: () => _openDir(f.path),
                                scale: 1.02,
                                child: tile,
                              );
                            },
                          ),
          ),
        ],
      ),
      // F Dosya Yöneticisi tarzı alt çubuk: İptal | Kaydet
      bottomNavigationBar: Material(
        color: theme.colorScheme.primary,
        elevation: 8,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                Expanded(
                  child: TvFocusable(
                    onActivate: _saving ? null : _cancel,
                    borderRadius: 0,
                    scale: 1.0,
                    child: InkWell(
                      onTap: _saving ? null : _cancel,
                      child: const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.close_rounded, color: Colors.white),
                          SizedBox(height: 2),
                          Text(
                            'İptal',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Container(
                  width: 1,
                  height: 36,
                  color: Colors.white24,
                ),
                Expanded(
                  child: TvFocusable(
                    autofocus: tv,
                    onActivate: (_saving || _loading) ? null : _saveHere,
                    borderRadius: 0,
                    scale: 1.0,
                    child: InkWell(
                      onTap: (_saving || _loading) ? null : _saveHere,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_saving)
                            const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          else
                            const Icon(Icons.save_rounded, color: Colors.white),
                          const SizedBox(height: 2),
                          Text(
                            _saving ? 'Kaydediliyor…' : 'Kaydet',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FolderRow {
  const _FolderRow({required this.name, required this.path});
  final String name;
  final String path;
}

class _QuickChip extends StatelessWidget {
  const _QuickChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ActionChip(
        avatar: Icon(icon, size: 18),
        label: Text(label),
        onPressed: onTap,
      ),
    );
  }
}
