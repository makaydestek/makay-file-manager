import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Tam ekran resim görüntüleyici (dosya, bellek baytları veya ağ URL).
class ImageViewerScreen extends StatelessWidget {
  const ImageViewerScreen({
    super.key,
    this.file,
    this.bytes,
    this.networkUrl,
    this.httpHeaders,
    this.title,
  });

  final File? file;
  final Uint8List? bytes;
  final Uri? networkUrl;
  final Map<String, String>? httpHeaders;
  final String? title;

  @override
  Widget build(BuildContext context) {
    // Kaynak yoksa çökme yerine okunabilir mesaj gösterilir.
    final hasImage = file != null || bytes != null || networkUrl != null;
    Widget imageChild;
    if (file != null) {
      imageChild =
          Image.file(file!, fit: BoxFit.contain, gaplessPlayback: true);
    } else if (bytes != null) {
      imageChild =
          Image.memory(bytes!, fit: BoxFit.contain, gaplessPlayback: true);
    } else if (networkUrl != null) {
      imageChild = Image.network(
        networkUrl!.toString(),
        headers: httpHeaders,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        errorBuilder: (_, _, _) => const Center(
          child: Text(
            'Resim yüklenemedi',
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    } else {
      imageChild = const SizedBox.shrink();
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: !hasImage
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Resim gösterilemedi:\ndosyaya erişilemedi',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            )
          : GestureDetector(
              onDoubleTap: () => Navigator.of(context).pop(),
              child: InteractiveViewer(
                maxScale: 8,
                minScale: 0.5,
                child: Center(child: imageChild),
              ),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Text(
            'Parmakla yakınlaştır • Çift dokunarak kapat',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
          ),
        ),
      ),
    );
  }
}
