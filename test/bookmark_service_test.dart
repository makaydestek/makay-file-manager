import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/bookmark_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BookmarkStore.save(const []);
  });

  test('toggle ekler ve çıkarır', () async {
    expect(await BookmarkStore.toggle(path: '/a', name: 'A'), isTrue);
    expect(BookmarkStore.contains('/a'), isTrue);
    expect(BookmarkStore.list.value, hasLength(1));

    expect(await BookmarkStore.toggle(path: '/a', name: 'A'), isFalse);
    expect(BookmarkStore.contains('/a'), isFalse);
  });

  test('reorder sırayı kalıcılaştırır', () async {
    await BookmarkStore.save(const [
      Bookmark(path: '/a', name: 'A'),
      Bookmark(path: '/b', name: 'B'),
      Bookmark(path: '/c', name: 'C'),
    ]);
    // onReorderItem: newIndex nihai konum (manuel −1 yok).
    await BookmarkStore.reorder(0, 1);
    expect(
      BookmarkStore.list.value.map((b) => b.path).toList(),
      ['/b', '/a', '/c'],
    );
  });
}
