import 'package:flutter/material.dart';

/// Ana ekrandaki kategori karolarının veri modeli.
class HomeCategory {
  const HomeCategory({
    required this.id,
    required this.title,
    required this.icon,
    required this.color,
    this.route,
  });

  final String id;
  final String title;
  final IconData icon;
  final Color color;

  /// İlgili ekran rotası; null ise "yakında" ekranı gösterilir.
  final String? route;
}

/// Ana ekran ızgarasındaki kategoriler.
///
/// **Bulut / Google Drive bu listede YER ALMAZ.** Google Drive OAuth
/// doğrulaması (restricted scope) tamamlanana kadar kart kullanıcıya hiç
/// gösterilmez — ne ana ekranda ne de Ayarlar → "Ana ekran kartları"
/// listesinde; kullanıcı yanlışlıkla açıp çalışmayan bir özelliğe
/// düşmesin diye kart tamamen listeden çıkarılmıştır.
///
/// Doğrulama tamamlandığında aşağıdaki tanımı listeye geri eklemek yeterlidir
/// (göster/gizle ayarı, rota ve ekranlar zaten hazırdır):
///
/// ```dart
/// HomeCategory(
///   id: 'cloud',
///   title: 'Bulut',
///   icon: Icons.cloud_rounded,
///   color: Color(0xFF1E88E5),
///   route: '/cloud',
/// ),
/// ```
const List<HomeCategory> kHomeCategories = [
  HomeCategory(
    id: 'internal',
    title: 'Ana bellek',
    icon: Icons.storage_rounded,
    color: Color(0xFF9E9E9E),
    route: '/browse/internal',
  ),
  HomeCategory(
    id: 'downloads',
    title: 'İndirilenler',
    icon: Icons.folder_zip_rounded,
    color: Color(0xFFF9A825),
    route: '/browse/downloads',
  ),
  HomeCategory(
    id: 'analysis',
    title: 'Bellek Analizi',
    icon: Icons.donut_small_rounded,
    color: Color(0xFF616161),
    route: '/analysis',
  ),
  HomeCategory(
    id: 'clean',
    title: 'Temizlik',
    icon: Icons.cleaning_services_rounded,
    color: Color(0xFF00897B),
    route: '/clean',
  ),
  HomeCategory(
    id: 'images',
    title: 'Resimler',
    icon: Icons.image_rounded,
    color: Color(0xFF8E24AA),
    route: '/browse/images',
  ),
  HomeCategory(
    id: 'audio',
    title: 'Ses',
    icon: Icons.music_note_rounded,
    color: Color(0xFF00897B),
    route: '/browse/audio',
  ),
  HomeCategory(
    id: 'videos',
    title: 'Videolar',
    icon: Icons.video_library_rounded,
    color: Color(0xFFD32F2F),
    route: '/browse/videos',
  ),
  HomeCategory(
    id: 'documents',
    title: 'Belgeler',
    icon: Icons.description_rounded,
    color: Color(0xFF1976D2),
    route: '/browse/documents',
  ),
  HomeCategory(
    id: 'apps',
    title: 'Uygulamalar',
    icon: Icons.android_rounded,
    color: Color(0xFF43A047),
    route: '/apps',
  ),
  HomeCategory(
    id: 'recent',
    title: 'Yeni Dosyalar',
    icon: Icons.schedule_rounded,
    color: Color(0xFF546E7A),
    route: '/recent',
  ),
  HomeCategory(
    id: 'remote',
    title: 'Uzak',
    icon: Icons.desktop_windows_rounded,
    color: Color(0xFF6D4C41),
    route: '/remote',
  ),
  HomeCategory(
    id: 'vault',
    title: 'Kasa',
    icon: Icons.lock_outline_rounded,
    color: Color(0xFF37474F),
    route: '/vault',
  ),
  HomeCategory(
    id: 'usb',
    title: 'USB / SD',
    icon: Icons.sd_card_rounded,
    color: Color(0xFF0277BD),
    route: '/usb',
  ),
  HomeCategory(
    id: 'network',
    title: 'Ağdan erişim',
    icon: Icons.devices_rounded,
    color: Color(0xFF00695C),
    route: '/network',
  ),
];
