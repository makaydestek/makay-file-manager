import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../utils/debug_log.dart';
import '../widgets/apk_install_dialog.dart';

/// Kullanıcının süren bir indirmeyi/önizlemeyi durdurmasını sağlayan basit
/// iptal belirteci.
///
/// Servis katmanlarındaki transferler (FTP/SMB/SFTP/WebDAV/bulut) tek tek
/// `CancelToken` parametresi almadığından iptal, **hedef dosya izlenerek**
/// uygulanır: belirteç iptal edilirse yazma döngüsü durdurur, kısmi dosya
/// silinir ve [TransferCancelled] fırlatılır.
class RemoteCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;

  /// İptal edilmişse [TransferCancelled] fırlatır.
  void check() {
    if (_cancelled) throw const TransferCancelled();
  }
}

/// Kullanıcı işlemi iptal etti.
class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'İptal edildi';
}

/// Uzak sunucudan (FTP/SFTP/SMB/WebDAV) dosya indirme akışı.
///
/// İki saha şikâyetini birlikte çözer:
///
///  1. Dosyalar `systemTemp` (uygulama özel önbellek) altına iniyordu;
///     kullanıcı cihazın dosya yöneticisinde indirilen dosyayı göremiyordu.
///     Artık Android'de **herkese açık Download klasörü** hedeflenir.
///  2. `.apk` dosyası indikten sonra yalnız "İndirildi" bildirimi
///     çıkıyordu; artık indirme biter bitmez **Kur / Güncelle**
///     diyaloğu (Android kurucusu) açılır.
///
/// Hedef dizin yazılamazsa (izin/taşma) sessizce uygulama önbelleğine
/// düşülür — indirme yine tamamlanır.
class RemoteDownload {
  const RemoteDownload._();

  /// Dosya adı APK mı? (uzantı büyük/küçük harf duyarsız)
  static bool isApk(String fileName) =>
      fileName.toLowerCase().endsWith('.apk');

  /// İndirme hedefi: Android'de herkese açık Download, değilse önbellek.
  static Directory targetDir() {
    if (Platform.isAndroid) {
      final public = Directory('/storage/emulated/0/Download');
      try {
        public.createSync(recursive: true);
        if (public.existsSync() && Directory(public.path).existsSync()) {
          return public;
        }
      } catch (e) {
        logSwallowed('uzak indirme: Download klasörü', e);
      }
    }
    final cache = Directory('${Directory.systemTemp.path}/makay_downloads');
    cache.createSync(recursive: true);
    return cache;
  }

  /// Uzak sunucudan gelen adı güvenli tek bir dosya adına indirger.
  ///
  /// Ad FTP/SMB/SFTP/WebDAV yanıtından gelir; kötü niyetli sunucu
  /// `../../data/evil.apk` gibi bir ad döndürerek hedef klasör DIŞINA
  /// yazdırabilirdi. Yol ayırıcıları atılır, `..`/`.` ve Windows'ta yasak
  /// karakterler temizlenir.
  static String sanitizeFileName(String fileName) {
    var name = fileName.replaceAll('\\', '/').split('/').last.trim();
    name = name.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
    name = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (name.isEmpty || name == '.' || name == '..') {
      name = 'indirilen_${DateTime.now().millisecondsSinceEpoch}';
    }
    return name;
  }

  /// Ad çakışmasını çözerek yazılacak dosya yolunu üretir.
  ///
  /// Aynı adlı dosya varsa `ad (2).apk`, `ad (3).apk` ... — önceki
  /// indirmeler silinmeden korunur.
  static File uniqueTarget(Directory dir, String fileName) {
    final safeName = sanitizeFileName(fileName);
    var candidate = File('${dir.path}${Platform.pathSeparator}$safeName');
    if (!candidate.existsSync()) return candidate;
    final dot = safeName.lastIndexOf('.');
    final base = dot > 0 ? safeName.substring(0, dot) : safeName;
    final ext = dot > 0 ? safeName.substring(dot) : '';
    for (var i = 2; i < 1000; i++) {
      final next = File(
          '${dir.path}${Platform.pathSeparator}$base ($i)$ext');
      if (!next.existsSync()) return next;
    }
    return candidate;
  }

  /// Ortak akış: ilerleme göstergesi (İptal düğmeli) → [transfer] → APK ise
  /// kurulum diyaloğu, değilse "İndirildi" bildirimi.
  ///
  /// [context] kullanım ömrü bitmişse (ekran kapandıysa) işlem sessizce
  /// sonlandırılır; hata kullanıcıya bildirilir.
  static Future<void> run(
    BuildContext context, {
    required String fileName,
    required Future<void> Function(File target, RemoteCancelToken token)
        transfer,
  }) async {
    if (!context.mounted) return;
    final target = uniqueTarget(targetDir(), fileName);
    final token = RemoteCancelToken();

    final navigator = Navigator.of(context, rootNavigator: true);
    final messenger = ScaffoldMessenger.of(context);
    // İlerleme diyaloğu: artık kapatılabilir ve İptal düğmesi vardır.
    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text('İndiriliyor: ${sanitizeFileName(fileName)}',
                  maxLines: 2, overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                token.cancel();
                Navigator.of(ctx).pop();
              },
              child: const Text('İptal'),
            ),
          ],
        ),
      ),
    ));

    try {
      await transfer(target, token);
      if (token.isCancelled) throw const TransferCancelled();
      if (navigator.canPop()) navigator.pop(); // ilerleme göstergesi

      if (isApk(fileName)) {
        // İstenen davranış: APK'ya dokununca doğrudan Kur/Güncelle.
        if (context.mounted) await showApkInstallDialog(context, target);
      } else {
        messenger.showSnackBar(
          SnackBar(
            content: Text('İndirildi: ${target.path}'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (navigator.canPop()) navigator.pop(); // ilerleme göstergesi
      // İptalde kısmi dosya kalmaz.
      try {
        if (await target.exists()) await target.delete();
      } catch (_) {}
      messenger.showSnackBar(
        SnackBar(
          content: Text(e is TransferCancelled
              ? 'İndirme iptal edildi'
              : 'İndirme başarısız: $e'),
        ),
      );
    }
  }
}
