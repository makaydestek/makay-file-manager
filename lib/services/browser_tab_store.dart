import 'package:flutter/foundation.dart';

/// Tarayıcı sekmeleri (MiXplorer tarzı çoklu klasör).
///
/// Sekmeler uygulama sürecinde bellekte tutulur; kalıcı değildir.
class BrowserTab {
  const BrowserTab({
    required this.id,
    required this.title,
    required this.path,
  });

  final String id;
  final String title;
  final String path;

  BrowserTab copyWith({String? title, String? path}) => BrowserTab(
        id: id,
        title: title ?? this.title,
        path: path ?? this.path,
      );
}

class BrowserTabStore {
  BrowserTabStore._();

  static final ValueNotifier<List<BrowserTab>> tabs =
      ValueNotifier<List<BrowserTab>>(const []);

  static String? activeId;

  static BrowserTab? get active {
    final id = activeId;
    if (id == null) return null;
    for (final t in tabs.value) {
      if (t.id == id) return t;
    }
    return null;
  }

  static BrowserTab open({required String title, required String path}) {
    final tab = BrowserTab(
      id: '${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      path: path,
    );
    tabs.value = [...tabs.value, tab];
    activeId = tab.id;
    return tab;
  }

  static void select(String id) {
    activeId = id;
    tabs.value = List.of(tabs.value);
  }

  static void close(String id) {
    final next = tabs.value.where((t) => t.id != id).toList();
    if (activeId == id) {
      activeId = next.isEmpty ? null : next.last.id;
    }
    tabs.value = next;
  }

  static void closeAll() {
    tabs.value = const [];
    activeId = null;
  }
}
