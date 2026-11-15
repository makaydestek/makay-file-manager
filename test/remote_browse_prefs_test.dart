import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/models/remote_item.dart';
import 'package:makay_file_manager/services/remote_browse_prefs.dart';

void main() {
  test('klasörler önce + ada göre sıralar', () {
    final prefs = RemoteBrowsePrefs()
      ..foldersFirst = true
      ..sortBy = RemoteSortBy.name
      ..sortDesc = false;
    final sorted = prefs.sort(const [
      RemoteItem(name: 'b.txt', remotePath: '/b.txt', isDir: false, size: 2),
      RemoteItem(name: 'z', remotePath: '/z', isDir: true),
      RemoteItem(name: 'a.txt', remotePath: '/a.txt', isDir: false, size: 1),
      RemoteItem(name: 'm', remotePath: '/m', isDir: true),
    ]);
    expect(sorted.map((e) => e.name).toList(), ['m', 'z', 'a.txt', 'b.txt']);
  });

  test('boyuta göre azalan sıralar', () {
    final prefs = RemoteBrowsePrefs()
      ..foldersFirst = false
      ..sortBy = RemoteSortBy.size
      ..sortDesc = true;
    final sorted = prefs.sort(const [
      RemoteItem(name: 'a', remotePath: '/a', isDir: false, size: 10),
      RemoteItem(name: 'b', remotePath: '/b', isDir: false, size: 30),
      RemoteItem(name: 'c', remotePath: '/c', isDir: false, size: 20),
    ]);
    expect(sorted.map((e) => e.name).toList(), ['b', 'c', 'a']);
  });

  test('klasör içi arama filtreler', () {
    final prefs = RemoteBrowsePrefs();
    final filtered = prefs.filter(const [
      RemoteItem(name: 'Foto.jpg', remotePath: '/Foto.jpg', isDir: false),
      RemoteItem(name: 'video.mp4', remotePath: '/video.mp4', isDir: false),
      RemoteItem(name: 'docs', remotePath: '/docs', isDir: true),
    ], 'fo');
    expect(filtered.map((e) => e.name).toList(), ['Foto.jpg']);
  });
}
