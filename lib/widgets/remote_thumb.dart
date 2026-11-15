import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/remote_item.dart';
import '../services/remote_preview.dart';
import '../services/remote_thumb_limiter.dart';

/// Uzak dosya/klasör küçük resmi veya tür ikonu.
class RemoteThumb extends StatefulWidget {
  const RemoteThumb({
    super.key,
    required this.item,
    required this.locationKey,
    this.fetchBytes,
    this.size = 44,
    this.fill = false,
  });

  final RemoteItem item;
  final String locationKey;

  /// Resim küçük önizlemesi için bayt indirici (yoksa yalnız ikon).
  final Future<Uint8List> Function()? fetchBytes;

  final double size;
  final bool fill;

  @override
  State<RemoteThumb> createState() => _RemoteThumbState();
}

class _RemoteThumbState extends State<RemoteThumb> {
  Uint8List? _bytes;
  bool _tried = false;

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(covariant RemoteThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.remotePath != widget.item.remotePath) {
      _bytes = null;
      _tried = false;
      _maybeLoad();
    }
  }

  Future<void> _maybeLoad() async {
    if (_tried) return;
    _tried = true;
    final fetch = widget.fetchBytes;
    if (fetch == null || widget.item.isDir || !widget.item.isImage) return;
    // Büyük fotoğraflar listeyi dondurmasın — 1.5 MB üstü ikon kalsın.
    if (widget.item.size > 1536 * 1024) return;
    final bytes = await RemoteThumbLimiter.instance.runBytes(
      () => RemotePreview.thumbnailBytes(
        locationKey: widget.locationKey,
        remotePath: widget.item.remotePath,
        fileName: widget.item.name,
        remoteSize: widget.item.size,
        fetch: fetch,
        maxBytes: 1536 * 1024,
      ),
    );
    if (!mounted || bytes == null) return;
    setState(() => _bytes = bytes);
  }

  IconData get _icon {
    if (widget.item.isDir) return Icons.folder_rounded;
    if (widget.item.isImage) return Icons.image_rounded;
    if (widget.item.isVideo) return Icons.videocam_rounded;
    if (widget.item.isAudio) return Icons.audiotrack_rounded;
    if (widget.item.extension == 'apk') return Icons.android_rounded;
    return Icons.insert_drive_file_rounded;
  }

  Color get _color {
    if (widget.item.isDir) return const Color(0xFFFFB300);
    if (widget.item.isImage) return const Color(0xFF8E24AA);
    if (widget.item.isVideo) return const Color(0xFFD32F2F);
    if (widget.item.isAudio) return const Color(0xFF00897B);
    return const Color(0xFF757575);
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(widget.fill ? 12 : 8);
    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.12),
        borderRadius: radius,
      ),
      child: Center(
        child: Icon(_icon, color: _color, size: widget.fill ? 40 : 26),
      ),
    );

    Widget child;
    if (_bytes != null) {
      child = ClipRRect(
        borderRadius: radius,
        child: Image.memory(
          _bytes!,
          fit: BoxFit.cover,
          width: widget.fill ? double.infinity : widget.size,
          height: widget.fill ? double.infinity : widget.size,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
    } else {
      child = fallback;
    }

    if (widget.item.isVideo && !widget.item.isDir) {
      child = Stack(
        fit: StackFit.expand,
        children: [
          child,
          Center(
            child: Icon(
              Icons.play_circle_fill_rounded,
              size: widget.fill ? 36 : 22,
              color: const Color(0x99000000),
            ),
          ),
        ],
      );
    }

    if (widget.fill) {
      return ClipRRect(borderRadius: radius, child: child);
    }
    return SizedBox(width: widget.size, height: widget.size, child: child);
  }
}
