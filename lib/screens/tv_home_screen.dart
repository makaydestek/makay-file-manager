import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/home_category.dart';
import '../providers/settings_provider.dart';
import '../services/category_size_service.dart';
import '../theme/app_theme.dart';
import '../widgets/app_drawer.dart';
import 'home_categories_screen.dart';

/// TV'ye özel ana ekran: odaklı büyük kart ızgarası, kumanda (D-pad)
/// ipuçları ve uzak tutma (overscan) güvenli kenar boşlukları.
class TvHomeScreen extends StatefulWidget {
  const TvHomeScreen({super.key});

  @override
  State<TvHomeScreen> createState() => _TvHomeScreenState();
}

class _TvHomeScreenState extends State<TvHomeScreen> {
  int _focusedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Kategori boyutları arka planda hesaplanır.
    CategorySizeService.refresh();
  }

  @override
  Widget build(BuildContext context) {
    // Dosya işlemleri kategori önbelleğini siler; ana ekrana her dönüşte
    // bayat etiketler tazelenir (bkz. HomeScreen.build).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) CategorySizeService.refresh();
    });
    final theme = Theme.of(context);
    // Ayar değiştiğinde ızgara anında yeniden kurulur.
    final settings = context.watch<SettingsProvider>();
    final viewStyle = settings.viewStyle;
    // Kullanıcının gizlediği kartlar TV ızgarasına da girmez.
    final categories = kHomeCategories
        .where((c) => settings.isCategoryVisible(c.id))
        .toList(growable: false);
    // Odak indeksi gizlenen kartlara kaymasın.
    if (_focusedIndex >= categories.length) _focusedIndex = 0;
    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('Makay Dosya Yöneticisi'),
        actions: [
          IconButton(
            tooltip: 'Kartları göster / gizle',
            icon: const Icon(Icons.tune_rounded, size: 30),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const HomeCategoriesScreen(),
              ),
            ),
          ),
          IconButton(
            tooltip: 'Ayarlar',
            icon: const Icon(Icons.settings_rounded, size: 30),
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      // Görünüm preset'i gradyan zemin çizebilir (bkz. home_screen).
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient(
            settings.appearance,
            Theme.of(context).brightness,
          ),
        ),
        child: Column(
        children: [
          const SizedBox(height: 12),
          // Odaklanan kartın adı büyük gösterilir.
          SizedBox(
            height: 40,
            child: Center(
              child: Text(
                categories.isEmpty
                    ? 'Tüm kartlar gizlendi'
                    : categories[_focusedIndex].title,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Görünüm düzeni ayarı (dikey/yatay sütun sayısı).
                final portrait =
                    constraints.maxHeight >= constraints.maxWidth;
                final columns = switch (viewStyle) {
                  'large' => portrait ? 2 : 3,
                  'medium' => portrait ? 3 : 4,
                  'small' => portrait ? 4 : 6,
                  _ => constraints.maxWidth > 1200 ? 5 : 4,
                };
                if (categories.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Göstermek istediğiniz kartları seçin.',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ),
                  );
                }
                return ValueListenableBuilder<Map<String, String>>(
                  valueListenable: CategorySizeService.labels,
                  builder: (context, sizes, _) => GridView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 48, vertical: 16),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 20,
                      crossAxisSpacing: 20,
                      childAspectRatio: 1.15,
                    ),
                    itemCount: categories.length,
                    itemBuilder: (context, index) => _TvCategoryCard(
                      key: ValueKey(categories[index].id),
                      category: categories[index],
                      label: sizes[categories[index].id],
                      autofocus: index == 0,
                      onFocus: (focused) {
                        if (focused && mounted) {
                          setState(() => _focusedIndex = index);
                        }
                      },
                    ),
                  ),
                );
              },
            ),
          ),
          // Kumanda ipuçları şeridi.
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: const [
                  _KeyHint(icon: Icons.gamepad_rounded, label: 'Gezin'),
                  SizedBox(width: 24),
                  _KeyHint(
                      icon: Icons.radio_button_checked_rounded, label: 'Aç'),
                  SizedBox(width: 24),
                  _KeyHint(icon: Icons.arrow_back_rounded, label: 'Geri'),
                  SizedBox(width: 24),
                  _KeyHint(icon: Icons.menu_rounded, label: 'Menü'),
                ],
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }
}

class _KeyHint extends StatelessWidget {
  const _KeyHint({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Row(
      children: [
        Icon(icon, size: 18, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: 6),
        Text(label, style: style?.copyWith(color: Theme.of(context).colorScheme.outline)),
      ],
    );
  }
}

class _TvCategoryCard extends StatefulWidget {
  const _TvCategoryCard({
    super.key,
    required this.category,
    required this.onFocus,
    this.label,
    this.autofocus = false,
  });

  final HomeCategory category;
  final ValueChanged<bool> onFocus;

  /// Başlık altındaki özet (ör. "1,5 GB"); null ise gösterilmez.
  final String? label;
  final bool autofocus;

  @override
  State<_TvCategoryCard> createState() => _TvCategoryCardState();
}

class _TvCategoryCardState extends State<_TvCategoryCard> {
  bool _focused = false;

  /// TV kumandasındaki OK / DPAD_CENTER ve klavye Enter/Space.
  static bool _isActivateKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.accept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Ana ekrandaki tüm modül kartları bu widget'ı paylaşır; tek düzeltme
    // hepsini kapsar. GestureDetector yalnız dokunuşu alır; kumanda OK'si
    // odaklı Focus düğümüne KeyDownEvent olarak gelir (genelde select).
    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        widget.onFocus(focused);
      },
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && _isActivateKey(event.logicalKey)) {
          _open();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: _open,
        child: AnimatedScale(
          scale: _focused ? 1.08 : 1.0,
          duration: const Duration(milliseconds: 140),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: _focused
                  ? widget.category.color.withValues(alpha: 0.18)
                  : theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _focused ? widget.category.color : Colors.transparent,
                width: 3,
              ),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: widget.category.color.withValues(alpha: 0.35),
                        blurRadius: 24,
                        spreadRadius: 2,
                      )
                    ]
                  : null,
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(widget.category.icon, size: 64,
                    color: widget.category.color),
                const SizedBox(height: 16),
                Text(
                  widget.category.title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: _focused ? FontWeight.bold : FontWeight.w500,
                  ),
                ),
                if (widget.label != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.label!,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: _focused
                          ? widget.category.color
                          : theme.colorScheme.outline,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _open() {
    final route = widget.category.route;
    if (route != null) {
      Navigator.of(context).pushNamed(route);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${widget.category.title} TV\'de açılıyor…')),
      );
    }
  }
}
