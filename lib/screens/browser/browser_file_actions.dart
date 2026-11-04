import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/file_entry.dart';
import '../../providers/settings_provider.dart';
import '../../services/archive_service.dart';
import '../../services/clipboard_manager.dart';
import '../../services/file_service.dart';
import '../../services/recycle_bin_service.dart';
import '../../services/root_service.dart';
import '../../services/transfer.dart';
import '../../services/vault_service.dart';
import '../../utils/debug_log.dart';
import '../../utils/formats.dart';
import '../../widgets/transfer_progress_dialog.dart';

/// Dosya tarayıcı işlemleri (yapıştır, sil, yeniden adlandır, arşiv…).
///
/// [BrowserScreen] state'i üzerinde karışım olarak kullanılır; host alanlarına
/// [browserPath] / [browserService] vb. üzerinden erişilir (kütüphane
/// sınırları yüzünden `_` önekli alanlar paylaşılmaz).
mixin BrowserFileActions<W extends StatefulWidget> on State<W> {
  String get browserPath;
  FileService get browserService;
  Set<String> get browserSelected;
  Set<String> get browserHighlighted;
  List<FileEntry> get browserEntries;

  Future<void> browserReload({
    bool quiet = false,
    bool preserveSelection = false,
  });

  /// Seçili öğeleri ZIP olarak yazar; önce hedef klasör sorulur.
  Future<void> compressToZip(List<FileEntry> entries) async {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sıkıştırılacak öğe seçin')),
      );
      return;
    }
    final dest = await askZipDestination(entries.first.name);
    if (dest == null || !mounted) return;
    final outPath = ArchiveService.suggestedZipPath(dest, entries.first.name);
    try {
      final count = await ArchiveService().createZip(
        sourcePaths: [for (final e in entries) e.path],
        outPath: outPath,
      );
      if (!mounted) return;
      setState(browserSelected.clear);
      markHighlighted([outPath]);
      await browserReload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              'Arşiv oluşturuldu: ${outPath.split(Platform.pathSeparator).last}'
              ' ($count dosya)'),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Arşiv oluşturulamadı: $err')),
      );
    }
  }

  /// ZIP hedef klasörü: bu klasör / üst klasör.
  Future<String?> askZipDestination(String sourceName) async {
    final parent = Directory(browserPath).parent.path;
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Arşiv konumu'),
        content: Text(
          '"$sourceName" için ZIP nereye yazılsın?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          if (parent.isNotEmpty && parent != browserPath)
            TextButton(
              onPressed: () => Navigator.pop(context, parent),
              child: const Text('Üst klasör'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, browserPath),
            child: const Text('Bu klasör'),
          ),
        ],
      ),
    );
  }

  void markHighlighted(Iterable<String> paths) {
    setState(() {
      browserHighlighted
        ..clear()
        ..addAll(paths);
    });
    Future<void>.delayed(const Duration(seconds: 8), () {
      if (!mounted) return;
      setState(browserHighlighted.clear);
    });
  }

  /// Seçim modundaki tüm öğeleri ZIP'e ekler.
  Future<void> compressSelected() async {
    final entries =
        browserEntries.where((e) => browserSelected.contains(e.path)).toList();
    await compressToZip(entries);
  }

  /// Dosyayı kopyalayıp şifreli kasaya ekler (kaynak dosya yerinde kalır).
  Future<void> addToVault(FileEntry e) async {
    if (!VaultService.unlocked) {
      // Önce kasa ekranı açılır; kullanıcı PIN ile girip döner.
      final opened = await Navigator.of(context).pushNamed('/vault');
      if (opened != true || !mounted) return;
    }
    if (!mounted || !VaultService.unlocked) return;
    try {
      final entry = await VaultService.add(File(e.path));
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${entry.name} kasaya eklendi (şifrelendi)')),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Kasaya eklenemedi: $err')),
      );
    }
  }

  /// Root'lu cihazlarda izin değiştirme diyaloğu; root yoksa bilgilendirir.
  Future<void> chmodDialog(FileEntry e) async {
    final rooted = await RootService.isRooted();
    if (!mounted) return;
    if (!rooted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
              'Kök (root) erişimi bulunamadı. chmod yalnızca root\'lu '
              'cihazlarda çalışır.'),
        ),
      );
      return;
    }
    var current = '';
    try {
      current = RootService.modeToString(File(e.path).statSync().mode);
    } catch (e) {
      logSwallowed('tarayıcı: chmod izin okuma', e);
    }
    final controller =
        TextEditingController(text: RootService.parseMode(current) ?? '644');
    final mode = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('İzinleri değiştir (chmod)'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(e.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 8),
            Text('Mevcut: $current'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Yeni izin (sekizlik)',
                hintText: '644, 755, 0755 …',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Uygula'),
          ),
        ],
      ),
    );
    if (mode == null || mode.isEmpty) return;
    try {
      final ok = await RootService.chmod(e.path, mode);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'İzinler güncellendi: $mode'
              : 'chmod başarısız oldu'),
        ),
      );
      if (ok && mounted) browserReload();
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hata: $err')),
      );
    }
  }

  /// Çift panel sürükle-bırak: ayara göre kopyala / taşı / sor.
  Future<void> dropToFolder(String filePath, String targetFolder) async {
    if (filePath == targetFolder) return;
    final parent = File(filePath).parent.path;
    if (parent == targetFolder) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dosya zaten bu klasörde')),
      );
      return;
    }
    final name = filePath.split(Platform.pathSeparator).last;
    var mode = context.read<SettingsProvider>().dropAction;
    if (mode == 'ask') {
      final choice = await showModalBottomSheet<String>(
        context: context,
        builder: (ctx) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text('"$name" → hedef klasör'),
                subtitle: const Text('Sürükle-bırak eylemi'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.copy_rounded),
                title: const Text('Kopyala'),
                onTap: () => Navigator.pop(ctx, 'copy'),
              ),
              ListTile(
                leading: const Icon(Icons.drive_file_move_rounded),
                title: const Text('Taşı'),
                onTap: () => Navigator.pop(ctx, 'move'),
              ),
              ListTile(
                leading: const Icon(Icons.close_rounded),
                title: const Text('Vazgeç'),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      );
      if (!mounted || choice == null) return;
      mode = choice;
    }
    final move = mode == 'move';
    if (!mounted) return;
    try {
      await showTransferProgress(
        context,
        title: move ? 'Taşınıyor' : 'Kopyalanıyor',
        action: (onProgress, token) => move
            ? browserService.movePath(
                filePath,
                targetFolder,
                onProgress: onProgress,
                cancelToken: token,
              )
            : browserService.copyPath(
                filePath,
                targetFolder,
                onProgress: onProgress,
                cancelToken: token,
              ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            move
                ? '$name taşındı → $targetFolder'
                : '$name kopyalandı → $targetFolder',
          ),
        ),
      );
      if (mounted) browserReload();
    } on TransferCancelled {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            move
                ? '$name taşıması iptal edildi'
                : '$name kopyalaması iptal edildi',
          ),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(move ? 'Taşınamadı: $err' : 'Kopyalanamadı: $err'),
        ),
      );
    }
  }

  /// Seçili dosyaları sistem paylaşım sayfasıyla paylaş.
  Future<void> shareSelected() async {
    final paths = browserEntries
        .where((e) => browserSelected.contains(e.path) && !e.isDirectory)
        .map((e) => e.path)
        .toList();
    if (paths.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Paylaşılacak dosya seçin')),
      );
      return;
    }
    setState(browserSelected.clear);
    await SharePlus.instance.share(
      ShareParams(files: [for (final p in paths) XFile(p)]),
    );
  }

  /// Panodaki öğeleri bu klasöre yapıştırır.
  ///
  /// Tüm öğeler **tek bir** ilerleme diyaloğu altında yürür: önce
  /// [FileService.estimate] ile genel toplam alınır, her öğenin ilerlemesi
  /// tamamlananlara eklenerek global olarak monoton bir çubuk sunulur.
  Future<void> paste() async {
    final clipboard = ClipboardManager.instance;
    if (clipboard.isEmpty) return;
    final target = browserPath;
    final isCut = clipboard.isCut;
    final entries = List<FileEntry>.of(clipboard.entries);

    final total = await browserService.estimate([for (final e in entries) e.path]);
    if (!mounted) return;

    var doneFiles = 0;

    late final TransferResult pasteResult;
    try {
      pasteResult = await showTransferProgress(
        context,
        title: isCut ? 'Taşınıyor' : 'Kopyalanıyor',
        action: (onProgress, token) => pasteAll(
          entries: entries,
          target: target,
          isCut: isCut,
          total: total,
          onProgress: onProgress,
          token: token,
          onStep: (files) => doneFiles = files,
        ),
      );
    } on TransferCancelled {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('İşlem iptal edildi')),
      );
      browserReload();
      return;
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Yapıştırılamadı: $err')),
      );
      return;
    }

    if (isCut) clipboard.clear();
    if (mounted) {
      final sep = Platform.pathSeparator;
      markHighlighted([
        for (final e in entries) '$target$sep${e.name}',
      ]);
      await browserReload();
      if (!mounted) return;
      final warning = pasteResult.warning;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            warning ??
                'Yapıştırıldı: ${entries.length} öğe'
                    '${doneFiles > 0 ? ' ($doneFiles dosya)' : ''}',
          ),
          backgroundColor: warning == null
              ? null
              : Theme.of(context).colorScheme.errorContainer,
        ),
      );
    }
  }

  /// Panodaki her öğeyi sırayla taşır/kopyalar ve genel toplamı raporlar.
  Future<TransferResult> pasteAll({
    required List<FileEntry> entries,
    required String target,
    required bool isCut,
    required ({int files, int bytes}) total,
    required void Function(TransferProgress) onProgress,
    required CancelToken token,
    required void Function(int files) onStep,
  }) async {
    var files = 0;
    var bytes = 0;
    final warnings = <String>[];
    for (final entry in entries) {
      final result = isCut
          ? await browserService.moveEntry(
              entry,
              target,
              cancelToken: token,
              onProgress: (p) => onProgress(TransferProgress(
                phase: p.phase,
                doneFiles: files + p.doneFiles,
                doneBytes: bytes + p.doneBytes,
                totalFiles: total.files,
                totalBytes: total.bytes,
                currentPath: p.currentPath,
              )),
            )
          : await browserService.copyEntry(
              entry,
              target,
              cancelToken: token,
              onProgress: (p) => onProgress(TransferProgress(
                phase: p.phase,
                doneFiles: files + p.doneFiles,
                doneBytes: bytes + p.doneBytes,
                totalFiles: total.files,
                totalBytes: total.bytes,
                currentPath: p.currentPath,
              )),
            );
      files += result.files;
      bytes += result.bytes;
      if (result.warning != null && result.warning!.isNotEmpty) {
        warnings.add('${entry.name}: ${result.warning}');
      }
      onStep(files);
      // Öğe bitimi: çubuk öğeler arası boşlukta da ilerlesin.
      onProgress(TransferProgress(
        phase: TransferPhase.copying,
        doneFiles: files,
        doneBytes: bytes,
        totalFiles: total.files,
        totalBytes: total.bytes,
      ));
    }
    return TransferResult(
      files: files,
      bytes: bytes,
      cancelled: false,
      warning: warnings.isEmpty ? null : warnings.join('\n'),
    );
  }

  /// Seçili/verilen öğeleri siler: geri dönüşüm kutusu ya da kalıcı.
  Future<void> deleteSelected() async =>
      deleteEntries(browserEntries.where((e) => browserSelected.contains(e.path)));

  Future<void> deleteEntries(Iterable<FileEntry> targets) async {
    final entries = targets.toList(growable: false);
    if (entries.isEmpty) return;
    final settings = context.read<SettingsProvider>();
    final count = entries.length;
    final useBin = settings.recycleBinDefault;
    var confirmed = !settings.recycleBinConfirm;
    if (!confirmed) {
      confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(useBin ? 'Geri dönüşüm kutusuna taşı' : 'Kalıcı sil'),
              content: Text('$count öğe silinecek.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('İptal'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Sil'),
                ),
              ],
            ),
          ) ??
          false;
    }
    if (!confirmed) return;
    var ok = 0;
    var fail = 0;
    String? lastError;
    for (final entry in entries) {
      try {
        if (useBin) {
          await RecycleBinService.instance.moveToRecycle(entry);
        } else {
          await browserService.deleteEntry(entry.path, useRecycleBin: false);
        }
        // Başarı saymadan önce kaynak gerçekten gitmiş olmalı
        // (eski rename sessizce başarısız olup "taşındı" diyordu).
        final stillThere = entry.isDirectory
            ? await Directory(entry.path).exists()
            : await File(entry.path).exists();
        if (stillThere) {
          throw FileSystemException('Dosya silinmedi', entry.path);
        }
        ok++;
      } catch (e) {
        fail++;
        lastError = e.toString();
        logSwallowed('tarayıcı: silme', e);
      }
    }
    if (!mounted) return;
    setState(browserSelected.clear);
    browserReload();
    final messenger = ScaffoldMessenger.of(context);
    if (fail == 0) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            useBin
                ? '$ok öğe geri dönüşüm kutusuna taşındı'
                : '$ok öğe silindi',
          ),
        ),
      );
    } else {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'Silme: $ok başarılı, $fail başarısız'
            '${lastError == null ? '' : ' — $lastError'}',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  /// Seçimi panoya alır ve kullanıcıyı "Yapıştır"a yönlendirir.
  void copySelectionToClipboard(List<FileEntry> entries, {required bool cut}) {
    if (entries.isEmpty) return;
    if (cut) {
      ClipboardManager.instance.cut(entries);
    } else {
      ClipboardManager.instance.copy(entries);
    }
    setState(browserSelected.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${entries.length} öğe ${cut ? 'taşınmak' : 'kopyalanmak'} üzere '
          'alındı — hedef klasörde "Yapıştır"a dokunun',
        ),
      ),
    );
  }

  Future<void> rename(FileEntry e) async {
    final controller = TextEditingController(text: e.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeniden adlandır'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Yeni ad'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == e.name) return;
    try {
      await browserService.rename(e.path, newName);
      if (!mounted) return;
      browserReload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('"$newName" olarak yeniden adlandırıldı')),
      );
    } catch (err) {
      logSwallowed('tarayıcı: yeniden adlandırma', err);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Yeniden adlandırılamadı: $err'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<void> newFolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Yeni klasör'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Klasör adı'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('İptal'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Oluştur'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final created = '$browserPath${Platform.pathSeparator}$name';
    try {
      await browserService.createDirectory(created);
      markHighlighted([created]);
      if (!mounted) return;
      browserReload();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Klasör oluşturuldu: $name')),
      );
    } catch (err) {
      logSwallowed('tarayıcı: klasör oluşturma', err);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Klasör oluşturulamadı: $err'),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  void showInfo(FileEntry e) async {
    final datePattern = context.read<SettingsProvider>().datePattern;
    // Klasörün "boyut" alanı dosya girdisinin kendisine ait değildir; gerçek
    // özyinelemeli boyut (içindeki dosyaların toplamı) ayrıca hesaplanır.
    String? folderSize;
    if (e.isDirectory) {
      folderSize = Formats.size(await browserService.directorySize(e.path));
      if (!mounted) return;
    }
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(e.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tür: ${e.kind.name}'),
            Text('Boyut: ${folderSize ?? Formats.size(e.size)}'),
            Text(
                'Değiştirilme: ${Formats.date(e.modified, pattern: datePattern)}'),
            if (permissionText(e.path) != null)
              Text('İzinler: ${permissionText(e.path)}'),
            const SizedBox(height: 8),
            SelectableText('Konum: ${e.path}'),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Tamam'),
          ),
        ],
      ),
    );
  }

  /// POSIX izin metni (ör. "-rw-r--r--"); alınamazsa null.
  static String? permissionText(String path) {
    try {
      final stat = File(path).statSync();
      return RootService.modeToString(stat.mode);
    } catch (_) {
      return null;
    }
  }
}
