import 'package:flutter/material.dart';

import '../services/platform_service.dart';
import '../theme/app_theme.dart';
import '../widgets/tv_focusable.dart';
import 'browser_screen.dart';

/// USB / SD kart ekranı: bağlı depolama birimlerini (OTG, SD kart, dahili
/// birimler) listeler; dokunulunca dosya tarayıcısıyla gezinilir.
class UsbStorageScreen extends StatefulWidget {
  const UsbStorageScreen({super.key});

  @override
  State<UsbStorageScreen> createState() => _UsbStorageScreenState();
}

class _UsbStorageScreenState extends State<UsbStorageScreen> {
  List<StorageVolumeInfo> _volumes = [];
  bool _loading = true;
  bool _supported = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final volumes = await PlatformService.storageVolumes();
    if (!mounted) return;
    setState(() {
      _volumes = volumes;
      _supported = PlatformService.supported;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Dahili (emüle edilmemiş) birimler hariç; bunlar zaten "Ana bellek"te.
    final external =
        _volumes.where((v) => !v.isEmulated).toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('USB / SD Kart'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Yenile',
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : !_supported
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'Bu platformda depolama birimi algılanamıyor.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : external.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.usb_off_rounded,
                                size: 56, color: theme.disabledColor),
                            const SizedBox(height: 12),
                            const Text(
                              'Bağlı harici depolama bulunamadı.\n'
                              'USB bellek veya SD kart taktığınızda '
                              'burada görünür.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    )
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: ListView(
                        padding: const EdgeInsets.all(12),
                        children: [
                          Text('Bağlı birimler',
                              style: theme.textTheme.titleSmall),
                          const SizedBox(height: 8),
                          for (var i = 0; i < external.length; i++)
                            Builder(builder: (context) {
                              final volume = external[i];
                              void open() {
                                if (!volume.isMounted || volume.path.isEmpty) {
                                  return;
                                }
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (_) => BrowserScreen(
                                      title: volume.description.isEmpty
                                          ? 'USB / SD'
                                          : volume.description,
                                      rootPath: volume.path,
                                    ),
                                  ),
                                );
                              }

                              return TvFocusable(
                                autofocus: i == 0,
                                onActivate: open,
                                scale: 1.02,
                                child: Card(
                                  child: ListTile(
                                    leading: Icon(
                                      volume.isRemovable
                                          ? Icons.sd_card_rounded
                                          : Icons.storage_rounded,
                                      color: AppTheme.accent,
                                      size: 32,
                                    ),
                                    title: Text(volume.description.isEmpty
                                        ? 'Depolama birimi'
                                        : volume.description),
                                    subtitle: Text(
                                      volume.isMounted
                                          ? (volume.path.isEmpty
                                              ? 'Bağlı'
                                              : volume.path)
                                          : 'Bağlı değil (${volume.state})',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    trailing: const Icon(
                                        Icons.chevron_right_rounded),
                                    onTap: !volume.isMounted ||
                                            volume.path.isEmpty
                                        ? null
                                        : open,
                                  ),
                                ),
                              );
                            }),
                        ],
                      ),
                    ),
    );
  }
}
