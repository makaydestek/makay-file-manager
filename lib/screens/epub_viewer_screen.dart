import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:xml/xml.dart';

/// Hafif EPUB okuyucu: EPUB bir ZIP'tir; container.xml → OPF → HTML bölümleri.
///
/// Harici `epub_view` paketi `archive ^3` istediği için (bizde archive 4)
/// bağımlılık çatışması yaratmadan mevcut ZIP + XML yığınıyla çalışır.
class EpubViewerScreen extends StatefulWidget {
  const EpubViewerScreen({super.key, required this.file, this.title});

  final File file;
  final String? title;

  @override
  State<EpubViewerScreen> createState() => _EpubViewerScreenState();
}

class _EpubViewerScreenState extends State<EpubViewerScreen> {
  bool _loading = true;
  String? _error;
  String _bookTitle = '';
  final List<_EpubChapter> _chapters = [];
  int _index = 0;

  String get _name =>
      widget.title ?? widget.file.path.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final input = InputFileStream(widget.file.path);
      late final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } finally {
        await input.close();
      }

      final byName = <String, ArchiveFile>{};
      for (final f in archive) {
        if (!f.isFile) continue;
        byName[f.name.replaceAll('\\', '/')] = f;
      }

      String? findIgnoreCase(String path) {
        if (byName.containsKey(path)) return path;
        final lower = path.toLowerCase();
        for (final k in byName.keys) {
          if (k.toLowerCase() == lower) return k;
        }
        return null;
      }

      final containerKey =
          findIgnoreCase('META-INF/container.xml') ??
          findIgnoreCase('meta-inf/container.xml');
      if (containerKey == null) {
        throw StateError('container.xml bulunamadı');
      }
      final containerXml =
          utf8.decode(byName[containerKey]!.content as List<int>,
              allowMalformed: true);
      final containerDoc = XmlDocument.parse(containerXml);
      final rootfile = containerDoc
          .findAllElements('rootfile')
          .map((e) => e.getAttribute('full-path'))
          .whereType<String>()
          .firstOrNull;
      if (rootfile == null) throw StateError('OPF yolu yok');

      final opfKey = findIgnoreCase(rootfile);
      if (opfKey == null) throw StateError('OPF bulunamadı: $rootfile');
      final opfDir = opfKey.contains('/')
          ? opfKey.substring(0, opfKey.lastIndexOf('/') + 1)
          : '';
      final opfXml = utf8.decode(byName[opfKey]!.content as List<int>,
          allowMalformed: true);
      final opf = XmlDocument.parse(opfXml);

      _bookTitle = opf
              .findAllElements('dc:title')
              .map((e) => e.innerText.trim())
              .where((t) => t.isNotEmpty)
              .firstOrNull ??
          opf
              .findAllElements('title')
              .map((e) => e.innerText.trim())
              .where((t) => t.isNotEmpty)
              .firstOrNull ??
          _name;

      final idToHref = <String, String>{};
      for (final item in opf.findAllElements('item')) {
        final id = item.getAttribute('id');
        final href = item.getAttribute('href');
        if (id != null && href != null) idToHref[id] = href;
      }

      final spine = <String>[];
      for (final itemref in opf.findAllElements('itemref')) {
        final idref = itemref.getAttribute('idref');
        if (idref == null) continue;
        final href = idToHref[idref];
        if (href != null) spine.add(href);
      }

      for (var i = 0; i < spine.length; i++) {
        final href = spine[i];
        final full = _resolve(opfDir, href);
        final key = findIgnoreCase(full);
        if (key == null) continue;
        final raw = utf8.decode(byName[key]!.content as List<int>,
            allowMalformed: true);
        final text = _htmlToText(raw);
        if (text.trim().isEmpty) continue;
        _chapters.add(_EpubChapter(
          title: 'Bölüm ${i + 1}',
          text: text,
        ));
      }

      await archive.clear();
      if (_chapters.isEmpty) {
        throw StateError('Okunabilir bölüm bulunamadı');
      }
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'EPUB açılamadı: $e';
        });
      }
    }
  }

  static String _resolve(String base, String href) {
    final h = href.split('#').first.replaceAll('\\', '/');
    if (h.startsWith('/')) return h.substring(1);
    return '$base$h';
  }

  static String _htmlToText(String html) {
    var s = html
        .replaceAll(
          RegExp(r'<script[^>]*>.*?</script>',
              caseSensitive: false, dotAll: true),
          '',
        )
        .replaceAll(
          RegExp(r'<style[^>]*>.*?</style>',
              caseSensitive: false, dotAll: true),
          '',
        )
        .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</p>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'</div>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'</h[1-6]>', caseSensitive: false), '\n\n')
        .replaceAll(RegExp(r'<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'");
    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
    return s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _loading ? _name : (_bookTitle.isEmpty ? _name : _bookTitle),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!_loading && _error == null && _chapters.length > 1)
            IconButton(
              icon: const Icon(Icons.list_rounded),
              tooltip: 'Bölümler',
              onPressed: () async {
                final i = await showModalBottomSheet<int>(
                  context: context,
                  builder: (context) => ListView.builder(
                    itemCount: _chapters.length,
                    itemBuilder: (context, i) => ListTile(
                      selected: i == _index,
                      title: Text(_chapters[i].title),
                      onTap: () => Navigator.pop(context, i),
                    ),
                  ),
                );
                if (i != null && mounted) setState(() => _index = i);
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : Column(
                  children: [
                    if (_chapters.length > 1)
                      Material(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: _index > 0
                                    ? () => setState(() => _index--)
                                    : null,
                                icon: const Icon(Icons.chevron_left_rounded),
                              ),
                              Expanded(
                                child: Text(
                                  _chapters[_index].title,
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.titleSmall,
                                ),
                              ),
                              IconButton(
                                onPressed: _index < _chapters.length - 1
                                    ? () => setState(() => _index++)
                                    : null,
                                icon: const Icon(Icons.chevron_right_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: SelectableText(
                          _chapters[_index].text,
                          style: theme.textTheme.bodyLarge?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
    );
  }
}

class _EpubChapter {
  const _EpubChapter({required this.title, required this.text});
  final String title;
  final String text;
}
