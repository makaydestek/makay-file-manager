/// Kopyalama / taşıma gibi uzun süren dosya işlemleri için ilerleme modeli
/// ve iptal belirteci.
///
/// Tasarım notu: bu sınıf `dart:io` bağımlılığı **içermez**, dolayısıyla
/// ağ/birim gecikmesi olmadan test edilebilir.
library;

/// Bir uzun süren işlemin iptal edilmesini talep eden belirteç.
///
/// İptal iş parçacığı (worker/isolate) arasında değil, aynı izolatta
/// geri çağırma (callback) tabanlı çalışır: işlem her dosya/kütük arasında
/// belirteci kontrol eder ve [TransferCancelled] fırlatır.
class CancelToken {
  bool _cancelled = false;

  /// İptal edildi mi?
  bool get isCancelled => _cancelled;

  /// İptal talep et. (Tekrar çağırmanın zararı yoktur.)
  void cancel() => _cancelled = true;
}

/// Fırlatılan istisna: işlem kullanıcı tarafından iptal edildi.
class TransferCancelled implements Exception {
  const TransferCancelled();

  @override
  String toString() => 'İşlem iptal edildi.';
}

/// İşin hangi aşamada olduğunu bildirir.
enum TransferPhase {
  /// Hedef ağacı ölçüyorken (dosya/bayt sayımı).
  measuring,

  /// Gerçek kopyalama/taşıma sürüyorken.
  copying,

  /// İptal sonrası kısmi çıktıyı temizlerken.
  cleaningUp,
}

/// Tek bir ilerleme anının görüntüsü (immutable).
class TransferProgress {
  const TransferProgress({
    required this.phase,
    required this.doneFiles,
    required this.doneBytes,
    this.currentPath = '',
    this.totalFiles,
    this.totalBytes,
  });

  final TransferPhase phase;

  /// Şu ana kadar tamamlanan dosya sayısı.
  final int doneFiles;

  /// Tahmini toplam dosya sayısı; `null` = henüz bilinmiyor.
  final int? totalFiles;

  /// Şu ana kadar kopyalanan bayt.
  final int doneBytes;

  /// Tahmini toplam bayt; `null` = henüz bilinmiyor.
  final int? totalBytes;

  /// İşlenen son dosyanın yolu (uygulama klasörü gibi, yalnız gösterim).
  final String currentPath;

  /// 0–1 arası ilerleme; toplam bilinmiyorsa `null`.
  double? get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return null;
    final value = doneBytes / total;
    if (value.isNaN) return null;
    return value.clamp(0.0, 1.0);
  }

  /// Ölçüm bitti mi (belirsizlik ortadan kalktı mı)?
  bool get hasTotals => totalFiles != null && totalBytes != null;

  /// "12 / 48 dosya" gibi kısa metin.
  String get fileText {
    final total = totalFiles;
    if (total == null) return '$doneFiles dosya';
    return '$doneFiles / $total dosya';
  }

  /// Ölçüm aşaması için gösterilecek Türkçe metin.
  String get measuringText => 'Ölçülüyor… ($doneFiles dosya)';

  @override
  String toString() =>
      'TransferProgress(${phase.name}, $fileText, $doneBytes bayt)';
}

/// İşin sonunda verilen özet.
class TransferResult {
  const TransferResult({
    required this.files,
    required this.bytes,
    required this.cancelled,
    this.warning,
  });

  /// Taşınan/kopyalanan dosya sayısı.
  final int files;

  /// Taşınan/kopyalanan bayt sayısı.
  final int bytes;

  /// Kullanıcı iptal ettiyse `true`.
  final bool cancelled;

  /// Kısmi başarı uyarısı (ör. kopyalandı ama kaynak silinemedi).
  final String? warning;

  @override
  String toString() =>
      'TransferResult($files dosya, $bytes bayt, cancelled: $cancelled'
      '${warning == null ? '' : ', warning: $warning'})';
}
