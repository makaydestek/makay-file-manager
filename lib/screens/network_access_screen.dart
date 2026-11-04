import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/ftp_server.dart';
import '../services/smb_server.dart';
import '../utils/app_paths.dart';
import '../widgets/tv_focusable.dart';

/// Ağdan erişim ekranı: gömülü FTP/FTPS ve SMB2 sunucularını başlat/durdur.
///
/// Referans uygulamadaki "Ağdan erişim" ekranının karşılığı: sunucu adresi
/// `ftp://<ip>:6586`, kullanıcı adı `admin`, şifre 4 haneli rakam (her
/// açılışta değişir), gizli dosyaları göster, BAŞLAT/DURDUR.
class NetworkAccessScreen extends StatefulWidget {
  const NetworkAccessScreen({super.key});

  @override
  State<NetworkAccessScreen> createState() => _NetworkAccessScreenState();
}

class _NetworkAccessScreenState extends State<NetworkAccessScreen> {
  MiniFtpServer? _server;
  MiniSmbServer? _smb;
  final _logLines = <String>[];

  bool _randomPassword = true;
  bool _showHidden = false;
  bool _readOnly = false;

  /// Paylaşılan kök: 'internal' | 'downloads'
  String _shareRoot = 'internal';

  /// Referans uygulamayla birebir: FTP kullanıcısı `admin`,
  /// şifre her açılışta 4 haneli rastgele rakam.
  final _username = 'admin';
  String _password = '';
  String _ipAddress = '…';
  final _rng = Random.secure();

  @override
  void initState() {
    super.initState();
    _password = _generatePassword();
    _resolveIp();
  }

