import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../l10n/app_localizations.dart';
import '../models/home_category.dart';
import '../providers/settings_provider.dart';
import '../screens/permissions_screen.dart';
import 'home_categories_screen.dart';
import '../services/auth_service.dart';
import '../services/platform_service.dart';
import '../services/update_service.dart';
import '../utils/formats.dart';
import '../widgets/appearance_picker.dart';
import '../widgets/app_drawer.dart';
import '../widgets/update_dialog.dart';

/// Referans uygulamadaki Ayarlar ekranı.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsProvider>();
    final theme = Theme.of(context);
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
          title: Text(AppLocalizations.of(context).settingsTitle)),
      body: ListView(
        children: [
          _sectionHeader(context, 'Genel Ayarlar'),
          ListTile(
            title: const Text('Tema'),
            subtitle: Text(switch (settings.themeMode) {
              ThemeMode.system => 'Sistem',
              ThemeMode.light => 'Açık',
              ThemeMode.dark => 'Koyu',
            }),
            leading: const Icon(Icons.palette_rounded),
            onTap: () => _pickTheme(context, settings),
          ),
          ListTile(
            title: const Text('Görünüm'),
            subtitle: Text(
              '${settings.appearance.label} — ${settings.appearance.description}',
            ),
            leading: const Icon(Icons.style_rounded),
            onTap: () => _pickAppearance(context, settings),
          ),
          ListTile(
            title: const Text('Arayüz modu'),
            subtitle: Text(switch (settings.tvMode) {
              'tv' => 'TV (kumanda odaklı)',
              'phone' => 'Telefon / tablet',
              _ => 'Otomatik (TV algılanırsa TV arayüzü)',
            }),
            leading: const Icon(Icons.tv_rounded),
            onTap: () => _pickUiMode(context, settings),
          ),
          ListTile(
            title: const Text('Görünüm düzeni'),
            subtitle: Text(switch (settings.viewStyle) {
              'large' => 'Büyük kartlar (dikey 2 / yatay 3)',
              'medium' => 'Dengeli (dikey 3 / yatay 4)',
              'small' => 'Sıkışık (dikey 4 / yatay 6)',
              _ => 'Otomatik (cihaz genişliğine göre)',
            }),
            leading: const Icon(Icons.grid_view_rounded),
            onTap: () => _pickViewStyle(context, settings),
          ),
          ListTile(
            title: const Text('Ana ekran kartları'),
            subtitle: Text(
              'Görünmek istemediğiniz özellikleri gizleyin '
              '(${kHomeCategories.length - settings.hiddenHomeCategories.length}'
              ' / ${kHomeCategories.length} görünür)',
            ),
            leading: const Icon(Icons.visibility_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const HomeCategoriesScreen()),
            ),
          ),
          SwitchListTile(
            title: const Text('Material You (sistem rengi)'),
            subtitle: const Text(
                'Android 12+ cihazlarda uygulama rengini sistemle eşleştir'),
            secondary: const Icon(Icons.format_color_fill_rounded),
            value: settings.dynamicColor,
            onChanged: (v) => settings.dynamicColor = v,
          ),
          ListTile(
            title: const Text('Kasa (gizli klasör)'),
            subtitle: const Text('PIN ile korunan şifreli dosyalar'),
            leading: const Icon(Icons.lock_outline_rounded),
            onTap: () => Navigator.of(context).pushNamed('/vault'),
          ),
          ListTile(
            title: const Text('Bulut bağlantıları'),
            subtitle: const Text(
              'Drive / Dropbox / OneDrive / Box — kendi istemci kimliğinizle '
              '(gelişmiş)',
            ),
            leading: const Icon(Icons.cloud_rounded),
            onTap: () => _openCloudAdvanced(context),
          ),
          ListTile(
            title: const Text('Temizlik merkezi'),
            subtitle: const Text('Öneriler, geçici, mükerrer, büyük dosyalar'),
            leading: const Icon(Icons.cleaning_services_rounded),
            onTap: () => Navigator.of(context).pushNamed('/clean'),
          ),
          ListTile(
            title: const Text('USB / SD Kart'),
            subtitle: const Text('Bağlı harici depolama birimleri'),
            leading: const Icon(Icons.sd_card_rounded),
            onTap: () => Navigator.of(context).pushNamed('/usb'),
          ),
          ListTile(
            title: const Text('Mükerrer dosyalar'),
            subtitle: const Text('Aynı içeriğe sahip kopyaları bul'),
            leading: const Icon(Icons.copy_all_rounded),
            onTap: () => Navigator.of(context).pushNamed('/duplicates'),
          ),
          ListTile(
            title: const Text('Gizlilik ve ilkeler'),
            subtitle: const Text('Reklam yok • Veri toplanmaz • Ücretsiz'),
            leading: const Icon(Icons.privacy_tip_rounded),
            onTap: () => Navigator.of(context).pushNamed('/privacy'),
          ),
          const Divider(),
          _sectionHeader(context, 'Güvenlik'),
          const _AppLockSettings(),
          const Divider(),
          _sectionHeader(context, 'Tarayıcı düzeni'),
          SwitchListTile(
            title: const Text('Çift bölme (telefon dahil)'),
            subtitle: const Text(
              'Açıkken dar ekranda da klasör ağacı + liste yan yana',
            ),
            secondary: const Icon(Icons.view_column_rounded),
            value: settings.forceDualPane,
            onChanged: (v) => settings.forceDualPane = v,
          ),
          ListTile(
            title: const Text('Çift bölme genişlik eşiği'),
            subtitle: Text('${settings.dualPaneMinWidth} px'),
            leading: const Icon(Icons.width_wide_rounded),
            onTap: () => _pickDualPaneWidth(context, settings),
          ),
          ListTile(
            title: const Text('Sürükle-bırak eylemi'),
            subtitle: Text(switch (settings.dropAction) {
              'copy' => 'Her zaman kopyala',
              'move' => 'Her zaman taşı',
              _ => 'Her seferinde sor',
            }),
            leading: const Icon(Icons.drag_indicator_rounded),
            onTap: () => _pickDropAction(context, settings),
          ),
          ListTile(
            title: const Text('İzinler'),
            subtitle: const Text('Tüm erişim izinlerini gör ve değiştir'),
            leading: const Icon(Icons.shield_rounded),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const PermissionsScreen()),
            ),
          ),
          ListTile(
            title: const Text('Sürüm seçimini göster'),
            subtitle: const Text('Mobil-Tablet / TV seçim ekranı yeniden açılsın'),
            leading: const Icon(Icons.restart_alt_rounded),
            onTap: () {
              settings.deviceModeChosen = false;
              // Ana rotaya dönünce _HomeLauncher seçim ekranını açar.
              Navigator.of(context).popUntil((r) => r.isFirst);
            },
          ),
          ListTile(
            title: const Text('Varsayılan uygulamalar'),
            subtitle: const Text('Dosya türleri için varsayılan uygulamalar'),
            leading: const Icon(Icons.open_in_new_rounded),
            onTap: () async {
              final ok = await PlatformService.openDefaultAppsSettings();
              if (!ok && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Ayarlar açılamadı')),
                );
              }
            },
          ),
          ListTile(
            title: const Text('Dahili uygulamalar'),
            subtitle: const Text('Cihazla gelen (sistem) uygulamalar'),
            leading: const Icon(Icons.apps_rounded),
            onTap: () => Navigator.of(context).pushNamed('/apps/system'),
          ),
          const Divider(),
          _sectionHeader(context, 'Diğer ayarlar'),
          ListTile(
            title: const Text('Dosya boyutu birimi'),
            subtitle: Text(settings.sizeUnit),
            leading: const Icon(Icons.data_object_rounded),
            onTap: () => _pickSizeUnit(context, settings),
          ),
          ListTile(
            title: const Text('Tarih biçimi'),
            subtitle: Text(Formats.date(DateTime.now(),
                pattern: settings.datePattern)),
            leading: const Icon(Icons.event_rounded),
            onTap: () => _pickDateFormat(context, settings),
          ),
          const Divider(),
          _sectionHeader(context, 'Geçici dosyalar'),
          ListTile(
            title: const Text('Geçici dosyalar'),
            subtitle: const Text('Önbellek ve geçici dosyaları temizle'),
            leading: const Icon(Icons.cleaning_services_rounded),
            onTap: () => Navigator.of(context).pushNamed('/temp'),
          ),
          const Divider(),
          _sectionHeader(context, 'Geri Dönüşüm Kutusu Ayarları'),
          SwitchListTile(
            title: const Text('Varsayılan olarak geri dönüşüm kutusu'),
            subtitle: const Text(
              'Kapalı: F Dosya Yöneticisi gibi kalıcı siler. '
              'Açık: silinenleri kutuya taşır',
            ),
            value: settings.recycleBinDefault,
            onChanged: (v) => settings.recycleBinDefault = v,
          ),
          SwitchListTile(
            title: const Text('Geri Dönüşüm onayını göster'),
            value: settings.recycleBinConfirm,
            onChanged: (v) => settings.recycleBinConfirm = v,
          ),
          const Divider(),
          _sectionHeader(context, 'Bildirim ayarları'),
          ListTile(
            title: const Text('Bellek dolu'),
            subtitle: Text(
                'Depolama alanı %${settings.storageWarnPercent} dolu olduğunda göster'),
            leading: const Icon(Icons.notifications_active_rounded),
            onTap: () => _pickWarnPercent(context, settings),
          ),
          const Divider(),
          _sectionHeader(context, 'Gelişmiş Ayarlar'),
          SwitchListTile(
            title: const Text('Nav icon simgesini (≡) her zaman göster'),
            value: settings.showNavIcon,
            onChanged: (v) => settings.showNavIcon = v,
          ),
          SwitchListTile(
            title: const Text('USB bağlantısını algıla'),
            value: settings.detectUsb,
            onChanged: (v) => settings.detectUsb = v,
          ),
          SwitchListTile(
            title: const Text('Sistem depolamasını göster'),
            value: settings.showSystemStorage,
            onChanged: (v) => settings.showSystemStorage = v,
          ),
          const Divider(),
          _sectionHeader(context, 'Gelişmiş menüleri göster'),
          SwitchListTile(
            title: const Text('Yer imine ekle'),
            subtitle: const Text('Klasör satır menüsünde yer imi seçeneği'),
            value: settings.showBookmarkMenu,
            onChanged: (v) => settings.showBookmarkMenu = v,
          ),
          SwitchListTile(
            title: const Text('Ana ekrana ekle'),
            subtitle: const Text('Klasörü cihaz ana ekranına kısayol olarak ekle'),
            value: settings.showAddToHomeMenu,
            onChanged: (v) => settings.showAddToHomeMenu = v,
          ),
          SwitchListTile(
            title: const Text('Gizli dosya anahtarı'),
            subtitle: const Text('Tarayıcı menüsünde gizli dosyaları göster/gizle'),
            value: settings.showHideToggleMenu,
            onChanged: (v) => settings.showHideToggleMenu = v,
          ),
          SwitchListTile(
            title: const Text('Farklı aç'),
            subtitle: const Text('Dosyayı başka uygulamayla açma seçeneği'),
            value: settings.showOpenWithMenu,
            onChanged: (v) => settings.showOpenWithMenu = v,
          ),
          SwitchListTile(
            title: const Text('Gizli dosyaları göster'),
            subtitle: const Text('Nokta ile başlayan dosya ve klasörler'),
            value: settings.showHiddenFiles,
            onChanged: (v) => settings.showHiddenFiles = v,
          ),
          const Divider(),
          _aboutHeader(context),
          _aboutCard(context, theme),
          ListTile(
            title: const Text('Güncelleme kontrolü'),
            subtitle: const Text('GitHub deposunda yeni sürüm var mı bak'),
            leading: const Icon(Icons.system_update_rounded),
            onTap: () => _checkUpdate(context),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  static Widget _sectionHeader(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
        ),
      );

  /// Hakkında başlığı (bilgi simgesi + başlık; Makay ekosistemiyle aynı
  /// görünüm).
  static Widget _aboutHeader(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        children: [
          Icon(Icons.info_rounded, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            'Hakkında',
            style: theme.textTheme.titleMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  /// Ekosistem uyumlu Hakkında kartı (Makay Cleaner ile birebir yapı):
  /// uygulama adı + sürüm, Geliştirici bilgisi ve telif satırı.
  static Widget _aboutCard(BuildContext context, ThemeData theme) => Card(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FutureBuilder<PackageInfo>(
            future: PackageInfo.fromPlatform(),
            builder: (context, snapshot) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Makay Dosya Yöneticisi',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                Text(
                  'Sürüm: ${snapshot.hasData ? snapshot.data!.version : '…'}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 14),
                Text(
                  'Geliştirici',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Bu uygulamanın tasarımı ve geliştirmesi Murat AKAY '
                  'tarafından yapılmıştır.',
                ),
                const SizedBox(height: 14),
                const Divider(height: 1),
                const SizedBox(height: 12),
                Text(
                  '© ${DateTime.now().year} Tüm hakları saklıdır. Sideload '
                  '/ yerel dağıtım için hazırlanmıştır.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      );

  /// Elle güncelleme denetimi (A15): depoda yeni sürüm varsa diyaloğu açar.
  static Future<void> _checkUpdate(BuildContext context) async {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Güncelleme kontrol ediliyor…')),
    );
    final info = await UpdateService.check();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Yeni sürüm bulunamadı')),
      );
    } else {
      await showUpdateDialog(context, info);
    }
  }

  /// Görünüm (görsel preset) seçimi: yazı, ikon, köşe ve arka plan birlikte.
  static Future<void> _pickAppearance(
      BuildContext context, SettingsProvider settings) async {
    final appearance = await showAppearanceDialog(
      context,
      selected: settings.appearance,
    );
    if (appearance != null) settings.appearance = appearance;
  }

  /// Ana ekran kartı kapalı; gelişmiş kullanıcılar Ayarlar'dan açabilir.
  static Future<void> _openCloudAdvanced(BuildContext context) async {
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = AppLocalizations.of(ctx);
        return AlertDialog(
          title: Text(l10n.cloudAdvancedTitle),
          content: const Text(
            'Google Drive, Dropbox, OneDrive ve Box için kendi ücretsiz '
            'geliştirici istemci kimliğinizi oluşturup uygulamaya yapıştırmanız '
            'gerekir.\n\n'
            'Google Drive "drive" kapsamı restricted olduğu için genel yayın '
            'doğrulaması (CASA) tamamlanmadan ana ekranda kart gösterilmez. '
            'Bu ekran ileri düzey kullanım içindir.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.cancelAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.continueAction),
            ),
          ],
        );
      },
    );
    if (go == true && context.mounted) {
      await Navigator.of(context).pushNamed('/cloud');
    }
  }

  static Future<void> _pickTheme(
      BuildContext context, SettingsProvider settings) async {
    final mode = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Tema seçin'),
        children: [
          RadioGroup<ThemeMode>(
            groupValue: settings.themeMode,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final m in ThemeMode.values)
                  RadioListTile<ThemeMode>(
                    title: Text(switch (m) {
                      ThemeMode.system => 'Sistem',
                      ThemeMode.light => 'Açık',
                      ThemeMode.dark => 'Koyu',
                    }),
                    value: m,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (mode != null) settings.themeMode = mode;
  }

  static Future<void> _pickUiMode(
      BuildContext context, SettingsProvider settings) async {
    const labels = {
      'auto': 'Otomatik (TV algılanırsa TV arayüzü)',
      'tv': 'TV (kumanda odaklı büyük kartlar)',
      'phone': 'Telefon / tablet',
    };
    final mode = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Arayüz modu'),
        children: [
          RadioGroup<String>(
            groupValue: settings.tvMode,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final m in labels.entries)
                  RadioListTile<String>(
                    title: Text(m.value),
                    value: m.key,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (mode != null) settings.tvMode = mode;
  }

  /// Görünüm düzeni seçimi: dikey/yatay sütun sayısı.
  static Future<void> _pickViewStyle(
      BuildContext context, SettingsProvider settings) async {
    const labels = <String, String>{
      'auto': 'Otomatik (cihaz genişliğine göre)',
      'large': 'Büyük kartlar — dikey 2 / yatay 3',
      'medium': 'Dengeli — dikey 3 / yatay 4',
      'small': 'Sıkışık — dikey 4 / yatay 6',
    };
    final style = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Görünüm düzeni'),
        children: [
          RadioGroup<String>(
            groupValue: settings.viewStyle,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final m in labels.entries)
                  RadioListTile<String>(
                    title: Text(m.value),
                    value: m.key,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (style != null) settings.viewStyle = style;
  }

  static Future<void> _pickSizeUnit(
      BuildContext context, SettingsProvider settings) async {
    const units = ['B', 'KB', 'MB', 'GB'];
    final unit = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Dosya boyutu birimi'),
        children: [
          RadioGroup<String>(
            groupValue: settings.sizeUnit,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final u in units)
                  RadioListTile<String>(title: Text(u), value: u),
              ],
            ),
          ),
        ],
      ),
    );
    if (unit != null) settings.sizeUnit = unit;
  }

  static Future<void> _pickDateFormat(
      BuildContext context, SettingsProvider settings) async {
    final pattern = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Tarih biçimi'),
        children: [
          RadioGroup<String>(
            groupValue: settings.datePattern,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final p in Formats.datePatterns)
                  RadioListTile<String>(
                    title: Text(p.label),
                    value: p.pattern,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (pattern != null) settings.datePattern = pattern;
  }

  static Future<void> _pickWarnPercent(
      BuildContext context, SettingsProvider settings) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Uyarı eşiği'),
        children: [
          RadioGroup<int>(
            groupValue: settings.storageWarnPercent,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final p in [80, 85, 90, 95, 98, 99])
                  RadioListTile<int>(title: Text('%$p'), value: p),
              ],
            ),
          ),
        ],
      ),
    );
    if (value != null) settings.storageWarnPercent = value;
  }

  static Future<void> _pickDualPaneWidth(
      BuildContext context, SettingsProvider settings) async {
    final value = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Çift bölme eşiği'),
        children: [
          RadioGroup<int>(
            groupValue: settings.dualPaneMinWidth,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: Column(
              children: [
                for (final w in [600, 720, 900, 1024])
                  RadioListTile<int>(
                    title: Text('$w px${w == 600 ? ' (telefon yatay)' : ''}'),
                    value: w,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (value != null) settings.dualPaneMinWidth = value;
  }

  static Future<void> _pickDropAction(
      BuildContext context, SettingsProvider settings) async {
    final value = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Sürükle-bırak eylemi'),
        children: [
          RadioGroup<String>(
            groupValue: settings.dropAction,
            onChanged: (v) {
              if (v != null) Navigator.of(context).pop(v);
            },
            child: const Column(
              children: [
                RadioListTile<String>(
                  title: Text('Her seferinde sor'),
                  value: 'ask',
                ),
                RadioListTile<String>(
                  title: Text('Her zaman kopyala'),
                  value: 'copy',
                ),
                RadioListTile<String>(
                  title: Text('Her zaman taşı'),
                  value: 'move',
                ),
              ],
            ),
          ),
        ],
      ),
    );
    if (value != null) settings.dropAction = value;
  }
}

/// Uygulama kilidi + biyometri ayarları (stateful — Async tercihler).
class _AppLockSettings extends StatefulWidget {
  const _AppLockSettings();

  @override
  State<_AppLockSettings> createState() => _AppLockSettingsState();
}

class _AppLockSettingsState extends State<_AppLockSettings> {
  bool _loading = true;
  bool _enabled = false;
  bool _hasPin = false;
  bool _bio = false;
  bool _vaultBio = false;
  bool _canBio = false;
  int _timeout = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final enabled = await AuthService.isEnabled;
    final hasPin = await AuthService.hasPin;
    final bio = await AuthService.biometricsEnabled;
    final vaultBio = await AuthService.vaultBiometricsEnabled;
    final can = await AuthService.canUseBiometrics();
    final timeout = await AuthService.timeoutSeconds;
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _hasPin = hasPin;
      _bio = bio;
      _vaultBio = vaultBio;
      _canBio = can;
      _timeout = timeout;
      _loading = false;
    });
  }

  Future<String?> _askPin({required String title, String? confirmLabel}) async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: c1,
              obscureText: true,
              keyboardType: TextInputType.number,
              maxLength: AuthService.pinMax,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'PIN',
                border: OutlineInputBorder(),
              ),
            ),
            if (confirmLabel != null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: c2,
                obscureText: true,
                keyboardType: TextInputType.number,
                maxLength: AuthService.pinMax,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: confirmLabel,
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Vazgeç'),
          ),
          FilledButton(
            onPressed: () {
              final a = c1.text.trim();
              if (a.length < AuthService.pinMin) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'PIN en az ${AuthService.pinMin} haneli olmalı'),
                  ),
                );
                return;
              }
              if (confirmLabel != null && a != c2.text.trim()) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('PIN tekrarları uyuşmuyor')),
                );
                return;
              }
              Navigator.pop(context, a);
            },
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleLock(bool value) async {
    if (value) {
      if (!_hasPin) {
        final pin = await _askPin(
          title: 'Uygulama kilidi PIN\'i',
          confirmLabel: 'PIN tekrar',
        );
        if (pin == null) return;
        try {
          await AuthService.setPin(pin);
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('$e')),
            );
          }
          return;
        }
      }
      await AuthService.setEnabled(true);
      AuthService.markUnlocked();
    } else {
      final pin = await _askPin(title: 'Kilidi kapatmak için PIN');
      if (pin == null) return;
      if (!await AuthService.verifyPin(pin)) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PIN hatalı')),
          );
        }
        return;
      }
      await AuthService.setEnabled(false);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const ListTile(
        title: Text('Uygulama kilidi'),
        trailing: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Column(
      children: [
        SwitchListTile(
          title: const Text('Uygulama kilidi'),
          subtitle: const Text('Açılışta ve arka plandan dönüşte PIN/biyometri'),
          secondary: const Icon(Icons.lock_rounded),
          value: _enabled,
          onChanged: _toggleLock,
        ),
        if (_enabled) ...[
          ListTile(
            title: const Text('PIN değiştir'),
            leading: const Icon(Icons.pin_rounded),
            onTap: () async {
              final old = await _askPin(title: 'Mevcut PIN');
              if (old == null || !mounted) return;
              if (!await AuthService.verifyPin(old)) {
                if (!mounted) return;
                ScaffoldMessenger.of(this.context).showSnackBar(
                  const SnackBar(content: Text('PIN hatalı')),
                );
                return;
              }
              if (!mounted) return;
              final neu = await _askPin(
                title: 'Yeni PIN',
                confirmLabel: 'Yeni PIN tekrar',
              );
              if (neu == null || !mounted) return;
              await AuthService.setPin(neu);
              if (!mounted) return;
              ScaffoldMessenger.of(this.context).showSnackBar(
                const SnackBar(content: Text('PIN güncellendi')),
              );
              await _reload();
            },
          ),
          ListTile(
            title: const Text('Kilit zaman aşımı'),
            subtitle: Text(switch (_timeout) {
              0 => 'Hemen (arka plana gidince)',
              30 => '30 saniye',
              60 => '1 dakika',
              300 => '5 dakika',
              _ => '$_timeout sn',
            }),
            leading: const Icon(Icons.timer_rounded),
            onTap: () async {
              final v = await showDialog<int>(
                context: context,
                builder: (context) => SimpleDialog(
                  title: const Text('Zaman aşımı'),
                  children: [
                    RadioGroup<int>(
                      groupValue: _timeout,
                      onChanged: (x) {
                        if (x != null) Navigator.pop(context, x);
                      },
                      child: const Column(
                        children: [
                          RadioListTile<int>(title: Text('Hemen'), value: 0),
                          RadioListTile<int>(
                              title: Text('30 saniye'), value: 30),
                          RadioListTile<int>(
                              title: Text('1 dakika'), value: 60),
                          RadioListTile<int>(
                              title: Text('5 dakika'), value: 300),
                        ],
                      ),
                    ),
                  ],
                ),
              );
              if (v != null) {
                await AuthService.setTimeoutSeconds(v);
                await _reload();
              }
            },
          ),
          SwitchListTile(
            title: const Text('Biyometri (uygulama kilidi)'),
            subtitle: Text(_canBio
                ? 'Parmak izi / yüz ile kilit aç'
                : 'Bu cihazda biyometri yok veya kayıtlı değil'),
            secondary: const Icon(Icons.fingerprint_rounded),
            value: _bio && _canBio,
            onChanged: !_canBio
                ? null
                : (v) async {
                    await AuthService.setBiometricsEnabled(v);
                    await _reload();
                  },
          ),
        ],
        SwitchListTile(
          title: const Text('Biyometri (kasa)'),
          subtitle: Text(_canBio
              ? 'Kasa PIN yerine parmak izi / yüz'
              : 'Bu cihazda biyometri yok veya kayıtlı değil'),
          secondary: const Icon(Icons.fingerprint_outlined),
          value: _vaultBio && _canBio,
          onChanged: !_canBio
              ? null
              : (v) async {
                  await AuthService.setVaultBiometricsEnabled(v);
                  await _reload();
                },
        ),
      ],
    );
  }
}
