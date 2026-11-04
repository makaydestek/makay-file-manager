import 'dart:async';
import 'dart:io';

import 'debug_log.dart';

/// Klasör değişikliklerini izler; burst olayları birleştirerek bildirir.
///
/// F Dosya Yöneticisi gibi **aktif** kalır: `Directory.watch` + yedek yoklama.
/// Debounce ve kısa bir settle yenilemesi, indirme sırasında "çok hızlı"
/// (yarım dosya / flicker) yenilemeyi önler; olay bittikten sonra bir kez
/// daha doğrular.
class FolderWatcher {
  FolderWatcher({
    required this.onChanged,
    this.debounce = const Duration(milliseconds: 600),
    this.settleFollowUp = const Duration(milliseconds: 1400),
    this.pollInterval = const Duration(seconds: 3),
  });

  /// Değişiklik birleşince çağrılır (UI thread'de).
  final void Function() onChanged;

  /// Olay patlamalarını tek yenilemede birleştirme süresi.
  final Duration debounce;

  /// İlk yenilemeden sonra dosya sisteminin oturması için ikinci tur.
  final Duration settleFollowUp;

  /// `watch` kaçırırsa yedek yoklama aralığı (`null` = yoklama yok).
  final Duration? pollInterval;

  final List<StreamSubscription<FileSystemEvent>> _subs = [];
  Timer? _debounce;
  Timer? _settle;
  Timer? _poll;
  bool _armed = false;
  int _fingerprint = 0;

  /// İzlemeyi başlatır; önceki abonelikleri kapatır.
  void start(Iterable<String> paths, {bool recursive = false}) {
    stop();
    _armed = true;
    final unique = <String>{};
    for (final path in paths) {
      if (path.isEmpty) continue;
      unique.add(path);
    }
    for (final path in unique) {
      _attach(path, recursive: recursive);
    }
    _fingerprint = _snapshot(unique);
    final poll = pollInterval;
    if (poll != null && unique.isNotEmpty) {
      _poll = Timer.periodic(poll, (_) => _pollCheck(unique));
    }
  }

  void stop() {
    _armed = false;
    _debounce?.cancel();
    _settle?.cancel();
    _poll?.cancel();
    _debounce = null;
    _settle = null;
    _poll = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  void dispose() => stop();

  void _attach(String path, {required bool recursive}) {
    final dir = Directory(path);
    if (!dir.existsSync()) return;
    try {
      final sub = dir
          .watch(recursive: recursive)
          .listen((_) => _schedule(), onError: (Object e) {
        logSwallowed('klasör izleyici: watch', e);
      });
      _subs.add(sub);
    } catch (e) {
      // Platform watch desteklemiyorsa yalnız yoklama çalışır.
      logSwallowed('klasör izleyici: başlatma', e);
    }
  }

  void _schedule() {
    if (!_armed) return;
    _debounce?.cancel();
    _debounce = Timer(debounce, () {
      if (!_armed) return;
      onChanged();
      // İndirme/yazma bitince ikinci tur: ilk olay "çok hızlı" gelmiş olabilir.
      _settle?.cancel();
      if (settleFollowUp > Duration.zero) {
        _settle = Timer(settleFollowUp, () {
          if (_armed) onChanged();
        });
      }
    });
  }

  void _pollCheck(Set<String> paths) {
    if (!_armed) return;
    final next = _snapshot(paths);
    if (next != _fingerprint) {
      _fingerprint = next;
      _schedule();
    }
  }

  /// Hafif imza: üst seviye adet + boyut/mtime toplamı (özyinelemesiz).
  static int _snapshot(Set<String> paths) {
    var hash = 0;
    for (final path in paths) {
      try {
        final dir = Directory(path);
        if (!dir.existsSync()) {
          hash = Object.hash(hash, path, -1);
          continue;
        }
        var count = 0;
        var bytes = 0;
        var mtime = 0;
        for (final e in dir.listSync(followLinks: false)) {
          count++;
          try {
            final st = e.statSync();
            bytes = (bytes + st.size) & 0x7fffffff;
            final ms = st.modified.millisecondsSinceEpoch;
            if (ms > mtime) mtime = ms;
          } catch (_) {}
        }
        hash = Object.hash(hash, path, count, bytes, mtime);
      } catch (_) {
        hash = Object.hash(hash, path, -2);
      }
    }
    return hash;
  }
}
