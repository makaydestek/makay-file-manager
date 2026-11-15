import '../utils/file_opener.dart';

/// Protokolden bağımsız uzak dizin/dosya girdisi.
class RemoteItem {
  const RemoteItem({
    required this.name,
    required this.remotePath,
    required this.isDir,
    this.size = 0,
    this.modified,
  });

  final String name;

  /// Sunucudaki tam yol (FTP/SFTP/WebDAV: `/a/b`, SMB: `a\b`).
  final String remotePath;

  final bool isDir;
  final int size;
  final DateTime? modified;

  String get extension {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(i + 1).toLowerCase() : '';
  }

  bool get isImage => kImageExts.contains(extension);
  bool get isVideo => kVideoExts.contains(extension);
  bool get isAudio => kAudioExts.contains(extension);
}
