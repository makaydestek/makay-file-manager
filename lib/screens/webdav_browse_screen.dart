import 'package:flutter/material.dart';

import '../models/remote_item.dart';
import '../services/remote_service.dart';
import '../services/webdav_service.dart';
import 'remote/remote_browse_scaffold.dart';

/// WebDAV gezinme (ortak F-FM tarzı uzak tarayıcı + ağ önizleme).
class WebDavBrowseScreen extends StatefulWidget {
  const WebDavBrowseScreen({super.key, required this.location});

  final RemoteLocation location;

  @override
  State<WebDavBrowseScreen> createState() => _WebDavBrowseScreenState();
}

class _WebDavBrowseScreenState extends State<WebDavBrowseScreen> {
  static const _service = WebDavService();

  String _path = '/';
  List<RemoteItem> _items = [];
  bool _loading = true;
  String? _error;

  CloudLocation get _cloud => CloudLocation(
        name: widget.location.name,
        provider: 'WebDAV',
        url: WebDavService.normalizeUrl(widget.location.host),
        username: widget.location.username,
        password: widget.location.password,
      );

  String get _locationKey => widget.location.secretKey;

  @override
  void initState() {
    super.initState();
    _path = widget.location.startPath.isEmpty
        ? '/'
        : widget.location.startPath;
    _load();
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

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      final entries = await _service.list(_cloud, path: _path);
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
      if (!mounted) return;
      setState(() => _error = 'Liste alınamadı: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDir(RemoteItem item) {
    setState(() => _path = item.remotePath);
    _load();
  }

  void _goUp() {
    if (_path == '/' || _path.isEmpty) return;
    final cleaned = _path.replaceAll(RegExp(r'/+$'), '');
    final idx = cleaned.lastIndexOf('/');
    setState(() => _path = idx <= 0 ? '/' : cleaned.substring(0, idx));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    return RemoteBrowseScaffold(
      title: '${widget.location.name} (WebDAV)',
      subtitleIcon: Icons.cloud_rounded,
      pathLabel: _path,
      crumbs: _crumbs,
      canGoUp: _path != '/' && _path.isNotEmpty,
      locationKey: _locationKey,
      items: _items,
      loading: _loading,
      error: _error,
      onRefresh: _load,
      onOpenDir: _openDir,
      onGoUp: _goUp,
      onCrumb: (path) {
        setState(() => _path = path);
        _load();
      },
      download: (item, target) =>
          _service.download(_cloud, item.remotePath, target),
      fetchBytes: (item) =>
          _service.downloadBytes(_cloud, item.remotePath),
      networkUrlFor: (item) =>
          item.isDir ? null : WebDavService.fileUri(_cloud, item.remotePath),
      httpHeaders: WebDavService.authHeaders(_cloud),
    );
  }
}
