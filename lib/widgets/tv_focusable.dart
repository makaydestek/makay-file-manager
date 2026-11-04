import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_ui.dart';

/// TV kumandası için belirgin odak halkası (F Dosya Yöneticisi tarzı).
///
/// • TV kapalıysa [child] olduğu gibi döner — mobil/tablet etkilenmez.
/// • TV açıkken D-pad odağı bu sarmalayıcıdadır; içteki [ListTile] /
///   [InkWell] / [IconButton] odak sırasına girmez (`ExcludeFocus`), böylece
///   her satır tek adımda gezinilir ve OK ile [onActivate] çalışır.
/// • Odak görünür: 3 px birincil renk çerçeve + hafif dolgu + küçük ölçek.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    this.onActivate,
    this.autofocus = false,
    this.borderRadius = 12,
    this.scale = 1.03,
  });

  final Widget child;

  /// OK / Enter / Select — null ise yalnız görsel vurgu (iç çocuk tıklanır).
  final VoidCallback? onActivate;

  final bool autofocus;
  final double borderRadius;

  /// Odaktayken hafif büyüme (listelerde 1.02–1.04, kartlarda daha fazla).
  final double scale;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  static bool _isActivateKey(LogicalKeyboardKey key) =>
      key == LogicalKeyboardKey.select ||
      key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter ||
      key == LogicalKeyboardKey.space ||
      key == LogicalKeyboardKey.gameButtonA ||
      key == LogicalKeyboardKey.accept;

  void _activate() => widget.onActivate?.call();

  void _onFocusChange(bool focused) {
    setState(() => _focused = focused);
    if (focused) {
      // Liste/ızgarada odak kaybolmasın: satırı görünür alana kaydır.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_focused) return;
        final ctx = context;
        if (!ctx.mounted) return;
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.35,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!TvUi.enabled(context)) return widget.child;

    final scheme = Theme.of(context).colorScheme;
    // İç çocuklar (ListTile / InkWell / IconButton) D-pad sırasına girmez;
    // dokunma hâlâ çocuğun onTap'ine gider. Kumanda OK → onKeyEvent.
    final body = ExcludeFocus(child: widget.child);

    return Focus(
      autofocus: widget.autofocus,
      onFocusChange: _onFocusChange,
      onKeyEvent: (node, event) {
        if (widget.onActivate == null) return KeyEventResult.ignored;
        if (event is KeyDownEvent && _isActivateKey(event.logicalKey)) {
          _activate();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AnimatedScale(
        scale: _focused ? widget.scale : 1.0,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(
              color: _focused ? scheme.primary : Colors.transparent,
              width: 3,
            ),
            color: _focused
                ? scheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            boxShadow: _focused
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.35),
                      blurRadius: 16,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
          child: body,
        ),
      ),
    );
  }
}
