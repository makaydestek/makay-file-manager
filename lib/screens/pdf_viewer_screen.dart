import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/platform_service.dart';

/// Dahili PDF görüntüleyici — Android PdfRenderer (platform kanalı).
///
/// Harici `pdfrx` gibi native-assets paketleri Windows test/CI'yi kırdığı
/// için sistem PdfRenderer kullanılır; diğer platformlarda sistem açıcıya
/// düşülür.
class PdfViewerScreen extends StatefulWidget {
  const PdfViewerScreen({super.key, required this.file, this.title});

  final File file;
  final String? title;

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  bool _loading = true;
  String? _error;
  int _page = 0;
  int _pageCount = 0;
  Uint8List? _bytes;

  String get _name =>
      widget.title ?? widget.file.path.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    _load(0);
  }

  Future<void> _load(int page) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await PlatformService.renderPdfPage(
      path: widget.file.path,
      page: page,
    );
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _loading = false;
        _error = PlatformService.supported
            ? 'PDF açılamadı (şifreli veya bozuk olabilir)'
            : 'PDF görüntüleme bu platformda desteklenmiyor';
      });
      return;
    }
    setState(() {
      _pageCount = result.pageCount;
      _page = result.page;
      _bytes = result.bytes;
      _loading = false;
    });
  }

  Future<void> _openExternal() async {
    final ok = await PlatformService.openWith(path: widget.file.path);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sistem PDF uygulaması açılamadı')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_new_rounded),
            tooltip: 'Başka uygulamayla aç',
            onPressed: _openExternal,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _openExternal,
                          icon: const Icon(Icons.open_in_new_rounded),
                          label: const Text('Sistem uygulamasıyla aç'),
                        ),
                      ],
                    ),
                  ),
                )
              : Column(
                  children: [
                    Expanded(
                      child: InteractiveViewer(
                        minScale: 0.5,
                        maxScale: 4,
                        child: Center(
                          child: _bytes == null
                              ? const SizedBox.shrink()
                              : Image.memory(_bytes!, fit: BoxFit.contain),
                        ),
                      ),
                    ),
                    if (_pageCount > 1)
                      SafeArea(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: _page > 0 && !_loading
                                    ? () => _load(_page - 1)
                                    : null,
                                icon: const Icon(Icons.chevron_left_rounded),
                              ),
                              Expanded(
                                child: Text(
                                  'Sayfa ${_page + 1} / $_pageCount',
                                  textAlign: TextAlign.center,
                                ),
                              ),
                              IconButton(
                                onPressed:
                                    _page < _pageCount - 1 && !_loading
                                        ? () => _load(_page + 1)
                                        : null,
                                icon: const Icon(Icons.chevron_right_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
    );
  }
}
