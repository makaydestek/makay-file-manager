import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../services/auth_service.dart';
import '../services/vault_service.dart';
import '../theme/app_theme.dart';
import '../utils/formats.dart';
import '../widgets/tv_focusable.dart';

/// Kasa (gizli klasör) ekranı: PIN oluşturma, kilitleme/açma, listeleme,
/// dışa aktarma ve silme.
class VaultScreen extends StatefulWidget {
  const VaultScreen({super.key});

  @override
  State<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends State<VaultScreen> {
  final TextEditingController _pin = TextEditingController();
  final TextEditingController _pinConfirm = TextEditingController();
  final TextEditingController _pinCreate = TextEditingController();

  bool _loading = true;
  bool _configured = false;
  bool _unlocked = false;
  List<VaultEntry> _entries = const [];
  String? _error;

  /// Kalan kilitlenme süresi; sıfırsa kilitleme/açma serbesttir.
  Duration _lockoutLeft = Duration.zero;

  /// Servisteki arka arkaya hatalı deneme sayısı.
  int _failures = 0;

  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _pin.dispose();
    _pinConfirm.dispose();
    _pinCreate.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final configured = await VaultService.isConfigured();
    var unlocked = configured && VaultService.unlocked;
    var entries = const <VaultEntry>[];
    if (unlocked) {
      entries = await VaultService.list();
      unlocked = true;
    }
    final lockout = await VaultService.lockoutRemaining();
    final failures = await VaultService.failedAttempts();
    if (!mounted) return;
    setState(() {
      _configured = configured;
      _unlocked = unlocked;
      _entries = entries;
      _lockoutLeft = lockout;
      _failures = failures;
      _loading = false;
    });
    _updateLockoutTimer();
  }

  // ----------------------------------------------------------- kilitlenme --

  /// Kilitlenme sürerken geri sayımın saniyede bir azalmasını sağlar.
  void _updateLockoutTimer() {
    if (_lockoutLeft > Duration.zero) {
      _lockoutTimer ??=
          Timer.periodic(const Duration(seconds: 1), (_) => _lockoutTick());
    } else if (_lockoutTimer != null) {
      _lockoutTimer!.cancel();
      _lockoutTimer = null;
    }
  }

  void _lockoutTick() {
    if (!mounted) {
      _lockoutTimer?.cancel();
      _lockoutTimer = null;
      return;
    }
    setState(() {
      _lockoutLeft -= const Duration(seconds: 1);
      if (_lockoutLeft < Duration.zero) _lockoutLeft = Duration.zero;
      if (_lockoutLeft == Duration.zero && _failures > 0) {
        // Süre doldu: kalan deneme bilgisi tekrar gösterilir. Kalan süre
        // kesin olarak servisten gelir; kullanıcı denemesinde servis yine
        // esas kaynağıdır.
        _error = _wrongPinText(_failures);
      }
    });
    if (_lockoutLeft == Duration.zero) {
      _lockoutTimer?.cancel();
      _lockoutTimer = null;
    }
  }

  /// Uzun (30 dk) kilitlenmeye kalan hatalı deneme sayısı.
  int _remainingAttempts(int failures) {
    final capIndex = VaultService.lockoutBackoffSeconds.length - 1;
    return failures >= capIndex ? 0 : capIndex - failures;
  }

  String _wrongPinText(int failures) =>
      'PIN hatalı. Kalan deneme: ${_remainingAttempts(failures)}';

  String _lockoutText(Duration remaining) =>
      'PIN için çok fazla deneme yapıldı. ${_countdownText(remaining)}';

  String _countdownText(Duration remaining) {
    final seconds = remaining.inSeconds;
    if (seconds < 60) return '$seconds saniye sonra tekrar deneyin';
    final minutes = (seconds + 59) ~/ 60;
    if (minutes < 60) return '$minutes dakika sonra tekrar deneyin';
    return '${(minutes + 59) ~/ 60} saat sonra tekrar deneyin';
  }

  // ------------------------------------------------------------- eylemler --

  Future<void> _create() async {
    final pin = _pinCreate.text.trim();
    final confirm = _pinConfirm.text.trim();
    if (!VaultService.isValidPin(pin)) {
      setState(() => _error =
          'PIN ${VaultService.pinMinLength} ile ${VaultService.pinMaxLength} '
          'hane arasında olmalı');
      return;
    }
    if (pin != confirm) {
      setState(() => _error = 'PIN\'ler eşleşmiyor');
      return;
    }
    setState(() {
      _error = null;
      _loading = true;
    });
    await VaultService.create(pin);
    // Ekran, kilidi yeniden kapatıp PIN girişini ister.
    VaultService.lock();
    _pin.clear();
    _pinConfirm.clear();
    _pinCreate.clear();
    if (!mounted) return;
    setState(() => _loading = false);
    await _refresh();
  }

