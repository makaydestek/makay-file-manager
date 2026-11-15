import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/update_service.dart';

void main() {
  group('UpdateService.verifySha256', () {
    late Directory dir;
    late File file;
    late String digestHex;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('update_sha_');
      file = File('${dir.path}/sample.bin');
      await file.writeAsBytes([1, 2, 3, 4, 5]);
      digestHex = (await sha256.bind(file.openRead()).first).toString();
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    test('eşleşen özet true döner', () async {
      expect(await UpdateService.verifySha256(file, digestHex), isTrue);
    });

    test('boş özet false döner (zorunlu SHA)', () async {
      expect(await UpdateService.verifySha256(file, ''), isFalse);
      expect(await UpdateService.verifySha256(file, '   '), isFalse);
    });

    test('geçersiz biçim false döner', () async {
      expect(await UpdateService.verifySha256(file, 'abcd'), isFalse);
      expect(await UpdateService.verifySha256(file, 'g' * 64), isFalse);
    });

    test('yanlış özet false döner', () async {
      expect(await UpdateService.verifySha256(file, '0' * 64), isFalse);
    });

    test('olmayan dosya false döner', () async {
      final missing = File('${dir.path}/yok.bin');
      expect(await UpdateService.verifySha256(missing, digestHex), isFalse);
    });
  });

  group('UpdateService.isNewerVersion', () {
    test('patch artışı yeni sayılır', () {
      expect(UpdateService.isNewerVersion('1.0.32', '1.0.31'), isTrue);
      expect(UpdateService.isNewerVersion('1.0.31', '1.0.31'), isFalse);
      expect(UpdateService.isNewerVersion('1.0.30', '1.0.31'), isFalse);
    });
  });

  group('UpdateService.tagFromLocation', () {
    test('releases/latest yönlendirmesinden etiket çıkarır', () {
      expect(
        UpdateService.tagFromLocation(
          'https://github.com/makaydestek/makay-file-manager/releases/tag/1.0.54',
        ),
        '1.0.54',
      );
      expect(
        UpdateService.tagFromLocation(
          '/makaydestek/makay-file-manager/releases/tag/v1.0.55',
        ),
        '1.0.55',
      );
      expect(UpdateService.stripV('v2.1.0'), '2.1.0');
    });
  });

  group('UpdateService.parseLatestTagFromAtom', () {
    test('alternate link ve id etiketinden sürüm çıkarır', () {
      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry>
    <id>tag:github.com,2008:Repository/1/1.0.55</id>
    <link rel="alternate" type="text/html"
      href="https://github.com/makaydestek/makay-file-manager/releases/tag/1.0.55"/>
    <title>1.0.55</title>
  </entry>
</feed>
''';
      expect(UpdateService.parseLatestTagFromAtom(xml), '1.0.55');
    });

    test('v önekini atar', () {
      const xml = '''
<entry>
  <link href="https://github.com/o/r/releases/tag/v2.3.4" rel="alternate"/>
</entry>
''';
      expect(UpdateService.parseLatestTagFromAtom(xml), '2.3.4');
    });
  });
}