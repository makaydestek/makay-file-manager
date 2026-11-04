import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/remote_download.dart';
import '../services/remote_service.dart';
import '../services/smb_client.dart';
import '../utils/formats.dart';

/// SMB paylaşımında gezinme: liste, indirme, yükleme, klasör, silme, yeniden adlandırma.
class SmbBrowseScreen extends StatefulWidget {
  const SmbBrowseScreen({super.key, required this.location});

  final RemoteLocation location;

  @override
  State<SmbBrowseScreen> createState() => _SmbBrowseScreenState();
}

class _SmbBrowseScreenState extends State<SmbBrowseScreen> {
  SmbClient? _client;
  String _path = '';
  List<SmbEntry> _entries = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _path = widget.location.startPath;
    _connect();
  }

  @override
  void dispose() {
    _client?.close();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _client ??= await SmbClient.connect(widget.location);
      final entries = await _client!.list(_path);
      if (!mounted) return;
      setState(() => _entries = entries);
    } on SmbException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Bağlantı/liste hatası: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(SmbEntry entry) {
    if (entry.isDir) {
      final next = _path.isEmpty ? entry.name : '$_path\\${entry.name}';
      setState(() => _path = next);
      _connect();
    } else {
      _download(entry);
    }
  }

  void _goUp() {
    if (_path.isEmpty) return;
    final idx = _path.lastIndexOf(r'\');
    setState(() => _path = idx < 0 ? '' : _path.substring(0, idx));
    _connect();
  }

  Future<void> _download(SmbEntry entry) async {
    final remote = _path.isEmpty ? entry.name : '$_path\\${entry.name}';
    if (!mounted) return;
    await RemoteDownload.run(
      context,
      fileName: entry.name,
      transfer: (target) => _client!.download(remote, target),
    );
  }

  Future<void> _mkdir() async {
    final name = await _askText('Yeni klasör', 'Klasör adı');
    if (name == null || name.trim().isEmpty || _client == null) return;
    final remote = _path.isEmpty ? name.trim() : '$_path\\${name.trim()}';
    setState(() => _busy = true);
    try {
      await _client!.mkdir(remote);
      if (mounted) await _connect();
    } on SmbException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _upload() async {
    // Yerel dosya seçimi: Download klasöründen basit diyalog.
    final root = Directory('/storage/emulated/0/Download');
    final fallback = await getApplicationDocumentsDirectory();
    final dir = root.existsSync() ? root : fallback;
    final files = dir
        .listSync()
        .whereType<File>()
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (!mounted) return;
    if (files.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yüklenecek dosya yok: ${dir.path}')),
      );
      return;
    }
    final picked = await showModalBottomSheet<File>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          children: [
            const ListTile(
              title: Text('Yüklenecek dosyayı seçin'),
              subtitle: Text('İndirilenler / belgeler'),
            ),
            for (final f in files.take(40))
              ListTile(
                leading: const Icon(Icons.insert_drive_file_rounded),
                title: Text(
                  f.path.split(Platform.pathSeparator).last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => Navigator.pop(ctx, f),
              ),
          ],
        ),
      ),
    );
    if (picked == null || _client == null) return;
    final name = picked.path.split(Platform.pathSeparator).last;
    final remote = _path.isEmpty ? name : '$_path\\$name';
    setState(() => _busy = true);
    try {
      await _client!.upload(remote, picked);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yüklendi: $name')),
      );
      await _connect();
    } on SmbException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Yükleme hatası: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rename(SmbEntry entry) async {
    final neu = await _askText('Yeniden adlandır', 'Yeni ad',
        initial: entry.name);
    if (neu == null || neu.trim().isEmpty || neu.trim() == entry.name) return;
    final from = _path.isEmpty ? entry.name : '$_path\\${entry.name}';
    final to = _path.isEmpty ? neu.trim() : '$_path\\${neu.trim()}';
    setState(() => _busy = true);
    try {
      await _client!.rename(from, to);
      if (mounted) await _connect();
    } on SmbException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(SmbEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sil'),
        content: Text('"${entry.name}" kalıcı olarak silinsin mi?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Sil')),
        ],
      ),
    );
    if (ok != true || _client == null) return;
    final remote = _path.isEmpty ? entry.name : '$_path\\${entry.name}';
    setState(() => _busy = true);
    try {
      await _client!.delete(remote, isDir: entry.isDir);
      if (mounted) await _connect();
    } on SmbException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(e.message)));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askText(String title, String label, {String? initial}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Vazgeç')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, c.text),
              child: const Text('Tamam')),
        ],
      ),
    );
  }

  void _rowMenu(SmbEntry e) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(e.isDir ? 'Klasör' : Formats.size(e.size)),
            ),
            const Divider(height: 1),
            if (!e.isDir)
              ListTile(
                leading: const Icon(Icons.download_rounded),
                title: const Text('İndir'),
                onTap: () {
                  Navigator.pop(ctx);
                  _download(e);
                },
              ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Yeniden adlandır'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(e);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Sil'),
              onTap: () {
                Navigator.pop(ctx);
                _delete(e);
              },
            ),
          ],
        ),
      ),
    );
  }

  String get _displayPath => '\\\\${widget.location.host}\\'
      '${widget.location.share.isEmpty ? 'C\$' : widget.location.share}'
      '${_path.isEmpty ? '' : '\\$_path'}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.location.name} (SMB)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_rounded),
            tooltip: 'Yeni klasör',
            onPressed: _busy || _loading || _error != null ? null : _mkdir,
          ),
          IconButton(
            icon: const Icon(Icons.upload_file_rounded),
            tooltip: 'Dosya yükle',
            onPressed: _busy || _loading || _error != null ? null : _upload,
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.folder_shared_rounded, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _displayPath,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline_rounded,
                                size: 48, color: Colors.redAccent),
                            const SizedBox(height: 12),
                            Text(_error!, textAlign: TextAlign.center),
                            const SizedBox(height: 12),
                            FilledButton(
                              onPressed: _connect,
                              child: const Text('Tekrar dene'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _connect,
                      child: _entries.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 120),
                                Center(child: Text('Bu dizin boş')),
                              ],
                            )
                          : ListView.builder(
                              itemCount: _entries.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  if (_path.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  return ListTile(
                                    leading: const Icon(
                                        Icons.drive_folder_upload),
                                    title: const Text('..'),
                                    onTap: _goUp,
                                  );
                                }
                                final e = _entries[index - 1];
                                return ListTile(
                                  leading: Icon(
                                    e.isDir
                                        ? Icons.folder_rounded
                                        : Icons.insert_drive_file_rounded,
                                    color: e.isDir
                                        ? const Color(0xFFFFB300)
                                        : theme.colorScheme.primary,
                                  ),
                                  title: Text(e.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                  subtitle: Text(
                                      e.isDir ? 'Klasör' : Formats.size(e.size)),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.more_vert_rounded),
                                    onPressed: () => _rowMenu(e),
                                  ),
                                  onTap: () => _open(e),
                                  onLongPress: () => _rowMenu(e),
                                );
                              },
                            ),
                    ),
          if (_busy)
            const ModalBarrier(dismissible: false, color: Color(0x33000000)),
          if (_busy)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
