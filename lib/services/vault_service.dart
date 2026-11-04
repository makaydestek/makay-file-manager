import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'category_size_service.dart';

/// Kasadaki bir şifreli dosyanın açılır kaydı.
class VaultEntry {
  const VaultEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.added,
  });

  /// '.enc' uzantısız dosya kimliği.
  final String id;

  /// Orijinal dosya adı (şifreli gövdenin başlığında saklanır).
  final String name;

  /// Orijinal boyut (bayt).
  final int size;

  /// Kasaya ekleme tarihi.
  final DateTime added;
}

/// PIN ile korunan, AES-256-GCM ile şifrelenmiş dosya kasası.
///
/// * Anahtar: PBKDF2-HMAC-SHA256, [kdfIterations] tur, 32 bayt;
///   tuz 16 bayt rastgele.
/// * PIN doğrulama: anahtarla şifrelenen bilinen metin ("doğrulayıcı").
/// * Kalıcılık: [SharedPreferences] içinde `vault_meta` (JSON) + kasa
///   dizininde `<id>.enc` dosyaları.
/// * Çevrimdışı kaba kuvveti yavaşlatmak için tur sayısı meta veride
///   saklanır (`kdfIterations`); eski kayıtlarda bu alan yoktur ve
///   [legacyKdfIterations] kullanılır — böylece 1.0.x kasaları açılmaya
///   devam eder.
/// * Çevrimiçi denemeleri yavaşlatmak için üstel geri çekilmeli
///   (backoff) kilitlenme uygulanır (bkz. [lockoutBackoffSeconds]).
///
/// Dosya biçimleri:
/// * **v1 (küçük dosya):** tek AES-GCM bloğu (nonce + şifre + etiket).
/// * **v2 / MKC1 (büyük dosya):** `MKC1` sihirli baytları + şifreli başlık +
///   1 MB'lık parça parça AES-GCM. Belleğe tüm dosyayı yüklemeden ekleme/
///   dışa aktarma yapılabilir.
class VaultService {
  VaultService._();

  static const String _prefsKey = 'vault_meta';
  static const int _formatVersion = 1;

  /// Parçalı (MKC1) biçim sihirli baytları.
  static const List<int> _mkc1Magic = [0x4d, 0x4b, 0x43, 0x31];

  /// MKC1 düz metin parça boyutu.
  static const int _plainChunkBytes = 1024 * 1024;

  /// Hatalı deneme/kilitlenme kaydının [SharedPreferences] anahtarı.
  static const String _lockoutKey = 'vault_lockout';

  /// Yeni kasalar ve yeni PIN'ler için PBKDF2-HMAC-SHA256 tur sayısı.
  ///
  /// Gerekçe: 1.0.x'te 20.000 tur kullanılıyordu; bu, verifier yanında
  /// saklanan kısa PIN'e karşı çevrimdışı kaba kuvveti ucuza yapılabiliyordu.
  /// 200.000 tur (10× artış) seçildi: pointycastle saf Dart'ta çalıştığı için
  /// tur sayısı cihaz kilidi açma gecikmesini doğrudan belirler; 200.000 tur
  /// orta seviye bir telefonda tek denemeyi ~0,5–0,8 sn aralığında tutarken
  /// çevrimdışı deneme maliyetini 10 katına çıkarır. OWASP'ın önerdiği
  /// 600.000 yerine bu değer, "tek açılış rahatlıkla 1 sn'nin altında"
  /// şartıyla dengelenerek seçildi.
  static const int kdfIterations = 200000;

  /// 1.0.x kasalarının anahtar türetme tur sayısı (meta veride `kdfIterations`
  /// alanı **yoksa** kullanılır; mevcut kasalar bu değerle açılmaya devam eder).
  static const int legacyKdfIterations = 20000;

  /// İzin verilen PIN uzunluğu (hanne).
  static const int pinMinLength = 6;
  static const int pinMaxLength = 12;

