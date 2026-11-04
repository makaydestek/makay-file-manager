import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Uygulama kilidi + biyometri (parmak izi / yüz) servisi.
///
/// PIN, tuz + SHA-256 ile saklanır (kasa AES anahtarından bağımsızdır).
/// Biyometri yalnızca cihaz destekliyorsa ve kullanıcı açtıysa kullanılır;
/// başarısız olursa PIN yedek kapı olarak kalır. Yanlış PIN'lerde kasa ile
/// aynı üstel geri çekilme uygulanır.
class AuthService {
  AuthService._();

  static const _pinHashKey = 'app_lock_pin_hash';
  static const _pinSaltKey = 'app_lock_pin_salt';
  static const _enabledKey = 'app_lock_enabled';
  static const _bioKey = 'app_lock_biometrics';
  static const _vaultBioKey = 'vault_biometrics';
  static const _timeoutKey = 'app_lock_timeout_sec';
  static const _lockoutKey = 'app_lock_lockout';

  /// Yanlış deneme sonrası bekleme (sn): 0 → 5 → 15 → 60 → 300 → 1800.
  static const List<int> lockoutBackoffSeconds = [0, 5, 15, 60, 300, 1800];

  /// Oturum kilidi: uygulama arka plana gidince [timeoutSeconds] sonra kilitlenir.
  static DateTime? _backgroundedAt;
  static bool _sessionUnlocked = false;

  static final LocalAuthentication _localAuth = LocalAuthentication();

  /// @visibleForTesting: kilitlenme zamanı enjeksiyonu.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  // ----------------------------------------------------------- ayarlar --

  static Future<bool> get isEnabled async =>
      (await _prefs).getBool(_enabledKey) ?? false;

  static Future<void> setEnabled(bool value) async {
    final p = await _prefs;
    await p.setBool(_enabledKey, value);
    if (!value) _sessionUnlocked = true;
  }

  static Future<bool> get biometricsEnabled async =>
      (await _prefs).getBool(_bioKey) ?? false;

  static Future<void> setBiometricsEnabled(bool value) async {
    await (await _prefs).setBool(_bioKey, value);
  }

  static Future<bool> get vaultBiometricsEnabled async =>
      (await _prefs).getBool(_vaultBioKey) ?? false;

  static Future<void> setVaultBiometricsEnabled(bool value) async {
    await (await _prefs).setBool(_vaultBioKey, value);
  }

  /// Arka planda kalınca kilitlenme süresi (saniye). 0 = hemen.
  static Future<int> get timeoutSeconds async =>
      (await _prefs).getInt(_timeoutKey) ?? 0;

  static Future<void> setTimeoutSeconds(int value) async {
    await (await _prefs).setInt(_timeoutKey, value.clamp(0, 3600));
  }

  static Future<bool> get hasPin async {
    final p = await _prefs;
    return (p.getString(_pinHashKey) ?? '').isNotEmpty &&
        (p.getString(_pinSaltKey) ?? '').isNotEmpty;
  }

  // ----------------------------------------------------------- biyometri --

