import 'package:flutter/material.dart';
import 'package:ftpconnect/ftpconnect.dart';

import '../models/remote_item.dart';
import '../services/ftp_session.dart';
import '../services/remote_service.dart';
import 'remote/remote_browse_scaffold.dart';

/// Uzak FTP sunucusunda gezinme (kalıcı oturum + F-FM tarzı uzak tarayıcı).
class FtpBrowseScreen extends StatefulWidget {
  const FtpBrowseScreen({super.key, required this.location});

  final RemoteLocation location;

  @override
  State<FtpBrowseScreen> createState() => _FtpBrowseScreenState();
}

class _FtpBrowseScreenState extends State<FtpBrowseScreen> {
  FtpSession? _session;
  String _path = '/';
  List<RemoteItem> _items = [];
  bool _loading = true;
  String? _error;
  int _loadGen = 0;

  String get _locationKey => widget.location.secretKey;

  @override
  void initState() {
    super.initState();
    _path = widget.location.startPath.isEmpty
        ? '/'
        : widget.location.startPath;
    _connectAndLoad();
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

  Future<void> _connectAndLoad() async {
    setState(() {
      _loading = true;
      _error = null;
      _items = [];
    });
    try {
      _session ??= await FtpSession.connect(widget.location);
      await _load(keepSession: true);
    } catch (e) {
      _session?.destroy();
      _session = null;
      if (!mounted) return;
      setState(() {
        _error = 'Bağlantı/liste hatası: $e';
        _loading = false;
      });
    }
  }

  Future<void> _load({bool keepSession = false, bool forceRefresh = false}) async {
    final gen = ++_loadGen;
    setState(() {
      _loading = true;
      _error = null;
      // Stale içerik + yanlış "boş klasör" hissini önlemek için temizle.
      _items = [];
    });
    try {
      _session ??= await FtpSession.connect(widget.location);
      if (forceRefresh) _session!.invalidateCache(_path);
      final entries =
          await _session!.list(_path, forceRefresh: forceRefresh);
      if (!mounted || gen != _loadGen) return;
      setState(() {
        _items = [
          for (final e in entries)
            RemoteItem(
              name: e.name,
              remotePath: _join(e.name),
              isDir: e.type == FTPEntryType.dir || e.type == FTPEntryType.link,
              size: e.size ?? 0,
              modified: e.modifyTime,
            ),
        ];
        _error = null;
      });
    } catch (e) {
      // Oturum koptuysa bir kez yeniden bağlan.
      if (!keepSession) {
        try {
          _session?.destroy();
          _session = await FtpSession.connect(widget.location);
          final entries =
              await _session!.list(_path, forceRefresh: true);
          if (!mounted || gen != _loadGen) return;
          setState(() {
            _items = [
              for (final e in entries)
                RemoteItem(
                  name: e.name,
                  remotePath: _join(e.name),
                  isDir:
                      e.type == FTPEntryType.dir || e.type == FTPEntryType.link,
                  size: e.size ?? 0,
                  modified: e.modifyTime,
                ),
            ];
            _error = null;
          });
          return;
        } catch (e2) {
          _session?.destroy();
          _session = null;
          if (!mounted || gen != _loadGen) return;
          setState(() => _error = 'Liste alınamadı: $e2');
          return;
        }
      }
      if (!mounted || gen != _loadGen) return;
      setState(() => _error = 'Liste alınamadı: $e');
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
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
      title: widget.location.name,
      subtitleIcon: Icons.dns_rounded,
      pathLabel: _path,
      crumbs: _crumbs,
      canGoUp: _path != '/' && _path.isNotEmpty,
      locationKey: _locationKey,
      items: _items,
      loading: _loading,
      error: _error,
      onRefresh: () => _load(forceRefresh: true),
      onOpenDir: _openDir,
      onGoUp: _goUp,
      onCrumb: (path) {
        setState(() => _path = path);
        _load();
      },
      download: (item, target) async {
        _session ??= await FtpSession.connect(widget.location);
        await _session!.download(item.remotePath, target);
      },
      fetchBytes: (item) async {
        _session ??= await FtpSession.connect(widget.location);
        return _session!.downloadBytes(item.remotePath);
      },
    );
  }
}