  /// Kasaya eklenebilecek tek dosya üst boyutu.
  ///
  /// MKC1 parçalı şifreleme sayesinde 64 MB üstü dosyalar da eklenir;
  /// tavan 512 MB (PIN değiştirmede yeniden şifreleme maliyeti).
  static const int maxAddBytes = 512 * 1024 * 1024;

  /// Bu boyuttan büyük dosyalar MKC1 parçalı biçime yazılır.
  static const int chunkedThresholdBytes = 4 * 1024 * 1024;

  /// Testlerde MKC1 eşiğini düşürmek için; üretimde null.
  @visibleForTesting
  static int? debugChunkedThresholdBytes;

  static int get _effectiveChunkedThreshold =>
      debugChunkedThresholdBytes ?? chunkedThresholdBytes;

  /// Testlerde eşiği düşürmek için; üretimde null.
  @visibleForTesting
  static int? debugMaxAddBytes;

  static int get _effectiveMaxAddBytes => debugMaxAddBytes ?? maxAddBytes;

  /// Arka arkaya hatalı deneme sayısına göre kilitlenme (saniye):
  /// 1. hata → 0 sn, 2. hata → 5 sn, 3. hata → 15 sn, 4. hata → 60 sn,
  /// 5. hata → 5 dk, 6. ve sonrası → 30 dk (üst sınır).
  static const List<int> lockoutBackoffSeconds = [0, 5, 15, 60, 300, 1800];

  static const int _saltLen = 16;
  static const int _ivLen = 12;
  static const int _tagLen = 16;
  static const int _keyLen = 32;

  /// Doğrulayıcı için anahtarla şifrelenen bilinen metin.
  static const String _verifierPlain = 'makay-vault-1';

  /// @visibleForTesting: kasa kökünü zorlar (testlerde geçici dizin).
  static String? debugRoot;

  /// Servisin gördüğü saat. Testlerde sahte zamanla beslenerek kilitlenme
  /// geri sayımları uyumaya gerek kalmadan sınanabilir.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static Uint8List? _key;

  /// Oturum boyunca (işlem belleğinde) tutulan PIN — biyometri ile
  /// yeniden açmak için. Uygulama süreci bitince silinir; diske yazılmaz.
  static String? _sessionPin;

  // ---------------------------------------------------------------- init --

  /// Uygulama açılışında çağrılabilir hazırlık adımı.
  static Future<void> init() async {}

  // ----------------------------------------------------------- anahtarlar --

  static bool get unlocked => _key != null;

  /// Bu oturumda biyometri ile yeniden açılabilir mi?
  static bool get hasSessionPin =>
      _sessionPin != null && _sessionPin!.isNotEmpty;

  /// Anahtarı bellekten atar (kasa kilitlenir).
  ///
  /// [clearSessionPin] true ise biyometri de bu oturumda kullanılamaz
  /// (varsayılan: false — kilit sonrası parmak izi ile tekrar açılabilir).
  static void lock({bool clearSessionPin = false}) {
    _key = null;
    if (clearSessionPin) _sessionPin = null;
  }

  static Uint8List _requireKey() {
    final key = _key;
    if (key == null) throw StateError('Kasa kilitli');
    return key;
  }

  // -------------------------------------------------------------- dizin --

  static Future<Directory> _vaultDir() async {
    final forced = debugRoot;
    if (forced != null) return Directory(forced);
    final base = await getApplicationSupportDirectory();
    return Directory('${base.path}${Platform.pathSeparator}vault');
  }

  static Future<Directory> _ensureDir() async {
    final dir = await _vaultDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static File _entryFile(Directory dir, String id) =>
      File('${dir.path}${Platform.pathSeparator}$id.enc');

  // ------------------------------------------------------------- meta --

  static Future<({Uint8List salt, Uint8List verifier, int kdfIterations})?>
      _readMeta() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return (
        salt: _fromHex(map['salt'] as String),
        verifier: _fromHex(map['verifier'] as String),
        // 1.0.x meta verisinde alan yok; eski tur sayısıyla açılır.
        kdfIterations:
            (map['kdfIterations'] as num?)?.toInt() ?? legacyKdfIterations,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeMeta(
      Uint8List salt, Uint8List verifier, int iterations) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode({
        'v': _formatVersion,
        'salt': _toHex(salt),
        'verifier': _toHex(verifier),
        'kdfIterations': iterations,
      }),
    );
  }

