import 'dart:io';

import 'package:flutter/material.dart';

import '../services/file_service.dart';
import '../services/platform_service.dart';
import '../utils/app_paths.dart';
import '../utils/formats.dart';

/// Sistem "Paylaş" menüsünden gelen dosyaları hedef klasöre kaydeder.
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
    _openRoot();
  }

  Future<void> _openRoot() async {
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
    // Depolama kökünün üstüne çıkma.
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
    if (ok > 0) Navigator.of(context).pop(true);
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Dosyaları kaydet'),
        actions: [
          IconButton(
            tooltip: 'Üst klasör',
            onPressed: _loading || _saving ? null : _goUp,
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving || _loading ? null : _saveHere,
        icon: _saving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_rounded),
        label: Text(_saving ? 'Kaydediliyor…' : 'Buraya kaydet'),
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
                    '${widget.files.length} dosya paylaşılacak',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 56,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: widget.files.length,
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
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
                            child: Text('Alt klasör yok — buraya kaydedebilirsiniz'),
                          )
                        : ListView.builder(
                            itemCount: _folders.length,
                            itemBuilder: (context, i) {
                              final f = _folders[i];
                              return ListTile(
                                leading: const Icon(Icons.folder_rounded,
                                    color: Color(0xFFF9A825)),
                                title: Text(f.name),
                                onTap: () => _openDir(f.path),
                              );
                            },
                          ),
          ),
          const SizedBox(height: 72),
        ],
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
