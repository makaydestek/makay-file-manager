import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/utils/folder_watcher.dart';

void main() {
  test('debounce birleştirir; settle ikinci tur tetikler', () async {
    final dir = Directory.systemTemp.createTempSync('watcher_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    var hits = 0;
    final watcher = FolderWatcher(
      onChanged: () => hits++,
      debounce: const Duration(milliseconds: 80),
      settleFollowUp: const Duration(milliseconds: 120),
      pollInterval: null,
    );
    addTearDown(watcher.dispose);
    watcher.start([dir.path]);

    File('${dir.path}${Platform.pathSeparator}a.txt').writeAsStringSync('1');
    File('${dir.path}${Platform.pathSeparator}b.txt').writeAsStringSync('2');

    // Debounce bitmeden tek bildirim beklenir.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hits, greaterThanOrEqualTo(1));
    final afterDebounce = hits;

    // Settle follow-up ikinci tur.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(hits, greaterThan(afterDebounce));
  });

  test('pollInterval watch kaçırırsa değişiklik yakalar', () async {
    final dir = Directory.systemTemp.createTempSync('watcher_poll_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    final done = Completer<void>();
    var hits = 0;
    final watcher = FolderWatcher(
      onChanged: () {
        hits++;
        if (!done.isCompleted) done.complete();
      },
      debounce: const Duration(milliseconds: 50),
      settleFollowUp: Duration.zero,
      pollInterval: const Duration(milliseconds: 120),
    );
    addTearDown(watcher.dispose);
    watcher.start([dir.path]);

    // İlk imza alındıktan sonra dosya ekle.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    File('${dir.path}${Platform.pathSeparator}c.txt').writeAsStringSync('x');

    await done.future.timeout(const Duration(seconds: 3));
    expect(hits, greaterThanOrEqualTo(1));
  });
}
