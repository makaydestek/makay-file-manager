import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/remote_service.dart';
import 'package:makay_file_manager/services/smb_client.dart';
import 'package:makay_file_manager/services/smb_server.dart';

/// SMB istemcisi ↔ gömülü mini SMB2 sunucusu tam oturum testi:
/// negotiate → NTLMv2 oturum kurulumu → tree connect → liste → indirme.
void main() {
  late Directory root;
  late MiniSmbServer server;
  const port = 14445;

  setUp(() {
    root = Directory.systemTemp.createTempSync('smb_client_root');
    File('${root.path}${Platform.pathSeparator}merhaba.txt')
        .writeAsStringSync('merhaba dünya');
    Directory('${root.path}${Platform.pathSeparator}klasor').createSync();
    File('${root.path}${Platform.pathSeparator}klasor'
            '${Platform.pathSeparator}ic.txt')
        .writeAsStringSync('içerik 123');
  });

  tearDown(() async {
    await server.stop();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  RemoteLocation loc() => RemoteLocation(
        name: 'test',
        host: '127.0.0.1',
        type: 'smb',
        port: port,
        username: 'kullanici',
        password: 'sifre',
        share: 'makay',
      );

  test('kotu baglanti parametreleri hata firlatir', () async {
    server = MiniSmbServer(
      rootPath: root.path,
      port: port,
      username: 'kullanici',
      password: 'sifre',
    );
    await server.start();
    final bad = loc();
    final client = await SmbClient.connect(bad);
    // Var olmayan dosya indirme → hata.
    await expectLater(
      client.download('yok.txt',
          File('${Directory.systemTemp.path}${Platform.pathSeparator}yok.bin')),
      throwsA(isA<SmbException>()),
    );
    await client.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('tam oturum: liste + alt dizin + indirme', () async {
    server = MiniSmbServer(
      rootPath: root.path,
      port: port,
      username: 'kullanici',
      password: 'sifre',
    );
    await server.start();

    final client = await SmbClient.connect(loc());

    // Kök liste: dosya + klasör.
    final entries = await client.list('');
    final names = entries.map((e) => e.name).toList();
    expect(names, containsAll(['merhaba.txt', 'klasor']));
    final klasor = entries.firstWhere((e) => e.name == 'klasor');
    expect(klasor.isDir, isTrue);
    final merhaba = entries.firstWhere((e) => e.name == 'merhaba.txt');
    expect(merhaba.isDir, isFalse);
    expect(merhaba.size, utf8.encode('merhaba dünya').length);
    expect(merhaba.modified, isNotNull);

    // Alt dizin gezinme ('/' ve '\' yolları eşdeğer).
    final sub = await client.list('klasor');
    expect(sub.map((e) => e.name), contains('ic.txt'));
    final sub2 = await client.list(r'\klasor\');
    expect(sub2.map((e) => e.name), contains('ic.txt'));

    // Kök liste tekrar (imleç yeniden başlatılıyor).
    final again = await client.list('/');
    expect(again.length, entries.length);

    // İndirme.
    final target = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}indirilen.txt');
    await client.download('merhaba.txt', target);
    expect(target.readAsStringSync(), 'merhaba dünya');

    // Alt dizindeki dosyayı da indir.
    final target2 = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}indirilen2.txt');
    await client.download('klasor/ic.txt', target2);
    expect(target2.readAsStringSync(), 'içerik 123');

    await client.close();
    target.deleteSync();
    target2.deleteSync();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('var olmayan klasor listelenemez', () async {
    server = MiniSmbServer(
      rootPath: root.path,
      port: port,
      username: 'kullanici',
      password: 'sifre',
    );
    await server.start();
    final client = await SmbClient.connect(loc());
    await expectLater(
      client.list('boyle-bir-klasor'),
      throwsA(isA<SmbException>()),
    );
    await client.close();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('yazma: mkdir + upload + rename + delete', () async {
    server = MiniSmbServer(
      rootPath: root.path,
      port: port,
      username: 'kullanici',
      password: 'sifre',
    );
    await server.start();
    final client = await SmbClient.connect(loc());

    await client.mkdir('yeni');
    final listed = await client.list('');
    expect(listed.map((e) => e.name), contains('yeni'));

    final local = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}smb_up.txt')
      ..writeAsStringSync('yuklenen veri');
    await client.upload(r'yeni\dosya.txt', local);

    final sub = await client.list('yeni');
    expect(sub.map((e) => e.name), contains('dosya.txt'));
    final down = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}smb_down.txt');
    await client.download(r'yeni\dosya.txt', down);
    expect(down.readAsStringSync(), 'yuklenen veri');

    await client.rename(r'yeni\dosya.txt', r'yeni\yeniad.txt');
    final renamed = await client.list('yeni');
    expect(renamed.map((e) => e.name), contains('yeniad.txt'));
    expect(renamed.map((e) => e.name), isNot(contains('dosya.txt')));

    await client.delete(r'yeni\yeniad.txt', isDir: false);
    await client.delete('yeni', isDir: true);
    final after = await client.list('');
    expect(after.map((e) => e.name), isNot(contains('yeni')));

    await client.close();
    local.deleteSync();
    down.deleteSync();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
