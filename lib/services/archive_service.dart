import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';

import 'platform_service.dart';
import 'transfer.dart';

/// Arşiv işleminde güvenlik ihlali: girdi yolu hedef klasörün dışına
/// çıkıyor (Zip-Slip / yol takibi saldırısı). Arşiv güvenilmez kaynaktan
/// gelmiş olabilir; bu tür girdiler asla yazılmaz.
class ArchiveSecurityException implements Exception {
  ArchiveSecurityException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Desteklenmeyen, bulunamayan ya da bozuk arşiv hatası (Türkçe mesaj).
class ArchiveServiceException implements Exception {
  ArchiveServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// İşlem ilerlemesi geri çağrısı: (biten, toplam). Toplam bilinmiyorsa -1.
typedef ArchiveProgress = void Function(int done, int total);

/// Arşiv içindeki tek bir girdinin (dosya/klasör) bilgisi.
class ArchiveEntryInfo {
  const ArchiveEntryInfo({
    required this.name,
    required this.isDirectory,
    required this.uncompressedSize,
    required this.compressedSize,
    required this.modificationTime,
    this.isVirtual = false,
  });

  /// Arşiv içi tam yol; '/' ayracı kullanır, sondaki ayrım çizgisi yoktur.
  final String name;

  /// Girdi bir klasör mü.
  final bool isDirectory;

  /// Sıkıştırılmamış boyut (bayt).
  final int uncompressedSize;

  /// Sıkıştırılmış boyut (bayt); bilinmiyorsa [uncompressedSize] ile eşit.
  final int compressedSize;

  /// Değiştirilme zamanı; alınamazsa null.
  final DateTime? modificationTime;

  /// true ise girdi arşivde fiilen yok, yalnızca klasör ağacı tamamlansın
  /// diye sentezlenmiş üst klasördür (çıkarılırken dikkate alınmaz).
  final bool isVirtual;

  /// Üst klasör yolu ('/' ayracı); kökteyse boş dize.
  String get parentPath {
    final i = name.lastIndexOf('/');
    return i <= 0 ? '' : name.substring(0, i);
  }

  /// Yolun son bileşeni (dosya/klasör adı).
  String get baseName {
    final i = name.lastIndexOf('/');
    return i < 0 ? name : name.substring(i + 1);
  }
}

/// ZIP/TAR arşivlerini okuma, gezme, çıkarma ve oluşturma servisi.
///
/// Tasarım gereği yalnızca `dart:io` dosya işlemleri kullanır; Android'e
/// özgü API yoktur, bu yüzden birim testlerinde geçici dizinle çalışır.
/// Bellek kullanımı için `InputFileStream`/`OutputFileStream` kullanılır:
/// arşivler tümüyle belleğe alınmaz.
class ArchiveService {
  const ArchiveService();

  /// Okunabilen (listelenebilir/çıkarılabilen) uzantılar.
  ///
  /// `.rar` / `.7z` Android'de native katmanla açılır.
  static const List<String> supportedExtensions = <String>[
    '.zip',
    '.tar',
    '.gz',
    '.tgz',
    '.tar.gz',
    '.rar',
    '.7z',
  ];

  /// Oluşturulabilen arşiv türleri.
  static const List<String> creatableExtensions = <String>['.zip', '.tar'];

  /// Tanınan ama henüz açılamayan biçimler (dürüst hata mesajı için).
  static const List<String> unsupportedKnownExtensions = <String>[
    '.iso',
    '.obb',
  ];

  /// [path] bir arşiv dosyası mı? (uzantıya göre; split .001 dahil)
  static bool isArchive(String path) {
    if (_formatOf(path) != null) return true;
    final lower = path.toLowerCase();
    if (RegExp(r'\.(zip\.)?\d{3}$').hasMatch(lower)) return true;
    if (lower.endsWith('.z01')) return true;
    return unsupportedKnownExtensions.any(lower.endsWith);
  }

  /// Kullanıcıya gösterilecek format adı (örn. 'ZIP'); bilinmiyorsa null.
  static String? formatName(String path) => switch (_formatOf(path)) {
        'zip' => 'ZIP',
        'tar' => 'TAR',
        'targz' => 'TAR.GZ',
        'gz' => 'GZIP',
        'rar' => 'RAR',
        '7z' => '7Z',
        'iso' => 'ISO',
        'obb' => 'OBB',
        'split' => 'Bölünmüş arşiv',
        _ => null,
      };

