import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:package_info_plus/package_info_plus.dart';

import '../services/update_service.dart';
import '../utils/formats.dart';

/// "Güncelleme bulundu" diyaloğu: indir → SHA256 doğrula → kur.
Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (context) => _UpdateDialog(info: info),
  );
}

enum _Phase { idle, downloading, verifying, ready, error }

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.info});

  final UpdateInfo info;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  _Phase _phase = _Phase.idle;
  double _progress = 0;
  String _error = '';
  String _currentVersion = '';

  @override
  void initState() {
    super.initState();
    // Karşılaştırma için mevcut sürümü göster.
    PackageInfo.fromPlatform()
        .then((p) => mounted ? setState(() => _currentVersion = p.version) : null)
        .catchError((_) {});
  }

  Future<void> _start() async {
    setState(() {
      _phase = _Phase.downloading;
      _progress = 0;
    });
    try {
      final file = await UpdateService.download(widget.info, (received, total) {
        if (!mounted) return;
        setState(() =>
            _progress = total > 0 ? (received / total).clamp(0.0, 1.0) : 0);
      });
      if (!mounted) return;
      // SHA256 zorunlu — özet yoksa veya eşleşmezse kurulum yapılmaz.
      setState(() => _phase = _Phase.verifying);
      final ok = await UpdateService.verifySha256(file, widget.info.sha256);
      if (!mounted) return;
      if (!ok) {
        try {
          await file.delete();
        } catch (_) {}
        setState(() {
          _phase = _Phase.error;
          _error = widget.info.sha256.trim().isEmpty
              ? 'SHA256 özeti eksik — güvenlik nedeniyle kurulum iptal edildi.'
              : 'SHA256 doğrulaması başarısız — dosya bozuk, indirme iptal edildi.';
        });
        return;
      }
      await UpdateService.install(file);
      if (!mounted) return;
      setState(() => _phase = _Phase.ready);
    } on PlatformException catch (e) {
      // Kurucu açılamadı (kanal/izin hatası) — indirme başarılıydı.
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = e.code == 'install_error'
            ? 'Kurulum ekranı açılamadı. Ayarlar → Uygulamalar üzerinden '
                'güncelleme yapabilir ya da tekrar deneyebilirsin.'
            : 'Kurulum başlatılamadı: ${e.message ?? e.code}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.error;
        _error = 'İndirme hatası: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      icon: Icon(
        switch (_phase) {
          _Phase.error => Icons.error_outline_rounded,
          _Phase.ready => Icons.check_circle_outline_rounded,
          _Phase.downloading || _Phase.verifying =>
            Icons.system_update_rounded,
          _Phase.idle => Icons.new_releases_rounded,
        },
        color: switch (_phase) {
          _Phase.error => Colors.redAccent,
          _Phase.ready => Colors.green,
          _ => theme.colorScheme.primary,
        },
        size: 40,
      ),
      title: const Text('Güncelleme bulundu'),
      content: ConstrainedBox(
        // D-pad/TV'de dikey taşmayı önle.
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Yeni sürüm: ${widget.info.version}'
              '${_currentVersion.isEmpty ? '' : ' (mevcut: $_currentVersion)'}',
              style: theme.textTheme.bodyMedium,
            ),
            if (widget.info.size > 0) ...[
              const SizedBox(height: 4),
              Text(
                'İndirme boyutu: ${Formats.size(widget.info.size)} • '
                'SHA256 ile doğrulanacak',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (widget.info.notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest
                      .withValues(alpha: .5),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  widget.info.notes,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 12),
            switch (_phase) {
              _Phase.idle => Text(
                  'Güncellemeyi indirip kurmak ister misiniz?',
                  style: theme.textTheme.bodyMedium,
                ),
              _Phase.downloading => Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LinearProgressIndicator(value: _progress > 0 ? _progress : null),
                    const SizedBox(height: 8),
                    Text('İndiriliyor… %${(_progress * 100).toStringAsFixed(0)}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              _Phase.verifying => const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('SHA256 doğrulanıyor…'),
                  ],
                ),
              _Phase.ready => const Text(
                  'Kur penceresi açıldı. Yüklemek için "Kur" düğmesine basın.',
                ),
              _Phase.error => Text(
                  _error,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.redAccent),
                ),
            },
          ],
        ),
      ),
      actions: [
        if (_phase == _Phase.idle || _phase == _Phase.error)
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_phase == _Phase.error ? 'Kapat' : 'Daha sonra'),
          ),
        if (_phase == _Phase.idle || _phase == _Phase.error)
          FilledButton(
            onPressed: _start,
            child: Text(_phase == _Phase.error ? 'Tekrar dene' : 'İndir ve kur'),
          ),
        if (_phase == _Phase.ready)
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Tamam'),
          ),
      ],
    );
  }
}
