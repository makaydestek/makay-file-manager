import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_ui.dart';

/// TV / D-pad odak yardımcıları (F Dosya Yöneticisi tarzı).
class TvFocus {
  TvFocus._();

  /// Yön tuşlarıyla odak taşı: TextField imleç hareketi yerine alanlar arası
  /// geçiş (yukarı/aşağı/ileri/geri). Formlarda D-pad gezinmesi için.
  static KeyEventResult handleDirectional(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;

    if (node.focusInDirection(direction)) {
      return KeyEventResult.handled;
    }
    // Dikey formda sol/sağ komşu olmayabilir → okuma sırası.
    final forward = direction == TraversalDirection.down ||
        direction == TraversalDirection.right;
    final moved = forward ? node.nextFocus() : node.previousFocus();
    return moved ? KeyEventResult.handled : KeyEventResult.ignored;
  }
}

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

/// TV'de yön tuşlarıyla alanlar arası geçen [TextFormField].
///
/// Mobil/tablet'te düz [TextFormField]. TV'de ok tuşları imleci değil odağı
/// taşır (Dosya Yöneticisi form gezinmesi); odak halkası görünür.
class TvTextFormField extends StatefulWidget {
  const TvTextFormField({
    super.key,
    this.controller,
    this.focusNode,
    this.decoration = const InputDecoration(),
    this.validator,
    this.obscureText = false,
    this.keyboardType,
    this.autofocus = false,
    this.onFieldSubmitted,
    this.textInputAction,
    this.maxLength,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final InputDecoration decoration;
  final FormFieldValidator<String>? validator;
  final bool obscureText;
  final TextInputType? keyboardType;
  final bool autofocus;
  final ValueChanged<String>? onFieldSubmitted;
  final TextInputAction? textInputAction;
  final int? maxLength;

  @override
  State<TvTextFormField> createState() => _TvTextFormFieldState();
}

class _TvTextFormFieldState extends State<TvTextFormField> {
  FocusNode? _ownedNode;
  late FocusNode _node;
  bool _focused = false;

  /// [TvUi.enabled] `select` kullanır; yalnız build sırasında güvenli.
  /// Post-frame / tuş işleyicide bu bayrak kullanılır.
  bool _tv = false;

  FocusNode get _effectiveNode => widget.focusNode ?? _ownedNode!;

  @override
  void initState() {
    super.initState();
    _attachNode(widget.focusNode);
  }

  @override
  void didUpdateWidget(covariant TvTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      _detachNode(oldWidget.focusNode ?? _ownedNode);
      _attachNode(widget.focusNode);
    }
  }

  void _attachNode(FocusNode? external) {
    if (external == null) {
      _ownedNode = FocusNode(debugLabel: 'TvTextFormField');
      _node = _ownedNode!;
    } else {
      _ownedNode = null;
      _node = external;
    }
    _node.addListener(_onFocusChange);
  }

  void _detachNode(FocusNode? node) {
    if (node == null) return;
    node.removeListener(_onFocusChange);
    if (identical(node.onKeyEvent, _onKeyEvent)) {
      node.onKeyEvent = null;
    }
    if (identical(node, _ownedNode)) {
      node.dispose();
      _ownedNode = null;
    }
  }

  @override
  void dispose() {
    _detachNode(_effectiveNode);
    super.dispose();
  }

  /// EditableText içindeki [Focus], build sırasında `onKeyEvent`'i ezer.
  /// Çerçeve sonunda yeniden bağlarız; böylece D-pad imleçten önce gelir.
  void _ensureKeyHandler() {
    if (!mounted || !_tv) return;
    _node.onKeyEvent = _onKeyEvent;
  }

  void _onFocusChange() {
    final focused = _node.hasFocus;
    if (focused == _focused) return;
    setState(() => _focused = focused);
    if (focused) {
      _ensureKeyHandler();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_node.hasFocus) return;
        _ensureKeyHandler();
        Scrollable.ensureVisible(
          context,
          alignment: 0.35,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        );
      });
    }
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (!mounted || !_tv) return KeyEventResult.ignored;
    return TvFocus.handleDirectional(node, event);
  }

  @override
  Widget build(BuildContext context) {
    _tv = TvUi.enabled(context);
    if (_tv) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureKeyHandler());
    }

    final field = TextFormField(
      controller: widget.controller,
      focusNode: _node,
      decoration: widget.decoration,
      validator: widget.validator,
      obscureText: widget.obscureText,
      keyboardType: widget.keyboardType,
      autofocus: widget.autofocus,
      onFieldSubmitted: widget.onFieldSubmitted,
      textInputAction: widget.textInputAction,
      maxLength: widget.maxLength,
    );

    if (!_tv) return field;

    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused ? scheme.primary : Colors.transparent,
          width: 3,
        ),
        color: _focused
            ? scheme.primary.withValues(alpha: 0.10)
            : Colors.transparent,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: field,
    );
  }
}
