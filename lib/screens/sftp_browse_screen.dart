import 'package:flutter/material.dart';

import '../models/remote_item.dart';
import '../services/remote_service.dart';
import '../services/sftp_service.dart';
import 'remote/remote_browse_scaffold.dart';

/// Uzak SSH/SFTP gezinme (ortak F-FM tarzı uzak tarayıcı).
class SftpBrowseScreen extends StatefulWidget {
  const SftpBrowseScreen({super.key, required this.location});

  final RemoteLocation location;

  @override
  State<SftpBrowseScreen> createState() => _SftpBrowseScreenState();
}

class _SftpBrowseScreenState extends State<SftpBrowseScreen> {
  SftpSession? _session;
  String _path = '/';
  List<RemoteItem> _items = [];
  bool _loading = true;
  String? _error;

  String get _locationKey => widget.location.secretKey;

  @override
  void initState() {
    super.initState();
    _path = widget.location.startPath.isEmpty
        ? '/'
        : widget.location.startPath;
    _connect();
  }

  @override
  void dispose() {
    _session?.close();
    super.dispose();
  }

  String _join(String name) =>
      _path.endsWith('/') ? '$_path$name' : '$_path/$name';

  List<(String, String)> get _crumbs {
    final segments = _path.split('/').where((s) => s.isNotEmpty).toList();
    final out = <(String, String)>[('/', '/')];
    for (var i = 0; i < segments.length; i++) {
      out.add((segments[i], '/${segments.sublist(0, i + 1).join('/')}'));
    }
    return out;
  }

  Future<void> _connect() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      _session ??= await SftpSession.connect(widget.location);
      final entries = await _session!.list(_path);
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
    } catch (e) {
      try {
        _session?.close();
        _session = await SftpSession.connect(widget.location);
        final entries = await _session!.list(_path);
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
      } catch (e2) {
        _session = null;
        if (!mounted) return;
        setState(() => _error = 'Bağlantı/liste hatası: $e2');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDir(RemoteItem item) {
    setState(() => _path = item.remotePath);
    _connect();
  }

  void _goUp() {
    if (_path == '/' || _path.isEmpty) return;
    final cleaned = _path.replaceAll(RegExp(r'/+$'), '');
    final idx = cleaned.lastIndexOf('/');
    setState(() => _path = idx <= 0 ? '/' : cleaned.substring(0, idx));
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    return RemoteBrowseScaffold(
      title: '${widget.location.name} (SFTP)',
      subtitleIcon: Icons.lock_rounded,
      pathLabel: _path,
      crumbs: _crumbs,
      canGoUp: _path != '/' && _path.isNotEmpty,
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
      download: (item, target) => _session!.download(item.remotePath, target),
      fetchBytes: (item) => _session!.downloadBytes(item.remotePath),
    );
  }
}
