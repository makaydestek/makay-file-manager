import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

/// Uzak küçük resim indirmelerini sınırlar (aynı anda en fazla [maxConcurrent]).
///
/// F Dosya Yöneticisi gibi: liste kaydırılırken onlarca paralel FTP/SMB
/// bağlantısı açılmaz; UI donması ve zaman aşımları azalır.
class RemoteThumbLimiter {
  RemoteThumbLimiter._();

  static final instance = RemoteThumbLimiter._();

  static const maxConcurrent = 2;

  int _active = 0;
  final _queue = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    await _acquire();
    try {
      return await task();
    } finally {
      _release();
    }
  }

  Future<Uint8List?> runBytes(Future<Uint8List?> Function() task) =>
      run(task);

  Future<void> _acquire() async {
    if (_active < maxConcurrent) {
      _active++;
      return;
    }
    final c = Completer<void>();
    _queue.add(c);
    await c.future;
    _active++;
  }

  void _release() {
    _active--;
    if (_queue.isNotEmpty && _active < maxConcurrent) {
      _queue.removeFirst().complete();
    }
  }
}
