import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/vault_service.dart';
import 'package:pointycastle/export.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Kasa hizmeti: PIN/anahtar, AES-256-GCM şifreleme, dışa aktarma,
/// yeniden şifreleme, sıfırlama, üstel geri çekilmeli kilitlenme ve
/// geriye dönük uyumluluk (1.0.x meta verisi) akışları.
void main() {
  late Directory root;
  late Directory outside;

  setUp(() {
    root = Directory.systemTemp.createTempSync('vault_');
    outside = Directory.systemTemp.createTempSync('vault_src_');
    VaultService.debugRoot = root.path;
    // SharedPreferences, setMockInitialValues çağrısından sonra hazırlanır.
    SharedPreferences.setMockInitialValues({});
    VaultService.lock();
    VaultService.now = DateTime.now;
  });

  tearDown(() {
    VaultService.lock();
    VaultService.debugRoot = null;
    VaultService.now = DateTime.now;
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (outside.existsSync()) outside.deleteSync(recursive: true);
  });

  File makeSource(String name, String content) {
    final file = File('${outside.path}${Platform.pathSeparator}$name');
    file.writeAsStringSync(content);
    return file;
  }

  // ------------------------------------- 1.0.x biçimini yeniden üretmek --

  /// Deterministik test tuzu/nonce'ı (16 bayt tuz, 12 bayt nonce korunur).
  Uint8List testBytes(int length, int start) =>
      Uint8List.fromList(List<int>.generate(length, (i) => start + i));

  String testToHex(Uint8List bytes) => bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();

  Uint8List testPbkdf2(String pin, Uint8List salt, int iterations) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    derivator.init(Pbkdf2Parameters(salt, iterations, 32));
    return derivator.process(Uint8List.fromList(utf8.encode(pin)));
  }

  /// AES-256-GCM: nonce(12) + şifreli içerik + etiket(16) — 1.0.x ile aynı.
  Uint8List testEncrypt(Uint8List key, List<int> plain) {
    final iv = testBytes(12, 0xA0);
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, ParametersWithIV(KeyParameter(key), iv));
    final out = cipher.process(Uint8List.fromList(plain));
    return Uint8List.fromList([...iv, ...out]);
  }

  /// 1.0.x meta verisini yazar. [iterations] verilmezse alan **yazılmaz**
  /// (1.0.10'un yaptığı tam olarak budur) ve anahtar 20.000 turda türetilir.
  Future<void> writeMeta(String pin, Uint8List salt, {int? iterations}) async {
    final key = testPbkdf2(pin, salt, iterations ?? 20000);
    final verifier = testEncrypt(key, utf8.encode('makay-vault-1'));
    final meta = <String, dynamic>{
      'v': 1,
      'salt': testToHex(salt),
      'verifier': testToHex(verifier),
    };
    // 1.0.10 bu alanı hiç yazmıyordu; verilmezse alan yazılmaz.
    if (iterations != null) meta['kdfIterations'] = iterations;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('vault_meta', jsonEncode(meta));
  }

  /// 1.0.x dosya biçimi: [4 bayt başlık uzunluğu][başlık json][içerik],
  /// AES-256-GCM ile şifrelenir.
  Uint8List legacyEntry({
    required Uint8List key,
    required String name,
    required int size,
    required DateTime added,
    required Uint8List content,
  }) {
    final header = Uint8List.fromList(utf8.encode(jsonEncode({
      'n': name,
      's': size,
      'a': added.toIso8601String(),
    })));
    final body = Uint8List(4 + header.length + content.length);
    ByteData.sublistView(body).setUint32(0, header.length);
    body.setAll(4, header);
    body.setAll(4 + header.length, content);
    return testEncrypt(key, body);
  }

  Future<Map<String, dynamic>> readRawMeta() async {
    final prefs = await SharedPreferences.getInstance();
    return jsonDecode(prefs.getString('vault_meta')!) as Map<String, dynamic>;
  }

  test('create → unlocked; add → listede 1 kayıt, ad/boyut doğru',
      () async {
    expect(await VaultService.isConfigured(), isFalse);
    await VaultService.create('123456');
    expect(VaultService.unlocked, isTrue);
    expect(await VaultService.isConfigured(), isTrue);

    final source = makeSource('belge.txt', 'x' * 500);
    final entry = await VaultService.add(source);

    final items = await VaultService.list();
    expect(items, hasLength(1));
    expect(items.first.id, entry.id);
    expect(items.first.name, 'belge.txt');
    expect(items.first.size, 500);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('kasa dosyası şifreli; kaynak dosya yerinde kalır', () async {
    await VaultService.create('654321');
    const content = 'gizli-kasa-icerigi';
    final source = makeSource('sir.txt', content);
    await VaultService.add(source);

    final encFiles = root
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.enc'))
        .toList();
    expect(encFiles, hasLength(1));
    final enc = await encFiles.first.readAsBytes();
    // Şifreli gövde düz metin içermez ve GCM/nonce başlığı nedeniyle
    // orijinal içerikten daha uzundur.
    expect(enc, isNot(Uint8List.fromList(content.codeUnits)));
    expect(String.fromCharCodes(enc.where((b) => b >= 0x20 && b < 0x7f))
        .contains(content),
        isFalse);
    expect(enc.length, greaterThan(content.length));

    expect(source.existsSync(), isTrue);
    expect(source.readAsStringSync(), content);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('kilitsizken list throws; yanlış PIN false, doğru PIN true',
      () async {
    await VaultService.create('987654');
    VaultService.lock();
    expect(VaultService.unlocked, isFalse);

    await expectLater(VaultService.list(), throwsA(isA<StateError>()));

    expect(await VaultService.unlock('000000'), isFalse);
    expect(VaultService.unlocked, isFalse);
    expect(await VaultService.unlock('987654'), isTrue);
    expect(VaultService.unlocked, isTrue);
    // İlk hata 0 sn kilitlenme verir; başarılı açılış sayacı sıfırlar.
    expect(await VaultService.failedAttempts(), 0);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('exportTo çözülen baytları orijinalle birebir aynı', () async {
    await VaultService.create('135791');
    final bytes = List<int>.generate(300, (i) => i % 251);
    final source = File('${outside.path}${Platform.pathSeparator}veri.bin')
      ..writeAsBytesSync(bytes);
    final entry = await VaultService.add(source);

    final dest = Directory('${outside.path}${Platform.pathSeparator}disa');
    final out = await VaultService.exportTo(entry.id, dest.path);

    expect(out.readAsBytesSync(), bytes);
    expect(out.path.endsWith('veri.bin'), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('remove sonrası kayıt listeden düşer', () async {
    await VaultService.create('246813');
    final a = await VaultService.add(makeSource('a.txt', 'aaa'));
    await VaultService.add(makeSource('b.txt', 'bbb'));
    expect(await VaultService.list(), hasLength(2));

    await VaultService.remove(a.id);

    final items = await VaultService.list();
    expect(items, hasLength(1));
    expect(items.single.name, 'b.txt');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('changePin sonrası eski PIN açmaz, yeni PIN açar ve dosya çözülür',
      () async {
    await VaultService.create('111111');
    final content = 'yeniden-sifrelenmis';
    final entry =
        await VaultService.add(makeSource('not.txt', content));

    await VaultService.changePin('111111', '999999');

    VaultService.lock();
    expect(await VaultService.unlock('111111'), isFalse,
        reason: 'eski PIN artık çalışmamalı');
    expect(await VaultService.unlock('999999'), isTrue);

    final items = await VaultService.list();
    expect(items.single.name, 'not.txt');
    final out = await VaultService.exportTo(
        entry.id, '${outside.path}${Platform.pathSeparator}cp');
    expect(out.readAsStringSync(), content);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('maxAddBytes üstü dosya kasaya eklenemez', () async {
    VaultService.debugMaxAddBytes = 64;
    addTearDown(() => VaultService.debugMaxAddBytes = null);
    await VaultService.create('121212');
    final over = File('${outside.path}${Platform.pathSeparator}over.bin');
    await over.writeAsBytes(List<int>.filled(128, 7));
    await expectLater(
      VaultService.add(over),
      throwsA(isA<StateError>()),
    );
    final small = makeSource('ok.txt', 'kucuk');
    final entry = await VaultService.add(small);
    expect(entry.name, 'ok.txt');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('MKC1 parçalı biçim: ekle → listele → dışa aktar birebir', () async {
    // Eşiği düşürerek küçük dosyayla MKC1 yolunu sınarız.
    VaultService.debugChunkedThresholdBytes = 8;
    addTearDown(() => VaultService.debugChunkedThresholdBytes = null);
    await VaultService.create('343434');
    final payload = List<int>.generate(3000, (i) => i & 0xff);
    final source = File('${outside.path}${Platform.pathSeparator}chunk.bin')
      ..writeAsBytesSync(payload);
    final entry = await VaultService.add(source);
    expect(entry.size, payload.length);

    final listed = await VaultService.list();
    expect(listed.single.name, 'chunk.bin');
    expect(listed.single.size, payload.length);

    final out = await VaultService.exportTo(entry.id, outside.path);
    expect(out.readAsBytesSync(), payload);
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('reset sonrası isConfigured false ve kasa dizini silinir', () async {
    await VaultService.create('555555');
    await VaultService.add(makeSource('kayip.txt', 'zzz'));
    expect(await VaultService.isConfigured(), isTrue);

    await VaultService.reset();

    expect(await VaultService.isConfigured(), isFalse);
    expect(VaultService.unlocked, isFalse);
    expect(root.existsSync(), isFalse);
    expect(await VaultService.failedAttempts(), 0,
        reason: 'sıfırlama kilitlenme kaydını da silmeli');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // --------------------------------------------------------- kilitlenme --

  test('üstel geri çekilme çizelgesi: 0, 5, 15, 60, 300, 1800 saniye',
      () {
    expect(VaultService.lockoutBackoffSeconds, [0, 5, 15, 60, 300, 1800]);
    expect(VaultService.lockoutBackoff(0), Duration.zero);
    expect(VaultService.lockoutBackoff(1), Duration.zero,
        reason: 'ilk hata beklemez');
    expect(VaultService.lockoutBackoff(2), const Duration(seconds: 5));
    expect(VaultService.lockoutBackoff(3), const Duration(seconds: 15));
    expect(VaultService.lockoutBackoff(4), const Duration(seconds: 60));
    expect(VaultService.lockoutBackoff(5), const Duration(minutes: 5));
    expect(VaultService.lockoutBackoff(6), const Duration(minutes: 30),
        reason: 'üst sınır');
    expect(VaultService.lockoutBackoff(500), const Duration(minutes: 30),
        reason: 'üst sınır aşılırsa da 30 dk kalır');
  });

  test('2 hatalı PIN → 5 sn kilitlenme; süre dolunca ve başarılı açılışta '
      'sayımlar sıfırlanır', () async {
    await VaultService.create('123456');
    VaultService.lock();

    var fakeNow = DateTime(2026, 10, 11, 12);
    VaultService.now = () => fakeNow;

    // 1. hata: henüz bekleme yok.
    expect(await VaultService.unlock('000000'), isFalse);
    expect(await VaultService.failedAttempts(), 1);
    expect(await VaultService.lockoutRemaining(), Duration.zero);

    // 2. hata: 5 saniye kilitlenme.
    expect(await VaultService.unlock('111111'), isFalse);
    expect(await VaultService.failedAttempts(), 2);
    expect(await VaultService.lockoutRemaining(), const Duration(seconds: 5));

    // Kilitlenme sırasında doğru PIN bile açmaz ve sayaç değişmez.
    expect(await VaultService.unlock('123456'), isFalse);
    expect(VaultService.unlocked, isFalse);
    expect(await VaultService.failedAttempts(), 2);

    // Saat ilerletilir → kilit kalkar.
    fakeNow = fakeNow.add(const Duration(seconds: 5));
    expect(await VaultService.lockoutRemaining(), Duration.zero);

    // Doğru PIN açar ve hatalı deneme sayacını sıfırlar.
    expect(await VaultService.unlock('123456'), isTrue);
    expect(VaultService.unlocked, isTrue);
    expect(await VaultService.failedAttempts(), 0);
    expect(await VaultService.lockoutRemaining(), Duration.zero);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('her hatada kilitlenme süresi büyür ve 30 dakikada sabitlenir',
      () async {
    await VaultService.create('654321');
    VaultService.lock();

    var fakeNow = DateTime(2026, 10, 11, 8);
    VaultService.now = () => fakeNow;

    Future<void> fail() async {
      expect(await VaultService.unlock('000000'), isFalse);
    }

    Future<void> expire(Duration wait) async {
      fakeNow = fakeNow.add(wait);
      expect(await VaultService.lockoutRemaining(), Duration.zero);
    }

    await fail(); // 1 → 0 sn
    expect(await VaultService.lockoutRemaining(), Duration.zero);
    await expire(const Duration(seconds: 1));
    await fail(); // 2 → 5 sn
    expect(await VaultService.lockoutRemaining(), const Duration(seconds: 5));
    await expire(const Duration(seconds: 5));
    await fail(); // 3 → 15 sn
    expect(await VaultService.lockoutRemaining(), const Duration(seconds: 15));
    await expire(const Duration(seconds: 15));
    await fail(); // 4 → 60 sn
    expect(await VaultService.lockoutRemaining(), const Duration(seconds: 60));
    await expire(const Duration(seconds: 60));
    await fail(); // 5 → 5 dk
    expect(await VaultService.lockoutRemaining(), const Duration(minutes: 5));
    await expire(const Duration(minutes: 5));
    await fail(); // 6 → 30 dk (üst sınır)
    expect(await VaultService.lockoutRemaining(), const Duration(minutes: 30));
    expect(await VaultService.failedAttempts(), 6);

    // Süre dolunca kilit kalkar, doğru PIN açar, sayaç sıfırlanır.
    await expire(const Duration(minutes: 30));
    expect(await VaultService.unlock('654321'), isTrue);
    expect(await VaultService.failedAttempts(), 0);
  }, timeout: const Timeout(Duration(seconds: 120)));

  // ------------------------------------------------ geriye dönük uyum --

  test('GERİYE DÖNÜK UYUMLULUK: 1.0.x meta verisi (kdfIterations alansız, '
      '20.000 tur, 4 haneli PIN) ve dosyası hâlâ açılır', () async {
    const oldPin = '1472'; // 1.0.x 4-6 hane kabul ediyordu
    final salt = testBytes(16, 1);
    final oldKey = testPbkdf2(oldPin, salt, 20000);
    await writeMeta(oldPin, salt); // alan YAZILMAZ → eski biçim

    // 1.0.x biçimiyle şifrelenmiş bir dosya da kasa dizinine konur.
    final content = Uint8List.fromList(utf8.encode('eski-gizli-dosya'));
    File('${root.path}${Platform.pathSeparator}eski01.enc').writeAsBytesSync(
      legacyEntry(
        key: oldKey,
        name: 'eski.txt',
        size: content.length,
        added: DateTime(2025, 1, 2, 3, 4),
        content: content,
      ),
    );

    expect(await VaultService.isConfigured(), isTrue);
    expect(
      await VaultService.unlock(oldPin),
      isTrue,
      reason: 'eski kısa PIN ve eski tur sayısıyla açılmalı',
    );

    final items = await VaultService.list();
    expect(items.single.name, 'eski.txt');
    expect(items.single.size, content.length);
    final out = await VaultService.exportTo(
        'eski01', '${outside.path}${Platform.pathSeparator}eski_out');
    expect(out.readAsBytesSync(), content);

    // PIN değişince yeni tur sayısı meta veriye yazılır ve oyunca açılır.
    VaultService.lock();
    await VaultService.changePin(oldPin, '123456789012');
    final meta = await readRawMeta();
    expect(meta['kdfIterations'], VaultService.kdfIterations);
    expect(await VaultService.unlock('123456789012'), isTrue);
    final items2 = await VaultService.list();
    expect(items2.single.name, 'eski.txt',
        reason: 'yeniden şifrelenmiş dosya yeni anahtarla açılmalı');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('meta veride kayıtlı tur sayısı ne ise açılış onunla yapılır',
      () async {
    const pin = '864210';
    final salt = testBytes(16, 100);
    // Kayıtlı değer yeni sabitle aynı olmasın ki hangisinin kullanıldığı
    // anlaşılsın: 30.000 turda türetilmiş anahtar yalnız o değerle açılır.
    await writeMeta(pin, salt, iterations: 30000);

    expect(await VaultService.unlock(pin), isTrue,
        reason: 'kayıtlı (30.000) tur sayısıyla türetilmeli');

    VaultService.lock();
    final meta = await readRawMeta();
    expect(meta['kdfIterations'], 30000);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('yeni kasalar meta veride güncel PBKDF2 tur sayısını ve 16 bayt '
      'tuzu kaydeder', () async {
    expect(VaultService.kdfIterations, 200000);
    expect(VaultService.legacyKdfIterations, 20000,
        reason: 'eski varsayılan korunmalı');

    await VaultService.create('123456');
    final meta = await readRawMeta();
    expect(meta['kdfIterations'], VaultService.kdfIterations);
    expect(meta['v'], 1);
    expect((meta['salt'] as String).length, 32, reason: '16 bayt tuz');
    expect((meta['verifier'] as String).length, greaterThanOrEqualTo(32),
        reason: '12 bayt nonce + 16 bayt etiket + içerik');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ------------------------------------------------------- PIN uzunluğu --

  test('uzun PIN (12 hane) kabul edilir; kısa veya hane olmayan PIN '
      'reddedilir', () async {
    expect(VaultService.isValidPin('123456'), isTrue);
    expect(VaultService.isValidPin('123456789012'), isTrue,
        reason: '12 hane en uzun geçerli PIN');
    expect(VaultService.isValidPin('12345'), isFalse);
    expect(VaultService.isValidPin('1234567890123'), isFalse);
    expect(VaultService.isValidPin('abcdef'), isFalse);

    await expectLater(VaultService.create('12345'), throwsArgumentError);
    await expectLater(
        VaultService.create('1234567890123'), throwsArgumentError);
    expect(await VaultService.isConfigured(), isFalse,
        reason: 'reddedilen create hiçbir şey yazmamalı');

    await VaultService.create('123456789012');
    expect(VaultService.unlocked, isTrue);
    await expectLater(
      VaultService.changePin('123456789012', '9999'),
      throwsArgumentError,
    );
    VaultService.lock();
    expect(await VaultService.unlock('123456789012'), isTrue,
        reason: 'geçersiz changePin kasayı bozmamalı');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