  Future<void> _resolveIp() async {
    String? ip;
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final i in interfaces) {
        for (final a in i.addresses) {
          final addr = a.address;
          if (!addr.startsWith('127.') && addr.startsWith('192.168.')) {
            ip = addr;
            break;
          }
        }
        if (ip != null) break;
      }
      ip ??= interfaces
          .expand((i) => i.addresses)
          .map((a) => a.address)
          .firstWhere((addr) => !addr.startsWith('127.'),
              orElse: () => '127.0.0.1');
    } catch (_) {
      ip = '127.0.0.1';
    }
    if (mounted) setState(() => _ipAddress = ip!);
  }

  /// F Dosya Yöneticisi tarzı: kolay yazılır 4 haneli rakam (1000–9999).
  String _generatePassword() {
    final n = 1000 + _rng.nextInt(9000);
    return n.toString();
  }

  Future<void> _toggle() async {
    if (_server?.running ?? false) {
      await _server!.stop();
      setState(() {});
      return;
    }
    final root = await AppPaths.byCategory(_shareRoot);
    final server = MiniFtpServer(
      rootPath: root ?? '/',
      port: 6586,
      tlsPort: 6588,
      username: _username,
      password: _password,
      showHidden: _showHidden,
      readOnly: _readOnly,
    );
    server.log.listen((line) {
      if (!mounted) return;
      setState(() {
        _logLines.add(line);
        if (_logLines.length > 200) _logLines.removeAt(0);
      });
    });
    try {
      await server.start();
      if (mounted) setState(() => _server = server);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sunucu başlatılamadı: $e')),
        );
      }
    }
  }

  Future<void> _toggleSmb() async {
    if (_smb?.running ?? false) {
      await _smb!.stop();
      setState(() {});
      return;
    }
    final root = await AppPaths.byCategory(_shareRoot);
    final server = MiniSmbServer(
      rootPath: root ?? '/',
      port: 445,
      shareName: 'makay',
      showHidden: _showHidden,
      username: _username,
      password: _password,
    );
    server.log.listen((line) {
      if (!mounted) return;
      setState(() {
        _logLines.add(line);
        if (_logLines.length > 200) _logLines.removeAt(0);
      });
    });
    try {
      await server.start();
      if (mounted) setState(() => _smb = server);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('SMB sunucusu başlatılamadı: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final running = _server?.running ?? false;
    final smbRunning = _smb?.running ?? false;

    return Scaffold(
      appBar: AppBar(title: const Text('Ağdan erişim')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FTP Sunucusu', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Aynı ağdaki bilgisayar veya mobil cihazlardan, bir FTP '
                    'istemcisiyle bu cihazdaki dosyalara erişebilirsiniz.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Rastgele şifre'),
                    subtitle: Text(_randomPassword
                        ? 'F Dosya Yöneticisi gibi 4 haneli rakam'
                        : 'Kendi şifrenizi belirleyin'),
                    value: _randomPassword,
                    onChanged: running
                        ? null
                        : (v) => setState(() {
                              _randomPassword = v;
                              if (v) _password = _generatePassword();
                            }),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Salt okunur'),
                    subtitle: const Text(
                        'FTP üzerinden yükleme/silme/klasör oluşturma kapalı'),
                    value: _readOnly,
                    onChanged: running
                        ? null
                        : (v) => setState(() => _readOnly = v),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Paylaşılan kök'),
                    subtitle: Text(_shareRoot == 'downloads'
                        ? 'İndirilenler klasörü'
                        : 'Ana bellek (dahili depolama)'),
                    trailing: DropdownButton<String>(
                      value: _shareRoot,
                      onChanged: (running || smbRunning)
                          ? null
                          : (v) {
                              if (v != null) setState(() => _shareRoot = v);
                            },
                      items: const [
                        DropdownMenuItem(
                            value: 'internal', child: Text('Ana bellek')),
                        DropdownMenuItem(
                            value: 'downloads', child: Text('İndirilenler')),
                      ],
                    ),
                  ),
                  if (_randomPassword)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.lock_rounded),
                      title: Text('Şifre: $_password',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontFamily: 'monospace',
                            letterSpacing: 4,
                          )),
                      trailing: IconButton(
                        tooltip: 'Kopyala',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () async {
                          await Clipboard.setData(
                              ClipboardData(text: _password));
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Şifre panoya kopyalandı')),
                          );
                        },
                      ),
                    ),
                  if (!_randomPassword)
                    TextField(
                      decoration: const InputDecoration(
                        labelText: 'Şifre',
                        border: OutlineInputBorder(),
                        helperText: 'Kısa rakam önerilir (örn. 4 hane)',
                      ),
                      keyboardType: TextInputType.number,
                      enabled: !running,
                      onChanged: (v) => _password = v,
                    ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Gizli dosyaları göster'),
                    value: _showHidden,
                    onChanged: running
                        ? null
                        : (v) => setState(() => _showHidden = v),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_rounded),
                    title: Text('Kullanıcı adı: $_username'),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.language_rounded),
                    title: Text('Sunucu adresi: $_ipAddress:6586'),
                    subtitle: Text(
                      running
                          ? 'Kullanıcı: admin  •  Şifre yukarıda\n'
                              'Şifreli FTPS: $_ipAddress:6588 '
                              '(kendi kendine imzalı sertifika)'
                          : 'Şifreli FTPS: port 6588',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TvFocusable(
                    onActivate: _toggle,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: running
                            ? FilledButton.styleFrom(
                                backgroundColor: theme.colorScheme.error)
                            : null,
                        icon: Icon(running
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded),
                        label: Text(running ? 'DURDUR' : 'BAŞLAT'),
                        onPressed: _toggle,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('SMB2 paylaşımı (Windows — önerilen)',
                      style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Fotoğraf ve dosyaları Windows Fotoğraflar / varsayılan '
                    'uygulamalarla açmak için bunu kullanın. FTP klasör '
                    'görünümü dosyaları Edge ile açabilir; SMB normal '
                    'klasör gibi davranır. NTLMv2 kimlik doğrulama zorunlu '
                    '(yukarıdaki kullanıcı/şifre). Okuma/yazma açıktır — '
                    'yalnızca güvendiğiniz Wi-Fi ağında etkinleştirin.',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_shared_rounded),
                    title: Text(smbRunning
                        ? 'Paylaşım yolu: \\\\$_ipAddress\\makay'
                        : 'Paylaşım: \\\\IP\\makay (port 445)'),
                    subtitle: Text(
                      smbRunning
                          ? 'PC: Win+R → \\\\$_ipAddress\\makay · '
                              'Kullanıcı: $_username · Şifre: $_password'
                          : 'Kullanıcı: $_username · Şifre: FTP ile aynı',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TvFocusable(
                    onActivate: _toggleSmb,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        style: smbRunning
                            ? FilledButton.styleFrom(
                                backgroundColor: theme.colorScheme.error)
                            : null,
                        icon: Icon(smbRunning
                            ? Icons.stop_rounded
                            : Icons.play_arrow_rounded),
                        label: Text(smbRunning ? 'DURDUR' : 'BAŞLAT'),
                        onPressed: _toggleSmb,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Sunucu günlüğü', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_logLines.isEmpty)
                    Text('Henüz bağlantı yok.',
                        style: TextStyle(color: theme.colorScheme.outline))
                  else
                    Container(
                      height: 160,
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: ListView.builder(
                        itemCount: _logLines.length,
                        itemBuilder: (context, i) => Text(
                          _logLines[i],
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'İpucu: Windows\'ta fotoğraf/video açmak için SMB\'yi '
                'başlatıp Win+R → \\\\$_ipAddress\\makay yazın. '
                'FTP için Dosya Gezgini adres çubuğuna '
                'ftp://$_ipAddress:6586 yazın (tarayıcıdan açmayın; '
                'Edge ile açılır). Kullanıcı: admin · Şifre: yukarıdaki '
                '4 haneli kod.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _server?.stop();
    _smb?.stop();
    super.dispose();
  }
}
