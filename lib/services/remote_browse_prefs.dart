import 'package:shared_preferences/shared_preferences.dart';

import '../models/remote_item.dart';
import '../utils/file_opener.dart';

/// Uzak tarayıcı sıralama ölçütü (F Dosya Yöneticisi tarzı).
enum RemoteSortBy { name, date, size, type }

/// Tüm uzak protokollerin paylaştığı görünüm/sıralama tercihleri.
class RemoteBrowsePrefs {
  RemoteBrowsePrefs();

  static const _kSortBy = 'remote_browse_sort_by';
  static const _kSortDesc = 'remote_browse_sort_desc';
  static const _kViewMode = 'remote_browse_view_mode';
  static const _kFoldersFirst = 'remote_browse_folders_first';

  RemoteSortBy sortBy = RemoteSortBy.name;
  bool sortDesc = false;
  bool foldersFirst = true;

  /// 'list' | 'grid'
  String viewMode = 'list';

  bool get isGrid => viewMode == 'grid';

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    sortBy = switch (prefs.getString(_kSortBy)) {
      'date' => RemoteSortBy.date,
      'size' => RemoteSortBy.size,
      'type' => RemoteSortBy.type,
      _ => RemoteSortBy.name,
    };
    sortDesc = prefs.getBool(_kSortDesc) ?? false;
    foldersFirst = prefs.getBool(_kFoldersFirst) ?? true;
    viewMode = prefs.getString(_kViewMode) == 'grid' ? 'grid' : 'list';
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSortBy,
      switch (sortBy) {
        RemoteSortBy.name => 'name',
        RemoteSortBy.date => 'date',
        RemoteSortBy.size => 'size',
        RemoteSortBy.type => 'type',
      },
    );
    await prefs.setBool(_kSortDesc, sortDesc);
    await prefs.setBool(_kFoldersFirst, foldersFirst);
    await prefs.setString(_kViewMode, viewMode);
  }

  void toggleViewMode() {
    viewMode = isGrid ? 'list' : 'grid';
  }

  /// Klasörler önce + seçili ölçüte göre sıralar (kopya döner).
  List<RemoteItem> sort(List<RemoteItem> raw) {
    int typeRank(RemoteItem e) {
      if (e.isDir) return 0;
      final ext = e.extension;
      if (kImageExts.contains(ext)) return 1;
      if (kVideoExts.contains(ext)) return 2;
      if (kAudioExts.contains(ext)) return 3;
      return 4;
    }

    int cmp(RemoteItem a, RemoteItem b) {
      if (foldersFirst && a.isDir != b.isDir) {
        return a.isDir ? -1 : 1;
      }
      final r = switch (sortBy) {
        RemoteSortBy.name =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        RemoteSortBy.date => (a.modified ?? DateTime.fromMillisecondsSinceEpoch(0))
            .compareTo(b.modified ?? DateTime.fromMillisecondsSinceEpoch(0)),
        RemoteSortBy.size => a.size.compareTo(b.size),
        RemoteSortBy.type => () {
            final t = typeRank(a).compareTo(typeRank(b));
            if (t != 0) return t;
            return a.name.toLowerCase().compareTo(b.name.toLowerCase());
          }(),
      };
      return sortDesc ? -r : r;
    }

    return List<RemoteItem>.of(raw)..sort(cmp);
  }

  /// Ada göre anlık klasör içi filtre.
  List<RemoteItem> filter(List<RemoteItem> items, String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return items;
    return items.where((e) => e.name.toLowerCase().contains(q)).toList();
  }
}
