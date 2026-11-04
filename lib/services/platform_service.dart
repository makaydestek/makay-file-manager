import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Yüklü bir uygulama (Uygulamalar ekranı için).
///
/// **İkon listede taşınmaz**: ikon üretimi bitmap rasterleştirme + PNG
/// sıkıştırmadır ve yüzlerce pakette onlarca saniye sürerdi (Android ana iş
/// parçacığında ANR'a yol açıyordu). İkon [PlatformService.appIcon] ile tek
/// tek, satır görünür olduğunda istenir.
class InstalledApp {
  const InstalledApp({
    required this.name,
    required this.packageName,
    required this.versionName,
    required this.isSystem,
    required this.size,
    required this.sourceDir,
  });

  final String name;
  final String packageName;
  final String versionName;
  final bool isSystem;

  /// Boyut bayt; alınamazsa -1.
  final int size;

  /// Kurulum APK'sının yolu (yedekleme için); alınamazsa boş.
  final String sourceDir;

  factory InstalledApp.fromMap(Map<Object?, Object?> map) => InstalledApp(
        name: (map['name'] as String?) ?? '?',
        packageName: (map['packageName'] as String?) ?? '',
        versionName: (map['versionName'] as String?) ?? '',
        isSystem: (map['isSystem'] as bool?) ?? false,
        size: (map['size'] as num?)?.toInt() ?? -1,
        sourceDir: (map['sourceDir'] as String?) ?? '',
      );
}

/// Bir APK dosyasının paket bilgileri (İndirilenler → Kur/Güncelle).
class ApkInfo {
  const ApkInfo({
    required this.name,
    required this.packageName,
    required this.versionName,
    required this.versionCode,
    required this.installed,
    required this.installedVersionName,
    required this.installedVersionCode,
    required this.size,
  });

  /// Uygulama adı (paket arşivinden okunamazsa paket adı).
  final String name;
  final String packageName;
  final String versionName;

  /// APK'nın sürüm numarası (kurulum diyaloğu başlığı için).
  final int versionCode;

  /// Aynı paket cihazda kurulu mu (→ "Güncelle" mi "Kur" mu?).
  final bool installed;
  final String installedVersionName;
  final int installedVersionCode;

  /// APK dosyasının boyutu (bayt).
  final int size;

  /// Aynı sürüm zaten kurulu mu? (Güncelleme yerine "zaten güncel" uyarısı)
  bool get sameVersion =>
      installed && installedVersionCode >= 0 && installedVersionCode == versionCode;

  factory ApkInfo.fromMap(Map<Object?, Object?> map) => ApkInfo(
        name: (map['name'] as String?) ?? '',
        packageName: (map['packageName'] as String?) ?? '',
        versionName: (map['versionName'] as String?) ?? '',
        versionCode: (map['versionCode'] as num?)?.toInt() ?? -1,
        installed: (map['installed'] as bool?) ?? false,
        installedVersionName: (map['installedVersionName'] as String?) ?? '',
        installedVersionCode: (map['installedVersionCode'] as num?)?.toInt() ?? -1,
        size: (map['size'] as num?)?.toInt() ?? -1,
      );
}

/// Bağlı depolama birimi (USB OTG / SD kart).
class StorageVolumeInfo {
  StorageVolumeInfo({
    required this.description,
    required this.isRemovable,
    required this.isEmulated,
    required this.path,
    required this.isMounted,
    this.state = '',
  });

  final String description;
  final bool isRemovable;

  /// Dahili (emüle edilmiş) birim mi — harici listesinden çıkarılır.
  final bool isEmulated;

  /// Erişim yolu; alınamazsa boş (ör. Android 11+ kısıtları).
  final String path;

  /// Birim "mounted" durumunda mı (kullanılabilir).
  final bool isMounted;

  /// Ham durum metni (ör. "mounted", "ejected").
  final String state;

  factory StorageVolumeInfo.fromMap(Map<Object?, Object?> map) =>
      StorageVolumeInfo(
        description: (map['description'] as String?) ?? '',
        isRemovable: (map['isRemovable'] as bool?) ?? false,
        isEmulated: (map['isEmulated'] as bool?) ?? false,
        path: (map['path'] as String?) ?? '',
        isMounted: (map['state'] as String?) == 'mounted',
        state: (map['state'] as String?) ?? '',
      );
}

/// Sistem "Paylaş" menüsünden alınan bir dosya (önbellek kopyası).
class SharedInboxFile {
  const SharedInboxFile({
    required this.path,
    required this.name,
    required this.mime,
    required this.size,
  });

  final String path;
  final String name;
  final String mime;
  final int size;

  factory SharedInboxFile.fromMap(Map<Object?, Object?> map) => SharedInboxFile(
        path: (map['path'] as String?) ?? '',
        name: (map['name'] as String?) ?? '',
        mime: (map['mime'] as String?) ?? '*/*',
        size: (map['size'] as num?)?.toInt() ?? 0,
      );
}

/// Android platform kanalı sarmalayıcısı (StatFs, uygulama listesi).
class PlatformService {
  const PlatformService._();

  static const MethodChannel _channel =
      MethodChannel('com.makay.filemanager/platform');

