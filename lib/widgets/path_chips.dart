import 'dart:io';

import 'package:flutter/material.dart';

/// Tıklanabilir üst klasör şeridi (breadcrumb yerine kompakt yol duygusu).
///
/// Kökten geçerli yola kadar segmentler; son segment seçili görünümdedir.
/// Derin yollarda baştan kırpılır (… + son N parça).
class PathChips extends StatelessWidget {
  const PathChips({
    super.key,
    required this.rootPath,
    required this.currentPath,
    required this.onNavigate,
    this.maxSegments = 4,
  });

  final String rootPath;
  final String currentPath;
  final ValueChanged<String> onNavigate;
  final int maxSegments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segments = _segments();
    if (segments.isEmpty) return const SizedBox.shrink();

    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
      child: SizedBox(
        height: 40,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          itemCount: segments.length,
          separatorBuilder: (_, _) => Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: theme.colorScheme.outline,
          ),
          itemBuilder: (context, index) {
            final seg = segments[index];
            final isLast = index == segments.length - 1;
            return ActionChip(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              label: Text(
                seg.label,
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: isLast ? FontWeight.w600 : FontWeight.w400,
                  color: isLast
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurface,
                ),
              ),
              onPressed: isLast ? null : () => onNavigate(seg.path),
            );
          },
        ),
      ),
    );
  }

  List<({String label, String path})> _segments() {
    final sep = Platform.pathSeparator;
    final root = _norm(rootPath);
    final cur = _norm(currentPath);
    if (root.isEmpty || cur.isEmpty) return const [];
    if (!cur.startsWith(root)) {
      final parts = cur.split(sep).where((s) => s.isNotEmpty).toList();
      final name = parts.isEmpty ? cur : parts.last;
      return [(label: name, path: cur)];
    }

    final out = <({String label, String path})>[
      (label: 'Kök', path: root),
    ];
    if (cur == root) return out;

    final rest = cur.substring(root.length);
    final parts =
        rest.split(sep).where((p) => p.isNotEmpty).toList(growable: false);
    var acc = root;
    for (final p in parts) {
      acc = acc.endsWith(sep) ? '$acc$p' : '$acc$sep$p';
      out.add((label: p, path: acc));
    }

    if (out.length <= maxSegments) return out;
    // Baştan kırp: Kök … a / b / c
    final keep = out.sublist(out.length - (maxSegments - 1));
    return [
      (label: '…', path: keep.first.path),
      ...keep,
    ];
  }

  static String _norm(String path) {
    if (path.isEmpty) return path;
    final sep = Platform.pathSeparator;
    var p = path.replaceAll('/', sep).replaceAll('\\', sep);
    while (p.length > 1 && p.endsWith(sep)) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }
}