  /// PIN ayarlanmış mı.
  static Future<bool> isConfigured() async => (await _readMeta()) != null;

  /// PIN'in izin verilen uzunlukta yalnız hanelerden oluşup oluşmadığı.
  ///
  /// Yalnızca **yeni** PIN'lerde (oluşturma/değiştirme) geçerlidir; mevcut
  /// bir kasadaki eski, kısa PIN'ler açılışta hâlâ kabul edilir.
  static bool isValidPin(String pin) =>
      pin.length >= pinMinLength &&
      pin.length <= pinMaxLength &&
      RegExp(r'^[0-9]+$').hasMatch(pin);

  /// Kasa oluşturur: tuz + anahtar türetilir, doğrulayıcı kaydedilir.
  ///
  /// [pin] geçersizse (bkz. [isValidPin]) [ArgumentError] fırlatır.
  /// Başarıdan sonra hizmet anahtarla **açık** durumdadır; ekran istemese
  /// [lock] çağrılmalıdır.
  static Future<void> create(String pin) async {
    if (!isValidPin(pin)) {
      throw ArgumentError('PIN $pinMinLength-$pinMaxLength hane olmalı');
    }
    final salt = _randomBytes(_saltLen);
    final key = await _deriveKeyAsync(pin, salt, kdfIterations);
    final verifier = _encrypt(key, _plainBytes(_verifierPlain));
    await _writeMeta(salt, verifier, kdfIterations);
    await _ensureDir();
    await _clearLockout();
    _key = key;
    _sessionPin = pin;
  }

  /// Doğru PIN verilirse anahtarı belleğe alır; yanlışsa false döner.
  ///
  /// Kilitlenme süresi dolmadan hiçbir deneme anahtar türetmez ve false
  /// döner. Yanlış deneme sayacı artar, başarılı açılışta sıfırlanır.
  static Future<bool> unlock(String pin) async {
    if (await lockoutRemaining() > Duration.zero) return false;
    final meta = await _readMeta();
    if (meta == null) return false;
    final key = await _deriveKeyAsync(pin, meta.salt, meta.kdfIterations);
    if (!_checkVerifier(key, meta.verifier)) {
      await _registerFailure();
      return false;
    }
    await _clearLockout();
    _key = key;
    _sessionPin = pin;
    return true;
  }

  /// Oturum PIN'i ile yeniden aç (biyometri sonrası). Diskte PIN yok.
  static Future<bool> unlockWithSessionPin() async {
    final pin = _sessionPin;
    if (pin == null || pin.isEmpty) return false;
    return unlock(pin);
  }

