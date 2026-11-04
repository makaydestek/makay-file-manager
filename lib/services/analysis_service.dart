import 'dart:io';

import '../models/file_entry.dart';
import '../utils/debug_log.dart';
import 'heavy_scan.dart';
import 'platform_service.dart';

/// Kategori kırılımı: kategori adı → toplam boyut (bayt).
typedef CategoryBreakdown = Map<String, int>;

/// Bellek analizi tarama servisi.
///
/// Medya ve diğer kategoriler bilinen standart klasörlerde dart:io ile
/// taranır (MANAGE_EXTERNAL_STORAGE izni ile). Ağır yürüyüş [HeavyScan]
/// ile arka izolatta çalışır.
class AnalysisService {
  const AnalysisService();

  /// Kategori bazlı depolama dağılımı.
  ///
  /// Kategoriler **karşılıklı dışlayıcıdır**: bir dosya en fazla tek
  /// kategoriye girer. Aksi halde yüzde/treemap toplamı kullanılan alandan
  /// büyük çıkardı (ör. `Download` altındaki bir hem "Belgeler" hem
  /// "Arşivler", `WhatsApp/Media/WhatsApp Video` altındaki hem "Videolar" hem
  /// "Diğerleri" sayılıyordu).
  Future<CategoryBreakdown> categoryBreakdown() async {
    final result = <String, int>{};

    final root = Platform.isAndroid ? '/storage/emulated/0' : null;
    if (root != null) {
      try {
        result.addAll(await HeavyScan.analysisBreakdown(root));
      } catch (e) {
        logSwallowed('analiz: izolat kırılım', e);
        result
          ..['Resimler'] = 0
          ..['Videolar'] = 0
          ..['Ses'] = 0
          ..['Belgeler'] = 0
          ..['Arşivler'] = 0;
      }

      // "Diğerleri": kullanılan alanın kalanı (Platform channel → ana izolat).
      final storage = await PlatformService.storageInfo();
      final used = (storage != null && storage.total > 0)
          ? storage.total - storage.free
          : 0;
      final counted = result.values.fold<int>(0, (sum, v) => sum + v);
      result['Diğerleri'] = used > counted ? used - counted : 0;
    } else {
      result
        ..putIfAbsent('Resimler', () => 0)
        ..putIfAbsent('Videolar', () => 0)
        ..putIfAbsent('Ses', () => 0)
        ..putIfAbsent('Belgeler', () => 0)
        ..putIfAbsent('Arşivler', () => 0)
        ..putIfAbsent('Diğerleri', () => 0);
    }
    return result;
  }

  /// Belirtilen boyutun üzerindeki dosyalar (sınırlı sayıda).
  ///
  /// [root] kökünden özyinelemeli taranır; [skipDirs] klasörleri atlanır.
  /// Ağır yürüyüş [HeavyScan] izolatında yapılır.
  Future<List<FileEntry>> largeFiles({
    String root = '/storage/emulated/0',
    int minBytes = 10 * 1024 * 1024,
    int limit = 300,
    int maxDepth = 5,
  }) async {
    try {
      final rows = await HeavyScan.largeFiles(
        root: root,
        minBytes: minBytes,
        limit: limit,
        maxDepth: maxDepth,
      );
      return [
        for (final r in rows)
          FileEntry(
            name: r.name,
            path: r.path,
            isDirectory: false,
            size: r.size,
            modified: r.modified,
          ),
      ];
    } catch (e) {
      logSwallowed('analiz: büyük dosya izolat', e);
      return const [];
    }
  }

  /// Uygulama önbellek klasörlerinin toplam boyutu (kaba tahmin).
  ///
  /// Android/data tam yürüyüşü çok yavaştır; izolatta sığ derinlikle
  /// ölçülür (analiz ekranı progressive yüklenirken UI donmaz).
  Future<int> cacheSize() async {
    if (!Platform.isAndroid) return 0;
    try {
      return await HeavyScan.cacheSize(maxDepth: 3);
    } catch (e) {
      logSwallowed('analiz: önbellek izolat', e);
      return 0;
    }
  }
}
