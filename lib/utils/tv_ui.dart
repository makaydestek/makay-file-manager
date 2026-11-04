import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../services/platform_service.dart';

/// TV / kumanda arayüzü yardımcıları.
///
/// • `tv` → her zaman odak halkası
/// • `phone` → asla
/// • `auto` → cihaz TV ise (önbellekli [PlatformService.isTvCached]) odak
///   halkası — aksi halde mobil. Böylece otomatik TV ana ekranı açıldığında
///   diğer ekranlardaki [TvFocusable] de çalışır.
class TvUi {
  TvUi._();

  /// Bu bağlamda TV odaklı arayüz mü?
  static bool enabled(BuildContext context) {
    try {
      final mode =
          context.select<SettingsProvider, String>((s) => s.tvMode);
      return enabledForMode(mode);
    } catch (_) {
      return false;
    }
  }

  /// [Provider] dışında (tema kurulumu vb.) doğrudan tercih değeri.
  static bool enabledFor(SettingsProvider settings) =>
      enabledForMode(settings.tvMode);

  static bool enabledForMode(String tvMode) {
    switch (tvMode) {
      case 'tv':
        return true;
      case 'phone':
        return false;
      default:
        return PlatformService.isTvCached;
    }
  }
}
