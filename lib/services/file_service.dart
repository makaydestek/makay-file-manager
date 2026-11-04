import 'dart:io';

import '../models/file_entry.dart';
import '../utils/debug_log.dart';
import '../utils/nomedia.dart';
import 'category_size_service.dart';
import 'transfer.dart';

/// Dosya sistemi okuma/yazma işlemleri.
///
/// İçerik değiştiren her işlem (oluşturma, yeniden adlandırma, kopyalama,
/// taşıma, silme) sonunda `CategorySizeService.invalidate()` çağrılır; yoksa
/// ana ekran kategori etiketleri dosya işleminden sonra bayat boyut
/// göstermeye devam ederdi.
class FileService {
  const FileService();

  /// Parçalı kopyalama için okuma/yazma bloğu boyutu (256 KB).
  ///
  /// Büyük dosyalarda tek seferde belleğe alınmaz; bu sayede hem bellek
  /// kullanımı sabit kalır hem de iptal/ilerleme mümkün olur.
  static const int chunkSize = 256 * 1024;

  /// İlerleme bildirimi arasındaki en kısa süre.
  ///
  /// On binlerce küçük dosyada her bayt için geri çağırma yapmak arayüzü
  /// boğar; bildirimler en fazla bu sıklıkta yapıp dosya bitiminde zorlanır.
  static const Duration progressInterval = Duration(milliseconds: 100);

  /// Bir dizini listeler; gizli dosyalar (nokta ile başlayanlar) atlanır.
  Future<List<FileEntry>> listDirectory(
    String path, {
    bool showHidden = false,
  }) async {
    final dir = Directory(path);
    if (!await dir.exists()) return const [];
    final entries = <FileEntry>[];
    await for (final entity in dir.list(followLinks: false)) {
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments[entity.uri.pathSegments.length - 1];
      final cleanName = name.isEmpty ? entity.path.split(Platform.pathSeparator).last : name;
      if (!showHidden && cleanName.startsWith('.')) continue;
      // Galeri'de "Gizli" yapılan (`.nomedia` işaretli) klasörler gizli
      // tutulur; gizli dosyalar gösterilirken bu klasörler de görünür.
      if (!showHidden && entity is Directory &&
          await isHiddenByNomediaAsync(entity.path)) {
        continue;
      }
      try {
        final stat = await entity.stat();
        entries.add(FileEntry(
          name: cleanName,
          path: entity.path,
          isDirectory: entity is Directory,
          // Dizin için `stat.size` **içerik toplamı değildir**: Linux/Android'te
          // dizin inode boyutudur (0 ya da 4096 B). Tarayıcıda zaten "Klasör"
          // gösterildiği ve bilgi diyaloğunda `directorySize` ayrıca
          // hesaplandığı için burada dürüst olan 0 yazılır — aksi halde
          // geri dönüşüm kutusu klasörleri "0 B / 4,1 KB" gösterirdi.
          size: entity is Directory ? 0 : stat.size,
          modified: stat.modified,
        ));
      } catch (_) {
        // Erişilemeyen girdiler atlanır (izin vb.).
      }
    }
    return entries;
  }

