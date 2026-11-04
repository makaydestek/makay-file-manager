import 'package:flutter/material.dart';

import '../services/google_drive_service.dart';
import '../services/webdav_service.dart';
import '../utils/debug_log.dart';
import 'cloud_add_dialog.dart';
import 'cloud_common.dart';
import 'cloud_webdav_browse_screen.dart';
import 'google_drive_screen.dart';

/// Bulut konumları ekranı: hesap listesi + ekleme + gezinme.
class CloudScreen extends StatefulWidget {
  const CloudScreen({super.key});

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

class _CloudScreenState extends State<CloudScreen> {
  List<CloudLocation> _locations = [];
  bool _loading = true;
  bool _gdriveConnected = false;
  String? _gdriveEmail;
  final _oauthConnected = <String, bool>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final locations = await CloudLocationStore.load();
    await _refreshGdrive();
    await _refreshOauth();
    if (!mounted) return;
    setState(() {
      _locations = locations;
      _loading = false;
    });
  }

  /// Google Drive oturum durumu (bağlıysa listede görünür).
  Future<void> _refreshGdrive() async {
    try {
      final has = await GoogleDriveService.hasSession;
      final email = has ? await GoogleDriveService.accountEmail() : null;
      if (!mounted) return;
      setState(() {
        _gdriveConnected = has;
        _gdriveEmail = email;
      });
    } catch (e) {
      logSwallowed('bulut: oturum durumu', e);
    }
  }

  /// Dropbox / OneDrive / Box oturum durumları (bağlıysa listede görünür).
  Future<void> _refreshOauth() async {
    final connected = <String, bool>{};
    for (final name in kOAuthProviderNames) {
      try {
        connected[name] = await oauthApiFor(name)?.hasTokens() ?? false;
      } catch (_) {
        connected[name] = false;
      }
    }
    if (!mounted) return;
    setState(
      () => _oauthConnected
        ..clear()
        ..addAll(connected),
    );
  }

  Future<void> _add() async {
    final result = await showDialog<Object?>(
      context: context,
      builder: (_) => const AddCloudDialog(),
    );
    if (result is CloudLocation) {
      _locations.add(result);
      await CloudLocationStore.save(_locations);
    }
    await _afterDialog(result);
  }

