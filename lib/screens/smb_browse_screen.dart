import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../models/remote_item.dart';
import '../services/remote_service.dart';
import '../services/smb_client.dart';
import 'remote/remote_browse_scaffold.dart';

/// SMB paylaşımında gezinme (ortak F-FM tarzı uzak tarayıcı).
class SmbBrowseScreen extends StatefulWidget {
  const SmbBrowseScreen({super.key, required this.location});

  final RemoteLocation location;

  @override
  State<SmbBrowseScreen> createState() => _SmbBrowseScreenState();
}

class _SmbBrowseScreenState extends State<SmbBrowseScreen> {
  SmbClient? _client;
  String _path = '';
  List<RemoteItem> _items = [];
  bool _loading = true;
  bool _busy = false;
  String? _error;

  String get _locationKey => widget.location.secretKey;

  String get _displayPath => '\\\\${widget.location.host}\\'
      '${widget.location.share.isEmpty ? 'C\$' : widget.location.share}'
      '${_path.isEmpty ? '' : '\\$_path'}';

  List<(String, String)> get _crumbs {
    final share = widget.location.share.isEmpty ? 'C\$' : widget.location.share;
    final out = <(String, String)>[(share, '')];
    if (_path.isEmpty) return out;
    final segments = _path.split(r'\').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i < segments.length; i++) {
      out.add((segments[i], segments.sublist(0, i + 1).join(r'\')));
    }
    return out;
  }

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

  String _join(String name) => _path.isEmpty ? name : '$_path\\$name';

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      _client ??= await SmbClient.connect(widget.location);
      final entries = await _client!.list(_path);
      if (!mounted) return;
      setState(() {
        _items = [
          for (final e in entries)
            RemoteItem(
              name: e.name,
              remotePath: _join(e.name),
              isDir: e.isDir,
              size: e.size,
              modified: e.modified,
            ),
        ];
        _error = null;
      });
    } on SmbException catch (e) {
      // Oturum koptuysa bir kez yeniden bağlan (photo gibi büyük klasörler).
      try {
        _client?.destroy();
        _client = await SmbClient.connect(widget.location);
        final entries = await _client!.list(_path);
        if (!mounted) return;
        setState(() {
          _items = [
            for (final e in entries)
              RemoteItem(
                name: e.name,
                remotePath: _join(e.name),
                isDir: e.isDir,
                size: e.size,
                modified: e.modified,
              ),
          ];
          _error = null;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _error = e.message);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Bağlantı/liste hatası: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDir(RemoteItem item) {
    setState(() => _path = item.remotePath);
    _connect();
  }

  void _goUp() {
    if (_path.isEmpty) return;
    final idx = _path.lastIndexOf(r'\');
    setState(() => _path = idx < 0 ? '' : _path.substring(0, idx));
    _connect();
  }

  Future<void> _mkdir() async {
    final name = await _askText('Yeni klasör', 'Klasör adı');
    if (name == null || name.trim().isEmpty || _client == null) return;
    final remote = _join(name.trim());
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
    final root = Directory('/storage/emulated/0/Download');
    final fallback = await getApplicationDocumentsDirectory();
    final dir = root.existsSync() ? root : fallback;
    final files = dir.listSync().whereType<File>().toList()
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
    final remote = _join(name);
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

  Future<void> _rename(RemoteItem item) async {
    final neu = await _askText('Yeniden adlandır', 'Yeni ad', initial: item.name);
    if (neu == null || neu.trim().isEmpty || neu.trim() == item.name) return;
    final to = _path.isEmpty ? neu.trim() : '$_path\\${neu.trim()}';
    setState(() => _busy = true);
    try {
      await _client!.rename(item.remotePath, to);
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

  Future<void> _delete(RemoteItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sil'),
        content: Text('"${item.name}" kalıcı olarak silinsin mi?'),
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
    setState(() => _busy = true);
    try {
      await _client!.delete(item.remotePath, isDir: item.isDir);
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        RemoteBrowseScaffold(
          title: '${widget.location.name} (SMB)',
          subtitleIcon: Icons.folder_shared_rounded,
          pathLabel: _displayPath,
          crumbs: _crumbs,
          canGoUp: _path.isNotEmpty,
          locationKey: _locationKey,
          items: _items,
          loading: _loading,
          error: _error,
          onRefresh: _connect,
          onOpenDir: _openDir,
          onGoUp: _goUp,
          onCrumb: (path) {
            setState(() => _path = path);
            _connect();
          },
          download: (item, target) =>
              _client!.download(item.remotePath, target),
          fetchBytes: (item) => _client!.downloadBytes(item.remotePath),
          extraActions: [
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
          extraMenuItems: (ctx, item, close) => [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Yeniden adlandır'),
              onTap: () {
                close();
                _rename(item);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Sil'),
              onTap: () {
                close();
                _delete(item);
              },
            ),
          ],
        ),
        if (_busy)
          const ModalBarrier(dismissible: false, color: Color(0x33000000)),
        if (_busy) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
