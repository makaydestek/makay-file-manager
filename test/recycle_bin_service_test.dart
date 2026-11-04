import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/models/file_entry.dart';
import 'package:makay_file_manager/services/file_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:makay_file_manager/services/recycle_bin_service.dart';

/// Test için geçici uygulama destek dizini.
class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.supportPath);
  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getTemporaryPath() async => supportPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => supportPath;
}

void main() {
  late Directory temp;
  late Directory support;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('makay_recycle_');
    support = Directory('${temp.path}${Platform.pathSeparator}support')
      ..createSync();
    PathProviderPlatform.instance = _FakePathProvider(support.path);
    // Singleton bellek durumu testler arası sızmasın.
    await RecycleBinService.instance.load();
    await RecycleBinService.instance.empty();
  });

  tearDown(() async {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('moveToRecycle kaynağı kaldırır ve kutuya koyar', () async {
    final file = File('${temp.path}${Platform.pathSeparator}silinecek.txt')
      ..writeAsStringSync('merhaba');
    final entry = FileEntry(
      name: 'silinecek.txt',
      path: file.path,
      isDirectory: false,
      size: 7,
      modified: DateTime.now(),
    );

    await RecycleBinService.instance.moveToRecycle(entry);

    expect(file.existsSync(), isFalse, reason: 'kaynak silinmeli');
    expect(RecycleBinService.instance.items, hasLength(1));
    expect(RecycleBinService.instance.items.first.name, 'silinecek.txt');
  });

  test('moveToRecycle yoksa hata fırlatır (sessiz başarı yok)', () async {
    final entry = FileEntry(
      name: 'yok.txt',
      path: '${temp.path}${Platform.pathSeparator}yok.txt',
      isDirectory: false,
      size: 0,
      modified: DateTime.now(),
    );
    expect(
      () => RecycleBinService.instance.moveToRecycle(entry),
      throwsA(isA<FileSystemException>()),
    );
  });

  test('FileService.movePath kaynak dosyayı hedefe taşır', () async {
    final src = File('${temp.path}${Platform.pathSeparator}a.txt')
      ..writeAsStringSync('x');
    final destDir = Directory('${temp.path}${Platform.pathSeparator}hedef')
      ..createSync();
    await const FileService().movePath(src.path, destDir.path, name: 'b.txt');
    expect(src.existsSync(), isFalse);
    expect(File('${destDir.path}${Platform.pathSeparator}b.txt').existsSync(),
        isTrue);
  });
}
