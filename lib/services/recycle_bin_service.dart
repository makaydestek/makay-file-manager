import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/file_entry.dart';
import 'category_size_service.dart';
import 'file_service.dart';

/// Geri dönüşüm kutusu öğesi (manifest kaydı).
class RecycleItem {
  RecycleItem({
    required this.storedName,
    required this.originalPath,
    required this.name,
    required this.size,
    required this.isDirectory,
    required this.deletedAt,
  });

  final String storedName;
  final String originalPath;
  final String name;
  final int size;
  final bool isDirectory;
  final DateTime deletedAt;

  Map<String, dynamic> toJson() => {
        'storedName': storedName,
        'originalPath': originalPath,
        'name': name,
        'size': size,
        'isDirectory': isDirectory,
        'deletedAt': deletedAt.toIso8601String(),
      };

  factory RecycleItem.fromJson(Map<String, dynamic> json) => RecycleItem(
        storedName: json['storedName'] as String,
        originalPath: json['originalPath'] as String,
        name: json['name'] as String,
        size: (json['size'] as num?)?.toInt() ?? 0,
        isDirectory: json['isDirectory'] as bool? ?? false,
        deletedAt: DateTime.parse(json['deletedAt'] as String),
      );
}

/// Uygulama veri dizininde tutulan geri dönüşüm kutusu.
class RecycleBinService {
  RecycleBinService._();

  static final RecycleBinService instance = RecycleBinService._();

  List<RecycleItem> _items = [];
  List<RecycleItem> get items => List.unmodifiable(_items);

  bool _loaded = false;

