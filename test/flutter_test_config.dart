import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/secure_store.dart';

/// Tüm testlerde [SecureStore] bellek deposuna düşer (Keystore yok).
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() {
    SecureStore.debugBackend = <String, String>{};
  });
  tearDown(() {
    SecureStore.debugBackend = null;
  });
  await testMain();
}
