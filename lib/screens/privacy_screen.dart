import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Gizlilik ve konumlandırma: reklam yok, veri toplanmaz, tüm özellikler ücretsiz.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Gizlilik ve ilkeler')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Icon(Icons.privacy_tip_rounded, size: 56, color: AppTheme.accent),
          const SizedBox(height: 12),
          Text(
            'Makay Dosya Yöneticisi',
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Reklamsız • Veri toplanmaz • Tüm özellikler ücretsiz',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              color: AppTheme.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 24),
          _card(
            theme,
            Icons.block_rounded,
            'Reklam yok',
            'Uygulamada hiçbir yerde reklam, takip pikseli veya '
                'üçüncü taraf reklam SDK\'sı yoktur.',
          ),
          _card(
            theme,
            Icons.cloud_off_rounded,
            'Arka planda veri toplanmaz',
            'Dosya listeleri, konumlar veya kullanım istatistikleri '
                'uzak sunucuya gönderilmez. Ağ özellikleri yalnızca '
                'sizin başlattığınız bağlantılar için kullanılır.',
          ),
          _card(
            theme,
            Icons.lock_rounded,
            'Yerel güvenlik',
            'Kasa dosyaları cihazınızda AES-256-GCM ile şifrelenir. '
                'Uygulama kilidi ve biyometri isteğe bağlıdır; PIN '
                'cihazınızda kalır.',
          ),
          _card(
            theme,
            Icons.volunteer_activism_rounded,
            'Premium yok',
            'Satın alma, abonelik veya özellik kilidi yoktur. '
                'Tüm araçlar herkese açıktır.',
          ),
          _card(
            theme,
            Icons.system_update_rounded,
            'Güncellemeler',
            'Sürüm kontrolü yalnızca sizin onayınızla GitHub Releases '
                'üzerinden yapılır; APK SHA-256 ile doğrulanır.',
          ),
          const SizedBox(height: 16),
          Text(
            'Bu metin uygulamanın ürün konumlandırmasını özetler; '
            'yasal gizlilik politikası metni değildir.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _card(
    ThemeData theme,
    IconData icon,
    String title,
    String body,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: Icon(icon, color: AppTheme.accent),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: Text(body),
        ),
        isThreeLine: true,
      ),
    );
  }
}
