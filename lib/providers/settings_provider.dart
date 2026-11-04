import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_appearance.dart';

/// Uygulama genelindeki ayarları tutar ve kalıcılaştırır.
class SettingsProvider extends ChangeNotifier {
  SettingsProvider(this._prefs);

  final SharedPreferences _prefs;

  static const _kThemeMode = 'theme_mode';
  static const _kSizeUnit = 'size_unit';
  static const _kDateFormat = 'date_format';
  static const _kRecycleBinDefault = 'recycle_bin_default';
  static const _kRecycleBinConfirm = 'recycle_bin_confirm';
  static const _kShowNavIcon = 'show_nav_icon';
  static const _kDetectUsb = 'detect_usb';
  static const _kShowSystemStorage = 'show_system_storage';
  static const _kStorageWarnPercent = 'storage_warn_percent';
  static const _kTvMode = 'tv_mode';
  static const _kViewStyle = 'view_style';
  static const _kBrowserViewMode = 'browser_view_mode';
  static const _kDeviceModeChosen = 'device_mode_chosen';
  static const _kPermissionsOnboarded = 'permissions_onboarded';
  static const _kDynamicColor = 'dynamic_color';
  static const _kAppearance = 'appearance';
  static const _kHiddenHomeCategories = 'hidden_home_categories';
  static const _kShowBookmarkMenu = 'show_bookmark_menu';
  static const _kShowAddToHomeMenu = 'show_add_to_home_menu';
  static const _kShowHideToggleMenu = 'show_hide_toggle_menu';
  static const _kShowOpenWithMenu = 'show_open_with_menu';
  static const _kShowHiddenFiles = 'show_hidden_files';
  static const _kForceDualPane = 'force_dual_pane';
  static const _kDropAction = 'drop_action'; // ask | copy | move
  static const _kDualPaneMinWidth = 'dual_pane_min_width';

  static Future<SettingsProvider> load() async =>
      SettingsProvider(await SharedPreferences.getInstance());

  /// Tema: system / light / dark. Her kullanıcıya açık (kısıtlama yok).
  ThemeMode get themeMode => switch (_prefs.getString(_kThemeMode)) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  set themeMode(ThemeMode value) {
    _prefs.setString(_kThemeMode, value.name);
    notifyListeners();
  }

  /// Dosya boyutu birimi (örn. GB).
  String get sizeUnit => _prefs.getString(_kSizeUnit) ?? 'GB';

  set sizeUnit(String value) {
    _prefs.setString(_kSizeUnit, value);
    notifyListeners();
  }

  /// Tarih biçimi deseni (örn. 'd MMM yyyy' → "9 Eki 2026").
  String get datePattern => _prefs.getString(_kDateFormat) ?? 'd MMM yyyy';

  set datePattern(String value) {
    _prefs.setString(_kDateFormat, value);
    notifyListeners();
  }

  /// Varsayılan: kapalı — F Dosya Yöneticisi gibi doğrudan kalıcı silme.
  /// Açılırsa silinenler uygulama geri dönüşüm kutusuna taşınır.
  bool get recycleBinDefault => _prefs.getBool(_kRecycleBinDefault) ?? false;

  set recycleBinDefault(bool value) {
    _prefs.setBool(_kRecycleBinDefault, value);
    notifyListeners();
  }

  bool get recycleBinConfirm => _prefs.getBool(_kRecycleBinConfirm) ?? true;

  set recycleBinConfirm(bool value) {
    _prefs.setBool(_kRecycleBinConfirm, value);
    notifyListeners();
  }

  bool get showNavIcon => _prefs.getBool(_kShowNavIcon) ?? true;

  set showNavIcon(bool value) {
    _prefs.setBool(_kShowNavIcon, value);
    notifyListeners();
  }

  bool get detectUsb => _prefs.getBool(_kDetectUsb) ?? true;

  set detectUsb(bool value) {
    _prefs.setBool(_kDetectUsb, value);
    notifyListeners();
  }

  bool get showSystemStorage => _prefs.getBool(_kShowSystemStorage) ?? false;

  set showSystemStorage(bool value) {
    _prefs.setBool(_kShowSystemStorage, value);
    notifyListeners();
  }

  /// "Bellek dolu" bildirimi eşiği (%).
  int get storageWarnPercent => _prefs.getInt(_kStorageWarnPercent) ?? 98;

