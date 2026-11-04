import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../services/platform_service.dart';
import '../utils/debug_log.dart';

/// Yerleşik medya oynatıcı (video ve ses).
///
/// F Dosya Yöneticisi benzeri akış:
/// 1. Dosya yolu veya Android `content://` URI ile ExoPlayer üzerinden oynatır.
/// 2. Codec/kapsayıcı uyumsuzluğunda hata gösterir ve **sistem oynatıcısıyla
///    aç** (Farklı aç) yedeği sunar — indirilen MKV/AVI vb. dışarıda açılabilir.
/// 3. Video: tam ekran, gizlenen denetimler, ±10 sn, döngü.
/// 4. Ses: sanat alanı + zaman çubuğu + aynı denetimler.
class MediaViewerScreen extends StatefulWidget {
  const MediaViewerScreen({
    super.key,
    this.file,
    this.contentUri,
    required this.isVideo,
    this.title,
  }) : assert(file != null || contentUri != null,
            'file veya contentUri gerekli');

  /// Yerel dosya (tarayıcı / indirme yolu).
  final File? file;

  /// Android MediaStore içerik URI'si (`content://media/...`).
  /// Albüm ekranından [AssetEntity.getMediaUrl] ile gelir; dosya kopyası
  /// başarısız olduğunda veya büyük videolarda tercih edilir.
  final Uri? contentUri;

  final bool isVideo;

  /// AppBar başlığı; verilmezse dosya adından üretilir.
  final String? title;

  @override
  State<MediaViewerScreen> createState() => _MediaViewerScreenState();
}

