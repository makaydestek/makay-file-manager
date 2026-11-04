import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/debug_log.dart';
import '../utils/formats.dart';
import '../utils/nomedia.dart';
import 'platform_service.dart';
import 'recent_seen_store.dart';
import 'remote_service.dart';
import 'webdav_service.dart';

/// Ana ekran kategori başlıklarının altına gösterilecek özet metinler.
///
/// Tüm tarama işi izolatta (arka plan) yürütülür; sonuç önbelleğe alınır.
/// Ekran ilk açıldığında önbellekteki değer anında gösterilir, taze hesap
/// tamamlanınca başlıklar sessizce güncellenir.
///
/// **Tazelik garantileri** (saha şikâyetleri: kart ile ekran hiç uyuşmuyordu):
///
/// 1. Kart değeri, ilgili **ekranın gösterdiği dosyalarla** hesaplanır:
///    İndirilenler → Download klasörü, Belgeler → Documents klasörü
///    (uzantı sınıflandırması değil), Yeni Dosyalar → seen filtresi.
/// 2. Ana ekranın build'i geri dönünçe yeniden çalışmadığı için tazelik
///    yalnızca build'e bağlanmaz: rota geri alındığında (`main.dart`
///    navigator gözlemcisi), uygulama ön plana döndüğünde ve her
///    [invalidate] çağrısında yenileme tetiklenir.
/// 3. Başarısız tarama **önbelleğe yazılmaz** (bayat değer "taze" diye
///    damgalanıp 10 dakika boyunca ekranda kalmaz); kısa bir beklemeyle
///    yeniden denenir.
/// 4. İzolat zaman aşımına uğrursa [refresh] takılı kalmaz — aksi hâlde
///    `_running` sonsuza dek true kalır ve hiçbir yenileme çalışmadan
///    uygulama yeniden başlatılana kadar donmuş kartlar gösterilirdi.
class CategorySizeService {
  CategorySizeService._();

  static const _cacheKey = 'category_sizes_cache';

  /// Önbelleğin taze sayıldığı süre; dolarsa yeniden hesaplanır.
  ///
  /// Dosya işlemleri (silme/taşıma/temizlik) [invalidate] ile önbelleği
  /// anında siler; bu süre yalnızca "değişiklik olmayan" durumlarda geçerli
  /// kalan bayatlık payıdır — bu yüzden kısa tutulur.
  /// Dış kaynaklı değişiklikler (başka uygulamanın indirmesi) ayrıca
  /// [refreshOnResume] ile uygulama ön plana döndüğünde yakalanır.
  static const cacheMaxAge = Duration(minutes: 10);

  /// Başarısız taramanın yeniden denenmesi arasındaki bekleme.
  ///
  /// Tarama başarısızsa değerler bayat kalır; her kart gösteriminde tekrar
  /// tekrar ağır tarama çalıştırmamak için kısa bir geri çekilme uygulanır.
  /// "Yenile" (force) bu beklemeyi aşar.
  static const failureBackoff = Duration(seconds: 30);

  /// İzolat taraması için azami bekleme.
  ///
  /// Süre dolarsa izolat öldürülür ve tarama başarısız sayılır; [refresh]
  /// asla bu süreden fazla `_running` durumunda kalmaz.
  static const isolateTimeout = Duration(seconds: 90);

  /// Uygulama ön plana döndüğünde taramanın en az ne kadar önce yapılmış
  /// olması gerektiği (hızlı uygulama geçişlerinde gereksiz tarama yok).
  ///
  /// İndirme/silme sonrası ana sayfa kartlarının F Dosya Yöneticisi kadar
  /// canlı kalması için kısa tutulur; 60 sn bayatlık bırakırdı.
  static const resumeMinInterval = Duration(seconds: 8);

  /// Kategori kimliği → başlık altı metin (ör. "1,5 GB", "3 hesap").
  static final ValueNotifier<Map<String, String>> labels =
      ValueNotifier(const {});

  static bool _running = false;

  /// Bir hesaplama sürerken gelen zorunlu istek (bkz. [refresh]).
  static bool _pendingForce = false;

  /// [invalidate] sayaç: devam eden taramanın dünyası değişmişse sonucu
  /// bayat saymak için kullanılır.
  static int _generation = 0;

