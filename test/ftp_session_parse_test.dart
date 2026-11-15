import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ftpconnect/ftpconnect.dart';

/// FtpSession toleranslı parse mantığının birim testi
/// (private metoda erişmeden aynı kuralları uygular).
List<FTPEntry> parseTolerant(String text, {required bool preferMlsd}) {
  final out = <FTPEntry>[];
  for (final line in text.split('\n')) {
    final t = line.replaceAll('\r', '').trim();
    if (t.isEmpty) continue;
    if (t.toLowerCase().startsWith('total ')) continue;
    try {
      if (preferMlsd && t.contains(';') && t.contains('=')) {
        out.add(FTPEntry.parse(t, ListCommand.mlsd));
      } else {
        out.add(FTPEntry.parse(t, ListCommand.list));
      }
    } catch (_) {
      // atla
    }
  }
  return out
      .where((e) => e.name != '.' && e.name != '..')
      .toList(growable: false);
}

void main() {
  test('total satırı tüm listeyi düşürmez', () {
    const listing = '''
total 48
drwxr-xr-x 1 user group 0 Aug 30 2017 100D7000
drwxr-xr-x 1 user group 0 Aug 30 2017 Fotolar
-rw-r--r-- 1 user group 1047000 Aug 26 2013 100_1473.JPG
''';
    // Eski davranış: FTPEntry.parse("total 48") fırlatır → boş klasör.
    expect(() => FTPEntry.parse('total 48', ListCommand.list), throwsA(anything));

    final entries = parseTolerant(listing, preferMlsd: false);
    expect(entries.length, 3);
    expect(entries[0].name, '100D7000');
    expect(entries[0].type, FTPEntryType.dir);
    expect(entries[2].name, '100_1473.JPG');
    expect(entries[2].type, FTPEntryType.file);
  });

  test('MLSD satırları ayrıştırılır', () {
    const listing = '''
type=dir;size=0;modify=20170830173700; 100D7000
type=file;size=1047000;modify=20130826120000; photo.jpg
''';
    final entries = parseTolerant(listing, preferMlsd: true);
    expect(entries.length, 2);
    expect(entries[0].type, FTPEntryType.dir);
    expect(entries[1].type, FTPEntryType.file);
  });

  test('bozuk satır diğerlerini bozmaz', () {
    final raw = utf8.encode('''
drwxr-xr-x 1 u g 0 Jan 1 2020 ok_folder
this is not a valid list line !!!
-rw-r--r-- 1 u g 100 Jan 1 2020 ok.jpg
''');
    final entries = parseTolerant(utf8.decode(raw), preferMlsd: false);
    expect(entries.map((e) => e.name), ['ok_folder', 'ok.jpg']);
  });
}