  /// Cihazda biyometri kullanılabilir mi?
  static Future<bool> canUseBiometrics() async {
    try {
      if (!await _localAuth.isDeviceSupported()) return false;
      if (!await _localAuth.canCheckBiometrics) return false;
      final types = await _localAuth.getAvailableBiometrics();
      return types.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Biyometrik kimlik doğrulama. Başarıda true.
  static Future<bool> authenticateBiometric({
    String reason = 'Kimliğinizi doğrulayın',
  }) async {
    try {
      if (!await canUseBiometrics()) return false;
      return await _localAuth.authenticate(
        localizedReason: reason,
        persistAcrossBackgrounding: true,
        biometricOnly: false,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('biyometri: $e');
      return false;
    }
  }

  // ----------------------------------------------------------- PIN --

  static const int pinMin = 4;
  static const int pinMax = 12;

  static Future<void> setPin(String pin) async {
    if (pin.length < pinMin || pin.length > pinMax) {
      throw ArgumentError('PIN $pinMin–$pinMax hane olmalı');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN yalnızca rakam olmalı');
    }
    final salt = _randomBytes(16);
    final hash = _hashPin(pin, salt);
    final p = await _prefs;
    await p.setString(_pinSaltKey, base64Encode(salt));
    await p.setString(_pinHashKey, base64Encode(hash));
  }

  static Future<bool> verifyPin(String pin) async {
    if (await lockoutRemaining() > Duration.zero) return false;
    final p = await _prefs;
    final saltB64 = p.getString(_pinSaltKey);
    final hashB64 = p.getString(_pinHashKey);
    if (saltB64 == null || hashB64 == null) return false;
    final salt = base64Decode(saltB64);
    final expected = base64Decode(hashB64);
    final actual = _hashPin(pin, salt);
    if (actual.length != expected.length) {
      await _registerFailure();
      return false;
    }
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual[i] ^ expected[i];
    }
    if (diff != 0) {
      await _registerFailure();
      return false;
    }
    await _clearLockout();
    return true;
  }

  static Future<void> clearPin() async {
    final p = await _prefs;
    await p.remove(_pinHashKey);
    await p.remove(_pinSaltKey);
    await p.setBool(_enabledKey, false);
    await _clearLockout();
  }

  // ----------------------------------------------------------- kilitlenme --

  static Duration lockoutBackoff(int failures) {
    if (failures <= 0) return Duration.zero;
    final index = min(failures - 1, lockoutBackoffSeconds.length - 1);
    return Duration(seconds: lockoutBackoffSeconds[index]);
  }

  static Future<int> failedAttempts() async =>
      (await _readLockout())?.failures ?? 0;

  static Future<Duration> lockoutRemaining() async {
    final state = await _readLockout();
    if (state == null || state.failures <= 0) return Duration.zero;
    final end = state.last.add(lockoutBackoff(state.failures));
    final remaining = end.difference(now());
    if (remaining <= Duration.zero) return Duration.zero;
    return Duration(seconds: (remaining.inMilliseconds + 999) ~/ 1000);
  }

  static Future<({int failures, DateTime last})?> _readLockout() async {
    final p = await _prefs;
    final raw = p.getString(_lockoutKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final failures = (map['f'] as num).toInt();
      if (failures <= 0) return null;
      return (
        failures: failures,
        last: DateTime.fromMillisecondsSinceEpoch((map['t'] as num).toInt()),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _registerFailure() async {
    final p = await _prefs;
    final failures = (await _readLockout())?.failures ?? 0;
    await p.setString(
      _lockoutKey,
      jsonEncode({'f': failures + 1, 't': now().millisecondsSinceEpoch}),
    );
  }

  static Future<void> _clearLockout() async {
    await (await _prefs).remove(_lockoutKey);
  }

  // ----------------------------------------------------------- oturum --

  static bool get isSessionUnlocked => _sessionUnlocked;

  static void markUnlocked() => _sessionUnlocked = true;

  static void lockNow() => _sessionUnlocked = false;

  static void onPaused() {
    _backgroundedAt = DateTime.now();
  }

  /// Arka plandan dönüşte kilit gerekli mi?
  static Future<bool> shouldLockOnResume() async {
    if (!await isEnabled) return false;
    if (!await hasPin) return false;
    if (!_sessionUnlocked) return true;
    final at = _backgroundedAt;
    if (at == null) return false;
    final timeout = await timeoutSeconds;
    final elapsed = DateTime.now().difference(at).inSeconds;
    if (elapsed >= timeout) {
      _sessionUnlocked = false;
      return true;
    }
    return false;
  }

  /// Uygulama açılışında kilit ekranı gösterilmeli mi?
  static Future<bool> needsLockGate() async {
    if (!await isEnabled) return false;
    if (!await hasPin) return false;
    return !_sessionUnlocked;
  }

  // ----------------------------------------------------------- yardımcılar --

  static Uint8List _hashPin(String pin, List<int> salt) {
    final data = <int>[...salt, ...utf8.encode(pin)];
    // Birkaç tur SHA-256 ile basit yavaşlatma (kasa PBKDF2 kadar ağır değil;
    // uygulama kilidi kısa PIN + cihazda biyometri ile tamamlanır).
    var digest = sha256.convert(data).bytes;
    for (var i = 0; i < 5000; i++) {
      digest = sha256.convert([...salt, ...digest]).bytes;
    }
    return Uint8List.fromList(digest);
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}