  /// Uzantıdan iç format anahtarına.
  static String? _formatOf(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.tar.gz') || lower.endsWith('.tgz')) return 'targz';
    if (lower.endsWith('.zip')) return 'zip';
    if (lower.endsWith('.tar')) return 'tar';
    if (lower.endsWith('.gz')) return 'gz';
    if (lower.endsWith('.rar')) return 'rar';
    if (lower.endsWith('.7z')) return '7z';
    if (lower.endsWith('.iso')) return 'iso';
    if (lower.endsWith('.obb')) return 'obb';
    if (lower.endsWith('.z01') || RegExp(r'\.(zip\.)?\d{3}$').hasMatch(lower)) {
      return 'split';
    }
    return null;
  }

  /// Şifre gerektiğinde fırlatılır; arayüz PIN ister.
  static bool isPasswordError(Object err) {
    final m = err.toString().toLowerCase();
    return m.contains('password') || m.contains('şifre') || m.contains('sifre');
  }

  /// Verilen aday için benzersiz bir zip dosya yolu önerir
  /// (örn. 'foto.jpg' → 'foto.zip', çakışma varsa 'foto (2).zip').
  static String suggestedZipPath(String directory, String sourceName) {
    var base = sourceName;
    final dot = base.lastIndexOf('.');
    if (dot > 0) base = base.substring(0, dot);
    if (base.isEmpty) base = 'arsiv';
    return uniquePath(_join(directory, '$base.zip'));
  }

  /// [path] dosyası yoksa aynen, varsa ' (2)', ' (3)' … ekli yeni yol döner.
  static String uniquePath(String path) {
    if (!File(path).existsSync() && !Directory(path).existsSync()) return path;
    final dot = path.lastIndexOf('.');
    final slash = path.lastIndexOf(Platform.pathSeparator);
    final hasExt = dot > slash;
    final stem = hasExt ? path.substring(0, dot) : path;
    final ext = hasExt ? path.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final candidate = '$stem ($i)$ext';
      if (!File(candidate).existsSync() && !Directory(candidate).existsSync()) {
        return candidate;
      }
    }
    return '$stem (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  /// Arşivin yanına, adı arşivin adından türetilen çıkarma klasörü önerir
  /// (örn. `yedek.zip` → `<klasör>/yedek`). Çakışmalar için [uniquePath]
  /// ile birlikte kullanın.
  static String defaultExtractDirFor(String archivePath) {
    final file = File(archivePath);
    var base = file.uri.pathSegments.isEmpty ? '' : file.uri.pathSegments[
        file.uri.pathSegments.length - 1];
    if (base.isEmpty) {
      base = _baseName(archivePath);
    }
    for (final suffix in const ['.tar.gz', '.tgz', '.zip', '.tar', '.gz']) {
      if (base.toLowerCase().endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        break;
      }
    }
    if (base.isEmpty) base = 'cikarilan';
    return _join(file.parent.path, base);
  }

  /// Arşivin içeriğini listeler. Eksik olan üst klasörler ağaç tamamlansın
  /// diye sentezlenir ([ArchiveEntryInfo.isVirtual] true).
  ///
  /// [password] şifreli ZIP için; split parçalar otomatik birleştirilir.
  Future<List<ArchiveEntryInfo>> listEntries(
    String archivePath, {
    String? password,
  }) async {
    final resolved = await materializeSplitIfNeeded(archivePath);
    final format = await _prepareFormat(resolved);

    if (format == 'rar' || format == '7z') {
      return _listNative(resolved, password: password);
    }

    if (format == 'gz') {
      // Tek dosyalık gzip: içinde tek bir girdi var.
      final file = File(resolved);
      return <ArchiveEntryInfo>[
        ArchiveEntryInfo(
          name: _gzInnerName(resolved),
          isDirectory: false,
          uncompressedSize: _gzUncompressedSize(file),
          compressedSize: await file.length(),
          modificationTime: await _modified(file),
        ),
      ];
    }

    final input = InputFileStream(resolved);
    try {
      final archive = _decode(format, input, password: password);
      final entries = <ArchiveEntryInfo>[];
      for (final entry in archive) {
        final name = _stripTrailingSlash(entry.name);
        if (name.isEmpty) continue;
        entries.add(ArchiveEntryInfo(
          name: name,
          isDirectory: entry.isDirectory,
          uncompressedSize: entry.size,
          compressedSize: _compressedSizeOf(entry),
          modificationTime: _modTimeOf(entry, format),
        ));
      }
      await archive.clear();
      return _withVirtualFolders(entries);
    } finally {
      await input.close();
    }
  }

