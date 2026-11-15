import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/services/auth_service.dart';
import 'package:makay_file_manager/services/secure_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime fakeNow;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // PIN özeti şifreli depoda tutulur; testlerde bellek içi arka uç.
    SecureStore.debugBackend = <String, String>{};
    fakeNow = DateTime.utc(2026, 1, 1, 12);
    AuthService.now = () => fakeNow;
    AuthService.lockNow();
  });

  tearDown(() {
    AuthService.now = DateTime.now;
    SecureStore.debugBackend = null;
  });

  test('PIN kaydedilir ve doğrulanır', () async {
    await AuthService.setPin('123456');
    expect(await AuthService.hasPin, isTrue);
    expect(await AuthService.verifyPin('123456'), isTrue);
    expect(await AuthService.verifyPin('999999'), isFalse);
  });

  test('yanlış PIN kilitlenme üretir; süre dolunca yeniden denenebilir',
      () async {
    await AuthService.setPin('123456');

    expect(await AuthService.verifyPin('000000'), isFalse);
    expect(await AuthService.failedAttempts(), 1);
    // İlk başarısızlıkta backoff 0 sn — hemen tekrar denenebilir.
    expect(await AuthService.lockoutRemaining(), Duration.zero);

    expect(await AuthService.verifyPin('000000'), isFalse);
    expect(await AuthService.failedAttempts(), 2);
    // 2. hata → 5 sn kilit.
    expect(await AuthService.lockoutRemaining(), const Duration(seconds: 5));
    expect(await AuthService.verifyPin('123456'), isFalse,
        reason: 'kilitliyken doğru PIN de reddedilmeli');

    fakeNow = fakeNow.add(const Duration(seconds: 6));
    expect(await AuthService.lockoutRemaining(), Duration.zero);
    expect(await AuthService.verifyPin('123456'), isTrue);
    expect(await AuthService.failedAttempts(), 0);
  });

  test('başarılı doğrulama kilit sayacını sıfırlar', () async {
    await AuthService.setPin('567890');
    await AuthService.verifyPin('000000');
    expect(await AuthService.failedAttempts(), 1);
    expect(await AuthService.verifyPin('567890'), isTrue);
    expect(await AuthService.failedAttempts(), 0);
  });

  test('4-5 haneli PIN artık reddedilir (pinMin = 6)', () async {
    await expectLater(AuthService.setPin('1234'), throwsArgumentError);
    await expectLater(AuthService.setPin('12345'), throwsArgumentError);
    await AuthService.setPin('123456');
    expect(await AuthService.hasPin, isTrue);
  });

  test('legacy 5.001×SHA-256 kaydı açılır ve PBKDF2ye yükseltilir', () async {
    // 1.0.x kaydını birebir üret: prefs'te öneksiz özet.
    final salt = List<int>.generate(16, (i) => i + 1);
    var digest = _sha256([...salt, ...'135790'.codeUnits]);
    for (var i = 0; i < 5000; i++) {
      digest = _sha256([...salt, ...digest]);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_lock_pin_salt', base64Encode(salt));
    await prefs.setString('app_lock_pin_hash', base64Encode(digest));

    expect(await AuthService.verifyPin('135790'), isTrue,
        reason: 'eski kayıtlı PIN hâlâ açılmalı');
    // Yükseltme sonrası kayıt yeni biçimde ve prefs temiz.
    expect(await AuthService.verifyPin('135790'), isTrue);
    expect(SecureStore.debugBackend!['app_lock_pin_hash'],
        startsWith('pbkdf2-sha256:'));
    expect(prefs.getString('app_lock_pin_hash'), isNull);
  });
}

List<int> _sha256(List<int> data) => sha256.convert(data).bytes;
