import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/remote_download.dart';

/// Uzak (FTP/SFTP/SMB/WebDAV) indirme ortak akışı:
///  - APK adı algılama (kurulum diyaloğu tetikleyicisi),
///  - ad çakışması çözümü (önceki indirmeler silinmeden korunur),
///  - hedef klasör her zaman var olmalı (indirme yazılabilsin).
void main() {
  test('isApk uzantıyı büyük/küçük harf duyarsız yakalar', () {
    expect(RemoteDownload.isApk('uygulama.apk'), isTrue);
    expect(RemoteDownload.isApk('UYGULAMA.APK'), isTrue);
    expect(RemoteDownload.isApk('resim.png'), isFalse);
    expect(RemoteDownload.isApk('arsiv.apk.zip'), isFalse);
    expect(RemoteDownload.isApk('apksiz'), isFalse);
  });

  test('targetDir yazılabilir bir dizin döndürür', () {
    final dir = RemoteDownload.targetDir();
    expect(dir.existsSync(), isTrue);
    // Dizinde dosya oluşturup silebiliyoruz (izin tamam).
    final probe = File(
        '${dir.path}${Platform.pathSeparator}makay_probe_${DateTime.now().microsecondsSinceEpoch}');
    probe.writeAsStringSync('x');
    expect(probe.existsSync(), isTrue);
    probe.deleteSync();
  });

  test('uniqueTarget aynı adlı mevcut dosyayı ezmez, numaralandırır', () {
    final dir = Directory.systemTemp.createTempSync('remote_dl_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    // İlk indirme: ad olduğu gibi kullanılır.
    final first = RemoteDownload.uniqueTarget(dir, 'notlar.txt');
    expect(first.path.endsWith('notlar.txt'), isTrue);
    first.writeAsStringSync('birinci');

    // İkincisi: "notlar (2).txt" — önceki dosya korunur.
    final second = RemoteDownload.uniqueTarget(dir, 'notlar.txt');
    expect(second.path.endsWith('notlar (2).txt'), isTrue);
    second.writeAsStringSync('ikinci');

    // Üçüncüsü: "notlar (3).txt".
    final third = RemoteDownload.uniqueTarget(dir, 'notlar.txt');
    expect(third.path.endsWith('notlar (3).txt'), isTrue);

    // Ezme yok: ilk dosyanın içeriği değişmedi.
    expect(first.readAsStringSync(), 'birinci');
    expect(second.readAsStringSync(), 'ikinci');
  });

  test('uniqueTarget uzantısız dosyada da adı korur', () {
    final dir = Directory.systemTemp.createTempSync('remote_dl2_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    RemoteDownload.uniqueTarget(dir, 'LICENSE').writeAsStringSync('a');
    final next = RemoteDownload.uniqueTarget(dir, 'LICENSE');
    expect(next.path.endsWith('LICENSE (2)'), isTrue);
  });

  test('uzak sunucudan gelen ad hedef klasör dışına çıkamaz', () {
    final dir = Directory.systemTemp.createTempSync('remote_dl3_');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    for (final evil in [
      '../../evil.apk',
      r'..\..\evil.apk',
      '/etc/passwd',
      r'C:\Windows\evil.dll',
      '..',
      '.',
    ]) {
      final target = RemoteDownload.uniqueTarget(dir, evil);
      expect(target.parent.path, dir.path,
          reason: '$evil hedef dizin içinde kalmalı');
      expect(target.path.contains('..'), isFalse, reason: evil);
    }
  });

  test('sanitizeFileName yol ayırıcı ve kontrol karakterlerini temizler', () {
    expect(RemoteDownload.sanitizeFileName('a/b/c.txt'), 'c.txt');
    expect(RemoteDownload.sanitizeFileName(r'a\b\c.txt'), 'c.txt');
    expect(RemoteDownload.sanitizeFileName('a:b?.txt'), 'a_b_.txt');
    expect(RemoteDownload.sanitizeFileName('  '), isNotEmpty);
  });
}
