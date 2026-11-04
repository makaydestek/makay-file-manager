import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../services/category_size_service.dart';

/// Metin görüntüleyici/editörü: satır numarası, bul, monospace.
class TextEditorScreen extends StatefulWidget {
  const TextEditorScreen({super.key, required this.file, this.title});

  final File file;
  final String? title;

  @override
  State<TextEditorScreen> createState() => _TextEditorScreenState();
}

class _TextEditorScreenState extends State<TextEditorScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  final _findController = TextEditingController();
  bool _loading = true;
  bool _editing = false;
  bool _saving = false;
  bool _truncated = false;
  bool _showFind = false;
  bool _showLineNumbers = true;
  String? _error;
  late String _original;
  int _findIndex = -1;
  final List<int> _findHits = [];

  /// Düzenleme için üst boyut sınırı (1 MB); üstünde salt okunur.
  static const int _editLimit = 1024 * 1024;

  /// Salt-okunur görünümde çizilecek azami karakter (çizim performansı için).
  static const int _displayLimit = 120 * 1024;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    _findController.dispose();
    super.dispose();
  }

  String get _name =>
      widget.title ?? widget.file.path.split(Platform.pathSeparator).last;

  Future<void> _load() async {
    try {
      final size = await widget.file.length();
      final raf = await widget.file.open();
      final take = size > _editLimit ? _editLimit : size;
      final bytes = await raf.read(take);
      await raf.close();
      final text = utf8.decode(bytes, allowMalformed: true);
      _truncated = size > _editLimit;
      _original = text;
      _controller.text = text;
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Dosya açılamadı: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.file.writeAsString(_controller.text, flush: true);
      _original = _controller.text;
      await CategorySizeService.invalidate();
      if (!mounted) return;
      setState(() => _editing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$_name kaydedildi')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kaydedilemedi: $e')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmLeave() async {
    if (_editing && _controller.text != _original) {
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Kaydedilmemiş değişiklik'),
          content: Text('$_name için kaydedilmemiş değişiklikler var.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Vazgeç'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Kaydet ve çık'),
            ),
          ],
        ),
      );
      if (save == true) {
        await _save();
        return true;
      }
      return false;
    }
    return true;
  }

  void _runFind() {
    final q = _findController.text;
    _findHits.clear();
    _findIndex = -1;
    if (q.isEmpty) {
      setState(() {});
      return;
    }
    final text = _controller.text;
    var from = 0;
    while (true) {
      final i = text.toLowerCase().indexOf(q.toLowerCase(), from);
      if (i < 0) break;
      _findHits.add(i);
      from = i + q.length;
    }
    if (_findHits.isNotEmpty) {
      _findIndex = 0;
      _controller.selection = TextSelection(
        baseOffset: _findHits.first,
        extentOffset: _findHits.first + q.length,
      );
    }
    setState(() {});
  }

  void _findNext() {
    if (_findHits.isEmpty) return;
    _findIndex = (_findIndex + 1) % _findHits.length;
    final start = _findHits[_findIndex];
    final len = _findController.text.length;
    _controller.selection = TextSelection(
      baseOffset: start,
      extentOffset: start + len,
    );
    setState(() {});
  }

  Widget _lineNumberGutter(String text, TextStyle style) {
    final lines = text.split('\n').length;
    final width = (lines.toString().length * 10.0).clamp(28.0, 56.0);
    return SizedBox(
      width: width,
      child: ListView.builder(
        controller: _scroll,
        physics: const NeverScrollableScrollPhysics(),
        itemCount: lines,
        itemBuilder: (context, i) => Text(
          '${i + 1}',
          textAlign: TextAlign.right,
          style: style.copyWith(
            color: Theme.of(context).colorScheme.outline,
            height: 1.4,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const mono = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.4);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeave() && context.mounted) {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_name, maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              icon: const Icon(Icons.search_rounded),
              tooltip: 'Bul',
              onPressed: _loading || _error != null
                  ? null
                  : () => setState(() => _showFind = !_showFind),
            ),
            IconButton(
              icon: Icon(_showLineNumbers
                  ? Icons.format_list_numbered_rounded
                  : Icons.format_list_bulleted_rounded),
              tooltip: 'Satır numaraları',
              onPressed: () =>
                  setState(() => _showLineNumbers = !_showLineNumbers),
            ),
            if (_editing)
              IconButton(
                icon: const Icon(Icons.save_rounded),
                tooltip: 'Kaydet',
                onPressed: _saving ? null : _save,
              ),
            IconButton(
              icon: Icon(
                _editing ? Icons.visibility_outlined : Icons.edit_outlined,
              ),
              tooltip: _editing ? 'Salt okunur' : 'Düzenle',
              onPressed: _loading || _error != null
                  ? null
                  : () => setState(() => _editing = !_editing),
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
                      if (_showFind)
                        Material(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 4),
                            child: Row(
                              children: [
                                Expanded(
                                  child: TextField(
                                    controller: _findController,
                                    decoration: const InputDecoration(
                                      hintText: 'Bul…',
                                      isDense: true,
                                      border: OutlineInputBorder(),
                                    ),
                                    onSubmitted: (_) => _runFind(),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.search_rounded),
                                  onPressed: _runFind,
                                ),
                                IconButton(
                                  icon: const Icon(Icons.keyboard_arrow_down),
                                  onPressed:
                                      _findHits.isEmpty ? null : _findNext,
                                ),
                                if (_findHits.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8),
                                    child: Text(
                                      '${_findIndex + 1}/${_findHits.length}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (_editing && _saving)
                        const LinearProgressIndicator(),
                      if (_truncated)
                        MaterialBanner(
                          backgroundColor:
                              theme.colorScheme.surfaceContainerHighest,
                          content: const Text(
                            'Dosyanın yalnızca ilk 1 MB\'ı yüklendi; '
                            'büyük dosyalar salt okunurdur.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => setState(() {}),
                              child: const Text('Anlaşıldı'),
                            ),
                          ],
                        ),
                      Expanded(
                        child: _editing
                            ? Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (_showLineNumbers)
                                    ColoredBox(
                                      color: theme.colorScheme
                                          .surfaceContainerHighest,
                                      child: Padding(
                                        padding: const EdgeInsets.only(
                                            top: 12, right: 6, left: 4),
                                        child: _lineNumberGutter(
                                          _controller.text,
                                          mono,
                                        ),
                                      ),
                                    ),
                                  Expanded(
                                    child: TextField(
                                      controller: _controller,
                                      maxLines: null,
                                      expands: true,
                                      keyboardType: TextInputType.multiline,
                                      style: mono,
                                      decoration: const InputDecoration(
                                        border: InputBorder.none,
                                        contentPadding: EdgeInsets.all(12),
                                      ),
                                      onChanged: (_) => setState(() {}),
                                    ),
                                  ),
                                ],
                              )
                            : SingleChildScrollView(
                                padding: const EdgeInsets.all(12),
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (_showLineNumbers) ...[
                                      _lineNumberGutter(
                                        _controller.text.length > _displayLimit
                                            ? _controller.text
                                                .substring(0, _displayLimit)
                                            : _controller.text,
                                        mono,
                                      ),
                                      const SizedBox(width: 8),
                                    ],
                                    Expanded(
                                      child: SelectableText(
                                        _controller.text.length > _displayLimit
                                            ? '${_controller.text.substring(0, _displayLimit)}\n\n… (devamı görüntülenmiyor; düzenleyip kaydedebilirsiniz)'
                                            : _controller.text,
                                        style: mono,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: Text(
                          '${_controller.text.split('\n').length} satır • '
                          '${_controller.text.length} karakter'
                          '${_findHits.isEmpty ? '' : ' • ${_findHits.length} eşleşme'}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