  /// Klasör içindeki alt öğe sayısı.
  Future<int> countChildren(String path) async {
    try {
      final dir = Directory(path);
      var count = 0;
      await for (final _ in dir.list(followLinks: false)) {
        count++;
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  /// Klasörün özyinelemeli toplam boyutu (dosyalar).
  Future<int> directorySize(String path) async {
    var total = 0;
    try {
      final dir = Directory(path);
      await for (final entity in dir.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          try {
            total += await entity.length();
          } catch (e) {
            logSwallowed('dosya servisi: boyut', e);
          }
        }
      }
    } catch (e) {
      logSwallowed('dosya servisi: yürüyüş', e);
    }
    return total;
  }

  /// Seçilen yolların toplam dosya/bayt sayısını hesaplar.
  ///
  /// Kullanıcıya "X dosya, Y GB taşınacak — emin misiniz?" onayı göstermeden
  /// önce çağrılır. Silinemeyen yollar sessizce atlanır.
  Future<({int files, int bytes})> estimate(List<String> paths) async {
    var files = 0;
    var bytes = 0;
    for (final path in paths) {
      if (FileSystemEntity.isDirectorySync(path)) {
        final counted = await _measureDirectory(Directory(path));
        files += counted.files;
        bytes += counted.bytes;
      } else if (FileSystemEntity.isFileSync(path)) {
        files++;
        try {
          bytes += await File(path).length();
        } catch (_) {
          // Erişilemeyen dosya boyutu atlanır.
        }
      }
    }
    return (files: files, bytes: bytes);
  }

  Future<void> createDirectory(String path) async {
    await Directory(path).create();
    await CategorySizeService.invalidate();
  }

  Future<void> rename(String path, String newName) async {
    final entity = FileSystemEntity.isDirectorySync(path)
        ? Directory(path)
        : File(path);
    final parent = entity.parent.path;
    await entity.rename('$parent${Platform.pathSeparator}$newName');
    await CategorySizeService.invalidate();
  }

  Future<TransferResult> copyEntry(
    FileEntry entry,
    String targetDir, {
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  }) =>
      copyPath(
        entry.path,
        targetDir,
        name: entry.name,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

  /// Yol tabanlı kopyalama (sürükle-bırak / paneller arası).
  ///
  /// [onProgress] bildirimleri [progressInterval] sıklıkla ve dosya bitiminde
  /// zorlanarak yapılır. [cancelToken] iptal edilirse kısmi çıktı temizlenir ve
  /// [TransferCancelled] fırlatılır.
  Future<TransferResult> copyPath(
    String source,
    String targetDir, {
    String? name,
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final sourceName = source.split(Platform.pathSeparator).last;
    final target = '$targetDir${Platform.pathSeparator}${name ?? sourceName}';
    final session = _Session(onProgress: onProgress, cancelToken: cancelToken);
    final isDir = FileSystemEntity.isDirectorySync(source);

    // Hedef bizim yarattığımızsa iptalde geri silinebilir; önceden
    // var olan bir hedef asla silinmez (kullanıcı verisi korunur).
    final targetExisted = FileSystemEntity.typeSync(target) !=
        FileSystemEntityType.notFound;

    try {
      if (isDir) {
        final measurement = await _measureDirectory(
          Directory(source),
          cancelToken: cancelToken,
          onMeasured: (files, bytes) {
            session
              ..totalFiles = files
              ..totalBytes = bytes
              ..phase = TransferPhase.measuring;
            session.report(force: true);
          },
        );
        session
          ..totalFiles = measurement.files
          ..totalBytes = measurement.bytes
          ..phase = TransferPhase.copying;
        await _copyDir(
          Directory(source),
          Directory(target),
          session,
          topTarget: target,
        );
      } else {
        session
          ..totalFiles = 1
          ..totalBytes = await _safeLength(File(source))
          ..phase = TransferPhase.copying;
        await _copyFile(
          File(source),
          File(target),
          session,
          topTarget: target,
        );
      }
    } on TransferCancelled {
      if (!targetExisted) {
        session
          ..phase = TransferPhase.cleaningUp
          ..report(force: true);
        await _deleteQuietly(target);
      }
      rethrow;
    } finally {
      // Tamamlansın ya da iptal edilsin: içerik değişti.
      await CategorySizeService.invalidate();
    }

    session.report(force: true);
    return TransferResult(
      files: session.doneFiles,
      bytes: session.doneBytes,
      cancelled: false,
    );
  }

  /// Taşıma. Aynı birimdeyse `rename` (anlık); farklı birimdeyse
  /// kopyala + sil ve [onProgress] bildirimleri kopyalama boyunca yapılır.
  Future<TransferResult> moveEntry(
    FileEntry entry,
    String targetDir, {
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  }) =>
      movePath(
        entry.path,
        targetDir,
        name: entry.name,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );

  /// Yol tabanlı taşıma (bkz. [moveEntry]).
  Future<TransferResult> movePath(
    String source,
    String targetDir, {
    String? name,
    void Function(TransferProgress)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final sourceName = source.split(Platform.pathSeparator).last;
    final target = '$targetDir${Platform.pathSeparator}${name ?? sourceName}';
    final isDir = FileSystemEntity.isDirectorySync(source);

    try {
      if (isDir) {
        await Directory(source).rename(target);
      } else {
        await File(source).rename(target);
      }
      final bytes = isDir
          ? (await _measureDirectory(Directory(target))).bytes
          : await _safeLength(File(target));
      final files = isDir
          ? (await _measureDirectory(Directory(target))).files
          : 1;
      onProgress?.call(TransferProgress(
        phase: TransferPhase.copying,
        doneFiles: files,
        doneBytes: bytes,
        totalFiles: files,
        totalBytes: bytes,
        currentPath: target,
      ));
      return TransferResult(files: files, bytes: bytes, cancelled: false);
    } on FileSystemException {
      // Farklı depolama birimi: rename çalışmaz → kopyala + sil.
      final result = await copyPath(
        source,
        targetDir,
        name: name,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      if (result.cancelled) return result;
      try {
        await deleteEntry(source, useRecycleBin: false);
        return result;
      } catch (e) {
        return TransferResult(
          files: result.files,
          bytes: result.bytes,
          cancelled: false,
          warning:
              'Hedefe kopyalandı ancak kaynak silinemedi — çift kopya olabilir. ($e)',
        );
      }
    } finally {
      await CategorySizeService.invalidate();
    }
  }

  /// Kalıcı silme veya geri dönüşüm kutusuna taşıma.
  /// Geri dönüşüm entegrasyonu RecycleBinService tarafından sağlanır.
  Future<void> deleteEntry(String path, {bool useRecycleBin = false}) async {
    if (useRecycleBin) {
      // Geri dönüşüm mantığı RecycleBinService.moveToRecycle ile yapılır;
      // buraya gelindiğinde kalıcı silinir.
    }
    final entity =
        FileSystemEntity.isDirectorySync(path) ? Directory(path) : File(path);
    if (entity is Directory) {
      await entity.delete(recursive: true);
    } else {
      await entity.delete();
    }
    await CategorySizeService.invalidate();
  }

  // -------------------------------------------------------------------
  // Dahili yardımcılar
  // -------------------------------------------------------------------

  Future<void> _copyDir(
    Directory source,
    Directory destination,
    _Session session, {
    required String topTarget,
  }) async {
    await destination.create(recursive: true);
    await for (final entity in source.list(followLinks: false)) {
      session.checkCancelled();
      final name = _nameOf(entity);
      if (name.isEmpty) continue;
      final newPath = '${destination.path}${Platform.pathSeparator}$name';
      if (entity is Directory) {
        await _copyDir(entity, Directory(newPath), session, topTarget: topTarget);
      } else if (entity is File) {
        await _copyFile(entity, File(newPath), session, topTarget: topTarget);
      }
    }
  }

  /// Bir dosya sistemi öğesinin adı.
  ///
  /// `Directory.uri` sonuna `/` eklediği için `uri.pathSegments` klasörlerde
  /// **boş son eleman** döner — adı oradan almak iç içe kopyalamayı düzleştirir
  /// (bu, önceden var olan ve test edilmemiş bir hataydı). Bu yüzden doğrudan
  /// yoldan ayrıştırılır.
  static String _nameOf(FileSystemEntity entity) {
    final trimmed = entity.path.replaceAll(RegExp(r'[/\\]+$'), '');
    final index = trimmed.lastIndexOf(RegExp(r'[/\\]'));
    return index < 0 ? trimmed : trimmed.substring(index + 1);
  }

  Future<void> _copyFile(
    File source,
    File destination,
    _Session session, {
    required String topTarget,
  }) async {
    session.checkCancelled();
    session.currentPath = source.path;
    await destination.parent.create(recursive: true);

    final input = await source.open();
    try {
      final output = await destination.open(mode: FileMode.write);
      try {
        while (true) {
          session.checkCancelled();
          final chunk = await input.read(chunkSize);
          if (chunk.isEmpty) break;
          await output.writeFrom(chunk);
          session.doneBytes += chunk.length;
          session.report();
        }
      } finally {
        await output.close();
      }
    } finally {
      await input.close();
    }

    // Dosya bitimi: bildirim zorlanır ve sayaç artar.
    session.doneFiles++;
    session.report(force: true);
  }

  Future<({int files, int bytes})> _measureDirectory(
    Directory dir, {
    CancelToken? cancelToken,
    void Function(int files, int bytes)? onMeasured,
  }) async {
    var files = 0;
    var bytes = 0;

    Future<void> walk(Directory current) async {
      await for (final entity in current.list(followLinks: false)) {
        if (cancelToken?.isCancelled ?? false) {
          throw const TransferCancelled();
        }
        if (entity is Directory) {
          await walk(entity);
        } else if (entity is File) {
          files++;
          bytes += await _safeLength(entity);
          if (files % 200 == 0) onMeasured?.call(files, bytes);
        }
      }
    }

    await walk(dir);
    onMeasured?.call(files, bytes);
    return (files: files, bytes: bytes);
  }

  Future<int> _safeLength(File file) async {
    try {
      return await file.length();
    } catch (_) {
      return 0;
    }
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final entity = FileSystemEntity.typeSync(path) ==
              FileSystemEntityType.directory
          ? Directory(path)
          : File(path);
      if (entity is Directory) {
        await entity.delete(recursive: true);
      } else {
        await entity.delete();
      }
    } catch (_) {
      // Temizlik hatası kullanıcının işini bozmaz.
    }
  }
}

/// Tek bir kopyalama/taşıma işleminin durumu.
class _Session {
  _Session({this.onProgress, this.cancelToken});

  final void Function(TransferProgress)? onProgress;
  final CancelToken? cancelToken;

  TransferPhase phase = TransferPhase.copying;
  int doneFiles = 0;
  int doneBytes = 0;
  int totalFiles = 0;
  int? totalBytes;
  String currentPath = '';

  final Stopwatch _clock = Stopwatch()..start();

  void checkCancelled() {
    if (cancelToken?.isCancelled ?? false) throw const TransferCancelled();
  }

  void report({bool force = false}) {
    final sink = onProgress;
    if (sink == null) return;
    if (!force && _clock.elapsed < FileService.progressInterval) return;
    _clock
      ..reset()
      ..start();
    sink(TransferProgress(
      phase: phase,
      doneFiles: doneFiles,
      doneBytes: doneBytes,
      totalFiles: totalFiles,
      totalBytes: totalBytes,
      currentPath: currentPath,
    ));
  }
}