  /// Tüm kasayı yeniden şifreler ve PIN'i değiştirir.
  ///
  /// [oldPin] yanlışsa [ArgumentError], [newPin] geçersizse (bkz.
  /// [isValidPin]) [ArgumentError] fırlatır. Yeni PIN her zaman güncel
  /// [kdfIterations] değeriyle türetilir; eski PIN kayıtlı tur sayısıyla
  /// doğrulanır.
  static Future<void> changePin(String oldPin, String newPin) async {
    if (!isValidPin(newPin)) {
      throw ArgumentError('PIN $pinMinLength-$pinMaxLength hane olmalı');
    }
    final meta = await _readMeta();
    if (meta == null) throw StateError('Kasa oluşturulmamış');
    final oldKey = await _deriveKeyAsync(oldPin, meta.salt, meta.kdfIterations);
    if (!_checkVerifier(oldKey, meta.verifier)) {
      throw ArgumentError('Eski PIN hatalı');
    }

    final dir = await _ensureDir();

    // Küçük dosyalar bellekte; MKC1 parçalı dosyalar diskten akışla
    // yeniden şifrelenir (OOM önlenir).
    final pending = <_PendingEntry>[];
    final chunkedIds = <String>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final fileName = _baseName(entity.path);
      if (!fileName.endsWith('.enc')) continue;
      final id = fileName.substring(0, fileName.length - 4);
      if (await _isChunkedFile(entity)) {
        final length = await entity.length();
        if (length > _effectiveMaxAddBytes + 65536) {
          throw StateError(
            'Kasada çok büyük dosya var; PIN değiştirilemedi: $fileName',
          );
        }
        chunkedIds.add(id);
        continue;
      }
      final bytes = await entity.readAsBytes();
      if (bytes.length > _effectiveMaxAddBytes + 4096) {
        throw StateError(
          'Kasada çok büyük dosya var; PIN değiştirilemedi: $fileName',
        );
      }
      final payload = _split(oldKey, bytes);
      pending.add(_PendingEntry(
        id: id,
        name: payload.name,
        size: payload.size,
        added: payload.added,
        content: payload.content,
      ));
    }

    final newSalt = _randomBytes(_saltLen);
    final newKey = await _deriveKeyAsync(newPin, newSalt, kdfIterations);