  static DateTime? _lastSuccessAt;
  static DateTime? _lastFailureAt;

  /// Klasör taramasının ürettiği anahtarlar. Bu platformda tarama
  /// yapılmazsa (masaüstü) ya da tarama başarısız olursa bu
  /// anahtarların eski değerleri korunur.
  static const _folderKeys = <String>{
    'downloads',
    'documents',
    'images',
    'videos',
    'audio',
    'recent',
  };

  /// Tarama sürüyor mu (test/uyarı amaçlı).
  static bool get running => _running;

  /// Önbelleği geçersiz kılar: bir sonraki [refresh] bayatlık payına
  /// bakılmaksızın yeniden hesaplar.
  ///
  /// **Dosya değiştiren her işlem sonrası çağrılır** (silme, taşıma,
  /// kopyalama, temizleme). Yoksa ana ekran kartları 10 dakika boyunca
  /// silinmiş bir dosyanın boyutunu göstermeye devam ederdi.
  ///
  /// Artık yalnız önbelleği silmekle kalmaz, kendiliğinden bir zorunlu
  /// yenileme de tetikler: kartların tazelenmesi ana ekranın build'ine (ki
  /// geri dönünçe yeniden çalışmaz) bağlı olmamalıdır. `force` sayesinde
  /// daha önce başarısız bir taramanın geri çekilme (backoff) beklemesi de
  /// aşılır — işlem sonrası kart bayat kalmaz.
  static Future<void> invalidate() async {
    _generation++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_cacheKey);
    } catch (e) {
      // Önbellek silinemezse bayat değer bir sonraki açılışta tazelenir.
      logSwallowed('kategori boyutu: önbellek silme', e);
    }
    unawaited(refresh(force: true));
  }

  /// Kategori özetlerini yükler; [force] ile önbellek atlanır.
  ///
  /// Hesaplama sürerken gelen zorunlu istek **yutulmaz**: bir sonraki
  /// hesap bitiminde yeniden çalıştırılır. Yoksa kullanıcı "Yenile" dese
  /// bile bayat etiket değişmezdi.
  static Future<void> refresh({bool force = false}) async {
    if (_running) {
      if (force) _pendingForce = true;
      return;
    }
    // Son deneme başarısızdıysa kısa bir bekleme: her gösterimde ağır
    // tarama tekrar tekrar çalışmasın (force bu gecikmeyi aşar).
    if (!force &&
        _lastFailureAt != null &&
        DateTime.now().difference(_lastFailureAt!) < failureBackoff) {
      return;
    }
    _running = true;
    try {
      final gen = _generation;
      final cached = await _readCache();
      if (cached != null) {
        labels.value = Map.unmodifiable(cached.$2);
        final fresh =
            DateTime.now().difference(cached.$1) < cacheMaxAge;
        if (fresh && !force) return;
      }
      final result = await _compute();

      // Tarama sırasında dosya işlemi yapıldı (invalidate): sonuç bayattır,
      // etiketlere/önbelleğe yazılmaz; bitiminde yeniden denenir.
      if (gen != _generation) {
        _pendingForce = true;
        return;
      }

      // Alt sistem hatası ya da bu denemede üretilmeyen anahtar
      // (masaüstünde klasör taraması, başarısız tarama) için
      // yalnız o anahtarın eski değeri korunur; kalanı taze
      // sonuçla değişir. Eski değerlerin GENELİ birleştirilmesi
      // bayat anahtarları sonsuza dek yaşatırdı (hesap silinir
      // "2 hesap" kalırdı) — bu yüzden ANAHTAR BAZINDA, yalnızca
      // gerçekten üretilmeyenler devralınır.
      final merged = <String, String>{...result.values};
      final old = labels.value;
      final stale = {...result.keepKeys, ...result.inheritedKeys};
      for (final key in stale) {
        final prev = old[key];
        if (prev != null && !merged.containsKey(key)) merged[key] = prev;
      }
      if (merged.isNotEmpty) labels.value = Map.unmodifiable(merged);

      if (!result.scanOk) {
        // Klasör taraması başarısız: önbelleğe YAZILMAZ — bayat değer
        // "taze" diye damgalanırsa 10 dakika boyunca tekrar denenmezdi.
        _lastFailureAt = DateTime.now();
        return;
      }
      _lastSuccessAt = DateTime.now();
      _lastFailureAt = null;
      if (merged.isNotEmpty) await _writeCache(merged);
    } catch (e) {
      // Boyut hesaplaması ana akışı asla bozmamalı; yutulduğu izlenebilsin.
      logSwallowed('kategori boyutu: yenileme', e);
      _lastFailureAt = DateTime.now();
    } finally {
      _running = false;
      if (_pendingForce) {
        _pendingForce = false;
        await refresh(force: true);
      }
    }
  }

  /// Uygulama ön plana döndüğünde çağrılır (bkz. `main.dart` yaşam
  /// döngüsü gözlemcisi).
  ///
  /// Dosya indirme gibi **dışarıda** yapılan değişiklikler invalidate
  /// edilemez; bunlar ancak uygulamaya geri dönülürken tespit edilebilir.
  /// Son hesaplama çok yeniyse (app'ler arası hızlı geçiş) tarama tekrar
  /// edilmez.
  static Future<void> refreshOnResume() async {
    final last = _lastSuccessAt;
    if (last != null &&
        DateTime.now().difference(last) < resumeMinInterval) {
      // Önbellek zaten taze; yalnız bayatlık payı dolduysa hesaplar.
      return refresh();
    }
    return refresh(force: true);
  }

  // -------------------------------------------------------------------------
  // Hesaplama
  // -------------------------------------------------------------------------

  /// Hesaplama sonucu.
  ///
  /// * [values] — bu denemede üretilebilen etiketler.
  /// * [keepKeys] — alt sistem hatası nedeniyle **eski değeri korunması**
  ///   gereken anahtarlar (ör. izin/geçici kanal hatasında depolama bilgisi).
  /// * [inheritedKeys] — bu denemede **üretilmeyen** anahtarlar
  ///   (bu platformda olmayan alt sistem: masaüstünde klasör
  ///   taraması; ya da başarısız tarama). Eski değerleri korunur:
  ///   boş/kısmi hesap ekranda olan etiketleri silemez.
  /// * [scanOk] — klasör taraması başarılı mı; false ise önbelleğe
  ///   yazılmaz (bkz. [refresh]).
  static Future<
      ({
        Map<String, String> values,
        Set<String> keepKeys,
        Set<String> inheritedKeys,
        bool scanOk,
      })> _compute() async {
    final out = <String, String>{};
    final keep = <String>{};

    // Ana bellek: kullanılan / toplam; Bellek Analizi: kalan boş alan.
    // Her alt sistem AYRI sarılır: birinin hatası klasör boyutlarını da
    // yok etmemeli (eskiden tek exception tüm taramayı çöpe atıyordu).
    try {
      final storage = await PlatformService.storageInfo();
      if (storage != null && storage.total > 0) {
        out['internal'] =
            '${Formats.size(storage.total - storage.free)} / ${Formats.size(storage.total)}';
        out['analysis'] = '${Formats.size(storage.free)} boş';
      } else {
        keep.addAll(const ['internal', 'analysis']);
      }
    } catch (e) {
      logSwallowed('kategori boyutu: depolama bilgisi', e);
      keep.addAll(const ['internal', 'analysis']);
    }

    // Klasör bazlı boyutlar izolatta (arayüz donmadan) hesaplanır.
    // Kapanış gönderilmez; test/sanal alan Zone'larında bu hataya yol açar.
    var scanOk = true;
    final inherited = <String>{..._folderKeys};
    if (Platform.isAndroid) {
      const root = '/storage/emulated/0';
      // "Yeni Dosyalar" boyutu ekrandaki listeyle aynıdır: kullanıcının
      // "Temizle" ile işaretlediği (görülen) dosyalar hariç tutulur. Yoksa
      // kart ile ekran arasındaki değer hiç değişmezdi.
      Set<String> seen;
      try {
        seen = await RecentSeenStore.load();
      } catch (e) {
        logSwallowed('kategori boyutu: görülen dosyalar', e);
        seen = const {};
      }
      final folder = await _scanInIsolate(root, seen);
      if (folder == null) {
        scanOk = false; // bayat kartlar korunur, önbellek yazılmaz
      } else {
        // Tarama tüm klasör anahtarlarını üretti: eskileri devralma
        // yok — 0 B gibi taze sıfırlar da ekrana yazılır.
        inherited.clear();
        // Boyut anahtarları + isteğe bağlı `*_n` adet anahtarları.
        for (final e in folder.entries) {
          if (e.key.endsWith('_n')) continue;
          final count = folder['${e.key}_n'];
          out[e.key] = (count != null && count > 0)
              ? '${Formats.size(e.value)} ($count)'
              : Formats.size(e.value);
        }
      }

      // Uygulamalar: yüklü paket boyutları toplamı + adet (F Dosya
      // Yöneticisi'ndeki gibi "13,9 GB (53)"). Boyut StorageStats ile
      // okunur; izin yoksa platform katmanı base.apk boyutuna düşer.
      try {
        final apps = await PlatformService.installedApps();
        final appsBytes =
            apps.fold<int>(0, (sum, a) => sum + (a.size > 0 ? a.size : 0));
        if (appsBytes > 0 && apps.isNotEmpty) {
          out['apps'] = '${Formats.size(appsBytes)} (${apps.length})';
        } else {
          keep.add('apps'); // bilgi gelmedi: önceki değer korunur
        }
      } catch (e) {
        logSwallowed('kategori boyutu: uygulama boyutları', e);
        keep.add('apps');
      }
    }

    // Bağlantılı hesap sayıları (Bulut / Uzak). Boşsa anahtar YOK sayılır
    // (etiket kaybolur) — hesap silinince eski "2 hesap" etiketi kalmamalı.
    try {
      final clouds = await CloudLocationStore.load();
      if (clouds.isNotEmpty) out['cloud'] = '${clouds.length} hesap';
    } catch (e) {
      logSwallowed('kategori: bulut hesapları', e);
      keep.add('cloud');
    }
    try {
      final remotes = await RemoteLocationStore.load();
      if (remotes.isNotEmpty) out['remote'] = '${remotes.length} bağlantı';
    } catch (e) {
      logSwallowed('kategori: uzak bağlantılar', e);
      keep.add('remote');
    }

    return (values: out, keepKeys: keep, inheritedKeys: inherited, scanOk: scanOk);
  }

  // -------------------------------------------------------------------------
  // İzolat çalıştırma
  // -------------------------------------------------------------------------

  /// Taramayı izolatta çalıştırır.
  ///
  /// Başarısızlık (izolat hatası, zaman aşımı, boş yanıt) durumunda **null**
  /// döner; asla sınırsız beklemez. Eskiden yanıt gelmezse [refresh] içindeki
  /// `port.first` sonsuza dek asılı kalır, `_running` true kalır ve uygulama
  /// yeniden başlatılana kadar hiçbir kart güncellenmezdi.
  ///
  /// Kapanış (closure) göndermek yerine istek nesnesi gönderilir; çünkü test
  /// veya sanal alan gibi özel Zone'larda kapanış "gönderilemez" sayılır.
  static Future<Map<String, int>?> _scanInIsolate(
    String root,
    Set<String> seenRecent,
  ) async {
    final port = ReceivePort();
    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _scanIsolateEntry,
        _SizeScanRequest(
          root: root,
          seenRecent: seenRecent.toList(growable: false),
          reply: port.sendPort,
        ),
      );
      final raw = await port.first.timeout(isolateTimeout);
      // scan() her koşulda 6 anahtar döndürür; boş harita = hata sinyali.
      if (raw is Map<String, int> && raw.isNotEmpty) return raw;
      return null;
    } on TimeoutException catch (e) {
      logSwallowed('kategori boyutu: tarama zaman aşımı', e);
      return null;
    } catch (e) {
      logSwallowed('kategori boyutu: izolat', e);
      return null;
    } finally {
      port.close();
      // Yanıt gelmişse izolat zaten bitmiştir; zaman aşımında ise
      // askıda kalan işi sonlandırır (yanıt gelse de zararsızdır).
      isolate?.kill(priority: Isolate.immediate);
    }
  }

  // -------------------------------------------------------------------------
  // İzolat içi tarama (yalnızca dart:io kullanır — channel/builder yok)
  // -------------------------------------------------------------------------

  /// Taranan klasör kökleri (medya kategorilerinin boyutu buradan gelir).
  ///
  /// Resimler/Videolar/Ses ekranları MediaStore üzerinden **cihazın tamamını**
  /// listelediği için, karttaki boyut da yalnızca tek bir klasörü değil bu
  /// klasörlerin tamamını kapsar. Klasör adı geçen uygulamaların medyası
  /// (WhatsApp, Telegram, Instagram …) böylece kategori toplamına girer.
  ///
  /// **Belgeler ve İndirilenler bu listeden ayrıdır**: bu iki kartın
  /// açtığı ekran klasör tarayıcısıdır (yalnızca Documents / Download),
  /// bu yüzden boyutları da doğrudan o klasörün içeriğinden gelir.
  static const List<String> _scanFolders = [
    'Download',
    'DCIM',
    'Pictures',
    'Screenshots',
    'Camera',
    'Movies',
    'Music',
    'Documents',
    'Recordings',
    'Ringtones',
    'Notifications',
    'Podcasts',
    'Audiobooks',
    'WhatsApp',
    'Telegram',
    'Messenger',
    'Signal',
    'Instagram',
    'Snapchat',
    // Android/media altındaki uygulama medyası (Android 11+ yolu).
    'Android/media',
  ];

  /// Dosya uzantısı → kategori kimliği; bilinmeyen uzantı null.
  ///
  /// Bu sınıflandırma yalnızca **medya kartları** (Resimler/Videolar/Ses)
  /// için kullanılır; kart ekranla aynı dosyaları sayar.
  static String? categoryOfExtension(String ext) {
    switch (ext.toLowerCase()) {
      case 'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'bmp' || 'svg' ||
        'heic' || 'heif' || 'tif' || 'tiff' || 'raw' || 'dng' || 'ico':
        return 'images';
      case 'mp4' || 'mkv' || 'avi' || 'mov' || 'webm' || 'flv' || '3gp' ||
        'm4v' || 'ts' || 'wmv' || 'mpg' || 'mpeg' || 'ogv' || '3g2':
        return 'videos';
      case 'mp3' || 'm4a' || 'aac' || 'flac' || 'ogg' || 'opus' || 'wav' ||
        'wma' || 'amr' || 'mid' || 'mka' || 'ape':
        return 'audio';
      case 'pdf' || 'doc' || 'docx' || 'xls' || 'xlsx' || 'ppt' || 'pptx' ||
        'txt' || 'csv' || 'rtf' || 'odt' || 'ods' || 'odp' || 'md' || 'epub' ||
        'json' || 'xml' || 'html' || 'htm' || 'log':
        return 'documents';
      default:
        return null;
    }
  }

  /// Kategori kimliği → toplam bayt.
  ///
  /// * `downloads` → `Download` klasörünün **içindeki her şey** (İndirilenler
  ///   ekranı da o klasörü açar; gizli dosyalar kartta da gösterilmez —
  ///   ekran varsayılanı gizli gizlemektir).
  /// * `documents` → `Documents` klasörünün içeriği. **Belgeler ekranı bu
  ///   klasörü açar**; klasör boşsa kart 0 gösterir (uzantı sınıflandırması
  ///   başka klasörlerdeki metin/PDF'leri sayıp kartı şişiriyordu).
  /// * `images` / `videos` / `audio` → yukarıdaki klasörlerde uzantısına
  ///   göre sınıflandırılan medya dosyalarının toplamı (medya ekranları
  ///   MediaStore ile cihazın tamamını listelediği için).
  /// * `recent` → son 7 günde değişen ve **henüz "Temizle" ile
  ///   işaretlenmemiş** dosyalar (ekranla birebir aynı).
  ///
  /// [root] test için parametre olarak verilir.
  @visibleForTesting
  static Map<String, int> scan(
    String root, {
    Set<String> seenRecent = const {},
    int maxEntries = 60000,
  }) {
    final sep = Platform.pathSeparator;
    final downloads = dirStats('$root${sep}Download', skipHidden: true);
    final documents = dirStats('$root${sep}Documents', skipHidden: true);
    final media = classifySizesAndCounts(root, maxEntries: maxEntries);
    final recent = recentStats(
      root,
      maxEntries: maxEntries,
      seen: seenRecent,
    );
    return {
      'downloads': downloads.bytes,
      'downloads_n': downloads.count,
      'documents': documents.bytes,
      'documents_n': documents.count,
      ...media.sizes,
      for (final e in media.counts.entries) '${e.key}_n': e.value,
      'recent': recent.bytes,
      'recent_n': recent.count,
    };
  }

  /// Klasörlerdeki dosyaları uzantısına göre **medya** kategorilerine böler.
  ///
  /// Tek bir yürüyüşte medya dosyası **yalnızca bir** kategoriye yazılır;
  /// böylece toplamlar şişmez ve Resimler/Videolar/Ses ayrımı doğru olur.
  ///
  /// Belgeler/İndirilenler bu fonksiyona girmez (onlar doğrudan klasör
  /// boyutudur — bkz. [scan]).
  @visibleForTesting
  static Map<String, int> classifySizes(
    String root, {
    int maxEntries = 60000,
  }) =>
      classifySizesAndCounts(root, maxEntries: maxEntries).sizes;

  /// Medya boyutu + adet (tek yürüyüş).
  @visibleForTesting
  static ({Map<String, int> sizes, Map<String, int> counts})
      classifySizesAndCounts(
    String root, {
    int maxEntries = 60000,
  }) {
    final sep = Platform.pathSeparator;
    final totals = <String, int>{
      'images': 0,
      'videos': 0,
      'audio': 0,
    };
    final counts = <String, int>{
      'images': 0,
      'videos': 0,
      'audio': 0,
    };
    var visited = 0;
    final stack = <String>[
      for (final folder in _scanFolders) '$root$sep$folder',
    ];
    while (stack.isNotEmpty && visited < maxEntries) {
      final path = stack.removeLast();
      List<FileSystemEntity> items;
      try {
        items = Directory(path).listSync(followLinks: false);
      } catch (_) {
        continue; // Erişilemeyen klasör yok sayılır.
      }
      for (final e in items) {
        if (++visited >= maxEntries) break;
        final name = _nameOf(e.path);
        if (name.isEmpty || name.startsWith('.')) continue;
        if (e is Directory) {
          if (name == 'LOST.DIR') continue;
          if (isHiddenByNomedia(e.path, name: name)) continue;
          stack.add(e.path);
        } else if (e is File) {
          final category = categoryOfExtension(_extensionOf(name));
          if (category == null || !totals.containsKey(category)) continue;
          try {
            totals[category] = totals[category]! + e.lengthSync();
            counts[category] = counts[category]! + 1;
          } catch (err) {
            logSwallowed('kategori boyutu: dosya boyutu', err);
          }
        }
      }
    }
    return (sizes: totals, counts: counts);
  }

  /// Klasörün özyinelemeli toplam boyutu (erişim hataları yutulur).
  ///
  /// [skipHidden] ile nokta ile başlayan dosya/klasörler sayılmaz; İndirilenler
  /// ve Belgeler kartları ekranın varsayılan görünümüyle (gizli gizli) birebir
  /// aynı toplamı verir.
  @visibleForTesting
  static int dirSize(String path, {bool skipHidden = false}) =>
      dirStats(path, skipHidden: skipHidden).bytes;

  /// Klasör boyutu + dosya adedi (kart etiketinde "1,5 GB (42)").
  @visibleForTesting
  static ({int bytes, int count}) dirStats(
    String path, {
    bool skipHidden = false,
  }) {
    final dir = Directory(path);
    if (!dir.existsSync()) return (bytes: 0, count: 0);
    var total = 0;
    var count = 0;
    try {
      for (final e in dir.listSync(followLinks: false)) {
        if (skipHidden && _nameOf(e.path).startsWith('.')) continue;
        if (e is File) {
          try {
            total += e.lengthSync();
            count++;
          } catch (err) {
            logSwallowed('kategori boyutu: dosya boyutu', err);
          }
        } else if (e is Directory) {
          if (skipHidden && isHiddenByNomedia(e.path)) continue;
          final nested = dirStats(e.path, skipHidden: skipHidden);
          total += nested.bytes;
          count += nested.count;
        }
      }
    } catch (e) {
      logSwallowed('kategori boyutu: yürüyüş', e);
    }
    return (bytes: total, count: count);
  }

  /// Son 7 günde değişen dosyaların toplam boyutu ("Yeni Dosyalar").
  ///
  /// [seen] kümesindeki dosyalar (kullanıcının "Temizle" ile işaretledikleri)
  /// **sayılmaz**: kart, ekranda gerçekten listelenen toplamı gösterir.
  ///
  /// Tarama erişilemeyen/ağır dizimler atlanır ve işlem sayısı
  /// sınırlandırılır; böylece arka plan taraması makul sürede biter.
  @visibleForTesting
  static int recentSize(
    String root, {
    int maxEntries = 60000,
    Set<String> seen = const {},
  }) =>
      recentStats(root, maxEntries: maxEntries, seen: seen).bytes;

  @visibleForTesting
  static ({int bytes, int count}) recentStats(
    String root, {
    int maxEntries = 60000,
    Set<String> seen = const {},
  }) {
    final cutoff = DateTime.now().subtract(const Duration(days: 7));
    var total = 0;
    var count = 0;
    var visited = 0;
    final stack = <String>[root];
    while (stack.isNotEmpty && visited < maxEntries) {
      final path = stack.removeLast();
      List<FileSystemEntity> items;
      try {
        items = Directory(path).listSync(followLinks: false);
      } catch (_) {
        continue;
      }
      for (final e in items) {
        if (++visited >= maxEntries) break;
        final name = _nameOf(e.path);
        if (name.isEmpty || name.startsWith('.')) continue;
        if (e is Directory) {
          if (name == 'Android' || name == 'LOST.DIR') continue;
          stack.add(e.path);
        } else if (e is File) {
          try {
            final stat = e.statSync();
            if (!stat.modified.isAfter(cutoff)) continue;
            if (seen.contains(RecentSeenStore.keyOf(e.path, stat.modified))) {
              continue;
            }
            total += stat.size;
            count++;
          } catch (err) {
            logSwallowed('kategori boyutu: son 7 gün', err);
          }
        }
      }
    }
    return (bytes: total, count: count);
  }

  /// Dosya adının uzantısı (nokta yoksa boş).
  static String _extensionOf(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(i + 1).toLowerCase() : '';
  }

  /// Yolun son ögesi (dosya/dizin adı); ayraç farklarını yutar.
  static String _nameOf(String path) {
    final sep = Platform.pathSeparator;
    final normalized = sep == '/' ? path : path.replaceAll('/', sep);
    final parts = normalized.split(sep);
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return '';
  }

  // -------------------------------------------------------------------------
  // Önbellek
  // -------------------------------------------------------------------------

  static Future<(DateTime, Map<String, String>)?> _readCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return null;
      final map = jsonDecode(raw) as Map<String, Object?>;
      final at = DateTime.fromMillisecondsSinceEpoch(
          (map['at'] as num?)?.toInt() ?? 0);
      final values = (map['values'] as Map<String, Object?>?) ?? const {};
      final parsed = <String, String>{
        for (final e in values.entries) e.key: '${e.value}',
      };
      if (at.millisecondsSinceEpoch == 0 || parsed.isEmpty) return null;
      return (at, parsed);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeCache(Map<String, String> values) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _cacheKey,
        jsonEncode({
          'at': DateTime.now().millisecondsSinceEpoch,
          'values': values,
        }),
      );
    } catch (_) {
      // Önbellek yazılamazsa bir sonraki açılışta yeniden hesaplanır;
      // taze sonuç zaten labels'a yazılmıştı, kullanıcı hiçbir şey fark etmez.
    }
  }
}

/// İzolata gönderilecek boyut tarama isteği.
class _SizeScanRequest {
  const _SizeScanRequest({
    required this.root,
    required this.seenRecent,
    required this.reply,
  });

  final String root;

  /// "Temizle" ile görülmüş dosyalar (yol + değiştirme zamanı anahtarı).
  final List<String> seenRecent;
  final SendPort reply;
}

/// İzolat giriş noktası: kapanış yerine üst düzey fonksiyon kullanılır.
void _scanIsolateEntry(_SizeScanRequest req) {
  try {
    req.reply.send(CategorySizeService.scan(
      req.root,
      seenRecent: req.seenRecent.toSet(),
    ));
  } catch (_) {
    req.reply.send(const <String, int>{});
  }
}
