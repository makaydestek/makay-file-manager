import 'dart:io';
import 'dart:isolate';

/// Ana izolatı bloke etmeden ağır listSync taramaları.
class HeavyScan {
  const HeavyScan._();

  static Future<Map<String, int>> analysisBreakdown(String root) {
    return Isolate.run(() => _analysisBreakdownSync(root));
  }

  /// Büyük dosya taraması (ana izolatı bloke etmez).
  static Future<List<({String name, String path, int size, DateTime modified})>>
      largeFiles({
    String root = '/storage/emulated/0',
    int minBytes = 10 * 1024 * 1024,
    int limit = 300,
    int maxDepth = 5,
  }) {
    return Isolate.run(
      () => _largeFilesSync(
        root: root,
        minBytes: minBytes,
        limit: limit,
        maxDepth: maxDepth,
      ),
    );
  }

  /// Android/data önbellek boyutu (sığ derinlik; tam yürüyüş çok yavaş).
  static Future<int> cacheSize({
    String path = '/storage/emulated/0/Android/data',
    int maxDepth = 3,
  }) {
    return Isolate.run(() => _dirSizeSync(path, maxDepth: maxDepth));
  }

  static Future<List<String>> downloadApkPaths() {
    return Isolate.run(_downloadApkPathsSync);
  }

  static Future<({List<(String, int)> temps, int thumbBytes})> tempScan({
    required String androidRoot,
    required List<String> suffixes,
  }) {
    return Isolate.run(
      () => _tempScanSync(androidRoot: androidRoot, suffixes: suffixes),
    );
  }

  static Map<String, int> _analysisBreakdownSync(String root) {
    return <String, int>{
      'Resimler': _dirSizeSync('$root/DCIM') + _dirSizeSync('$root/Pictures'),
      'Videolar': _dirSizeSync('$root/Movies') +
          _dirSizeSync('$root/WhatsApp/Media/WhatsApp Video'),
      'Ses': _dirSizeSync('$root/Music') +
          _dirSizeSync('$root/WhatsApp/Media/WhatsApp Audio'),
      'Belgeler':
          _dirSizeSync('$root/Documents') + _dirSizeSync('$root/Download'),
      'Arşivler': _scanArchivesSync(
        Directory(root),
        depth: 3,
        exclude: const [
          'DCIM',
          'Pictures',
          'Movies',
          'Music',
          'Documents',
          'Download',
          'WhatsApp',
          'Telegram',
          'Android',
        ],
      ),
    };
  }

  static int _dirSizeSync(String path, {int maxDepth = 64}) {
    var total = 0;
    // (yol, kalan derinlik)
    final stack = <(String, int)>[(path, maxDepth)];
    while (stack.isNotEmpty) {
      final (dirPath, depth) = stack.removeLast();
      try {
        final dir = Directory(dirPath);
        if (!dir.existsSync()) continue;
        for (final e in dir.listSync(followLinks: false)) {
          if (e is File) {
            try {
              total += e.lengthSync();
            } catch (_) {}
          } else if (e is Directory) {
            if (depth <= 0) continue;
            final name = e.uri.pathSegments.isEmpty
                ? ''
                : e.uri.pathSegments[e.uri.pathSegments.length - 2];
            if (name.startsWith('.')) continue;
            final nomedia = File('${e.path}${Platform.pathSeparator}.nomedia');
            if (nomedia.existsSync()) continue;
            stack.add((e.path, depth - 1));
          }
        }
      } catch (_) {}
    }
    return total;
  }

