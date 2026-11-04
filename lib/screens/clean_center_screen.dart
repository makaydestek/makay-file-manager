import 'package:flutter/material.dart';

import '../services/clean_suggestion_service.dart';
import '../theme/app_theme.dart';
import '../utils/app_paths.dart';
import '../utils/formats.dart';
import '../widgets/tv_focusable.dart';
import 'duplicate_files_screen.dart';
import 'large_files_screen.dart';
import 'temp_cleaner_screen.dart';

/// Temizlik merkezi: öneriler + mevcut temizleme araçlarına tek giriş.
class CleanCenterScreen extends StatefulWidget {
  const CleanCenterScreen({super.key});

  @override
  State<CleanCenterScreen> createState() => _CleanCenterScreenState();
}

class _CleanCenterScreenState extends State<CleanCenterScreen> {
  static const _svc = CleanSuggestionService();
  List<CleanSuggestion> _items = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final items = await _svc.suggestions();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loading = false;
    });
  }

  IconData _icon(String key) => switch (key) {
        'cleaning' => Icons.cleaning_services_rounded,
        'large' => Icons.insert_drive_file_rounded,
        'dup' => Icons.copy_all_rounded,
        'downloads' => Icons.download_rounded,
        _ => Icons.tips_and_updates_rounded,
      };

  void _open(CleanSuggestion s) {
    switch (s.route) {
      case '/temp':
        Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const TempCleanerScreen()),
        );
      case '/duplicates':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DuplicateFilesScreen(root: AppPaths.scanRoot),
          ),
        );
      case '/clean/large':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => const LargeFilesScreen(title: 'Büyük dosyalar'),
          ),
        );
      default:
        Navigator.of(context).pushNamed(s.route);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final estimable = CleanSuggestionService.estimableBytes(_items);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Temizlik merkezi'),
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
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    color: AppTheme.accent.withValues(alpha: 0.12),
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Akıllı temizlik önerileri',
                            style: theme.textTheme.titleLarge
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            estimable > 0
                                ? 'Tahmini kazanılabilir alan: ${Formats.size(estimable)}'
                                : 'Öneriler hazır — tek dokunuşla ilgili araca gidin',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Öneriler cihazınızdaki taramalara dayanır; '
                            'bulut tabanlı yapay zeka kullanılmaz.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('Öneriler', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  if (_items.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('Şu an belirgin bir temizlik önerisi yok'),
                      ),
                    )
                  else
                    for (var i = 0; i < _items.length; i++)
                      TvFocusable(
                        autofocus: i == 0,
                        onActivate: () => _open(_items[i]),
                        scale: 1.02,
                        child: Card(
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor:
                                  AppTheme.accent.withValues(alpha: 0.15),
                              child: Icon(_icon(_items[i].icon),
                                  color: AppTheme.accent),
                            ),
                            title: Text(_items[i].title),
                            subtitle: Text(
                              _items[i].bytes > 0
                                  ? '${_items[i].subtitle}\n${_items[i].sizeLabel}'
                                  : _items[i].subtitle,
                            ),
                            isThreeLine: _items[i].bytes > 0,
                            trailing: FilledButton.tonal(
                              onPressed: () => _open(_items[i]),
                              child: Text(_items[i].actionLabel),
                            ),
                            onTap: () => _open(_items[i]),
                          ),
                        ),
                      ),
                  const SizedBox(height: 16),
                  Text('Araçlar', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  TvFocusable(
                    onActivate: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const TempCleanerScreen()),
                    ),
                    scale: 1.02,
                    child: ListTile(
                      leading: const Icon(Icons.cleaning_services_rounded),
                      title: const Text('Geçici dosyalar'),
                      subtitle: const Text('Önbellek, .tmp, küçük resimler'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const TempCleanerScreen()),
                      ),
                    ),
                  ),
                  TvFocusable(
                    onActivate: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            DuplicateFilesScreen(root: AppPaths.scanRoot),
                      ),
                    ),
                    scale: 1.02,
                    child: ListTile(
                      leading: const Icon(Icons.copy_all_rounded),
                      title: const Text('Mükerrer dosyalar'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              DuplicateFilesScreen(root: AppPaths.scanRoot),
                        ),
                      ),
                    ),
                  ),
                  TvFocusable(
                    onActivate: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) =>
                            const LargeFilesScreen(title: 'Büyük dosyalar'),
                      ),
                    ),
                    scale: 1.02,
                    child: ListTile(
                      leading: const Icon(Icons.insert_drive_file_rounded),
                      title: const Text('Büyük dosyalar'),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              const LargeFilesScreen(title: 'Büyük dosyalar'),
                        ),
                      ),
                    ),
                  ),
                  TvFocusable(
                    onActivate: () =>
                        Navigator.of(context).pushNamed('/analysis'),
                    scale: 1.02,
                    child: ListTile(
                      leading: const Icon(Icons.donut_small_rounded),
                      title: const Text('Bellek analizi'),
                      onTap: () =>
                          Navigator.of(context).pushNamed('/analysis'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