class _MediaViewerScreenState extends State<MediaViewerScreen> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  String? _error;
  bool _controlsVisible = true;
  bool _looping = false;
  bool _openingExternal = false;
  Timer? _hideTimer;

  String get _name {
    if (widget.title != null && widget.title!.trim().isNotEmpty) {
      return widget.title!.trim();
    }
    final file = widget.file;
    if (file != null) {
      final segments = file.uri.pathSegments.where((s) => s.isNotEmpty);
      if (segments.isNotEmpty) return segments.last;
      return file.path;
    }
    final uri = widget.contentUri;
    if (uri != null) {
      final segs = uri.pathSegments.where((s) => s.isNotEmpty);
      if (segs.isNotEmpty) return segs.last;
      return uri.toString();
    }
    return widget.isVideo ? 'Video' : 'Ses';
  }

  /// Sistem "Farklı aç" için yol veya URI.
  String? get _openPath => widget.file?.path;

  String? get _openUri {
    final u = widget.contentUri;
    if (u == null) return null;
    return u.toString();
  }

  @override
  void initState() {
    super.initState();
    // Video'da durum çubuğu karanlık kalsın (immersive geçişler için).
    if (widget.isVideo) {
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    }
    unawaited(_initPlayer());
  }

  Future<void> _initPlayer() async {
    setState(() {
      _initialized = false;
      _error = null;
    });

    // Android albüm medyasında content:// genelde daha güvenilir (büyük
    // dosya kopyası / scoped storage). Dosya yolu ikinci sırada denenir.
    final attempts = <Future<VideoPlayerController> Function()>[];

    final uri = widget.contentUri;
    if (uri != null && Platform.isAndroid && uri.scheme == 'content') {
      attempts.add(() async => VideoPlayerController.contentUri(uri));
    }
    final file = widget.file;
    if (file != null) {
      attempts.add(() async => VideoPlayerController.file(file));
    }
    // content URI Android dışı veya file:// ise network/file olarak dene.
    if (uri != null &&
        !(Platform.isAndroid && uri.scheme == 'content') &&
        file == null) {
      if (uri.scheme == 'file') {
        attempts.add(() async => VideoPlayerController.file(File(uri.toFilePath())));
      } else {
        attempts.add(() async => VideoPlayerController.networkUrl(uri));
      }
    }

    Object? lastError;
    for (final build in attempts) {
      VideoPlayerController? c;
      try {
        c = await build();
        await c.initialize();
        if (!mounted) {
          await c.dispose();
          return;
        }
        await _controller?.dispose();
        _controller = c
          ..setLooping(_looping)
          ..addListener(_onTick);
        setState(() {
          _initialized = true;
          _error = null;
        });
        await c.play();
        _scheduleHideControls();
        return;
      } catch (e) {
        lastError = e;
        logSwallowed('medya oynatıcı: başlatma', e);
        try {
          await c?.dispose();
        } catch (_) {}
      }
    }

    if (!mounted) return;
    setState(() {
      _error = lastError?.toString() ?? 'Medya kaynağı açılamadı';
      _initialized = false;
    });
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  void _scheduleHideControls() {
    _hideTimer?.cancel();
    if (!widget.isVideo) return;
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      final c = _controller;
      if (c != null && c.value.isPlaying && _controlsVisible) {
        setState(() => _controlsVisible = false);
        _setImmersive(true);
      }
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    _setImmersive(!_controlsVisible && widget.isVideo);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _setImmersive(bool immersive) {
    if (immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Future<void> _openExternal() async {
    if (_openingExternal) return;
    setState(() => _openingExternal = true);
    try {
      final ok = await PlatformService.openWith(
        path: _openPath,
        uri: _openUri,
      );
      if (!mounted) return;
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sistem oynatıcısı açılamadı'),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _openingExternal = false);
    }
  }

  Future<void> _seekBy(Duration delta) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = c.value.position + delta;
    final max = c.value.duration;
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > max ? max : target);
    await c.seekTo(clamped);
    _scheduleHideControls();
  }

  Future<void> _toggleLoop() async {
    final next = !_looping;
    setState(() => _looping = next);
    await _controller?.setLooping(next);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _controller?.removeListener(_onTick);
    _controller?.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _controlsVisible || _error != null || !_initialized
          ? AppBar(
              backgroundColor: Colors.black,
              foregroundColor: Colors.white,
              title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: [
                IconButton(
                  tooltip: _looping ? 'Döngü açık' : 'Döngü',
                  onPressed: _initialized ? _toggleLoop : null,
                  icon: Icon(
                    Icons.repeat_rounded,
                    color: _looping ? Colors.tealAccent : Colors.white70,
                  ),
                ),
                IconButton(
                  tooltip: 'Farklı aç',
                  onPressed: _openingExternal ? null : _openExternal,
                  icon: _openingExternal
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.open_in_new_rounded),
                ),
              ],
            )
          : null,
      body: Center(
        child: _error != null
            ? _errorBody()
            : !_initialized
                ? const CircularProgressIndicator()
                : widget.isVideo
                    ? _videoBody()
                    : _audioBody(),
      ),
    );
  }

  Widget _errorBody() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded,
              color: Colors.white70, size: 48),
          const SizedBox(height: 16),
          Text(
            'Bu dosya yerleşik oynatıcıda açılamadı.\n'
            'Cihaz kodeği veya biçim desteklenmiyor olabilir.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 8),
          Text(
            _error!,
            textAlign: TextAlign.center,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _openingExternal ? null : _openExternal,
            icon: const Icon(Icons.play_circle_outline_rounded),
            label: const Text('Sistem oynatıcısıyla aç'),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _initPlayer,
            child: const Text('Yeniden dene',
                style: TextStyle(color: Colors.white70)),
          ),
        ],
      ),
    );
  }

  Widget _videoBody() {
    final c = _controller!;
    final v = c.value;
    final ratio = v.aspectRatio == 0 ? 16 / 9 : v.aspectRatio;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleControls,
      onDoubleTapDown: (details) {
        final w = MediaQuery.sizeOf(context).width;
        if (details.localPosition.dx < w / 2) {
          unawaited(_seekBy(const Duration(seconds: -10)));
        } else {
          unawaited(_seekBy(const Duration(seconds: 10)));
        }
      },
      child: Stack(
        alignment: Alignment.center,
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: ratio,
              child: VideoPlayer(c),
            ),
          ),
          if (_controlsVisible) ...[
            Positioned.fill(
              child: Container(color: Colors.black45),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.replay_10_rounded,
                      color: Colors.white),
                  onPressed: () =>
                      unawaited(_seekBy(const Duration(seconds: -10))),
                ),
                IconButton(
                  iconSize: 72,
                  icon: Icon(
                    v.isPlaying
                        ? Icons.pause_circle_filled_rounded
                        : Icons.play_circle_fill_rounded,
                    color: Colors.white,
                  ),
                  onPressed: () {
                    v.isPlaying ? c.pause() : c.play();
                    _scheduleHideControls();
                  },
                ),
                IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.forward_10_rounded,
                      color: Colors.white),
                  onPressed: () =>
                      unawaited(_seekBy(const Duration(seconds: 10))),
                ),
              ],
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(child: _controlsBar()),
            ),
          ],
        ],
      ),
    );
  }

  Widget _audioBody() {
    final c = _controller!;
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF00897B), Color(0xFF26A69A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(Icons.music_note_rounded,
                size: 96, color: Colors.white),
          ),
          const SizedBox(height: 24),
          Text(
            _name,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          const SizedBox(height: 16),
          _controlsBar(),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.replay_10_rounded, color: Colors.white),
                onPressed: () =>
                    unawaited(_seekBy(const Duration(seconds: -10))),
              ),
              IconButton(
                iconSize: 64,
                icon: Icon(
                  c.value.isPlaying
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: Colors.white,
                ),
                onPressed: () {
                  c.value.isPlaying ? c.pause() : c.play();
                },
              ),
              IconButton(
                iconSize: 40,
                icon: const Icon(Icons.forward_10_rounded, color: Colors.white),
                onPressed: () =>
                    unawaited(_seekBy(const Duration(seconds: 10))),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _controlsBar() {
    final c = _controller!;
    final v = c.value;
    final duration = v.duration;
    final maxMs =
        duration.inMilliseconds.toDouble().clamp(1.0, double.infinity).toDouble();
    final posMs = v.position.inMilliseconds
        .clamp(0, duration.inMilliseconds)
        .toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Text(
            _fmt(v.position),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          Expanded(
            child: Slider(
              value: posMs,
              max: maxMs,
              onChanged: (value) {
                c.seekTo(Duration(milliseconds: value.round()));
                _scheduleHideControls();
              },
            ),
          ),
          Text(
            _fmt(duration),
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
          IconButton(
            icon: Icon(
              v.volume > 0 ? Icons.volume_up_rounded : Icons.volume_off_rounded,
              color: Colors.white,
            ),
            onPressed: () {
              c.setVolume(v.volume > 0 ? 0 : 1);
              _scheduleHideControls();
            },
          ),
        ],
      ),
    );
  }
}