  Future<void> _unlock() async {
    if (_lockoutLeft > Duration.zero) return;
    final pin = _pin.text.trim();
    setState(() {
      _error = null;
      _loading = true;
    });
    final ok = await VaultService.unlock(pin);
    if (!mounted) return;
    setState(() => _loading = false);
    if (!ok) {
      final remaining = await VaultService.lockoutRemaining();
      final failures = await VaultService.failedAttempts();
      if (!mounted) return;
      final lockedOut = remaining > Duration.zero;
      setState(() {
        _lockoutLeft = remaining;
        _failures = failures;
        _error = lockedOut ? null : _wrongPinText(failures);
      });
      _updateLockoutTimer();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(lockedOut ? _lockoutText(remaining) : 'PIN hatalı'),
        ),
      );
      return;
    }
    _pin.clear();
    await _refresh();
  }

  /// Biyometri: PIN diske yazılmaz; yalnızca bu oturumda daha önce
  /// girilmiş PIN ile yeniden açılır. Süreç yeniden başlarsa önce PIN gerekir.
  Future<void> _unlockBiometric() async {
    if (_lockoutLeft > Duration.zero) return;
    if (!VaultService.hasSessionPin) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Biyometri için önce bir kez PIN ile açın '
            '(oturum boyunca geçerli)',
          ),
        ),
      );
      return;
    }
    final enabled = await AuthService.vaultBiometricsEnabled;
    if (!enabled) return;
    final bio = await AuthService.authenticateBiometric(
      reason: 'Kasayı açmak için doğrulayın',
    );
    if (!bio || !mounted) return;
    setState(() => _loading = true);
    final ok = await VaultService.unlockWithSessionPin();
    if (!mounted) return;
    setState(() => _loading = false);
    if (ok) {
      await _refresh();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Biyometri ile açılamadı; PIN deneyin')),
      );
    }
  }

  /// TV/OK ve satır dokunuşu: dışa aktar / sil seçenekleri.
  Future<void> _entryActions(VaultEntry entry) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.description_rounded),
              title: Text(entry.name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(Formats.size(entry.size)),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.file_download_rounded),
              title: const Text('Dışa aktar'),
              onTap: () => Navigator.pop(context, 'export'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('Sil'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'export') await _export(entry);
    if (action == 'delete') await _delete(entry);
  }

  Future<void> _export(VaultEntry entry) async {
    final String dest;
    try {
      final docs = await getApplicationDocumentsDirectory();
      dest = '${docs.path}${Platform.pathSeparator}Download';
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İndirme klasörü bulunamadı')),
      );
      return;
    }
    try {
      final file = await VaultService.exportTo(entry.id, dest);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Dışa aktarıldı: ${file.path}')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dışa aktarma başarısız oldu')),
      );
    }
  }

  Future<void> _delete(VaultEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kasadan sil'),
        content: Text('"${entry.name}" kalıcı olarak silinecek. Emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SİL'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await VaultService.remove(entry.id);
    if (!mounted) return;
    await _refresh();
  }

  Future<void> _changePin() async {
    final result = await showDialog<({String oldPin, String newPin})>(
      context: context,
      builder: (context) => const _ChangePinDialog(),
    );
    if (result == null || !mounted) return;
    try {
      await VaultService.changePin(result.oldPin, result.newPin);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('PIN değiştirilemedi')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PIN değiştirildi')),
    );
    await _refresh();
  }

  Future<void> _reset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Kasayı sıfırla'),
        content: const Text(
            'Tüm dosyalar ve PIN kalıcı olarak silinecek. Bu işlem geri '
            'alınamaz. Emin misiniz?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SIFIRLA'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await VaultService.reset();
    if (!mounted) return;
    setState(() => _error = null);
    await _refresh();
  }

  // ---------------------------------------------------------------- build --

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Kasa')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (!_configured) return _buildCreate();
    if (!_unlocked) return _buildLocked();
    return _buildOpen();
  }

  Widget _buildCreate() {
    return Scaffold(
      appBar: AppBar(title: const Text('Kasa Oluştur')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Dosyalarınızı korumak için bir PIN belirleyin. 6 ile 12 hane '
            'kullanabilirsiniz; 8 hane ve üzeri PIN\'ler önerilir. '
            'PIN unutulursa dosyalar kurtarılamaz.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pinCreate,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: VaultService.pinMaxLength,
            decoration: const InputDecoration(
              labelText: 'PIN',
              helperText: '6-12 hane; 8 hane ve üzeri önerilir',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pinConfirm,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: VaultService.pinMaxLength,
            decoration: const InputDecoration(
              labelText: 'PIN (tekrar)',
              helperText: '6-12 hane; 8 hane ve üzeri önerilir',
              border: OutlineInputBorder(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _create,
            child: const Text('OLUŞTUR'),
          ),
        ],
      ),
    );
  }

  Widget _buildLocked() {
    final lockedOut = _lockoutLeft > Duration.zero;
    return Scaffold(
      appBar: AppBar(title: const Text('Kasa')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const SizedBox(height: 24),
          Icon(Icons.lock_outline_rounded, size: 64, color: AppTheme.accent),
          const SizedBox(height: 24),
          FutureBuilder<bool>(
            future: AuthService.vaultBiometricsEnabled,
            builder: (context, snap) {
              if (snap.data != true) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: TvFocusable(
                  onActivate: lockedOut ? null : _unlockBiometric,
                  child: OutlinedButton.icon(
                    onPressed: lockedOut ? null : _unlockBiometric,
                    icon: const Icon(Icons.fingerprint_rounded),
                    label: const Text('Biyometri ile aç'),
                  ),
                ),
              );
            },
          ),
          TextField(
            controller: _pin,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: VaultService.pinMaxLength,
            decoration: const InputDecoration(
              labelText: 'PIN',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _unlock(),
          ),
          if (lockedOut) ...[
            const SizedBox(height: 12),
            Text(
              _lockoutText(_lockoutLeft),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ] else if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 20),
          TvFocusable(
            autofocus: true,
            onActivate: lockedOut || _loading ? null : _unlock,
            child: FilledButton(
              // Kilitlenme süresince açma denemesi yapılamaz.
              onPressed: lockedOut || _loading ? null : _unlock,
              child: const Text('KİLİT AÇ'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpen() {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Kasa'),
        actions: [
          IconButton(
            icon: const Icon(Icons.lock_rounded),
            tooltip: 'Kilitle',
            onPressed: () {
              VaultService.lock();
              _refresh();
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: _refresh,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert_rounded),
            onSelected: (value) {
              switch (value) {
                case 'pin':
                  _changePin();
                case 'reset':
                  _reset();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'pin', child: Text('PIN\'i değiştir')),
              PopupMenuItem(value: 'reset', child: Text('Kasayı sıfırla')),
            ],
          ),
        ],
      ),
      body: _entries.isEmpty
          ? const Center(child: Text('Kasa boş'))
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, index) {
                final entry = _entries[index];
                return TvFocusable(
                  autofocus: index == 0,
                  onActivate: () => _entryActions(entry),
                  scale: 1.02,
                  child: ListTile(
                    leading: Icon(Icons.description_rounded,
                        color: AppTheme.accent),
                    title: Text(entry.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                        '${Formats.size(entry.size)} • ${Formats.date(entry.added)}'),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.file_download_rounded),
                          tooltip: 'Dışa aktar',
                          onPressed: () => _export(entry),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline_rounded),
                          tooltip: 'Sil',
                          onPressed: () => _delete(entry),
                        ),
                      ],
                    ),
                    onTap: () => _entryActions(entry),
                  ),
                );
              },
            ),
      // FAB yok: dosya ekleme tarayıcıdan "Kasaya taşı" ile yapılır.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.all(12),
        child: Text(
          'Dosyalara tarayıcıdan uzun basıp "Kasaya taşı" ile ekleyin.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
  }
}