  /// Bölünmüş arşiv parçalarını (`.001` / `.z01`) tek geçici dosyada birleştirir.
  ///
  /// Birleştirme gerekmezse orijinal yolu döner.
  static Future<String> materializeSplitIfNeeded(String archivePath) async {
    final lower = archivePath.toLowerCase();
    final file = File(archivePath);
    if (!await file.exists()) return archivePath;

    Future<String> joinParts(List<File> parts) async {
      if (parts.length <= 1) return archivePath;
      final out = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'makay_split_${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      final sink = out.openWrite();
      try {
        for (final p in parts) {
          await sink.addStream(p.openRead());
        }
      } finally {
        await sink.close();
      }
      return out.path;
    }

    // name.zip.001 veya name.001
    final mZipDot = RegExp(r'^(.*)\.zip\.001$', caseSensitive: false)
        .firstMatch(archivePath);
    final mPlain = RegExp(r'^(.*)\.001$', caseSensitive: false)
        .firstMatch(archivePath);
    if (mZipDot != null || (mPlain != null && !lower.endsWith('.zip.001'))) {
      final stem = mZipDot?.group(1) ?? mPlain!.group(1)!;
      final useZipInfix = mZipDot != null;
      final parts = <File>[file];
      for (var i = 2; i < 1000; i++) {
        final n = i.toString().padLeft(3, '0');
        final candidate = File(
          useZipInfix ? '$stem.zip.$n' : '$stem.$n',
        );
        if (!await candidate.exists()) break;
        parts.add(candidate);
      }
      return joinParts(parts);
    }

    if (lower.endsWith('.z01')) {
      // WinZip: name.zip + name.z01 + name.z02 …
      final base = archivePath.substring(0, archivePath.length - 3); // drop 01
      // base ends with `.z`
      final nameBase = base.substring(0, base.length - 2); // drop `.z`
      final parts = <File>[];
      final zipMain = File('$nameBase.zip');
      if (await zipMain.exists()) parts.add(zipMain);
      parts.add(file);
      for (var i = 2; i < 1000; i++) {
        final p = File('$nameBase.z${i.toString().padLeft(2, '0')}');
        if (!await p.exists()) break;
        parts.add(p);
      }
      if (parts.length <= 1) {
        throw ArchiveServiceException(
          'Bölünmüş ZIP (.z01) için ana .zip veya diğer parçalar bulunamadı.',
        );
      }
      return joinParts(parts);
    }

    return archivePath;
  }