  /// Kanalın çalıştığı platform (şimdilik yalnızca Android).
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// Canlı paylaşım dinleyicisi (uygulama açıkken yeni SEND intent).
  static void Function(List<SharedInboxFile> files)? onSharedFiles;

  static bool _sharedHandlerBound = false;

  /// Native → Dart `onSharedFiles` çağrılarını bir kez bağlar.
  static void ensureSharedFilesHandler() {
    if (!supported || _sharedHandlerBound) return;
    _sharedHandlerBound = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'onSharedFiles') return null;
      final raw = call.arguments;
      if (raw is! List) return null;
      final files = <SharedInboxFile>[
        for (final item in raw)
          if (item is Map) SharedInboxFile.fromMap(item),
      ];
      if (files.isEmpty) return null;
      onSharedFiles?.call(files);
      return null;
    });
  }

  /// Depolama bilgisi: toplam ve boş bayt.
  static Future<({int total, int free})?> storageInfo() async {
    if (!supported) return null;
    try {
      final map = await _channel.invokeMapMethod<String, dynamic>(
          'getStorageInfo');
      if (map == null) return null;
      return (
        total: (map['total'] as num?)?.toInt() ?? 0,
        free: (map['free'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Yüklü uygulamaların listesi (ikonlar hariç — bkz. [appIcon]).
  static Future<List<InstalledApp>> installedApps() async {
    if (!supported) return const [];
    try {
      final list =
          await _channel.invokeListMethod<Map<Object?, Object?>>(
              'getInstalledApps');
      return (list ?? const [])
          .map(InstalledApp.fromMap)
          .toList(growable: false);
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// Tek bir uygulamanın PNG ikonu (tembel yükleme).
  ///
  /// Sonuçlar [iconCache] içinde tutulur: liste kaydırılırken aynı uygulama
  /// için ikinci kez platform çağrısı yapılmaz.
  static final Map<String, Uint8List?> _iconCache = {};

  static Uint8List? cachedIcon(String packageName) =>
      _iconCache[packageName];

  static Future<Uint8List?> appIcon(String packageName) async {
    if (!supported || packageName.isEmpty) return null;
    if (_iconCache.containsKey(packageName)) return _iconCache[packageName];
    Uint8List? bytes;
    try {
      bytes = await _channel
          .invokeMethod<Uint8List>('getAppIcon', {'packageName': packageName});
    } on PlatformException {
      bytes = null;
    } on MissingPluginException {
      bytes = null;
    }
    _iconCache[packageName] = bytes;
    return bytes;
  }

  /// Videonun ilk karesi (JPEG baytları) — liste/ızgara önizlemesi için.
  ///
  /// Sonuçlar [_videoThumbCache] içinde tutulur: aynı video liste
  /// kaydırılırken yeniden çözülmez. Okunamazsa null döner ve arayüz
  /// standart video ikonuna düşer.
  static final Map<String, Uint8List?> _videoThumbCache = {};

  static const int _videoThumbCacheMax = 240;

  static Uint8List? cachedVideoThumbnail(String path) =>
      _videoThumbCache[path];

  static Future<Uint8List?> videoThumbnail(String path) async {
    if (!supported || path.isEmpty) return null;
    if (_videoThumbCache.containsKey(path)) return _videoThumbCache[path];
    Uint8List? bytes;
    try {
      bytes = await _channel
          .invokeMethod<Uint8List>('getVideoThumbnail', {'path': path});
    } on PlatformException {
      bytes = null;
    } on MissingPluginException {
      bytes = null;
    }
    // Sınırlı önbellek: eski (artık görünmeyen) kayıtlar atılır.
    if (_videoThumbCache.length >= _videoThumbCacheMax) {
      _videoThumbCache.remove(_videoThumbCache.keys.first);
    }
    _videoThumbCache[path] = bytes;
    return bytes;
  }

  /// Son bilinen TV algılama sonucu (TvUi / tema için senkron okuma).
  static bool? _isTvCached;

  /// Önbelleğe alınmış TV sonucu; henüz çözülmediyse false.
  static bool get isTvCached => _isTvCached ?? false;

  /// Cihaz Android TV mi? (Leanback desteği var mı)
  static Future<bool> isTv() async {
    if (!supported) {
      _isTvCached = false;
      return false;
    }
    try {
      final v = await _channel.invokeMethod<bool>('isTv') ?? false;
      _isTvCached = v;
      return v;
    } on PlatformException {
      _isTvCached = false;
      return false;
    } on MissingPluginException {
      _isTvCached = false;
      return false;
    }
  }

  /// "Kullanım erişimi" (PACKAGE_USAGE_STATS) izni verildi mi?
  ///
  /// İzin yoksa yalnız kendi paketimizin boyutu okunabilir; Uygulamalar
  /// ekranı kullanıcıyı Ayarlar → Kullanım erişimi'ne yönlendirir.
  static Future<bool> hasUsageAccess() async {
    if (!supported) return false;
    try {
      // Kanal adı Kotlin tarafındaki "hasUsageAccess" ile eşleşmelidir.
      return await _channel.invokeMethod<bool>('hasUsageAccess') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Ayarlar → Kullanım erişimi ekranını açar.
  static Future<bool> openUsageAccessSettings() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openUsageAccessSettings') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Uygulamanın kendi Ayarlar bilgi sayfasını açar.
  ///
  /// Android 13+ "kısıtlı ayarlar": sideload edilmiş uygulamalara özel
  /// erişimler (kullanım erişimi vb.) yalnız bu sayfadaki ⋮ menüsünden
  /// "Kısıtlı ayarlara izin ver" ile açılabilir.
  static Future<bool> openAppSettings() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openAppSettings') ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// APK dosyasının paket bilgileri (kurulum diyaloğu için).
  ///
  /// Dosya bir APK değilse ya da okunamazsa null döner.
  static Future<ApkInfo?> apkInfo(String path) async {
    if (!supported || path.isEmpty) return null;
    try {
      final map = await _channel
          .invokeMapMethod<Object?, Object?>('getApkInfo', {'path': path});
      if (map == null) return null;
      return ApkInfo.fromMap(map);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Android'in "Varsayılan uygulamalar" ayarını açar (A15).
  static Future<bool> openDefaultAppsSettings() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('openDefaultAppsSettings') ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Bağlı depolama birimleri (USB OTG / SD kart / dahili).
  static Future<List<StorageVolumeInfo>> storageVolumes() async {
    if (!supported) return const [];
    try {
      final list = await _channel.invokeListMethod<Map<Object?, Object?>>(
          'getStorageVolumes');
      return (list ?? const [])
          .map(StorageVolumeInfo.fromMap)
          .toList(growable: false);
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  /// RAR/7Z arşiv girdilerini listeler (Android native).
  static Future<List<Map<String, dynamic>>> listNativeArchive({
    required String path,
    String? password,
  }) async {
    if (!supported) {
      throw UnsupportedError('RAR/7Z yalnızca Android cihazda açılır');
    }
    final raw = await _channel.invokeMethod<List<dynamic>>(
      'listNativeArchive',
      {'path': path, if (password != null) 'password': password},
    );
    return [
      for (final e in raw ?? const [])
        if (e is Map) Map<String, dynamic>.from(e),
    ];
  }

  /// RAR/7Z arşivini çıkarır. [entryName] null ise tümü.
  static Future<int> extractNativeArchive({
    required String path,
    required String destDir,
    String? password,
    String? entryName,
  }) async {
    if (!supported) {
      throw UnsupportedError('RAR/7Z yalnızca Android cihazda açılır');
    }
    final n = await _channel.invokeMethod<int>(
      'extractNativeArchive',
      {
        'path': path,
        'destDir': destDir,
        if (password != null) 'password': password,
        if (entryName != null) 'entryName': entryName,
      },
    );
    return n ?? 0;
  }

  /// PDF sayfasını Android PdfRenderer ile JPEG'e çevirir.
  ///
  /// Başarısızsa veya eklenti yoksa null döner (Windows testleri etkilenmez).
  static Future<({int pageCount, int page, Uint8List? bytes})?> renderPdfPage({
    required String path,
    int page = 0,
  }) async {
    if (!supported || path.isEmpty) return null;
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'renderPdfPage',
        {'path': path, 'page': page},
      );
      if (raw == null) return null;
      final count = (raw['pageCount'] as num?)?.toInt() ?? 0;
      final idx = (raw['page'] as num?)?.toInt() ?? page;
      final bytes = raw['bytes'];
      return (
        pageCount: count,
        page: idx,
        bytes: bytes is Uint8List
            ? bytes
            : (bytes is List<int> ? Uint8List.fromList(bytes) : null),
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Dosyayı veya içerik URI'sini sistem "Farklı aç" seçicisiyle açar.
  ///
  /// [path] yerel dosya yolu; [uri] MediaStore `content://` (veya file://).
  /// En az biri dolu olmalıdır. Medya oynatıcı codec uyumsuzluğunda yedek
  /// olarak bunu kullanır.
  static Future<bool> openWith({String? path, String? uri}) async {
    if (!supported) return false;
    final p = path?.trim() ?? '';
    final u = uri?.trim() ?? '';
    if (p.isEmpty && u.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('openWith', {
            if (p.isNotEmpty) 'path': p,
            if (u.isNotEmpty) 'uri': u,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Klasörü ana ekrana sabit kısayol olarak eklemeyi ister.
  static Future<bool> pinShortcut({
    required String path,
    required String label,
  }) async {
    if (!supported || path.isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('pinShortcut', {
            'path': path,
            'label': label,
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Kısayoldan gelen gezinme yolunu bir kez okur (sonra temizlenir).
  static Future<String?> takeLaunchBrowsePath() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('takeLaunchBrowsePath');
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Sistem paylaşımından gelen dosyaları bir kez okur (sonra temizlenir).
  static Future<List<SharedInboxFile>?> takeSharedFiles() async {
    if (!supported) return null;
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('takeSharedFiles');
      if (raw == null || raw.isEmpty) return null;
      return [
        for (final item in raw)
          if (item is Map) SharedInboxFile.fromMap(item),
      ];
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