  /// Diyalog kapandıktan sonra durumları tazeler; OAuth sağlayıcısı
  /// bağlanmışsa gezinme ekranını açar (Google Drive davranışı değişmez).
  Future<void> _afterDialog(Object? result) async {
    if (result is String) {
      final screen = oauthScreenFor(result);
      if (screen != null && mounted) {
        await Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));
      }
    }
    await _refreshGdrive();
    await _refreshOauth();
    if (mounted) setState(() {});
  }

  Future<void> _delete(CloudLocation loc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Hesabı kaldır'),
        content: Text('"${loc.name}" kaldırılsın mı?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Kaldır'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final i = _locations.indexOf(loc);
    if (i < 0) return;
    _locations.removeAt(i);
    await CloudLocationStore.save(_locations);
    if (mounted) setState(() {});
  }

  Future<void> _editCloud(CloudLocation loc) async {
    final i = _locations.indexOf(loc);
    if (i < 0) return;
    final edited = await showDialog<CloudLocation>(
      context: context,
      builder: (_) => _EditCloudDialog(location: loc),
    );
    if (edited == null || !mounted) return;
    _locations[i] = edited;
    await CloudLocationStore.save(_locations);
    setState(() {});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${edited.name}" güncellendi')),
    );
  }

  Future<void> _renameCloud(CloudLocation loc) async {
    final i = _locations.indexOf(loc);
    if (i < 0) return;
    final controller = TextEditingController(text: loc.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeniden adlandır'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Bağlantı adı'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Kaydet'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || name == loc.name) return;
    _locations[i] = loc.copyWith(name: name);
    await CloudLocationStore.save(_locations);
    if (mounted) setState(() {});
  }

  void _showCloudMenu(CloudLocation loc) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.cloud_rounded),
                title: Text(loc.name),
                subtitle: Text('${loc.provider} • ${loc.username}'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.edit_rounded),
                title: const Text('Düzenle'),
                onTap: () {
                  Navigator.pop(context);
                  _editCloud(loc);
                },
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_rename_outline_rounded),
                title: const Text('Yeniden adlandır'),
                onTap: () {
                  Navigator.pop(context);
                  _renameCloud(loc);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete_outline_rounded,
                    color: Theme.of(context).colorScheme.error),
                title: Text('Kaldır',
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
                onTap: () {
                  Navigator.pop(context);
                  _delete(loc);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bulut')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add_rounded),
        label: const Text('Bulut konumu ekle'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _showEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.cloud_rounded,
                      size: 64,
                      color: Colors.grey,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Henüz hesap eklenmedi.\nGoogle Drive, Dropbox, '
                      'OneDrive ve Box\'a tarayıcı girişiyle '
                      'bağlanabilir veya WebDAV tabanlı bulut '
                      'hesaplarınızı (Nextcloud, pCloud, Yandex Disk, '
                      'kendi sunucunuz) ekleyebilirsiniz.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _add,
                      icon: const Icon(Icons.add_rounded),
                      label: const Text('Bir bulut konumu ekle'),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                _gdriveTile(context),
                for (final name in kOAuthProviderNames)
                  _oauthTile(context, name),
                for (final loc in _locations) _locationTile(loc),
              ],
            ),
    );
  }

  /// Hiçbir hesap eklenmemiş ve hiçbir OAuth sağlayıcısı bağlı değilse
  /// boş durum gösterilir.
  bool get _showEmpty =>
      _locations.isEmpty &&
      !_gdriveConnected &&
      !_oauthConnected.containsValue(true);

  /// Google Drive satırı: bağlıysa gezinmeye, değilse bağlanma akışına açılır.
  Widget _gdriveTile(BuildContext context) {
    return ListTile(
      leading: Icon(
        _gdriveConnected ? Icons.cloud_done_rounded : Icons.cloud_queue_rounded,
        color: _gdriveConnected ? const Color(0xFF1E88E5) : Colors.grey,
      ),
      title: const Text('Google Drive'),
      subtitle: Text(
        _gdriveConnected
            ? (_gdriveEmail == null || _gdriveEmail!.isEmpty
                  ? 'Bağlı'
                  : _gdriveEmail!)
            : 'Bağlı değil — tarayıcıyla giriş yapın',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: _gdriveConnected
          ? const Icon(Icons.chevron_right_rounded)
          : FilledButton.tonal(
              onPressed: () => _openConnect(),
              child: const Text('Bağlan'),
            ),
      onTap: _gdriveConnected
          ? () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const GoogleDriveScreen()))
          : null,
    );
  }

  /// Dropbox / OneDrive / Box satırı: bağlıysa gezinmeye, değilse
  /// bağlanma akışına (ücretsiz client ID rehberi) açılır.
  Widget _oauthTile(BuildContext context, String name) {
    final connected = _oauthConnected[name] ?? false;
    return ListTile(
      leading: Icon(
        connected ? Icons.cloud_done_rounded : Icons.cloud_queue_rounded,
        color: connected ? Theme.of(context).colorScheme.primary : Colors.grey,
      ),
      title: Text(name),
      subtitle: Text(
        connected
            ? 'Bağlı ✓ — dokunup gezinin'
            : 'Bağlı değil — ücretsiz client ID ile bağlanın',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: connected
          ? const Icon(Icons.chevron_right_rounded)
          : FilledButton.tonal(
              onPressed: () => _openConnect(name),
              child: const Text('Bağlan'),
            ),
      onTap: connected
          ? () {
              final screen = oauthScreenFor(name);
              if (screen != null) {
                Navigator.of(context)
                    .push(MaterialPageRoute<void>(builder: (_) => screen));
              }
            }
          : null,
    );
  }

  Future<void> _openConnect([String provider = 'Google Drive']) async {
    final result = await showDialog<Object?>(
      context: context,
      builder: (_) => AddCloudDialog(initialProvider: provider),
    );
    await _afterDialog(result);
  }

  Widget _locationTile(CloudLocation loc) {
    return ListTile(
      leading: Icon(
        Icons.cloud_rounded,
        color: Theme.of(context).colorScheme.primary,
      ),
      title: Text(loc.name),
      subtitle: Text('${loc.provider} • ${loc.username}'),
      trailing: IconButton(
        icon: const Icon(Icons.more_vert_rounded),
        tooltip: 'Düzenle / sil',
        onPressed: () => _showCloudMenu(loc),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CloudBrowseScreen(location: loc)),
      ),
      onLongPress: () => _showCloudMenu(loc),
    );
  }
}

/// Kayıtlı WebDAV / Nextcloud hesabını düzenleme diyaloğu.
class _EditCloudDialog extends StatefulWidget {
  const _EditCloudDialog({required this.location});

  final CloudLocation location;

  @override
  State<_EditCloudDialog> createState() => _EditCloudDialogState();
}

class _EditCloudDialogState extends State<_EditCloudDialog> {
  late final TextEditingController _name;
  late final TextEditingController _url;
  late final TextEditingController _username;
  late final TextEditingController _password;

  @override
  void initState() {
    super.initState();
    final loc = widget.location;
    _name = TextEditingController(text: loc.name);
    _url = TextEditingController(text: loc.url);
    _username = TextEditingController(text: loc.username);
    _password = TextEditingController(text: loc.password);
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Bulut konumunu düzenle'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Bağlantı adı'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(labelText: 'WebDAV adresi (URL)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _username,
              decoration: const InputDecoration(labelText: 'Kullanıcı adı'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              decoration: const InputDecoration(labelText: 'Şifre'),
              obscureText: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Vazgeç'),
        ),
        FilledButton(
          onPressed: () {
            final name = _name.text.trim();
            final url = _url.text.trim();
            if (url.isEmpty) return;
            Navigator.pop(
              context,
              widget.location.copyWith(
                name: name.isEmpty ? widget.location.provider : name,
                url: url,
                username: _username.text.trim(),
                password: _password.text,
              ),
            );
          },
          child: const Text('Güncelle'),
        ),
      ],
    );
  }
}