    // Atomik: once staging'e yaz, sonra dosyalari degistir, meta EN SONDA.
    final staging = Directory(
      '${dir.path}${Platform.pathSeparator}.pin_change_${DateTime.now().millisecondsSinceEpoch}',
    );
    await staging.create(recursive: true);
    final backups = <File>[];
    final stagedIds = <String>[
      ...pending.map((e) => e.id),
      ...chunkedIds,
    ];
    try {
      for (final item in pending) {
        final staged = File(
          '${staging.path}${Platform.pathSeparator}${item.id}.enc',
        );
        await staged.writeAsBytes(
          _join(
            newKey,
            name: item.name,
            size: item.size,
            added: item.added,
            content: item.content,
          ),
          flush: true,
        );
      }
      for (final id in chunkedIds) {
        final staged = File(
          '${staging.path}${Platform.pathSeparator}$id.enc',
        );
        await _reencryptChunked(
          oldKey: oldKey,
          newKey: newKey,
          source: _entryFile(dir, id),
          dest: staged,
        );
      }
      for (final id in stagedIds) {
        final dest = _entryFile(dir, id);
        final staged = File(
          '${staging.path}${Platform.pathSeparator}$id.enc',
        );
        if (await dest.exists()) {
          final bak = File('${dest.path}.bak');
          if (await bak.exists()) await bak.delete();
          await dest.rename(bak.path);
          backups.add(bak);
        }
        await staged.rename(dest.path);
      }
      final newVerifier = _encrypt(newKey, _plainBytes(_verifierPlain));
      await _writeMeta(newSalt, newVerifier, kdfIterations);
      await _clearLockout();
      _key = newKey;
      for (final bak in backups) {
        if (await bak.exists()) await bak.delete();
      }
    } catch (e) {
      // Geri al: .bak varsa geri koy.
      for (final bak in backups) {
        try {
          if (await bak.exists()) {
            final destPath = bak.path.substring(0, bak.path.length - 4);
            final dest = File(destPath);
            if (await dest.exists()) await dest.delete();
            await bak.rename(destPath);
          }
        } catch (_) {}
      }
      rethrow;
    } finally {
      try {
        if (await staging.exists()) {
          await staging.delete(recursive: true);
        }
      } catch (_) {}
    }
  }

  /// Kasayı ve PIN'i tamamen siler.
  static Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsKey);
    await prefs.remove(_lockoutKey);
    final dir = await _vaultDir();
    if (await dir.exists()) await dir.delete(recursive: true);
    _key = null;
  }

  // -------------------------------------------------------- kilitlenme --

  /// [failures] hatalı deneme sonrası bekleme (üstel geri çekilmeli).
  ///
  /// [lockoutBackoffSeconds] listesinden okunur; liste bittikten sonra
  /// son (en uzun) değer uygulanır.
  static Duration lockoutBackoff(int failures) {
    if (failures <= 0) return Duration.zero;
    final index = min(failures - 1, lockoutBackoffSeconds.length - 1);
    return Duration(seconds: lockoutBackoffSeconds[index]);
  }

  /// Kilitlenme kaydındaki arka arkaya hatalı deneme sayısı.
  ///
  /// Başarılı açılışta (ve kasa oluşturma/sıfırlamada) sıfırlanır.
  static Future<int> failedAttempts() async =>
      (await _readLockout())?.failures ?? 0;

  /// Kalan kilitlenme süresi; [Duration.zero] ise deneme serbesttir.
  ///
  /// Ekran bu değeri okuyup saniye saniye geri sayım gösterir.
  static Future<Duration> lockoutRemaining() async {
    final state = await _readLockout();
    if (state == null || state.failures <= 0) return Duration.zero;
    final end = state.last.add(lockoutBackoff(state.failures));
    final remaining = end.difference(now());
    if (remaining <= Duration.zero) return Duration.zero;
    // Tam saniyeye yukarı yuvarlanır ki geri sayım 5…4…3 diye başlasın.
    return Duration(seconds: (remaining.inMilliseconds + 999) ~/ 1000);
  }

  /// Kilitlenme kaydını okur (`{f: deneme, t: son hata (ms epoch)}`).
  static Future<({int failures, DateTime last})?> _readLockout() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_lockoutKey);
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

  /// Yanlış PIN'de sayacı bir artırır ve son hata zamanını günceller.
  static Future<void> _registerFailure() async {
    final prefs = await SharedPreferences.getInstance();
    final failures = (await _readLockout())?.failures ?? 0;
    await prefs.setString(
      _lockoutKey,
      jsonEncode({'f': failures + 1, 't': now().millisecondsSinceEpoch}),
    );
  }

  /// Hatalı deneme sayacını siler (başarılı açılışta çağrılır).
  static Future<void> _clearLockout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lockoutKey);
  }

  // -------------------------------------------------------------- dosya --

  /// Dosyayı kopyalayıp şifreler; **kaynak dosya silinmez**.
  ///
  /// Küçük dosyalar tek AES-GCM bloğu; [chunkedThresholdBytes] üstü MKC1
  /// parçalı biçimle diske akar (tüm içerik belleğe alınmaz).
  static Future<VaultEntry> add(File source) async {
    final key = _requireKey();
    final length = await source.length();
    final limit = _effectiveMaxAddBytes;
    if (length > limit) {
      throw StateError(
        'Dosya çok büyük (en fazla ${limit ~/ (1024 * 1024)} MB). '
        'Kasaya eklemek için daha küçük bir dosya seçin.',
      );
    }
    final added = DateTime.now();
    final name = _baseName(source.path);
    final id = _newId();
    final dir = await _ensureDir();
    final dest = _entryFile(dir, id);
    if (length > _effectiveChunkedThreshold) {
      await _writeChunked(
        dest,
        key,
        name: name,
        size: length,
        added: added,
        source: source,
      );
    } else {
      final content = await source.readAsBytes();
      await dest.writeAsBytes(
        _join(key,
            name: name, size: content.length, added: added, content: content),
        flush: true,
      );
    }
    return VaultEntry(id: id, name: name, size: length, added: added);
  }

  /// Kasadaki tüm dosyaların kayıtları (yeniden eskiye).
  static Future<List<VaultEntry>> list() async {
    final key = _requireKey();
    final dir = await _ensureDir();
    final result = <VaultEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final fileName = _baseName(entity.path);
      if (!fileName.endsWith('.enc')) continue;
      try {
        final meta = await _readEntryMeta(key, entity);
        result.add(VaultEntry(
          id: fileName.substring(0, fileName.length - 4),
          name: meta.name,
          size: meta.size,
          added: meta.added,
        ));
      } catch (_) {
        // Bozuk ya da bu anahtarla açılamayan kayıt atlanır.
        continue;
      }
    }
    result.sort((a, b) => b.added.compareTo(a.added));
    return result;
  }

  /// Kasadan bir dosyayı siler.
  static Future<void> remove(String id) async {
    final dir = await _ensureDir();
    final file = _entryFile(dir, id);
    if (await file.exists()) await file.delete();
  }

  /// Dosyayı çözüp [destDir] içine yazar; dönen dosya hedefin kendisidir.
  static Future<File> exportTo(String id, String destDir) async {
    final key = _requireKey();
    final dir = await _ensureDir();
    final enc = _entryFile(dir, id);
    final dest = Directory(destDir);
    if (!await dest.exists()) await dest.create(recursive: true);
    final meta = await _readEntryMeta(key, enc);
    final target = File(
        '${dest.path}${Platform.pathSeparator}${_safeName(meta.name)}');
    if (await _isChunkedFile(enc)) {
      await _exportChunked(key, enc, target);
    } else {
      final payload = _split(key, await enc.readAsBytes());
      await target.writeAsBytes(payload.content, flush: true);
    }
    await CategorySizeService.invalidate();
    return target;
  }

  // ---------------------------------------------------------- şifreleme --

  /// PBKDF2'yi arka izolatta çalıştırır — UI donmasını önler.
  static Future<Uint8List> _deriveKeyAsync(
    String pin,
    Uint8List salt,
    int iterations,
  ) {
    // İzolata yalnızca ilkel/kopyalanabilir veri gönderilir (sınıf yakalanmaz).
    final request = (
      pin: pin,
      salt: Uint8List.fromList(salt),
      iterations: iterations,
      keyLen: _keyLen,
    );
    return Isolate.run(() {
      final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
      derivator.init(
        Pbkdf2Parameters(request.salt, request.iterations, request.keyLen),
      );
      return derivator.process(Uint8List.fromList(utf8.encode(request.pin)));
    });
  }

  static bool _checkVerifier(Uint8List key, Uint8List verifier) {
    try {
      return listEquals(_decrypt(key, verifier), _plainBytes(_verifierPlain));
    } catch (_) {
      return false;
    }
  }

  /// AES-256-GCM: nonce(12) + şifreli içerik + etiket(16).
  static Uint8List _encrypt(Uint8List key, Uint8List plain) {
    final iv = _randomBytes(_ivLen);
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, ParametersWithIV(KeyParameter(key), iv));
    final out = cipher.process(plain);
    final blob = Uint8List(_ivLen + out.length);
    blob.setAll(0, iv);
    blob.setAll(_ivLen, out);
    return blob;
  }

  static Uint8List _decrypt(Uint8List key, Uint8List blob) {
    if (blob.length < _ivLen + _tagLen) {
      throw const FormatException('Bozuk kasa verisi');
    }
    final iv = blob.sublist(0, _ivLen);
    final body = blob.sublist(_ivLen);
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(false, ParametersWithIV(KeyParameter(key), iv));
    return cipher.process(body);
  }

  /// Şifreli gövde: [4 bayt başlık uzunluğu][başlık json][dosya içeriği].
  static Uint8List _join(
    Uint8List key, {
    required String name,
    required int size,
    required DateTime added,
    required Uint8List content,
  }) {
    final header = _plainBytes(jsonEncode({
      'n': name,
      's': size,
      'a': added.toIso8601String(),
    }));
    final body = Uint8List(4 + header.length + content.length);
    ByteData.sublistView(body).setUint32(0, header.length);
    body.setAll(4, header);
    body.setAll(4 + header.length, content);
    return _encrypt(key, body);
  }

  static ({String name, int size, DateTime added, Uint8List content}) _split(
      Uint8List key, Uint8List blob) {
    final body = _decrypt(key, blob);
    if (body.length < 4) throw const FormatException('Bozuk kasa kaydı');
    final headerLen = ByteData.sublistView(body).getUint32(0);
    if (headerLen < 0 || 4 + headerLen > body.length) {
      throw const FormatException('Bozuk kasa kaydı');
    }
    final header = jsonDecode(utf8.decode(body.sublist(4, 4 + headerLen)))
        as Map<String, dynamic>;
    return (
      name: header['n'] as String,
      size: (header['s'] as num).toInt(),
      added: DateTime.parse(header['a'] as String),
      content: body.sublist(4 + headerLen),
    );
  }

  static Future<bool> _isChunkedFile(File file) async {
    final raf = await file.open();
    try {
      if (await raf.length() < 4) return false;
      final magic = await raf.read(4);
      return magic.length == 4 &&
          magic[0] == _mkc1Magic[0] &&
          magic[1] == _mkc1Magic[1] &&
          magic[2] == _mkc1Magic[2] &&
          magic[3] == _mkc1Magic[3];
    } finally {
      await raf.close();
    }
  }

  static Future<({String name, int size, DateTime added})> _readEntryMeta(
    Uint8List key,
    File file,
  ) async {
    if (await _isChunkedFile(file)) {
      final header = await _readChunkedHeader(key, file);
      return (name: header.name, size: header.size, added: header.added);
    }
    final payload = _split(key, await file.readAsBytes());
    return (name: payload.name, size: payload.size, added: payload.added);
  }

  static Future<({String name, int size, DateTime added, int chunkSize})>
      _readChunkedHeader(Uint8List key, File file) async {
    final raf = await file.open();
    try {
      await raf.setPosition(4); // magic sonrası
      final lenBytes = await raf.read(4);
      if (lenBytes.length < 4) {
        throw const FormatException('Bozuk MKC1 başlığı');
      }
      final headerLen = ByteData.sublistView(lenBytes).getUint32(0);
      final enc = await raf.read(headerLen);
      if (enc.length != headerLen) {
        throw const FormatException('Bozuk MKC1 başlığı');
      }
      final map = jsonDecode(utf8.decode(_decrypt(key, enc)))
          as Map<String, dynamic>;
      return (
        name: map['n'] as String,
        size: (map['s'] as num).toInt(),
        added: DateTime.parse(map['a'] as String),
        chunkSize: (map['cs'] as num?)?.toInt() ?? _plainChunkBytes,
      );
    } finally {
      await raf.close();
    }
  }

  static Future<void> _writeChunked(
    File dest,
    Uint8List key, {
    required String name,
    required int size,
    required DateTime added,
    required File source,
  }) async {
    final raf = await dest.open(mode: FileMode.write);
    final src = await source.open();
    try {
      await raf.writeFrom(Uint8List.fromList(_mkc1Magic));
      final headerPlain = _plainBytes(jsonEncode({
        'n': name,
        's': size,
        'a': added.toIso8601String(),
        'cs': _plainChunkBytes,
      }));
      final headerEnc = _encrypt(key, headerPlain);
      final lenBuf = ByteData(4)..setUint32(0, headerEnc.length);
      await raf.writeFrom(lenBuf.buffer.asUint8List());
      await raf.writeFrom(headerEnc);

      var remaining = size;
      while (remaining > 0) {
        final n = min(_plainChunkBytes, remaining);
        final chunk = await src.read(n);
        if (chunk.length != n) {
          throw const FileSystemException('Dosya okuma yarım kaldı');
        }
        final enc = _encrypt(key, chunk);
        final cLen = ByteData(4)..setUint32(0, enc.length);
        await raf.writeFrom(cLen.buffer.asUint8List());
        await raf.writeFrom(enc);
        remaining -= n;
      }
    } finally {
      await src.close();
      await raf.close();
    }
  }

  static Future<void> _exportChunked(
    Uint8List key,
    File encFile,
    File target,
  ) async {
    final header = await _readChunkedHeader(key, encFile);
    final raf = await encFile.open();
    final out = await target.open(mode: FileMode.write);
    try {
      await raf.setPosition(4);
      final lenBytes = await raf.read(4);
      final headerLen = ByteData.sublistView(lenBytes).getUint32(0);
      await raf.setPosition(4 + 4 + headerLen);

      var remaining = header.size;
      while (remaining > 0) {
        final cLenBytes = await raf.read(4);
        if (cLenBytes.length < 4) {
          throw const FormatException('Bozuk MKC1 parçası');
        }
        final cLen = ByteData.sublistView(cLenBytes).getUint32(0);
        final enc = await raf.read(cLen);
        if (enc.length != cLen) {
          throw const FormatException('Bozuk MKC1 parçası');
        }
        final plain = _decrypt(key, enc);
        await out.writeFrom(plain);
        remaining -= plain.length;
      }
      if (remaining != 0) {
        throw const FormatException('MKC1 boyut uyuşmazlığı');
      }
    } finally {
      await raf.close();
      await out.close();
    }
  }

  /// PIN değişiminde MKC1 dosyasını parçaları belleğe toplamadan yeniden şifreler.
  static Future<void> _reencryptChunked({
    required Uint8List oldKey,
    required Uint8List newKey,
    required File source,
    required File dest,
  }) async {
    final header = await _readChunkedHeader(oldKey, source);
    final src = await source.open();
    final out = await dest.open(mode: FileMode.write);
    try {
      await src.setPosition(4);
      final oldHdrLenBytes = await src.read(4);
      final oldHdrLen = ByteData.sublistView(oldHdrLenBytes).getUint32(0);
      await src.setPosition(4 + 4 + oldHdrLen);

      await out.writeFrom(Uint8List.fromList(_mkc1Magic));
      final headerPlain = _plainBytes(jsonEncode({
        'n': header.name,
        's': header.size,
        'a': header.added.toIso8601String(),
        'cs': header.chunkSize,
      }));
      final headerEnc = _encrypt(newKey, headerPlain);
      final lenBuf = ByteData(4)..setUint32(0, headerEnc.length);
      await out.writeFrom(lenBuf.buffer.asUint8List());
      await out.writeFrom(headerEnc);

      var remaining = header.size;
      while (remaining > 0) {
        final cLenBytes = await src.read(4);
        if (cLenBytes.length < 4) {
          throw const FormatException('Bozuk MKC1 parçası');
        }
        final cLen = ByteData.sublistView(cLenBytes).getUint32(0);
        final enc = await src.read(cLen);
        if (enc.length != cLen) {
          throw const FormatException('Bozuk MKC1 parçası');
        }
        final plain = _decrypt(oldKey, enc);
        final reenc = _encrypt(newKey, plain);
        final nLen = ByteData(4)..setUint32(0, reenc.length);
        await out.writeFrom(nLen.buffer.asUint8List());
        await out.writeFrom(reenc);
        remaining -= plain.length;
      }
      if (remaining != 0) {
        throw const FormatException('MKC1 boyut uyuşmazlığı');
      }
    } finally {
      await src.close();
      await out.close();
    }
  }

  // ------------------------------------------------------------ yardımcı --

  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}${_toHex(_randomBytes(4))}';

  static String _baseName(String path) {
    final i = max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
    return i < 0 ? path : path.substring(i + 1);
  }

  static String _safeName(String name) =>
      name.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_');

  static Uint8List _plainBytes(String s) => Uint8List.fromList(utf8.encode(s));

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)));
  }

  static String _toHex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  static Uint8List _fromHex(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }
}

/// PIN değiştirirken dosyaların yeniden şifrelenmesi için bellekte tutulan
/// geçici kayıt.
class _PendingEntry {
  const _PendingEntry({
    required this.id,
    required this.name,
    required this.size,
    required this.added,
    required this.content,
  });

  final String id;
  final String name;
  final int size;
  final DateTime added;
  final Uint8List content;
}
