import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:pointycastle/export.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'secure_store.dart';

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
    final prefsHas = (p.getString(_pinHashKey) ?? '').isNotEmpty &&
        (p.getString(_pinSaltKey) ?? '').isNotEmpty;
    if (prefsHas) return true;
    try {
      final secureHash = await SecureStore.read(_pinHashKey);
      final secureSalt = await SecureStore.read(_pinSaltKey);
      return (secureHash ?? '').isNotEmpty && (secureSalt ?? '').isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// PIN özeti/tuzu: önce şifreli depo, yoksa eski prefs kaydı (migrasyon).
  static Future<({String salt, String hash})?> _readPinRecord() async {
    try {
      final secureHash = await SecureStore.read(_pinHashKey);
      final secureSalt = await SecureStore.read(_pinSaltKey);
      if ((secureHash ?? '').isNotEmpty && (secureSalt ?? '').isNotEmpty) {
        return (salt: secureSalt!, hash: secureHash!);
      }
    } catch (_) {}
    final p = await _prefs;
    final hash = p.getString(_pinHashKey);
    final salt = p.getString(_pinSaltKey);
    if ((hash ?? '').isEmpty || (salt ?? '').isEmpty) return null;
    // Eski prefs kaydı: şifreli depoya taşı, düz kopyayı sil.
    try {
      await SecureStore.write(_pinHashKey, hash!);
      await SecureStore.write(_pinSaltKey, salt!);
      await p.remove(_pinHashKey);
      await p.remove(_pinSaltKey);
    } catch (_) {}
    return (salt: salt!, hash: hash!);
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

  static const int pinMin = 6;
  static const int pinMax = 12;

  /// PBKDF2-HMAC-SHA256 tur sayısı (kasa ile aynı sertlik sınıfı).
  ///
  /// PIN uzayı küçüktür; kilit HIZLI açılmalı ama çevrimdışı kaba kuvvete
  /// dayanıklı olmalı. Kasa erişimi 200.000 tur kullandığı için 100.000 tur
  /// (~60–120 ms) kilit ekranında fark edilmez bir gecikmedir.
  static const int kdfIterations = 100000;

  /// Yeni biçim önekı (eski kayıtlar öneksiz 5.001×SHA-256'dır).
  static const String _kdfPrefix = 'pbkdf2-sha256:';

  static Future<void> setPin(String pin) async {
    if (pin.length < pinMin || pin.length > pinMax) {
      throw ArgumentError('PIN $pinMin–$pinMax hane olmalı');
    }
    if (!RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN yalnızca rakam olmalı');
    }
    final salt = _randomBytes(16);
    final hash = await _derivePinAsync(pin, salt);
    await SecureStore.write(_pinSaltKey, base64Encode(salt));
    await SecureStore.write(_pinHashKey,
        '$_kdfPrefix$kdfIterations:${base64Encode(hash)}');
    // Eski düz kopya varsa temizlenir (yedeğe sızmasın).
    final p = await _prefs;
    await p.remove(_pinSaltKey);
    await p.remove(_pinHashKey);
  }

  static Future<bool> verifyPin(String pin) async {
    if (await lockoutRemaining() > Duration.zero) return false;
    final record = await _readPinRecord();
    if (record == null) return false;
    final salt = base64Decode(record.salt);
    final stored = record.hash;
    Uint8List expected;
    Uint8List actual;
    if (stored.startsWith(_kdfPrefix)) {
      final rest = stored.substring(_kdfPrefix.length);
      final sep = rest.indexOf(':');
      final iterations = sep > 0 ? int.tryParse(rest.substring(0, sep)) : null;
      expected = base64Decode(rest.substring(sep + 1));
      actual = await _derivePinAsync(pin, salt,
          iterations: iterations ?? kdfIterations);
    } else {
      // Eski kayıt: 5.001×SHA-256. Doğrulanınca yeni PBKDF2'ye yükseltilir.
      expected = base64Decode(stored);
      actual = _hashPinLegacy(pin, salt);
    }
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
    // Şeffaf yükseltme: legacy özet doğru açıldıysa yeni KDF ile yeniden yaz.
    if (!stored.startsWith(_kdfPrefix)) {
      try {
        final newSalt = _randomBytes(16);
        final newHash = await _derivePinAsync(pin, newSalt);
        await SecureStore.write(_pinSaltKey, base64Encode(newSalt));
        await SecureStore.write(_pinHashKey,
            '$_kdfPrefix$kdfIterations:${base64Encode(newHash)}');
      } catch (_) {
        // Yükseltme başarısız olsa da giriş geçerli.
      }
    }
    return true;
  }

  static Future<void> clearPin() async {
    try {
      await SecureStore.delete(_pinHashKey);
      await SecureStore.delete(_pinSaltKey);
    } catch (_) {}
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

  /// Eski (1.0.x) özet: 5.001×SHA-256. Yalnızca geriye dönük doğrulama için.
  static Uint8List _hashPinLegacy(String pin, List<int> salt) {
    final data = <int>[...salt, ...utf8.encode(pin)];
    var digest = sha256.convert(data).bytes;
    for (var i = 0; i < 5000; i++) {
      digest = sha256.convert([...salt, ...digest]).bytes;
    }
    return Uint8List.fromList(digest);
  }

  /// PBKDF2-HMAC-SHA256 (izolatta) — GPU tabanlı kaba kuvveti pahalılaştırır.
  static Future<Uint8List> _derivePinAsync(
    String pin,
    Uint8List salt, {
    int? iterations,
  }) {
    final request = (
      pin: pin,
      salt: Uint8List.fromList(salt),
      iterations: iterations ?? kdfIterations,
    );
    return Isolate.run(() {
      final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
      derivator.init(Pbkdf2Parameters(request.salt, request.iterations, 32));
      return derivator.process(Uint8List.fromList(utf8.encode(request.pin)));
    });
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}
