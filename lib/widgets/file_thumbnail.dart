import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../models/file_entry.dart';
import '../services/platform_service.dart';
import '../utils/folder_glyph.dart';

/// Dosya/klasör için satır ve ızgara önizlemesi.
///
/// Görsel geri düşme zinciri (yüklenemezse ikona atlar, hata fırlatmaz):
///
///  • **Resim** → dosyanın kendisi küçük çözünürlükte (`cacheWidth`) belleğe
///    alınır; bozuk dosyada renkli tip ikonu gösterilir.
///  • **Video** → platform kanalından ilk kare JPEG (`MediaMetadataRetriever`);
///    okunamazsa video ikonu + oynatma rozeti.
///  • **Diğer** → renkli tip ikonu (klasör, ses, belge, arşiv, apk, ...).
class FileThumbnail extends StatelessWidget {
  const FileThumbnail({
    super.key,
    required this.entry,
    this.size = 40,
    this.borderRadius = 8,
  });

  final FileEntry entry;

  /// Kenar uzunluğu (kare önizleme).
  final double size;

  /// Yuvarlatılmış köşe yarıçapı.
  final double borderRadius;

  /// Video karesi isteği yalnızca **bir kez** yapılır.
  ///
  /// Future `build` içinde üretilirse her rebuild'te yeniden oluşur ve
  /// FutureBuilder `waiting`e döner: görsel titrer, her seferinde
  /// MediaMetadataRetriever ile video açılıp ilk kare decode edilir (tarayıcı
  /// listesinde her setState bunu tetikliyordu).
  static final Map<String, Future<Uint8List?>> _videoFutures = {};

  Future<Uint8List?>? _videoFuture(String path) {
    if (!PlatformService.supported) return null;
    if (PlatformService.cachedVideoThumbnail(path) != null) return null;
    return _videoFutures.putIfAbsent(
        path, () => PlatformService.videoThumbnail(path));
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(borderRadius);
    switch (entry.kind) {
      case FileKind.image:
        return ClipRRect(
          borderRadius: radius,
          child: Image.file(
            File(entry.path),
            width: size,
            height: size,
            fit: BoxFit.cover,
            // Bellek: çözünürlük önizleme boyutuna indirgenir.
            cacheWidth: (size * 2.5).round(),
            errorBuilder: (_, _, _) => _fallback(radius),
          ),
        );
      case FileKind.video:
        return ClipRRect(
          borderRadius: radius,
          child: SizedBox(
            width: size,
            height: size,
            child: FutureBuilder<Uint8List?>(
              // Önce önbellek; değilse platformdan ilk kare (memoize edilmiş).
              future: _videoFuture(entry.path),
              builder: (context, snapshot) {
                final bytes = snapshot.data ??
                    PlatformService.cachedVideoThumbnail(entry.path);
                if (bytes == null) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return _fallback(radius);
                  }
                  return _videoFallback(radius);
                }
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _videoFallback(radius),
                    ),
                    // Oynatma rozeti: "bu bir video" bilgisi.
                    Center(
                      child: Icon(
                        Icons.play_circle_fill_rounded,
                        size: size * 0.42,
                        color: Colors.black.withValues(alpha: 0.45),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      case FileKind.folder:
        // Referans görünümü: dolu amber klasör + bilinen adlarda iç simge.
        return _folderBadge(radius);
      default:
        return _fallback(radius);
    }
  }

  /// Klasör rozeti: amber klasör ikonunun üzerine iç simge (varsa).
  Widget _folderBadge(BorderRadius radius) {
    final glyph = FolderGlyph.of(entry.name);
    if (glyph == null) {
      return SizedBox(
        width: size,
        height: size,
        child: Icon(Icons.folder_rounded, size: size * 0.92, color: entry.color),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.folder_rounded, size: size * 0.92, color: entry.color),
          // Simge klasörün gövdesinde (ikon kutusunun orta hizasında).
          Align(
            alignment: const Alignment(0, 0.14),
            child: Icon(glyph, size: size * 0.34, color: Colors.white),
          ),
        ],
      ),
    );
  }

  /// Renkli tip ikonu (görsel değil ya da görsel okunamadı).
  Widget _fallback(BorderRadius radius) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: entry.color.withValues(alpha: 0.12),
          borderRadius: radius,
        ),
        alignment: Alignment.center,
        child: Icon(entry.icon, size: size * 0.55, color: entry.color),
      );

  /// Video geri düşmesi: ikon + küçük oynatma rozeti.
  Widget _videoFallback(BorderRadius radius) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: entry.color.withValues(alpha: 0.12),
          borderRadius: radius,
        ),
        alignment: Alignment.center,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Icon(entry.icon, size: size * 0.5, color: entry.color),
            Positioned(
              right: size * 0.12,
              bottom: size * 0.12,
              child: Icon(
                Icons.play_arrow_rounded,
                size: size * 0.32,
                color: entry.color,
              ),
            ),
          ],
        ),
      );
}