  Future<Directory> _binDir() async {
    final base = await getApplicationSupportDirectory();
    final dir =
        Directory('${base.path}${Platform.pathSeparator}recycle_bin');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  Future<File> _manifest() async {
    final dir = await _binDir();
    return File('${dir.path}${Platform.pathSeparator}manifest.json');
  }

  Future<void> load() async {
    try {
      final file = await _manifest();
      if (!await file.exists()) {
        _items = [];
        _loaded = true;
        return;
      }
      final data = jsonDecode(await file.readAsString()) as List<dynamic>;
      _items = data
          .map((e) => RecycleItem.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      _items = [];
    }
    _loaded = true;
  }

  /// Manifest bellekte yoksa diskten okur (tarayıcıdan silmede ezilmesin).
  Future<void> _ensureLoaded() async {
    if (!_loaded) await load();
  }

  Future<void> _save() async {
    final file = await _manifest();
    await file.writeAsString(
        jsonEncode(_items.map((e) => e.toJson()).toList()));
  }

  /// Dosyayı/klasörü geri dönüşüm kutusuna taşır.
  ///
  /// Android'de İndirilenler (`/storage/emulated/0/Download`) ile uygulama
  /// destek dizini farklı birimdedir; düz `rename` EXDEV ile başarısız olur.
  /// Bu yüzden [FileService.movePath] kullanılır: aynı birimde rename, farklı
  /// birimde kopyala + kaynak sil.
  ///
  /// Taşınamazsa [FileSystemException] fırlatır — çağıran "başarılı" göstermez.
  Future<void> moveToRecycle(FileEntry entry) async {
    await _ensureLoaded();

    // Dizin için [FileEntry.size] bir içerik boyutu DEĞİLDİR: `stat.size`
    // dizinlerde inode boyutudur (0 ya da 4096 B). Kutudaki ve çekmecedeki
    // "Toplam"ın doğru olması için içerik toplamı taşınmadan önce hesaplanır.
    var size = entry.size;
    if (entry.isDirectory) {
      try {
        size = await const FileService().directorySize(entry.path);
      } catch (_) {
        size = 0;
      }
    }

    final sourceExists = entry.isDirectory
        ? await Directory(entry.path).exists()
        : await File(entry.path).exists();
    if (!sourceExists) {
      throw FileSystemException('Dosya bulunamadı', entry.path);
    }

    final bin = await _binDir();
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final storedName = '${stamp}__${entry.name}';
    final destPath = '${bin.path}${Platform.pathSeparator}$storedName';

    final result = await const FileService().movePath(
      entry.path,
      bin.path,
      name: storedName,
    );

    // Kopyalandı ama kaynak silinemedi → kutuda kopya + orijinal duruyor.
    // Kullanıcıya "taşındı" dememek için kopyayı temizleyip hata veririz.
    if (result.warning != null && result.warning!.isNotEmpty) {
      await _deleteQuietly(destPath);
      throw FileSystemException(
        'Kutuya taşınamadı (kaynak silinemedi)',
        entry.path,
      );
    }

    final stillThere = entry.isDirectory
        ? await Directory(entry.path).exists()
        : await File(entry.path).exists();
    if (stillThere) {
      await _deleteQuietly(destPath);
      throw FileSystemException(
        'Kutuya taşınamadı (kaynak hâlâ mevcut)',
        entry.path,
      );
    }

    final destOk = await File(destPath).exists() ||
        await Directory(destPath).exists();
    if (!destOk) {
      throw FileSystemException(
        'Kutuya taşınamadı (hedef oluşmadı)',
        entry.path,
      );
    }

    _items.insert(
      0,
      RecycleItem(
        storedName: storedName,
        originalPath: entry.path,
        name: entry.name,
        size: size,
        isDirectory: entry.isDirectory,
        deletedAt: DateTime.now(),
      ),
    );
    await _save();
    await CategorySizeService.invalidate();
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final asDir = Directory(path);
      if (await asDir.exists()) {
        await asDir.delete(recursive: true);
        return;
      }
      final asFile = File(path);
      if (await asFile.exists()) await asFile.delete();
    } catch (_) {}
  }

  /// Kutudan geri yükler: özgün konumuna döner.
  Future<void> restore(RecycleItem item) async {
    await _ensureLoaded();
    final bin = await _binDir();
    final stored = File('${bin.path}${Platform.pathSeparator}${item.storedName}');
    final storedDir = Directory(stored.path);
    final source = await stored.exists()
        ? stored
        : (await storedDir.exists() ? storedDir : null);
    if (source == null) {
      _items.removeWhere((e) => e.storedName == item.storedName);
      await _save();
      return;
    }
    final target = item.originalPath;
    final parent = Directory(target).parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    var name = target.split(Platform.pathSeparator).last;
    // Ad çakışmasında üzerine yazmak yerine "geri_" öneki.
    final clash = await File(target).exists() ||
        await Directory(target).exists();
    if (clash) name = 'geri_$name';
    // İndirilenler ↔ uygulama dizini farklı birim: movePath kopyala+sil yapar.
    await const FileService().movePath(
      source.path,
      parent.path,
      name: name,
    );
    _items.removeWhere((e) => e.storedName == item.storedName);
    await _save();
    await CategorySizeService.invalidate();
  }

  Future<void> deletePermanently(RecycleItem item) async {
    await _ensureLoaded();
    final bin = await _binDir();
    final path = '${bin.path}${Platform.pathSeparator}${item.storedName}';
    final asDir = Directory(path);
    if (await asDir.exists()) {
      await asDir.delete(recursive: true);
    } else {
      final asFile = File(path);
      if (await asFile.exists()) await asFile.delete();
    }
    _items.removeWhere((e) => e.storedName == item.storedName);
    await _save();
    await CategorySizeService.invalidate();
  }

  Future<void> empty() async {
    await _ensureLoaded();
    final bin = await _binDir();
    await for (final entity in bin.list(followLinks: false)) {
      final name = entity.uri.pathSegments.isEmpty
          ? ''
          : entity.uri.pathSegments[entity.uri.pathSegments.length - 1];
      if (name == 'manifest.json') continue;
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else {
          await entity.delete();
        }
      } catch (_) {
        // Öge kilitli ya da az önce silinmiş olabilir; kutu yine de
        // boşaltılır ve listesi güncellenir, tekil ögeyi bozmaz.
      }
    }
    _items.clear();
    await _save();
    await CategorySizeService.invalidate();
  }

  /// Kutudaki toplam boyut.
  int get totalSize => _items.fold(0, (sum, i) => sum + i.size);
}
