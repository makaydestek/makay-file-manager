import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../screens/image_viewer_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../utils/debug_log.dart';
import '../utils/file_opener.dart';

/// Uzak dosyanın (FTP/SFTP/SMB/WebDAV) indirmeden önizlenmesi.
///
/// F Dosya Yöneticisi benzeri akış: medya tıklanınca **İndirilenler**
/// klasörüne yazılmaz; uygulama önbelleğine alınır ve yerleşik
/// görüntüleyici/oynatıcı açılır. Kalıcı indirme [RemoteDownload] ile ayrıdır.
class RemotePreview {
  const RemotePreview._();

  /// Önizlenebilir medya mı? (resim / video / ses)
  static bool isPreviewable(String fileName) {
    final ext = _ext(fileName);
    return kImageExts.contains(ext) ||
        kVideoExts.contains(ext) ||
        kAudioExts.contains(ext);
  }

  static bool isImage(String fileName) => kImageExts.contains(_ext(fileName));

  static bool isVideo(String fileName) => kVideoExts.contains(_ext(fileName));

  static bool isAudio(String fileName) => kAudioExts.contains(_ext(fileName));

  static String _ext(String fileName) {
    final i = fileName.lastIndexOf('.');
    return i > 0 ? fileName.substring(i + 1).toLowerCase() : '';
  }

  /// Bağlantı + uzak yol için kararlı önbellek anahtarı.
  static String cacheKey({
    required String locationKey,
    required String remotePath,
  }) {
    final digest = sha1.convert(utf8.encode('$locationKey|$remotePath'));
    return digest.toString();
  }

  /// Uygulama özel önizleme klasörü (kullanıcıya görünmez).
  static Future<Directory> cacheDir() async {
    final root = await getTemporaryDirectory();
    final dir = Directory('${root.path}${Platform.pathSeparator}makay_remote_preview');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  /// Önbellekteki dosya yolu (varsa).
  static Future<File> cacheFileFor({
    required String locationKey,
    required String remotePath,
    required String fileName,
  }) async {
    final dir = await cacheDir();
    final key = cacheKey(locationKey: locationKey, remotePath: remotePath);
    final safeExt = _ext(fileName);
    final name = safeExt.isEmpty ? key : '$key.$safeExt';
    return File('${dir.path}${Platform.pathSeparator}$name');
  }

  /// [transfer] ile önbelleğe alır (zaten varsa atlar) ve görüntüleyiciyi açar.
  ///
  /// [networkUrl] verilirse (WebDAV) indirmeden doğrudan ağdan açılır;
  /// başarısız olursa [transfer] yedeğine düşülür.
  ///
  /// [context] kullanımı bitmişse sessizce çıkar. Hata SnackBar ile bildirilir.
  static Future<void> open(
    BuildContext context, {
    required String fileName,
    required String locationKey,
    required String remotePath,
    required Future<void> Function(File target) transfer,
    Future<Uint8List> Function()? transferBytes,
    Uri? networkUrl,
    Map<String, String>? httpHeaders,
  }) async {
    if (!context.mounted) return;
    if (!isPreviewable(fileName)) return;

    // WebDAV vb.: önce ağ akışı / ağ resmi dene.
    if (networkUrl != null) {
      if (isImage(fileName)) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(
              networkUrl: networkUrl,
              httpHeaders: httpHeaders,
              title: fileName,
            ),
          ),
        );
        return;
      }
      if (isVideo(fileName) || isAudio(fileName)) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              contentUri: networkUrl,
              httpHeaders: httpHeaders,
              isVideo: isVideo(fileName),
              title: fileName,
            ),
          ),
        );
        return;
      }
    }

    final target = await cacheFileFor(
      locationKey: locationKey,
      remotePath: remotePath,
      fileName: fileName,
    );
    if (!context.mounted) return;

    // İptal: geçici önizleme dosyası silinir ve dialoğ kapanır. (Büyük bir
    // videoda kullanıcı artık beklemek zorunda değil.)
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Önizleme hazırlanıyor…'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                cancelled = true;
                Navigator.of(ctx).pop();
              },
              child: const Text('İptal'),
            ),
          ],
        ),
      ),
    );

    try {
      if (!target.existsSync() || target.lengthSync() == 0) {
        // Küçük resimler için bellek yolu (isteğe bağlı); aksi halde dosya.
        if (transferBytes != null && isImage(fileName)) {
          final bytes = await transferBytes();
          await target.writeAsBytes(bytes, flush: true);
        } else {
          await transfer(target);
        }
      }
      if (cancelled || !context.mounted) {
        // Kullanıcı vazgeçti: kısmi/indirilmiş geçici dosya kalmamalı.
        try {
          if (target.existsSync()) target.deleteSync();
        } catch (_) {}
        return;
      }
      Navigator.of(context).pop(); // ilerleme

      if (isImage(fileName)) {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(file: target, title: fileName),
          ),
        );
      } else {
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => MediaViewerScreen(
              file: target,
              isVideo: isVideo(fileName),
              title: fileName,
            ),
          ),
        );
      }
    } catch (e) {
      logSwallowed('uzak önizleme', e);
      if (!context.mounted) return;
      Navigator.of(context).pop(); // ilerleme
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Önizleme açılamadı: $e')),
      );
    }
  }

  /// Küçük resim baytları (önbellekten veya [fetch] ile).
  ///
  /// Büyük dosyalarda ([maxBytes] üstü) null döner — tam indirme yapılmaz.
  static Future<Uint8List?> thumbnailBytes({
    required String locationKey,
    required String remotePath,
    required String fileName,
    required int? remoteSize,
    required Future<Uint8List> Function() fetch,
    int maxBytes = 2 * 1024 * 1024,
  }) async {
    if (!isImage(fileName)) return null;
    if (remoteSize != null && remoteSize > maxBytes) return null;
    try {
      final cached = await cacheFileFor(
        locationKey: locationKey,
        remotePath: remotePath,
        fileName: fileName,
      );
      if (cached.existsSync() && cached.lengthSync() > 0) {
        return await cached.readAsBytes();
      }
      final bytes = await fetch();
      if (bytes.length <= maxBytes) {
        await cached.writeAsBytes(bytes, flush: true);
      }
      return bytes.length <= maxBytes ? bytes : null;
    } catch (e) {
      logSwallowed('uzak küçük resim', e);
      return null;
    }
  }
}