  /// Arşivdeki tüm girdileri [destDir] altına çıkarır.
  ///
  /// [onProgress] her girdiden sonra çağrılır. [totalEntries] biliniyorsa
  /// (ör. ekranda liste varken) iletilmelidir; tar türlerinde girdi sayısı
  /// tek geçişte bilinemediği için ilerleme ancak onunla orantılıdır
  /// (bilinmiyorsa toplam -1 döner).
  ///
  /// Güvenlik: [ArchiveSecurityException] fırlatır ve hedef dışına hiçbir
  /// girdi yazılmaz. Sembolik bağlantılar hiç oluşturulmaz.
  /// Dönen değer gerçekten yazılan dosya sayısıdır.
  Future<int> extractAll({
    required String archivePath,
    required String destDir,
    ArchiveProgress? onProgress,
    int? totalEntries,
    CancelToken? cancelToken,
    String? password,
  }) async {
    final resolved = await materializeSplitIfNeeded(archivePath);
    final format = await _prepareFormat(resolved);
    await Directory(destDir).create(recursive: true);

    void checkCancel() {
      if (cancelToken?.isCancelled == true) {
        throw const TransferCancelled();
      }
    }

    Future<void> cleanupPartial() async {
      try {
        final dir = Directory(destDir);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    }

    try {
      if (format == 'rar' || format == '7z') {
        checkCancel();
        final n = await _extractNative(
          resolved,
          destDir,
          password: password,
        );
        onProgress?.call(n, totalEntries ?? n);
        return n;
      }

      if (format == 'gz') {
        checkCancel();
        final target = safeTargetPath(destDir, _gzInnerName(resolved));
        await Directory(_parentOf(target)).create(recursive: true);
        final input = InputFileStream(resolved);
        final output = OutputFileStream(target);
        try {
          final ok = GZipDecoder().decodeStream(input, output, verify: true);
          if (!ok) {
            throw ArchiveServiceException(
                'Arşiv çıkarılamadı; dosya bozuk olabilir: $resolved');
          }
        } finally {
          await input.close();
          await output.close();
        }
        checkCancel();
        onProgress?.call(1, 1);
        return 1;
      }

      final input = InputFileStream(resolved);
      var written = 0;
      var done = 0;
      try {
        if (format == 'zip') {
          final archive = _decode('zip', input, password: password);
          final total = totalEntries ?? archive.length;
          try {
            for (final entry in archive) {
              checkCancel();
              if (_writeEntry(entry, destDir)) written++;
              done++;
              onProgress?.call(done, total);
            }
          } finally {
            await archive.clear();
          }
        } else {
          // tar / tar.gz: tek geçiş; içerik yalnızca girdiye ulaşıldığında
          // elde bulunur, bu yüzden yazma geri çağrıcı içinde yapılır.
          final tarInput =
              format == 'targz' ? GZipDecoder().decodeLazy(input) : input;
          final total = totalEntries ?? -1;
          try {
            TarDecoder().decodeStream(tarInput,
                verify: true, keepEntries: false, callback: (entry) {
              checkCancel();
              if (_writeEntry(entry, destDir)) written++;
              done++;
              onProgress?.call(done, total);
            });
          } on ArchiveException catch (err) {
            _corrupt(err);
          } on FormatException catch (err) {
            _corrupt(err);
          }
        }
      } finally {
        await input.close();
      }
      return written;
    } on TransferCancelled {
      await cleanupPartial();
      rethrow;
    }
  }

  /// [entryName] girdisini (dosya ya da klasör alt ağacı) tek başına
  /// [destDir] altına çıkarır; arşiv içindeki yolu korunur.
  Future<void> extractEntry({
    required String archivePath,
    required String entryName,
    required String destDir,
    String? password,
  }) async {
    final resolved = await materializeSplitIfNeeded(archivePath);
    final format = await _prepareFormat(resolved);
    final wanted = _stripTrailingSlash(entryName.replaceAll('\\', '/'));
    if (wanted.isEmpty) {
      throw ArchiveServiceException('Geçersiz arşiv girdi adı.');
    }
    await Directory(destDir).create(recursive: true);

    if (format == 'rar' || format == '7z') {
      await _extractNative(
        resolved,
        destDir,
        password: password,
        entryName: wanted,
      );
      return;
    }

    if (format == 'gz') {
      final inner = _gzInnerName(resolved);
      if (inner != wanted) {
        throw ArchiveServiceException(
            'Arşivde "$wanted" adında bir girdi bulunamadı.');
      }
      await _extractGz(resolved, destDir);
      return;
    }

    final input = InputFileStream(resolved);
    var found = false;
    try {
      if (format == 'zip') {
        final archive = _decode('zip', input, password: password);
        try {
          for (final entry in archive) {
            final name = _stripTrailingSlash(entry.name);
            if (_matches(name, wanted)) {
              found = true;
              _writeEntry(entry, destDir);
            }
          }
        } finally {
          await archive.clear();
        }
      } else {
        final tarInput =
            format == 'targz' ? GZipDecoder().decodeLazy(input) : input;
        try {
          TarDecoder().decodeStream(tarInput,
              verify: true, keepEntries: false, callback: (entry) {
            final name = _stripTrailingSlash(entry.name);
            if (_matches(name, wanted)) {
              found = true;
              _writeEntry(entry, destDir);
            }
          });
        } on ArchiveException catch (err) {
          _corrupt(err);
        } on FormatException catch (err) {
          _corrupt(err);
        }
      }
    } finally {
      await input.close();
    }
    if (!found) {
      throw ArchiveServiceException(
          'Arşivde "$wanted" adında bir girdi bulunamadı.');
    }
  }

  /// [sourcePaths] içindeki dosya ve klasörleri (klasörler alt ağacıyla
  /// birlikte) [outPath] konumuna ZIP olarak yazar.
  ///
  /// Girdi adları klasör adı ya da dosya adıyla başlar; klasör kaynakların
  /// tüm alt içerikleri korunur. Dönen değer arşive eklenen dosya sayısı.
  Future<int> createZip({
    required List<String> sourcePaths,
    required String outPath,
    ArchiveProgress? onProgress,
  }) async {
    final plan = _creationPlan(sourcePaths);
    final total = plan.where((item) => !item.isDirectory).length;
    final encoder = ZipFileEncoder();
    var done = 0;
    var added = 0;
    try {
      encoder.create(outPath);
      for (final item in plan) {
        if (item.isDirectory) {
          encoder.addArchiveFile(ArchiveFile.directory('${item.entryName}/'));
        } else {
          await encoder.addFile(File(item.diskPath), item.entryName);
          added++;
          done++;
          onProgress?.call(done, total);
        }
      }
    } catch (_) {
      await _deleteQuietly(outPath);
      rethrow;
    } finally {
      await encoder.close();
    }
    return added;
  }

  /// [sourcePaths] içindeki dosya ve klasörleri (klasörler alt ağacıyla
  /// birlikte) [outPath] konumuna TAR olarak yazar.
  Future<int> createTar({
    required List<String> sourcePaths,
    required String outPath,
    ArchiveProgress? onProgress,
  }) async {
    final plan = _creationPlan(sourcePaths);
    final total = plan.where((item) => !item.isDirectory).length;
    final output = OutputFileStream(outPath);
    final encoder = TarEncoder();
    encoder.start(output);
    var done = 0;
    var added = 0;
    try {
      for (final item in plan) {
        if (item.isDirectory) {
          encoder.add(ArchiveFile.directory('${item.entryName}/'));
          continue;
        }
        final stream = InputFileStream(item.diskPath);
        try {
          final stat = await File(item.diskPath).stat();
          final entry = ArchiveFile.stream(item.entryName, stream)
            ..mode = stat.mode
            ..lastModTime =
                stat.modified.millisecondsSinceEpoch ~/ 1000;
          encoder.add(entry);
        } finally {
          await stream.close();
        }
        added++;
        done++;
        onProgress?.call(done, total);
      }
      encoder.finish();
    } catch (_) {
      await _deleteQuietly(outPath);
      rethrow;
    } finally {
      await output.close();
    }
    return added;
  }

  /// Zip-Slip denetimi: [entryName] (arşiv içi göreli yol) ile [destDir]
  /// altında kalacak güvenli mutlak yol döner. Mutlak yol ya da '..'
  /// içeren, ya da hedef klasörün dışına çıkan girdilerde
  /// [ArchiveSecurityException] fırlatır.
  static String safeTargetPath(String destDir, String entryName) {
    final name = entryName.replaceAll('\\', '/');
    if (name.isEmpty) {
      throw ArchiveSecurityException(
          'Güvenlik ihlali: boş arşiv girdi adı reddedildi.');
    }
    if (_isAbsolute(name)) {
      throw ArchiveSecurityException(
          'Güvenlik ihlali: arşiv girdisi mutlak yol kullanıyor ($entryName). '
          'Çıkarılmadı.');
    }
    if (name.split('/').contains('..')) {
      throw ArchiveSecurityException(
          'Güvenlik ihlali: arşiv girdisi hedef klasörün dışına çıkıyor '
          '($entryName). Çıkarılmadı.');
    }
    final destAbs = _absoluteOf(destDir);
    final target = _normalize('$destAbs/$name');
    if (target != destAbs && !target.startsWith('$destAbs/')) {
      throw ArchiveSecurityException(
          'Güvenlik ihlali: arşiv girdisi hedef klasörün dışına çıkıyor '
          '($entryName). Çıkarılmadı.');
    }
    return target.replaceAll('/', Platform.pathSeparator);
  }

  // -------------------------------------------------------------------------
  // Dahilî yardımcılar
  // -------------------------------------------------------------------------

  /// Uzantı ve dosya varlığı denetimi; zip için ayrıca EOCD imzası
  /// kontrol edilir (kitaplık bozuk bir zip'i sessizce boş listeleyebilir).
  static Future<String> _prepareFormat(String archivePath) async {
    final format = _requireFormat(archivePath);
    final file = File(archivePath);
    if (!await file.exists()) {
      throw ArchiveServiceException('Arşiv dosyası bulunamadı: $archivePath');
    }
    if (format == 'zip') _assertZipSignature(file);
    return format;
  }

  static String _requireFormat(String archivePath) {
    final format = _formatOf(archivePath);
    if (format == null) {
      throw ArchiveServiceException(
          'Desteklenmeyen arşiv biçimi. Desteklenenler: ZIP (şifreli dahil), '
          'RAR, 7Z, TAR, GZ, TGZ, TAR.GZ ve bölünmüş ZIP (.001 / .z01).');
    }
    if (format == 'iso' || format == 'obb') {
      throw ArchiveServiceException(
        '${formatName(archivePath)} biçimi bu sürümde açılamaz.',
      );
    }
    if (format == 'split') {
      throw ArchiveServiceException(
        'Bölünmüş arşiv birleştirilemedi. İlk parçayı (.001 / .z01) seçin.',
      );
    }
    return format;
  }

  Future<List<ArchiveEntryInfo>> _listNative(
    String path, {
    String? password,
  }) async {
    try {
      final raw = await PlatformService.listNativeArchive(
        path: path,
        password: password,
      );
      final entries = <ArchiveEntryInfo>[
        for (final m in raw)
          ArchiveEntryInfo(
            name: _stripTrailingSlash('${m['name'] ?? ''}'),
            isDirectory: m['isDirectory'] == true,
            uncompressedSize: (m['uncompressedSize'] as num?)?.toInt() ?? 0,
            compressedSize: (m['compressedSize'] as num?)?.toInt() ?? 0,
            modificationTime: null,
          ),
      ].where((e) => e.name.isNotEmpty).toList();
      return _withVirtualFolders(entries);
    } on UnsupportedError catch (e) {
      throw ArchiveServiceException('$e');
    } on PlatformException catch (e) {
      final msg = e.message ?? '';
      if (ArchiveService.isPasswordError(msg) ||
          msg.toLowerCase().contains('password')) {
        throw ArchiveServiceException('Şifre gerekli veya hatalı');
      }
      throw ArchiveServiceException(
        'Arşiv açılamadı: ${msg.isEmpty ? e.code : msg}',
      );
    }
  }

  Future<int> _extractNative(
    String path,
    String destDir, {
    String? password,
    String? entryName,
  }) async {
    try {
      return await PlatformService.extractNativeArchive(
        path: path,
        destDir: destDir,
        password: password,
        entryName: entryName,
      );
    } on UnsupportedError catch (e) {
      throw ArchiveServiceException('$e');
    } on PlatformException catch (e) {
      throw ArchiveServiceException(
        'Çıkarılamadı: ${e.message ?? e.code}',
      );
    }
  }

  /// ZIP dosyasının sonunda EOCD imzası (PK\\x05\\x06) aranır; bulunamazsa
  /// dosya zip değildir ya da bozuktur.
  static void _assertZipSignature(File file) {
    const signature = [0x50, 0x4B, 0x05, 0x06];
    final raf = file.openSync();
    try {
      final length = raf.lengthSync();
      // EOCD kaydı en az 22 bayttır; yorum alanı 65535 bayta kadar ekler.
      final tail = length < 22 ? length : (length - 22 < 65535 ? length : 65557);
      if (length < 22) _corrupt('EOCD yok (dosya çok küçük: $length bayt)');
      raf.setPositionSync(length - tail);
      final bytes = raf.readSync(tail);
      var found = false;
      for (var i = bytes.length - 22; i >= 0; i--) {
        if (bytes[i] == signature[0] &&
            bytes[i + 1] == signature[1] &&
            bytes[i + 2] == signature[2] &&
            bytes[i + 3] == signature[3]) {
          found = true;
          break;
        }
      }
      if (!found) _corrupt('ZIP EOCD imzası bulunamadı');
    } finally {
      raf.closeSync();
    }
  }

  Archive _decode(
    String format,
    InputFileStream input, {
    String? password,
  }) {
    // Arşiv akışını çözer; bozuk/okunamayan girdilerde Türkçe hata fırlatır.
    //
    // Not: tar türlerinde içerik her zaman saklanır; `storeData: false`
    // iken kütüphane girdi boyutunu 0 olarak verir, bu da listelemeyi
    // işelevsiz kılar. İçerik dosyaya bağlı akış olduğundan bellek şişmez.
    try {
      switch (format) {
        case 'zip':
          return ZipDecoder().decodeStream(input, password: password);
        case 'tar':
          return TarDecoder().decodeStream(input, verify: true);
        case 'targz':
          return TarDecoder().decodeStream(GZipDecoder().decodeLazy(input),
              verify: true);
        default:
          throw ArchiveServiceException('Desteklenmeyen arşiv biçimi.');
      }
    } on ArchiveServiceException {
      rethrow;
    } on ArchiveException catch (err) {
      _corrupt(err);
    } on FormatException catch (err) {
      _corrupt(err);
    } catch (err) {
      _corrupt(err);
    }
  }

  /// Bozuk/okunamayan arşiv için ortak Türkçe hata.
  static Never _corrupt(Object err) {
    throw ArchiveServiceException(
        'Arşiv okunamadı; dosya bozuk veya desteklenmeyen bir formatta '
        'olabilir. ($err)');
  }

  /// Bir girdiyi diske yazar; true dönerse dosya/klasör yazıldı demektir.
  /// Sembolik bağlantılar güvenlik gereği hiç yazılmaz.
  bool _writeEntry(ArchiveFile entry, String destDir) {
    final name = _stripTrailingSlash(entry.name);
    if (name.isEmpty) return false;
    final target = safeTargetPath(destDir, name); // Zip-Slip denetimi.
    if (entry.isSymbolicLink) return false;
    if (entry.isDirectory) {
      Directory(target).createSync(recursive: true);
      return false;
    }
    final parent = _parentOf(target);
    _assertSafeExistingAncestor(destDir, parent);
    Directory(parent).createSync(recursive: true);
    final output = OutputFileStream(target);
    try {
      entry.writeContent(output);
    } finally {
      output.closeSync();
    }
    return true;
  }

  /// [dirPath] içindeki en derin MEVCUT ataya kadar bakılıp o atанın kanonik
  /// yolunun hedef klasör içinde kaldığı doğrulanır; böylece var olan bir
  /// sembolik bağlantı üzerinden de dışarıya yazılamaz.
  static void _assertSafeExistingAncestor(String destDir, String dirPath) {
    var ancestor = dirPath;
    while (!Directory(ancestor).existsSync() &&
        !File(ancestor).existsSync()) {
      final parent = _parentOf(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
    try {
      final canonicalDest =
          _normalize(Directory(destDir).resolveSymbolicLinksSync());
      final canonicalAncestor =
          _normalize(Directory(ancestor).resolveSymbolicLinksSync());
      if (canonicalAncestor != canonicalDest &&
          !canonicalAncestor.startsWith('$canonicalDest/')) {
        throw ArchiveSecurityException(
            'Güvenlik ihlali: hedef klasör bir sembolik bağlantı üzerinden '
            'dışarıya çıkıyor. Çıkarılmadı.');
      }
    } on ArchiveSecurityException {
      rethrow;
    } catch (_) {
      // Kanonik yol alınamazsa sözel denetim yeterli sayılır.
    }
  }

  Future<void> _extractGz(String archivePath, String destDir) async {
    final target = safeTargetPath(destDir, _gzInnerName(archivePath));
    await Directory(_parentOf(target)).create(recursive: true);
    final input = InputFileStream(archivePath);
    final output = OutputFileStream(target);
    try {
      final ok = GZipDecoder().decodeStream(input, output, verify: true);
      if (!ok) {
        throw ArchiveServiceException(
            'Arşiv çıkarılamadı; dosya bozuk olabilir: $archivePath');
      }
    } finally {
      await input.close();
      await output.close();
    }
  }

  /// gzip dosyasının içindeki tek girdinin adı (uzantı kırpılır).
  static String _gzInnerName(String archivePath) {
    final name = _baseName(archivePath);
    final lower = name.toLowerCase();
    if (lower.endsWith('.tar.gz')) {
      return name.substring(0, name.length - '.tar.gz'.length);
    }
    if (lower.endsWith('.gz')) return name.substring(0, name.length - 3);
    return name;
  }

  /// gzip trailer'ındaki ISIZE alanı (mod 2^32 sıkıştırılmamış boyut).
  static int _gzUncompressedSize(File file) {
    try {
      final raf = file.openSync();
      try {
        final length = raf.lengthSync();
        if (length < 18) return 0;
        raf.setPositionSync(length - 4);
        final bytes = raf.readSync(4);
        return bytes[0] | (bytes[1] << 8) | (bytes[2] << 16) | (bytes[3] << 24);
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return 0;
    }
  }

  static int _compressedSizeOf(ArchiveFile entry) {
    final raw = entry.rawContent;
    if (raw is ZipFile) return raw.compressedSize;
    return entry.size;
  }

  static DateTime? _modTimeOf(ArchiveFile entry, String format) {
    if (entry.lastModTime <= 0) return null;
    try {
      // ZIP'te lastModTime DOS tarih/biçimiyle paketlenmiştir; tar'da ise
      // epoch cinsinden saniyedir.
      if (format == 'zip') return entry.lastModDateTime;
      return DateTime.fromMillisecondsSinceEpoch(entry.lastModTime * 1000);
    } catch (_) {
      return null;
    }
  }

  static Future<DateTime?> _modified(FileSystemEntity entity) async {
    try {
      return await entity.stat().then((s) => s.modified);
    } catch (_) {
      return null;
    }
  }

  /// Eksik üst klasörleri sentezleyip listeyi (klasörler önce) sıralar.
  static List<ArchiveEntryInfo> _withVirtualFolders(
      List<ArchiveEntryInfo> entries) {
    final known = <String>{
      for (final e in entries) e.name,
    };
    final extra = <ArchiveEntryInfo>[];
    for (final entry in entries) {
      var parent = entry.parentPath;
      while (parent.isNotEmpty && known.add(parent)) {
        extra.add(ArchiveEntryInfo(
          name: parent,
          isDirectory: true,
          uncompressedSize: 0,
          compressedSize: 0,
          modificationTime: entry.modificationTime,
          isVirtual: true,
        ));
        final i = parent.lastIndexOf('/');
        parent = i <= 0 ? '' : parent.substring(0, i);
      }
    }
    final all = [...entries, ...extra];
    int compare(ArchiveEntryInfo a, ArchiveEntryInfo b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }

    return all..sort(compare);
  }

  /// Kaynaklardan çıkarma planı: diske gidecek yol + arşiv içi ad.
  static List<_ArchiveSourceItem> _creationPlan(List<String> sourcePaths) {
    final items = <_ArchiveSourceItem>[];
    final seen = <String>{};
    for (final source in sourcePaths) {
      final normalized = _normalize(_absoluteOf(source));
      if (!seen.add(normalized)) continue;
      final base = _baseName(normalized);
      if (base.isEmpty) continue;
      final file = File(normalized);
      if (file.existsSync()) {
        items.add(_ArchiveSourceItem(normalized, base, false));
        continue;
      }
      final dir = Directory(normalized);
      if (!dir.existsSync()) {
        throw ArchiveServiceException('Kaynak bulunamadı: $source');
      }
      items.add(_ArchiveSourceItem(normalized, base, true));
      final children = dir.listSync(recursive: true, followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final childNorm = _normalize(child.path);
        final rel = _relativeTo(childNorm, normalized);
        if (rel.isEmpty) continue;
        items.add(_ArchiveSourceItem(
          child.path,
          '$base/$rel',
          child is Directory,
        ));
      }
    }
    return items;
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Geçici arşiv artığı silinemezse bir sonraki açılışta üzerine yazılır
      // ya da sistem tarafından temizlenir; işlem sonucu değişmez.
    }
  }

  static bool _matches(String entryName, String wanted) =>
      entryName == wanted || entryName.startsWith('$wanted/');

  static String _stripTrailingSlash(String name) {
    var result = name;
    while (result.endsWith('/')) {
      result = result.substring(0, result.length - 1);
    }
    return result;
  }

  static String _baseName(String path) {
    final normalized = _normalize(path);
    final i = normalized.lastIndexOf('/');
    return i < 0 ? normalized : normalized.substring(i + 1);
  }

  static String _parentOf(String path) {
    final normalized = _normalize(path);
    final i = normalized.lastIndexOf('/');
    if (i < 0) return '';
    if (i == 0) return '/';
    return normalized
        .substring(0, i)
        .replaceAll('/', Platform.pathSeparator);
  }

  static String _join(String a, String b) =>
      '${a.endsWith(Platform.pathSeparator) ? a : '$a${Platform.pathSeparator}'}$b';

  static bool _isAbsolute(String path) =>
      path.startsWith('/') || (path.length >= 2 && path[1] == ':');

  static String _absoluteOf(String path) {
    final normalized = _normalize(path);
    if (_isAbsolute(normalized)) return normalized;
    return _normalize('${Directory.current.path}/$normalized');
  }

  /// Yol ayraçlarını '/' yapar, '.' ve ' içeren bileşenleri çözümler.
  static String _normalize(String path) {
    final unified = path.replaceAll('\\', '/');
    final isAbsolute = unified.startsWith('/');
    final segments = unified.split('/');
    final out = <String>[];
    for (final segment in segments) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (out.isNotEmpty && out.last != '..') {
          out.removeLast();
        } else if (!isAbsolute) {
          out.add('..');
        }
        continue;
      }
      out.add(segment);
    }
    final joined = out.join('/');
    if (isAbsolute) return '/$joined';
    return joined;
  }

  /// [path], [from] dizinine göre göreli yolu ('/' ayracıyla).
  static String _relativeTo(String path, String from) {
    final p = _normalize(path).split('/');
    final f = _normalize(from).split('/');
    var i = 0;
    while (i < p.length && i < f.length && p[i] == f[i]) {
      i++;
    }
    return p.sublist(i).join('/');
  }
}

/// Oluşturma planındaki tek kayıt.
class _ArchiveSourceItem {
  const _ArchiveSourceItem(this.diskPath, this.entryName, this.isDirectory);

  final String diskPath;
  final String entryName;
  final bool isDirectory;
}