  set storageWarnPercent(int value) {
    _prefs.setInt(_kStorageWarnPercent, value);
    notifyListeners();
  }

  /// Arayüz modu: 'auto' (TV algılanırsa TV), 'tv' (zorla TV), 'phone'.
  String get tvMode => _prefs.getString(_kTvMode) ?? 'auto';

  set tvMode(String value) {
    _prefs.setString(_kTvMode, value);
    notifyListeners();
  }

  /// Görünüm düzeni: ana ekran ızgarasındaki sütun sayısı.
  ///
  /// • `auto`   → cihaz genişliğine göre (3/4/5)
  /// • `large`  → büyük kartlar: dikey 2 / yatay 3
  /// • `medium` → dengeli: dikey 3 / yatay 4
  /// • `small`  → sıkışık: dikey 4 / yatay 6
  String get viewStyle => _prefs.getString(_kViewStyle) ?? 'auto';

  set viewStyle(String value) {
    _prefs.setString(_kViewStyle, value);
    notifyListeners();
  }

  /// Dosya tarayıcısı görünümü: 'list' (satır) veya 'grid' (ızgara).
  ///
  /// Kullanıcının seçimi kalıcıdır ve tüm tarayıcı ekranlarında ortaktır.
  String get browserViewMode => _prefs.getString(_kBrowserViewMode) ?? 'list';

  set browserViewMode(String value) {
    _prefs.setString(_kBrowserViewMode, value);
    notifyListeners();
  }

  /// İlk açılıştaki "Mobil-Tablet / TV sürümü" seçimi yapıldı mı.
  /// Yapılmadıysa uygulama [DeviceModeScreen] ile açılır.
  bool get deviceModeChosen => _prefs.getBool(_kDeviceModeChosen) ?? false;

  set deviceModeChosen(bool value) {
    _prefs.setBool(_kDeviceModeChosen, value);
    notifyListeners();
  }

  /// Sürüm seçimi: 'phone' (Mobil-Tablet) veya 'tv' (TV Sürümü).
  /// Seçime göre gereken ayarları otomatik uygular:
  /// • TV → kumanda odaklı TV arayüzü + koyu tema
  /// • Telefon/tablet → klasik dokunmatik arayüz
  void applyDeviceMode(String mode) {
    tvMode = mode;
    if (mode == 'tv') {
      themeMode = ThemeMode.dark;
    }
    deviceModeChosen = true;
  }

  /// İlk açılıştaki izin onayı tamamlandı mı?
  bool get permissionsOnboarded => _prefs.getBool(_kPermissionsOnboarded) ?? false;

  set permissionsOnboarded(bool value) {
    _prefs.setBool(_kPermissionsOnboarded, value);
    notifyListeners();
  }

  /// Material You: Android 12+ sistem (dinamik) rengi kullanılsın mı?
  /// Eski sürüm/cihazda etkisizdir (dinamik palet yoksa turkuaza döner).
  ///
  /// Not: dinamik renk yalnız **Klasik** görünümde etkilidir; seçili başka
  /// bir görünümün kendi tarz rengi ezilmez (bkz. [AppAppearance]).
  bool get dynamicColor => _prefs.getBool(_kDynamicColor) ?? true;

  set dynamicColor(bool value) {
    _prefs.setBool(_kDynamicColor, value);
    notifyListeners();
  }

  /// Seçili **görünüm preset'i**: yazı fontu, ikon stili, köşe yuvarlaklığı,
  /// renk doygunluğu ve ana ekran arka planını birlikte değiştirir.
  ///
  /// Tema (açık/koyu) ile bağımsızdır: koyu temada da görünüm korunur.
  AppAppearance get appearance =>
      AppAppearance.fromId(_prefs.getString(_kAppearance));

  set appearance(AppAppearance value) {
    _prefs.setString(_kAppearance, value.id);
    notifyListeners();
  }

  /// Ana ekranda **gizlenmiş** kategori kimlikleri.
  ///
  /// Boş küme = tüm kartlar görünür (varsayılan). Gizlenen kart yalnızca
  /// ana ekrandan kaldırılır; çekmece, ayarlar ve rotalar etkilenmez, yani
  /// özellik tamamen erişilemez olmaz.
  ///
  /// Kullanıcıya hiç sunulmayan kartlar (örn. doğrulaması tamamlanmamış
  /// "Bulut") zaten `kHomeCategories` listesinde yer almaz; bunlar bu kümeye
  /// hiç girmez, gizleme listesi yalnızca gösterilen kartlarla ilgilidir.
  Set<String> get hiddenHomeCategories =>
      (_prefs.getStringList(_kHiddenHomeCategories) ?? const <String>[])
          .toSet();

