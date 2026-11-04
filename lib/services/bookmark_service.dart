import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Yer imi (favori klasör) kaydı.
class Bookmark {
  const Bookmark({required this.path, required this.name});

  final String path;
  final String name;

  Map<String, String> toJson() => {'path': path, 'name': name};

  factory Bookmark.fromJson(Map<String, dynamic> json) => Bookmark(
        path: json['path'] as String? ?? '',
        name: json['name'] as String? ?? '',
      );
}

/// Yer imlerini SharedPreferences'ta tutar; sıra kalıcıdır (sürükle-bırak).
class BookmarkStore {
  BookmarkStore._();

  static const _key = 'bookmarks';

  /// Değişince çekmece / ana ekran dinleyicileri yenilenir.
  static final ValueNotifier<List<Bookmark>> list =
      ValueNotifier<List<Bookmark>>(const []);

  static bool _loaded = false;

  /// Prefs'ten yükler (uygulama açılışında ve her değişiklikte).
  static Future<List<Bookmark>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) {
      list.value = const [];
      _loaded = true;
      return const [];
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        list.value = const [];
        _loaded = true;
        return const [];
      }
      final items = <Bookmark>[
        for (final e in decoded)
          if (e is Map)
            Bookmark.fromJson(Map<String, dynamic>.from(e)),
      ].where((b) => b.path.isNotEmpty).toList(growable: false);
      list.value = items;
      _loaded = true;
      return items;
    } catch (_) {
      list.value = const [];
      _loaded = true;
      return const [];
    }
  }

  /// Listeyi yazar ve [list] bildirimini günceller.
  static Future<void> save(List<Bookmark> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode([for (final b in items) b.toJson()]),
    );
    list.value = List<Bookmark>.unmodifiable(items);
    _loaded = true;
  }

  /// Yol zaten yer iminde mi?
  static bool contains(String path) {
    if (!_loaded) return false;
    return list.value.any((b) => b.path == path);
  }

  /// Yoksa ekler, varsa çıkarır. Dönüş: eklendiyse true.
  static Future<bool> toggle({required String path, required String name}) async {
    await load();
    final next = List<Bookmark>.of(list.value);
    final i = next.indexWhere((b) => b.path == path);
    if (i >= 0) {
      next.removeAt(i);
      await save(next);
      return false;
    }
    next.add(Bookmark(path: path, name: name.isEmpty ? path : name));
    await save(next);
    return true;
  }

  static Future<void> remove(String path) async {
    await load();
    final next = List<Bookmark>.of(list.value)..removeWhere((b) => b.path == path);
    await save(next);
  }

  /// Sürükle-bırak sonrası sıra güncellemesi ([onReorderItem] indeksleri).
  static Future<void> reorder(int oldIndex, int newIndex) async {
    await load();
    final next = List<Bookmark>.of(list.value);
    if (oldIndex < 0 || oldIndex >= next.length) return;
    if (newIndex < 0 || newIndex >= next.length) return;
    final item = next.removeAt(oldIndex);
    next.insert(newIndex, item);
    await save(next);
  }
}
