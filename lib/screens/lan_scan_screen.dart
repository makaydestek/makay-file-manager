import 'package:flutter/material.dart';

import '../services/lan_scan_service.dart';
import '../services/remote_service.dart';
import 'remote_screen.dart' show RemoteFormDialog;

/// Yerel ağ taraması: alt ağı tarar, SMB/FTP/SFTP/WebDAV sunucularını
/// listeler ve tek dokunuşla uzak konum olarak ekler.
///
/// Ekran, eklenen konumu [Navigator.pop] ile döndürür.
class LanScanScreen extends StatefulWidget {
  const LanScanScreen({super.key});

  @override
  State<LanScanScreen> createState() => _LanScanScreenState();
}

class _LanScanScreenState extends State<LanScanScreen> {
  List<LanDevice> _devices = [];
  bool _scanning = false;
  int _done = 0;
  int _total = 254;
  String? _subnet;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _scanning = true;
      _done = 0;
      _devices = [];
    });
        final subnet = await LanScanService.localSubnet();
    if (!mounted) return;
    setState(() => _subnet = subnet);
    if (subnet == null) {
      setState(() => _scanning = false);
      return;
    }
    final devices = await LanScanService.scan(
      onProgress: (done, total) {
        if (mounted) {
          setState(() {
            _done = done;
            _total = total;
          });
        }
      },
    );
    if (!mounted) return;
    devices.sort((a, b) => a.ip.compareTo(b.ip));
    setState(() {
      _devices = devices;
      _scanning = false;
    });
  }

  void _deviceOptions(LanDevice device) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.dns_rounded),
              title: Text(device.ip),
              subtitle: Text(device.summary),
            ),
            const Divider(height: 1),
            if (device.hasSmb)
              ListTile(
                leading: const Icon(Icons.folder_shared_rounded,
                    color: Color(0xFF00897B)),
                title: const Text('SMB paylaşımına bağlan'),
                subtitle: const Text('Windows / Samba paylaşımı (port 445)'),
                onTap: () => _add(device, 'smb'),
              ),
            if (device.hasFtp)
              ListTile(
                leading:
                    const Icon(Icons.dns_rounded, color: Color(0xFF00897B)),
                title: const Text('FTP sunucusuna bağlan'),
                onTap: () => _add(device, 'ftp'),
              ),
            if (device.hasSftp)
              ListTile(
                leading:
                    const Icon(Icons.lock_rounded, color: Color(0xFF00897B)),
                title: const Text('SFTP sunucusuna bağlan'),
                subtitle: const Text('SSH tabanlı (port 22)'),
                onTap: () => _add(device, 'sftp'),
              ),
            if (device.hasWebDav)
              ListTile(
                leading:
                    const Icon(Icons.cloud_rounded, color: Color(0xFF00897B)),
                title: const Text('WebDAV adresi ekle'),
                subtitle: Text('http://${device.ip} adresiyle başlar'),
                onTap: () => _add(device, 'webdav'),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _add(LanDevice device, String type) async {
    Navigator.of(context).pop(); // alt sayfa
    final defaults = RemoteLocation(
      name: '${type.toUpperCase()} ${device.ip}',
      host: type == 'webdav' ? 'http://${device.ip}' : device.ip,
      type: type,
      port: switch (type) {
        'smb' => 445,
        'sftp' => 22,
        'webdav' => 80,
        _ => 21,
      },
      username: type == 'ftp' ? 'anonymous' : '',
      share: '',
    );
    final loc = await showDialog<RemoteLocation>(
      context: context,
      builder: (_) => RemoteFormDialog(initialType: type, defaults: defaults),
    );
    if (loc != null && mounted) {
      Navigator.of(context).pop(loc); // konumu çağırya döndür
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Yerel ağ taraması'),
        actions: [
          if (!_scanning)
            IconButton(
              icon: const Icon(Icons.refresh_rounded),
              tooltip: 'Yeniden tara',
              onPressed: _start,
            ),
        ],
      ),
      body: _scanning
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                        'Taranan: $_subnet.x  ($_done / $_total adres)'),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                        value: _total > 0 ? _done / _total : null),
                    const SizedBox(height: 16),
                    Text(
                      '445 / 21 / 22 / 80 / 443 portları sınanır',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : _subnet == null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Yerel ağ adresi bulunamadı.\n'
                          'Wi-Fi\'ye bağlı olduğunuzdan emin olun.',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _start,
                          icon: const Icon(Icons.refresh_rounded),
                          label: const Text('Tekrar dene'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _start,
                  child: ListView(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          'Ağ: $_subnet.0/24 — '
                          '${_devices.length} cihaz bulundu',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'Bir cihaza dokunup protokol seçin; kayıt '
                          'uzak listesine eklenir.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      if (_devices.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                            child: Text(
                              'Paylaşım sunucusu bulunamadı.\n\n'
                              '• Bilgisayarda dosya paylaşımı / Samba açık mı?\n'
                              '• Telefon ile aynı Wi-Fi\'de misiniz?\n'
                              '• Güvenlik duvarı 445/21/22 portlarını '
                              'engelliyor olabilir.\n\n'
                              'Aşağı kaydırarak yeniden tarayın.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      for (final d in _devices)
                        ListTile(
                          leading: const Icon(Icons.computer_rounded,
                              color: Color(0xFF00897B)),
                          title: Text(d.ip),
                          subtitle: Text(d.summary),
                          trailing: Wrap(
                            spacing: 4,
                            children: [
                              if (d.hasSmb)
                                const Chip(
                                  label: Text('SMB'),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                              if (d.hasFtp)
                                const Chip(
                                  label: Text('FTP'),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                              if (d.hasSftp)
                                const Chip(
                                  label: Text('SFTP'),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                              if (d.hasWebDav)
                                const Chip(
                                  label: Text('DAV'),
                                  visualDensity: VisualDensity.compact,
                                  padding: EdgeInsets.zero,
                                ),
                            ],
                          ),
                          onTap: () => _deviceOptions(d),
                        ),
                    ],
                  ),
                ),
    );
  }
}
