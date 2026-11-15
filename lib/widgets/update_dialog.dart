import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../services/update_service.dart';

/// Makay Cleaner [AppUpdateHost] ile aynı güncelleme diyaloğu.
///
/// Başlık → soru → güven notu → (notlar) → ilerleme → Güncelle / Ertele
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog<void>(
    context: context,
    // Cleaner: dışarı tıklayınca Ertele (indirme sırasında PopScope engeller).
    barrierDismissible: true,
    builder: (context) => _UpdateDialog(info: info),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _downloading = false;
  int _progress = 0;
  String? _error;

  Future<void> _start() async {
    if (_downloading) return;
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    try {
      final file = await UpdateService.download(widget.info, (received, total) {
        if (!mounted) return;
        final pct = total > 0
            ? ((received / total) * 100).round().clamp(0, 100)
            : 0;
        setState(() => _progress = pct);
      });
      if (!mounted) return;
      setState(() => _progress = 100);
      final ok = await UpdateService.verifySha256(file, widget.info.sha256);
      if (!mounted) return;
      if (!ok) {
        try {
          await file.delete();
        } catch (_) {}
        setState(() {
          _downloading = false;
          _error = widget.info.sha256.trim().isEmpty
              ? 'SHA-256 özeti bulunamadı veya geçersiz; kurulum iptal edildi.'
              : 'SHA-256 doğrulaması başarısız. Dosya değiştirilmiş olabilir; kurulum iptal edildi.';
        });
        return;
      }
      await UpdateService.install(file);
      if (!mounted) return;
      setState(() => _downloading = false);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = e.code == 'install_error'
            ? 'Kurulum ekranı açılamadı. Ayarlardan “Bilinmeyen uygulamalar” iznini açıp tekrar deneyin.'
            : 'Kurulum başlatılamadı: ${e.message ?? e.code}';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error =
            'İndirme başarısız. Bağlantınızı kontrol edip tekrar deneyin.';
      });
    }
  }

  void _postpone() {
    if (_downloading) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return PopScope(
      canPop: !_downloading,
      child: AlertDialog(
        title: Text('Yeni sürüm: ${widget.info.version}'),
        content: SizedBox(
          width: double.maxFinite,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Uygulamayı güncellemek ister misiniz?',
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Güncelleme yalnızca resmi GitHub Releases’ten indirilir. '
                    'Kurulumdan önce paket adı, imza ve (varsa) SHA-256 doğrulanır.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  if (_downloading) ...[
                    const SizedBox(height: 8),
                    LinearProgressIndicator(
                      value: _progress > 0 ? _progress / 100.0 : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _progress >= 100
                          ? 'Bütünlük kontrol ediliyor…'
                          : '%$_progress indiriliyor…',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _downloading ? null : _postpone,
            child: const Text('Ertele'),
          ),
          TextButton(
            onPressed: _downloading ? null : _start,
            child: Text(_downloading ? 'İndiriliyor…' : 'Güncelle'),
          ),
        ],
      ),
    );
  }
}