  set hiddenHomeCategories(Set<String> value) {
    // Sıralı saklanır: prefs içeriği kararlı ve testlerde öngörülebilir olur.
    _prefs.setStringList(_kHiddenHomeCategories, value.toList()..sort());
    notifyListeners();
  }

  /// Kategori ana ekranda görünür mü?
  bool isCategoryVisible(String id) => !hiddenHomeCategories.contains(id);

  /// Tek bir kategoriyi gösterir veya gizler.
  void setCategoryVisible(String id, bool visible) {
    final hidden = hiddenHomeCategories;
    if (visible) {
      hidden.remove(id);
    } else {
      hidden.add(id);
    }
    hiddenHomeCategories = hidden;
  }

  /// Tüm ana ekran kartlarını yeniden gösterir.
  ///
  /// Bu, kullanıcının kendi kararını da siler: kartlar **hiçbiri varsayılan
  /// olarak gizli olmadığından** hepsi yeniden görünür olur. Varsayılandan
  /// gizli kart kavramı bilinçli olarak yoktur — yeni bir kart eklendiğinde
  /// kullanıcı onu istemediği sürece görünür başlar.
  void resetHiddenHomeCategories() => hiddenHomeCategories = <String>{};

  /// Satır menüsünde "Yer imine ekle" görünsün mü?
  bool get showBookmarkMenu => _prefs.getBool(_kShowBookmarkMenu) ?? true;

  set showBookmarkMenu(bool value) {
    _prefs.setBool(_kShowBookmarkMenu, value);
    notifyListeners();
  }

  /// Satır menüsünde "Ana ekrana ekle" görünsün mü?
  bool get showAddToHomeMenu => _prefs.getBool(_kShowAddToHomeMenu) ?? true;

  set showAddToHomeMenu(bool value) {
    _prefs.setBool(_kShowAddToHomeMenu, value);
    notifyListeners();
  }

  /// Tarayıcı menüsünde "Gizli dosyaları göster" anahtarı görünsün mü?
  bool get showHideToggleMenu => _prefs.getBool(_kShowHideToggleMenu) ?? true;

  set showHideToggleMenu(bool value) {
    _prefs.setBool(_kShowHideToggleMenu, value);
    notifyListeners();
  }

  /// Satır menüsünde "Farklı aç" görünsün mü?
  bool get showOpenWithMenu => _prefs.getBool(_kShowOpenWithMenu) ?? true;

  set showOpenWithMenu(bool value) {
    _prefs.setBool(_kShowOpenWithMenu, value);
    notifyListeners();
  }

  /// Nokta ile başlayan gizli dosya/klasörler listelensin mi?
  bool get showHiddenFiles => _prefs.getBool(_kShowHiddenFiles) ?? false;

  set showHiddenFiles(bool value) {
    _prefs.setBool(_kShowHiddenFiles, value);
    notifyListeners();
  }

  /// Telefon dahil çift bölmeli tarayıcıyı zorla (Solid Explorer tarzı).
  ///
  /// Kapalıyken yalnızca genişlik eşiği (≥ [dualPaneMinWidth]) aşılırsa
  /// çift panel açılır.
  bool get forceDualPane => _prefs.getBool(_kForceDualPane) ?? false;

  set forceDualPane(bool value) {
    _prefs.setBool(_kForceDualPane, value);
    notifyListeners();
  }

  /// Çift panel eşiği (px). Varsayılan 900; telefonda yatay kullanım için
  /// 600'e indirilebilir.
  int get dualPaneMinWidth => _prefs.getInt(_kDualPaneMinWidth) ?? 900;

  set dualPaneMinWidth(int value) {
    _prefs.setInt(_kDualPaneMinWidth, value.clamp(480, 1200));
    notifyListeners();
  }

  /// Sürükle-bırak eylemi: `ask` (sor), `copy`, `move`.
  String get dropAction => _prefs.getString(_kDropAction) ?? 'ask';

  set dropAction(String value) {
    _prefs.setString(_kDropAction, value);
    notifyListeners();
  }
}
