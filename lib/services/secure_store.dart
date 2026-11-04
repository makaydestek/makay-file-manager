import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Hassas değerler (parola, OAuth jetonu) için güvenli anahtar-değer deposu.
///
/// Android'de EncryptedSharedPreferences / Keystore kullanır. Birim
/// testlerinde [debugBackend] ile bellek içi harita enjekte edilir.
class SecureStore {
  SecureStore._();

  /// Android 6+: Keystore sarmalı AES-GCM (paket varsayılanı).
  static FlutterSecureStorage get _native => const FlutterSecureStorage(
        aOptions: AndroidOptions(),
      );

  /// Testlerde SharedPreferences mock'u gibi bellek deposu.
  @visibleForTesting
  static Map<String, String>? debugBackend;

  static Future<void> write(String key, String value) async {
    final mem = debugBackend;
    if (mem != null) {
      mem[key] = value;
      return;
    }
    try {
      await _native.write(key: key, value: value);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SecureStore.write($key) başarısız: $e');
      }
      rethrow;
    }
  }

  static Future<String?> read(String key) async {
    final mem = debugBackend;
    if (mem != null) return mem[key];
    try {
      return await _native.read(key: key);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SecureStore.read($key) başarısız: $e');
      }
      return null;
    }
  }

  static Future<void> delete(String key) async {
    final mem = debugBackend;
    if (mem != null) {
      mem.remove(key);
      return;
    }
    try {
      await _native.delete(key: key);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('SecureStore.delete($key) başarısız: $e');
      }
    }
  }
}
