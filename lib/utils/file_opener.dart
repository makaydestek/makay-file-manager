import 'dart:io';

import 'package:flutter/material.dart';

import '../models/file_entry.dart';
import '../services/archive_service.dart';
import '../screens/archive_screen.dart';
import '../screens/epub_viewer_screen.dart';
import '../screens/hex_viewer_screen.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/media_viewer_screen.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/sqlite_viewer_screen.dart';
import '../screens/text_editor_screen.dart';
import '../widgets/apk_install_dialog.dart';

/// Önizleme destekli dosya uzantıları.
const kImageExts = {
  'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'svg', 'heic', 'heif', 'tif',
  'tiff'
};
const kVideoExts = {
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', '3gp', 'm4v', 'ts', 'wmv',
  'mpg', 'mpeg', 'm2ts', 'mts', 'vob', 'f4v',
};
const kAudioExts = {
  'mp3', 'm4a', 'aac', 'flac', 'ogg', 'opus', 'wav', 'wma', 'amr', 'aiff',
  'aif', 'mid', 'midi',
};

/// Metin editörüyle açılan düz metin uzantıları.
const kTextExts = {
  'txt', 'md', 'log', 'csv', 'json', 'xml', 'yaml', 'yml', 'ini', 'conf',
  'cfg', 'toml', 'html', 'css', 'js', 'dart', 'kt', 'java', 'py', 'sh', 'bat',
  'gradle', 'properties', 'env', 'srt', 'vtt'
};

/// SQLite veritabanı uzantıları (salt okunur görüntüleyici).
const kSqliteExts = {'db', 'sqlite', 'sqlite3'};

/// Dahili PDF görüntüleyici.
const kPdfExts = {'pdf'};

/// Dahili EPUB okuyucu.
const kEpubExts = {'epub'};

/// Dosya türüne göre yerleşik görüntüleyiciyi açar.
///
/// Tarayıcı ve cihaz geneli arama ekranının **ortak** açma mantığı:
/// arşiv → arşiv görüntüleyici, resim → görüntüleyici, video/ses → medya
/// oynatıcı, metin → editör, SQLite → görüntüleyici, APK → Android kurucusu
/// (Kur/Güncelle). Desteklenmeyen türde [onUnsupported] çağrılır.
///
/// Dizinler burada açılmaz; gezinme çağıran ekranın işidir.
class FileOpener {
  const FileOpener._();

  static Future<void> openFile(
    BuildContext context,
    FileEntry entry, {
    VoidCallback? onUnsupported,
  }) async {
    if (entry.isDirectory) return;
    final ext =
        entry.name.contains('.') ? entry.name.split('.').last.toLowerCase() : '';
    if (ArchiveService.isArchive(entry.name)) {
      _push(context, ArchiveScreen(archivePath: entry.path));
    } else if (kImageExts.contains(ext)) {
      _push(context, ImageViewerScreen(file: File(entry.path), title: entry.name));
    } else if (kVideoExts.contains(ext)) {
      _push(
        context,
        MediaViewerScreen(
          file: File(entry.path),
          isVideo: true,
          title: entry.name,
        ),
      );
    } else if (kAudioExts.contains(ext)) {
      _push(
        context,
        MediaViewerScreen(
          file: File(entry.path),
          isVideo: false,
          title: entry.name,
        ),
      );
    } else if (kTextExts.contains(ext)) {
      _push(context, TextEditorScreen(file: File(entry.path), title: entry.name));
    } else if (kSqliteExts.contains(ext)) {
      _push(context, SqliteViewerScreen(file: File(entry.path), title: entry.name));
    } else if (kPdfExts.contains(ext)) {
      _push(context, PdfViewerScreen(file: File(entry.path), title: entry.name));
    } else if (kEpubExts.contains(ext)) {
      _push(context, EpubViewerScreen(file: File(entry.path), title: entry.name));
    } else if (ext == 'apk') {
      // APK: bilgi diyaloğu yerine Android kurucusu (Kur/Güncelle).
      await showApkInstallDialog(context, File(entry.path));
    } else if (ext == 'hex') {
      _push(context, HexViewerScreen(file: File(entry.path), title: entry.name));
    } else {
      onUnsupported?.call();
    }
  }

  static void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }
}
