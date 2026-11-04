import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/archive_service.dart';

/// ArchiveService birim testleri: listeleme, çıkarma, oluşturma ve
/// Zip-Slip (yol dışına çıkma) güvenlik denetimi. Tüm I/O gerçek dosya
/// sisteminde, setUp() içinde hazırlanan geçici dizinde yapılır.
void main() {
  const svc = ArchiveService();
  final sep = Platform.pathSeparator;

  late Directory root;
  late String sampleZip;
  late String sampleTar;
  late String sampleTgz;
  late String sampleGz;

  setUp(() {
    root = Directory.systemTemp.createTempSync('archive_svc_');

    // Örnek ZIP: docs/readme.txt, docs/notlar/kayit.txt, kok.txt,
    // bosklasor/ (boş klasör girdisi).
    final zip = Archive()
      ..add(ArchiveFile.string('docs/readme.txt', 'Merhaba arşiv'))
      ..add(ArchiveFile.string('docs/notlar/kayit.txt', 'ikinci dosya'))
      ..add(ArchiveFile.string('kok.txt', 'kok dosyasi'))
      ..add(ArchiveFile.directory('bosklasor/'));
    sampleZip = '${root.path}${sep}ornek.zip';
    File(sampleZip).writeAsBytesSync(ZipEncoder().encodeBytes(zip));

    // Örnek TAR: a.txt, alt/b.txt.
    final tar = Archive()
      ..add(ArchiveFile.string('a.txt', 'tar icerik'))
      ..add(ArchiveFile.string('alt/b.txt', 'alt icerik'));
    sampleTar = '${root.path}${sep}ornek.tar';
    File(sampleTar).writeAsBytesSync(TarEncoder().encodeBytes(tar));

    // Örnek TAR.GZ: aynı içerik gzip ile sıkıştırılmış.
    sampleTgz = '${root.path}${sep}ornek.tar.gz';
    File(sampleTgz)
        .writeAsBytesSync(GZipEncoder().encodeBytes(File(sampleTar)
            .readAsBytesSync()));

    // Örnek GZ: tek dosyalık gzip.
    sampleGz = '${root.path}${sep}dosya.txt.gz';
    File(sampleGz)
        .writeAsBytesSync(GZipEncoder().encodeBytes(utf8.encode('gzip icerigi')));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('isArchive / uzantılar', () {
    test('desteklenen uzantılar arşiv sayılır (ZIP/TAR/RAR/7Z/split)', () {
      expect(ArchiveService.isArchive('a.zip'), isTrue);
      expect(ArchiveService.isArchive('a.tar'), isTrue);
      expect(ArchiveService.isArchive('a.gz'), isTrue);
      expect(ArchiveService.isArchive('a.tgz'), isTrue);
      expect(ArchiveService.isArchive('a.tar.gz'), isTrue);
      expect(ArchiveService.isArchive('ARŞİV.ZIP'), isTrue);
      // RAR/7z/ISO tarayıcıda arşiv menüsüne düşsün diye tanınır; açılışta
      // dürüst "açılamaz" mesajı verilir.
      expect(ArchiveService.isArchive('a.rar'), isTrue);
      expect(ArchiveService.isArchive('a.7z'), isTrue);
      expect(ArchiveService.isArchive('a.001'), isTrue);
      expect(ArchiveService.isArchive('a.txt'), isFalse);
      expect(ArchiveService.supportedExtensions, contains('.zip'));
      expect(ArchiveService.creatableExtensions, ['.zip', '.tar']);
    });

    test('formatName Türkçe gösterim için ad döner', () {
      expect(ArchiveService.formatName('x.zip'), 'ZIP');
      expect(ArchiveService.formatName('x.tar.gz'), 'TAR.GZ');
      expect(ArchiveService.formatName('x.tgz'), 'TAR.GZ');
      expect(ArchiveService.formatName('x.rar'), 'RAR');
      expect(ArchiveService.formatName('x.7z'), '7Z');
    });
  });

  group('listEntries', () {
    test('zip: adlar, boyutlar, parentPath ve sentezlenen klasörler', () async {
      final entries = await svc.listEntries(sampleZip);
      final names = entries.map((e) => e.name).toList();
      expect(
        names,
        containsAll(<String>[
          'bosklasor',
          'docs',
          'docs/notlar',
          'docs/readme.txt',
          'docs/notlar/kayit.txt',
          'kok.txt',
        ]),
      );

      final readme = entries.firstWhere((e) => e.name == 'docs/readme.txt');
      expect(readme.isDirectory, isFalse);
      expect(readme.parentPath, 'docs');
      expect(readme.baseName, 'readme.txt');
      expect(readme.uncompressedSize, utf8.encode('Merhaba arşiv').length);
      expect(readme.compressedSize, greaterThanOrEqualTo(0));
      expect(readme.modificationTime, isNotNull);

      // 'docs' ve 'docs/notlar' arşivde fiilen yok, sentezlendi.
      final docs = entries.firstWhere((e) => e.name == 'docs');
      expect(docs.isDirectory, isTrue);
      expect(docs.isVirtual, isTrue);
      expect(docs.parentPath, '');

      // Klasörler dosyalardan önce listelenir.
      final firstFileIndex =
          entries.indexWhere((e) => !e.isDirectory);
      expect(entries.take(firstFileIndex).every((e) => e.isDirectory), isTrue);
    });

    test('tar: adlar ve parentPath', () async {
      final entries = await svc.listEntries(sampleTar);
      final names = entries.map((e) => e.name).toList();
      expect(names, containsAll(<String>['a.txt', 'alt', 'alt/b.txt']));
      final b = entries.firstWhere((e) => e.name == 'alt/b.txt');
      expect(b.parentPath, 'alt');
      expect(b.uncompressedSize, utf8.encode('alt icerik').length);
    });

    test('tar.gz açılır', () async {
      final entries = await svc.listEntries(sampleTgz);
      final names = entries.map((e) => e.name).toList();
      expect(names, containsAll(<String>['a.txt', 'alt/b.txt']));
    });

    test('gz: tek girdi ve ISIZE boyutu', () async {
      final entries = await svc.listEntries(sampleGz);
      expect(entries, hasLength(1));
      expect(entries.single.name, 'dosya.txt');
      expect(entries.single.isDirectory, isFalse);
      expect(entries.single.uncompressedSize, 'gzip icerigi'.length);
    });

    test('boş zip → boş liste', () async {
      final emptyZip = '${root.path}${sep}bos.zip';
      File(emptyZip).writeAsBytesSync(ZipEncoder().encodeBytes(Archive()));
      final entries = await svc.listEntries(emptyZip);
      expect(entries, isEmpty);
    });

    test('bozuk zip → Türkçe ArchiveServiceException', () async {
      final corrupt = '${root.path}${sep}bozuk.zip';
      File(corrupt).writeAsBytesSync(const [1, 2, 3, 4, 5, 6, 7, 8]);
      await expectLater(
        svc.listEntries(corrupt),
        throwsA(isA<ArchiveServiceException>()
            .having((e) => e.message, 'mesaj', contains('okunamadı'))),
      );
    });

    test('RAR masaüstünde platform yok → Türkçe hata', () async {
      // Android'de native junrar ile açılır; birim testleri Windows'ta
      // platform kanalı olmadığı için dürüst hata verir.
      final rar = File('${root.path}${sep}yedek.rar')
        ..writeAsBytesSync(const [0x52, 0x61, 0x72, 0x21]); // "Rar!" imzası
      await expectLater(
        svc.listEntries(rar.path),
        throwsA(isA<ArchiveServiceException>().having(
            (e) => e.message.toLowerCase(),
            'mesaj',
            anyOf(contains('android'), contains('açılamadı')))),
      );
    });

    test('var olmayan dosya → bulunamadı hatası', () async {
      await expectLater(
        svc.listEntries('${root.path}${sep}yok.zip'),
        throwsA(isA<ArchiveServiceException>()
            .having((e) => e.message, 'mesaj', contains('bulunamadı'))),
      );
    });
  });

  group('extractAll', () {
    test('tüm girdiler diske çıkar, ilerleme bildirilir', () async {
      final dest = '${root.path}${sep}cikar';
      final progress = <(int, int)>[];
      final written = await svc.extractAll(
        archivePath: sampleZip,
        destDir: dest,
        onProgress: (done, total) => progress.add((done, total)),
      );
      expect(written, 3); // 3 dosya; boş klasör yalnızca oluşturulur.
      expect(File('$dest${sep}kok.txt').readAsStringSync(), 'kok dosyasi');
      expect(File('$dest${sep}docs${sep}readme.txt').readAsStringSync(),
          'Merhaba arşiv');
      expect(File('$dest${sep}docs${sep}notlar${sep}kayit.txt')
          .readAsStringSync(), 'ikinci dosya');
      expect(Directory('$dest${sep}bosklasor').existsSync(), isTrue);
      expect(progress, isNotEmpty);
      expect(progress.last.$1, 4);
      expect(progress.last.$2, 4);
    });

    test('tar.gz çıkarılır', () async {
      final dest = '${root.path}${sep}tgz_cikar';
      final written =
          await svc.extractAll(archivePath: sampleTgz, destDir: dest);
      expect(written, 2);
      expect(File('$dest${sep}a.txt').readAsStringSync(), 'tar icerik');
      expect(File('$dest${sep}alt${sep}b.txt').readAsStringSync(), 'alt icerik');
    });

    test('gz çıkarılır', () async {
      final dest = '${root.path}${sep}gz_cikar';
      final written =
          await svc.extractAll(archivePath: sampleGz, destDir: dest);
      expect(written, 1);
      expect(File('$dest${sep}dosya.txt').readAsStringSync(), 'gzip icerigi');
    });

    test('Zip-Slip: ../ ile dışarı sıçramaya çalışan girdi reddedilir',
        () async {
      final evil = Archive()
        ..add(ArchiveFile.string('guvenli.txt', 'tamam'))
        ..add(ArchiveFile.string('../kotu.txt', 'kotu'));
      final evilZip = '${root.path}${sep}kotu.zip';
      File(evilZip).writeAsBytesSync(ZipEncoder().encodeBytes(evil));

      final dest = '${root.path}${sep}kotu_cikar';
      await expectLater(
        svc.extractAll(archivePath: evilZip, destDir: dest),
        throwsA(isA<ArchiveSecurityException>()
            .having((e) => e.message, 'mesaj', contains('Güvenlik ihlali'))),
      );
      // Hedef klasörün DIŞINA hiçbir dosya yazılmamış olmalı.
      expect(File('${root.path}${sep}kotu.txt').existsSync(), isFalse);
      expect(Directory(dest).existsSync(), isTrue, reason: 'hedef oluşturulur');
    });

    test('mutlak yol içeren girdi reddedilir', () async {
      final evil = Archive()
        ..add(ArchiveFile.string('/mutlak.txt', 'kotu'));
      final evilZip = '${root.path}${sep}mutlak.zip';
      File(evilZip).writeAsBytesSync(ZipEncoder().encodeBytes(evil));

      await expectLater(
        svc.extractAll(archivePath: evilZip, destDir: '${root.path}${sep}c2'),
        throwsA(isA<ArchiveSecurityException>()),
      );
      expect(File('${root.path}${sep}mutlak.txt').existsSync(), isFalse);
    });

    test('safeTargetPath yol denetimi yapar', () {
      final dest = '${root.path}${sep}hedef';
      expect(
        () => ArchiveService.safeTargetPath(dest, '../disari.txt'),
        throwsA(isA<ArchiveSecurityException>()),
      );
      expect(
        () => ArchiveService.safeTargetPath(dest, 'ic/dosya.txt'),
        returnsNormally,
      );
      final safe = ArchiveService.safeTargetPath(dest, 'ic/dosya.txt');
      expect(safe.startsWith(dest), isTrue);
    });
  });

  group('extractEntry', () {
    test('tek dosya çıkarılır, diğerleri çıkarılmaz', () async {
      final dest = '${root.path}${sep}tek';
      await svc.extractEntry(
        archivePath: sampleZip,
        entryName: 'docs/notlar/kayit.txt',
        destDir: dest,
      );
      expect(
        File('$dest${sep}docs${sep}notlar${sep}kayit.txt').readAsStringSync(),
        'ikinci dosya',
      );
      expect(File('$dest${sep}kok.txt').existsSync(), isFalse);
      expect(File('$dest${sep}docs${sep}readme.txt').existsSync(), isFalse);
    });

    test('klasör alt ağacıyla çıkarılır', () async {
      final dest = '${root.path}${sep}alt_agac';
      await svc.extractEntry(
        archivePath: sampleZip,
        entryName: 'docs',
        destDir: dest,
      );
      expect(
          File('$dest${sep}docs${sep}readme.txt').existsSync(), isTrue);
      expect(
          File('$dest${sep}docs${sep}notlar${sep}kayit.txt').existsSync(),
          isTrue);
      expect(File('$dest${sep}kok.txt').existsSync(), isFalse);
    });

    test('var olmayan girdi → Türkçe hata', () async {
      await expectLater(
        svc.extractEntry(
          archivePath: sampleZip,
          entryName: 'yok/boyle.txt',
          destDir: '${root.path}${sep}yok_cikar',
        ),
        throwsA(isA<ArchiveServiceException>()
            .having((e) => e.message, 'mesaj', contains('bulunamadı'))),
      );
    });
  });

  group('createZip / createTar', () {
    late String srcFile;
    late String srcDir;

    setUp(() {
      srcFile = '${root.path}${sep}tek.txt';
      File(srcFile).writeAsStringSync('tek icerik');
      srcDir = '${root.path}${sep}kaynak';
      Directory('$srcDir${sep}alt').createSync(recursive: true);
      File('$srcDir${sep}b.txt').writeAsStringSync('b icerik');
      File('$srcDir${sep}alt${sep}k.txt').writeAsStringSync('k icerik');
    });

    test('createZip: klasör alt ağacıyla eklenir, round-trip', () async {
      final out = '${root.path}${sep}yeni.zip';
      var lastDone = 0;
      var lastTotal = 0;
      final added = await svc.createZip(
        sourcePaths: [srcDir, srcFile],
        outPath: out,
        onProgress: (done, total) {
          lastDone = done;
          lastTotal = total;
        },
      );
      expect(added, 3); // b.txt, alt/k.txt, tek.txt
      expect(lastDone, 3);
      expect(lastTotal, 3);

      final entries = await svc.listEntries(out);
      final names = entries.map((e) => e.name).toList();
      expect(
        names,
        containsAll(<String>[
          'kaynak',
          'kaynak/b.txt',
          'kaynak/alt',
          'kaynak/alt/k.txt',
          'tek.txt',
        ]),
      );

      // Geri çıkış: içerikler korunur.
      final dest = '${root.path}${sep}yeni_cikar';
      await svc.extractAll(archivePath: out, destDir: dest);
      expect(File('$dest${sep}tek.txt').readAsStringSync(), 'tek icerik');
      expect(
          File('$dest${sep}kaynak${sep}alt${sep}k.txt').readAsStringSync(),
          'k icerik');
    });

    test('createTar: round-trip', () async {
      final out = '${root.path}${sep}yeni.tar';
      final added =
          await svc.createTar(sourcePaths: [srcDir], outPath: out);
      expect(added, 2);

      final entries = await svc.listEntries(out);
      final names = entries.map((e) => e.name).toList();
      expect(names, containsAll(<String>['kaynak/b.txt', 'kaynak/alt/k.txt']));

      final dest = '${root.path}${sep}tar_cikar';
      await svc.extractAll(archivePath: out, destDir: dest);
      expect(
          File('$dest${sep}kaynak${sep}b.txt').readAsStringSync(), 'b icerik');
    });

    test('var olmayan kaynak → Türkçe hata, çıktı dosyası kalmaz', () async {
      final out = '${root.path}${sep}hata.zip';
      await expectLater(
        svc.createZip(
            sourcePaths: ['${root.path}${sep}yok_kaynak'], outPath: out),
        throwsA(isA<ArchiveServiceException>()
            .having((e) => e.message, 'mesaj', contains('bulunamadı'))),
      );
      expect(File(out).existsSync(), isFalse);
    });
  });

  group('ad yardımcıları', () {
    test('suggestedZipPath uzantıyı değiştirir, çakışmada numaralandırır',
        () {
      final dir = Directory.systemTemp.createTempSync('archive_name_');
      try {
        File('${dir.path}${sep}foto.jpg').writeAsStringSync('x');
        final zipPath = ArchiveService.suggestedZipPath(dir.path, 'foto.jpg');
        expect(zipPath, endsWith('foto.zip'));
        expect(File(zipPath).existsSync(), isFalse);

        // 'foto.zip' varsa '(2)' eklenir.
        File(zipPath).writeAsStringSync('z');
        expect(ArchiveService.suggestedZipPath(dir.path, 'foto.jpg'),
            endsWith('foto (2).zip'));

        // Uzantısız ad (klasör) için aynen '.zip' eklenir.
        Directory('${dir.path}${sep}klasor').createSync();
        expect(ArchiveService.suggestedZipPath(dir.path, 'klasor'),
            endsWith('klasor.zip'));
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('defaultExtractDirFor arşiv adından türetilir', () {
      expect(ArchiveService.defaultExtractDirFor('${root.path}${sep}yedek.zip'),
          '${root.path}${sep}yedek');
      expect(ArchiveService.defaultExtractDirFor('${root.path}${sep}yedek.tar.gz'),
          '${root.path}${sep}yedek');
      expect(ArchiveService.defaultExtractDirFor('${root.path}${sep}yedek.tgz'),
          '${root.path}${sep}yedek');
    });
  });
}