  static List<({String name, String path, int size, DateTime modified})>
      _largeFilesSync({
    required String root,
    required int minBytes,
    required int limit,
    required int maxDepth,
  }) {
    final found =
        <({String name, String path, int size, DateTime modified})>[];
    const skipDirs = {'Android', 'data', 'obb', '.thumbnails', 'LOST.DIR'};

    void walk(Directory dir, int depth) {
      if (depth < 0 || found.length >= limit) return;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        if (found.length >= limit) return;
        final name = e.uri.pathSegments.isEmpty
            ? ''
            : e.uri.pathSegments[e.uri.pathSegments.length - 1];
        if (name.startsWith('.')) continue;
        if (e is File) {
          try {
            final len = e.lengthSync();
            if (len >= minBytes) {
              final stat = e.statSync();
              found.add((
                name: name.isEmpty ? e.path : name,
                path: e.path,
                size: len,
                modified: stat.modified,
              ));
            }
          } catch (_) {}
        } else if (e is Directory) {
          if (skipDirs.contains(name)) continue;
          walk(e, depth - 1);
        }
      }
    }

    walk(Directory(root), maxDepth);
    found.sort((a, b) => b.size.compareTo(a.size));
    return found;
  }

  static int _scanArchivesSync(
    Directory root, {
    int depth = 3,
    List<String> exclude = const [],
  }) {
    var total = 0;
    const exts = {'.zip', '.rar', '.7z', '.tar', '.gz', '.bz2', '.xz'};
    void walk(Directory dir, int left) {
      if (left < 0) return;
      try {
        for (final e in dir.listSync(followLinks: false)) {
          if (e is File) {
            final lower = e.path.toLowerCase();
            if (exts.any(lower.endsWith)) {
              try {
                total += e.lengthSync();
              } catch (_) {}
            }
          } else if (e is Directory) {
            final name = e.uri.pathSegments.isEmpty
                ? ''
                : e.uri.pathSegments[e.uri.pathSegments.length - 2];
            if (name == 'Android' || name.startsWith('.')) continue;
            if (exclude.contains(name)) continue;
            walk(e, left - 1);
          }
        }
      } catch (_) {}
    }

    walk(root, depth);
    return total;
  }

  static List<String> _downloadApkPathsSync() {
    if (!Platform.isAndroid) return const [];
    final dir = Directory('/storage/emulated/0/Download');
    if (!dir.existsSync()) return const [];
    try {
      final files = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.apk'))
          .toList();
      files.sort(
        (a, b) => b.statSync().modified.compareTo(a.statSync().modified),
      );
      return [for (final f in files) f.path];
    } catch (_) {
      return const [];
    }
  }

  static ({List<(String, int)> temps, int thumbBytes}) _tempScanSync({
    required String androidRoot,
    required List<String> suffixes,
  }) {
    final temps = <(String, int)>[];
    final seen = <String>{};
    var thumbBytes = 0;

    final thumbDir = Directory('$androidRoot/DCIM/.thumbnails');
    if (thumbDir.existsSync()) {
      thumbBytes = _dirSizeSync(thumbDir.path);
    }

    void scanTemps(Directory dir, {required int depth}) {
      if (temps.length >= 500) return;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync(followLinks: false);
      } catch (_) {
        return;
      }
      for (final e in entries) {
        if (temps.length >= 500) return;
        if (e is File) {
          final name = e.path.split(Platform.pathSeparator).last.toLowerCase();
          var match = name.endsWith('~');
          if (!match) {
            for (final s in suffixes) {
              if (name.endsWith(s)) {
                match = true;
                break;
              }
            }
          }
          if (match && seen.add(e.path)) {
            try {
              temps.add((e.path, e.lengthSync()));
            } catch (_) {}
          }
        } else if (e is Directory && depth > 0) {
          final lower = e.path.toLowerCase();
          if (lower.endsWith('/android') || lower.endsWith('/.thumbnails')) {
            continue;
          }
          scanTemps(e, depth: depth - 1);
        }
      }
    }

    for (final entry in <(String, int)>[
      ('$androidRoot/Download', 3),
      ('$androidRoot/Documents', 3),
      (androidRoot, 1),
    ]) {
      scanTemps(Directory(entry.$1), depth: entry.$2);
    }
    temps.sort((a, b) => b.$2.compareTo(a.$2));
    return (temps: temps, thumbBytes: thumbBytes);
  }
}