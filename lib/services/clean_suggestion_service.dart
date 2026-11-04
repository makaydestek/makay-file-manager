import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import '../utils/app_paths.dart';
import '../utils/formats.dart';
import 'analysis_service.dart';
import 'file_service.dart';

/// Akıllı temizlik önerisi kartı.
class CleanSuggestion {
  const CleanSuggestion({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.bytes,
    required this.icon,
    required this.route,
    this.actionLabel = 'İncele',
  });

  final String id;
  final String title;
  final String subtitle;
  final int bytes;
  final String icon; // material icon adı yerine sabit anahtar
  final String route;
  final String actionLabel;

  String get sizeLabel => Formats.size(bytes);
}

/// Heuristic temizlik önerileri (AI değil — mevcut taramalara dayalı).
///
/// Files by Google tarzı "X GB kazanabilirsiniz" kartlarını mevcut
/// AnalysisService / DuplicateService / önbellek taramasıyla üretir.
class CleanSuggestionService {
  const CleanSuggestionService();

  static const _analysis = AnalysisService();

  /// Önerileri toplar. Ağır taramalar izolatta / sınırlı örnekle çalışır.
  Future<List<CleanSuggestion>> suggestions() async {
    final out = <CleanSuggestion>[];

    // 1) Önbellek / geçici
    final cache = await _analysis.cacheSize();
    var tempBytes = 0;
    try {
      final tmp = (await getTemporaryDirectory()).path;
      tempBytes = await Isolate.run(() {
        var total = 0;
        try {
          for (final e in Directory(tmp)
              .listSync(recursive: true, followLinks: false)) {
            if (e is File) {
              try {
                total += e.lengthSync();
              } catch (_) {}
            }
          }
        } catch (_) {}
        return total;
      });
    } catch (_) {}
    final junk = cache + tempBytes;
    if (junk > 2 * 1024 * 1024) {
      out.add(CleanSuggestion(
        id: 'temp',
        title: 'Önbellek ve geçici dosyalar',
        subtitle: 'Güvenle temizlenebilir geçici veriler',
        bytes: junk,
        icon: 'cleaning',
        route: '/temp',
        actionLabel: 'Temizle',
      ));
    }

    // 2) Büyük dosyalar (örnek)
    final large = await _analysis.largeFiles(limit: 50);
    final largeTotal = large.fold<int>(0, (s, f) => s + f.size);
    if (largeTotal > 50 * 1024 * 1024) {
      out.add(CleanSuggestion(
        id: 'large',
        title: 'Büyük dosyalar',
        subtitle: '${large.length} büyük dosya incelenebilir',
        bytes: largeTotal,
        icon: 'large',
        route: '/clean/large',
        actionLabel: 'Görüntüle',
      ));
    }

    // 3) Mükerrer (hızlı: yalnızca boyut grup özeti — tam hash yok)
    try {
      if (Directory(AppPaths.scanRoot).existsSync()) {
        // Tam mükerrer taraması pahalı; öneri kartında yalnızca
        // DuplicateService ekranına yönlendirilir.
        out.add(const CleanSuggestion(
          id: 'dup',
          title: 'Mükerrer dosyalar',
          subtitle: 'Aynı içeriğe sahip kopyaları bulun ve temizleyin',
          bytes: 0,
          icon: 'dup',
          route: '/duplicates',
          actionLabel: 'Tara',
        ));
      }
    } catch (_) {}

    // 4) İndirilenler klasörü boyutu
    try {
      final downloads = await AppPaths.byCategory('downloads');
      if (downloads != null && Directory(downloads).existsSync()) {
        final size = await const FileService().directorySize(downloads);
        if (size > 100 * 1024 * 1024) {
          out.add(CleanSuggestion(
            id: 'downloads',
            title: 'İndirilenler',
            subtitle: 'Eski indirmeleri gözden geçirin',
            bytes: size,
            icon: 'downloads',
            route: '/browse/downloads',
            actionLabel: 'Aç',
          ));
        }
      }
    } catch (_) {}

    out.sort((a, b) => b.bytes.compareTo(a.bytes));
    return out;
  }

  /// Tahmini kazanılabilecek alan (mükerrer kartı hariç).
  static int estimableBytes(List<CleanSuggestion> list) =>
      list.where((s) => s.id != 'dup').fold(0, (s, e) => s + e.bytes);
}
