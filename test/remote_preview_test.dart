import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/remote_preview.dart';

void main() {
  test('önizlenebilir uzantılar doğru tanınır', () {
    expect(RemotePreview.isPreviewable('foto.jpg'), isTrue);
    expect(RemotePreview.isPreviewable('klip.MP4'), isTrue);
    expect(RemotePreview.isPreviewable('sarki.mp3'), isTrue);
    expect(RemotePreview.isPreviewable('belge.pdf'), isFalse);
    expect(RemotePreview.isPreviewable('kurulum.apk'), isFalse);
  });

  test('önbellek anahtarı yol ve konuma göre kararlıdır', () {
    final a = RemotePreview.cacheKey(
      locationKey: 'ftp|host|21|u||n',
      remotePath: '/media/a.mp4',
    );
    final b = RemotePreview.cacheKey(
      locationKey: 'ftp|host|21|u||n',
      remotePath: '/media/a.mp4',
    );
    final c = RemotePreview.cacheKey(
      locationKey: 'ftp|host|21|u||n',
      remotePath: '/media/b.mp4',
    );
    expect(a, equals(b));
    expect(a, isNot(equals(c)));
  });
}
