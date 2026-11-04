import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../theme/app_theme.dart';
import '../widgets/tv_focusable.dart';

/// Uygulama kilidi: PIN ve isteğe bağlı biyometri.
class AppLockScreen extends StatefulWidget {
  const AppLockScreen({super.key, required this.onUnlocked});

  final VoidCallback onUnlocked;

  @override
  State<AppLockScreen> createState() => _AppLockScreenState();
}

class _AppLockScreenState extends State<AppLockScreen> {
  final _pin = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _bioAvailable = false;
  bool _bioEnabled = false;
  Duration _lockoutLeft = Duration.zero;
  Timer? _lockoutTimer;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  @override
  void dispose() {
    _lockoutTimer?.cancel();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _prepare() async {
    await _refreshLockout();
    final can = await AuthService.canUseBiometrics();
    final enabled = await AuthService.biometricsEnabled;
    if (!mounted) return;
    setState(() {
      _bioAvailable = can;
      _bioEnabled = enabled;
    });
    if (can && enabled && _lockoutLeft == Duration.zero) {
      await _tryBio();
    }
  }

  Future<void> _refreshLockout() async {
    final remaining = await AuthService.lockoutRemaining();
    if (!mounted) return;
    setState(() => _lockoutLeft = remaining);
    _updateLockoutTimer();
  }

  void _updateLockoutTimer() {
    if (_lockoutLeft > Duration.zero) {
      _lockoutTimer ??= Timer.periodic(const Duration(seconds: 1), (_) async {
        final left = await AuthService.lockoutRemaining();
        if (!mounted) return;
        setState(() => _lockoutLeft = left);
        if (left == Duration.zero) {
          _lockoutTimer?.cancel();
          _lockoutTimer = null;
        }
      });
    } else {
      _lockoutTimer?.cancel();
      _lockoutTimer = null;
    }
  }

  Future<void> _tryBio() async {
    if (_lockoutLeft > Duration.zero) return;
    setState(() => _busy = true);
    final ok = await AuthService.authenticateBiometric(
      reason: 'Makay Dosya Yöneticisi kilidini açın',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (ok) {
      AuthService.markUnlocked();
      widget.onUnlocked();
    }
  }

  Future<void> _submit() async {
    if (_lockoutLeft > Duration.zero) return;
    final pin = _pin.text.trim();
    if (pin.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await AuthService.verifyPin(pin);
    if (!mounted) return;
    if (ok) {
      AuthService.markUnlocked();
      widget.onUnlocked();
      return;
    }
    await _refreshLockout();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = _lockoutLeft > Duration.zero
          ? 'Çok fazla hatalı deneme — ${_lockoutLeft.inSeconds} sn bekleyin'
          : 'PIN hatalı';
      _pin.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedOut = _lockoutLeft > Duration.zero;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_rounded,
                      size: 64, color: AppTheme.accent),
                  const SizedBox(height: 16),
                  Text(
                    'Uygulama kilitli',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    lockedOut
                        ? 'Çok fazla hatalı deneme. '
                            '${_lockoutLeft.inSeconds} saniye sonra yeniden deneyin.'
                        : 'Devam etmek için PIN veya biyometri kullanın',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 28),
                  TextField(
                    controller: _pin,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    maxLength: AuthService.pinMax,
                    enabled: !_busy && !lockedOut,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'PIN',
                      counterText: '',
                      errorText: _error,
                      border: const OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 12),
                  TvFocusable(
                    autofocus: true,
                    onActivate: (_busy || lockedOut) ? null : _submit,
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: (_busy || lockedOut) ? null : _submit,
                        child: _busy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Kilit aç'),
                      ),
                    ),
                  ),
                  if (_bioAvailable && _bioEnabled) ...[
                    const SizedBox(height: 12),
                    TvFocusable(
                      onActivate: (_busy || lockedOut) ? null : _tryBio,
                      child: TextButton.icon(
                        onPressed: (_busy || lockedOut) ? null : _tryBio,
                        icon: const Icon(Icons.fingerprint_rounded),
                        label: const Text('Biyometri ile aç'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
