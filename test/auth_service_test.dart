import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:makay_file_manager/services/auth_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime fakeNow;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fakeNow = DateTime.utc(2026, 1, 1, 12);
    AuthService.now = () => fakeNow;
    AuthService.lockNow();
  });

  tearDown(() {
    AuthService.now = DateTime.now;
  });

  test('PIN kaydedilir ve doğrulanır', () async {
    await AuthService.setPin('1234');
    expect(await AuthService.hasPin, isTrue);
    expect(await AuthService.verifyPin('1234'), isTrue);
    expect(await AuthService.verifyPin('9999'), isFalse);
  });

  test('yanlış PIN kilitlenme üretir; süre dolunca yeniden denenebilir',
      () async {
    await AuthService.setPin('1234');

    expect(await AuthService.verifyPin('0000'), isFalse);
    expect(await AuthService.failedAttempts(), 1);
    // İlk başarısızlıkta backoff 0 sn — hemen tekrar denenebilir.
    expect(await AuthService.lockoutRemaining(), Duration.zero);

    expect(await AuthService.verifyPin('0000'), isFalse);
    expect(await AuthService.failedAttempts(), 2);
    // 2. hata → 5 sn kilit.
    expect(await AuthService.lockoutRemaining(), const Duration(seconds: 5));
    expect(await AuthService.verifyPin('1234'), isFalse,
        reason: 'kilitliyken doğru PIN de reddedilmeli');

    fakeNow = fakeNow.add(const Duration(seconds: 6));
    expect(await AuthService.lockoutRemaining(), Duration.zero);
    expect(await AuthService.verifyPin('1234'), isTrue);
    expect(await AuthService.failedAttempts(), 0);
  });

  test('başarılı doğrulama kilit sayacını sıfırlar', () async {
    await AuthService.setPin('5678');
    await AuthService.verifyPin('0000');
    expect(await AuthService.failedAttempts(), 1);
    expect(await AuthService.verifyPin('5678'), isTrue);
    expect(await AuthService.failedAttempts(), 0);
  });
}