/// "PIN'i değiştir" diyaloğu: eski PIN + yeni PIN + tekrar.
class _ChangePinDialog extends StatefulWidget {
  const _ChangePinDialog();

  @override
  State<_ChangePinDialog> createState() => _ChangePinDialogState();
}

class _ChangePinDialogState extends State<_ChangePinDialog> {
  final TextEditingController _old = TextEditingController();
  final TextEditingController _new = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _old.dispose();
    _new.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _submit() {
    final oldPin = _old.text.trim();
    final newPin = _new.text.trim();
    if (oldPin.isEmpty) {
      setState(() => _error = 'Eski PIN boş olamaz');
      return;
    }
    if (!VaultService.isValidPin(newPin)) {
      setState(() => _error = 'Yeni PIN ${VaultService.pinMinLength} ile '
          '${VaultService.pinMaxLength} hane arasında olmalı');
      return;
    }
    if (newPin != _confirm.text.trim()) {
      setState(() => _error = 'Yeni PIN\'ler eşleşmiyor');
      return;
    }
    Navigator.pop(context, (oldPin: oldPin, newPin: newPin));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('PIN\'i değiştir'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _old,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: VaultService.pinMaxLength,
              decoration: const InputDecoration(labelText: 'Eski PIN'),
            ),
            TextField(
              controller: _new,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: VaultService.pinMaxLength,
              decoration: const InputDecoration(
                labelText: 'Yeni PIN',
                helperText: '6-12 hane; 8 hane ve üzeri önerilir',
              ),
            ),
            TextField(
              controller: _confirm,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: VaultService.pinMaxLength,
              decoration: const InputDecoration(labelText: 'Yeni PIN (tekrar)'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('İptal'),
        ),
        FilledButton(
          onPressed: _submit,
          child: const Text('DEĞİŞTİR'),
        ),
      ],
    );
  }
}
