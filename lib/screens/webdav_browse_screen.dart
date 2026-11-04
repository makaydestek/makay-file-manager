import 'package:flutter/material.dart';

import '../services/remote_download.dart';
import '../services/remote_service.dart';
import '../services/webdav_service.dart';
import '../utils/formats.dart';

/// WebDAV sunucusunda gezinme: dizin listesi + dosya indirme.
class WebDavBrowseScreen extends StatefulWidget {
  const WebDavBrowseScreen({super.key, required this.location});

  final RemoteLocation location;

  @override
  State<WebDavBrowseScreen> createState() => _WebDavBrowseScreenState();
}

class _WebDavBrowseScreenState extends State<WebDavBrowseScreen> {
  static const _service = WebDavService();

  String _path = '/';
  List<DavEntry> _entries = [];
  bool _loading = true;
  String? _error;

  CloudLocation get _cloud => CloudLocation(
        name: widget.location.name,
        provider: 'WebDAV',
        url: WebDavService.normalizeUrl(widget.location.host),
        username: widget.location.username,
        password: widget.location.password,
      );

  @override
  void initState() {
    super.initState();
    _path = widget.location.startPath;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service.list(_cloud, path: _path);
      if (!mounted) return;
      setState(() => _entries = entries);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = 'Liste alınamadı: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(DavEntry entry) {
    if (entry.isDir) {
      final next = _path.endsWith('/')
          ? '$_path${entry.name}'
          : '$_path/${entry.name}';
      setState(() => _path = next);
      _load();
    } else {
      _download(entry);
    }
  }

  void _goUp() {
    if (_path == '/' || _path.isEmpty) return;
    final cleaned = _path.replaceAll(RegExp(r'/+$'), '');
    final idx = cleaned.lastIndexOf('/');
    setState(() => _path = idx <= 0 ? '/' : cleaned.substring(0, idx));
    _load();
  }

  Future<void> _download(DavEntry entry) async {
    final remote = _path.endsWith('/')
        ? '$_path${entry.name}'
        : '$_path/${entry.name}';
    if (!mounted) return;
    // Download klasörüne iner; APK ise bitince Kur/Güncelle diyaloğu açılır.
    await RemoteDownload.run(
      context,
      fileName: entry.name,
      transfer: (target) => _service.download(_cloud, remote, target),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.location.name} (WebDAV)'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(36),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.cloud_rounded, size: 16),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _path,
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
      body: _loading
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
                          onPressed: _load,
                          child: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
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
                              if (_path == '/') return const SizedBox.shrink();
                              return ListTile(
                                leading:
                                    const Icon(Icons.drive_folder_upload),
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
                              subtitle:
                                  Text(e.isDir ? 'Klasör' : Formats.size(e.size)),
                              onTap: () => _open(e),
                            );
                          },
                        ),
                ),
    );
  }
}
