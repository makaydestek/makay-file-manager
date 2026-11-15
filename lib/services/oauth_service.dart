import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:url_launcher/url_launcher.dart';

/// OAuth 2.0 oturum sonucu.
class OAuthSession {
  OAuthSession({
    required this.accessToken,
    required this.refreshToken,
    required this.expiresAt,
  });

  final String accessToken;
  final String? refreshToken;
  final DateTime expiresAt;
}

/// OAuth 2.0 "authorization code + PKCE" akışı.
///
/// Uygulama, cihaz üzerinde 127.0.0.1 üzerinde geçici bir HTTP sunucusu
/// açar; kullanıcı tarayıcıda giriş yapar ve Google tarayıcıyı bu adrese
/// geri yönlendirir. Kod burada toplanır → istemci anahtarıyla değiştirilir.
/// Ek hazırlık gerektirmez (kayıtlı yönlendirme adresi, manifest vb.).
class OAuthService {
  OAuthService._();

  /// Döngü arayüzü sunucusu + tarayıcı akışını yürütür.
  ///
  /// [buildAuthorizeUrl] yetki adresini, [exchangeCode] ise alınan kodu
  /// token'larla değiştiren sağlayıcıya özgü mantığı sağlar.
  static Future<OAuthSession> authorize({
    required Uri Function(String redirectUri, String state, String codeChallenge)
        buildAuthorizeUrl,
    required Future<OAuthSession> Function(
            String code, String redirectUri, String codeVerifier)
        exchangeCode,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}/callback';
    final state = _randomToken(32);
    final verifier = _randomToken(64);
    final challenge = _base64Url(sha256.convert(utf8.encode(verifier)).bytes);

    final authorizeUrl =
        buildAuthorizeUrl(redirectUri, state, challenge);

    try {
      final launched = await launchUrl(
        authorizeUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw const OAuthException('Tarayıcı açılamadı');
      }

      final request = await server.first.timeout(timeout);
      final params = request.uri.queryParameters;
      final html = StringBuffer();

      OAuthSession? session;
      String? error;
      if (params['error'] != null) {
        error = params['error_description'] ?? params['error'];
      } else if (params['code'] == null) {
        error = 'Doğrulama kodu alınamadı';
      } else if (params['state'] != state) {
        // state **zorunludur**: yokluğu da hata sayılır. Aksi halde aynı
        // cihazdaki bir uygulama loopback callback'ine kendi `code`'unu
        // enjekte edebilirdi (login CSRF / kod enjeksiyonu).
        error = 'Güvenlik doğrulaması başarısız (state)';
      } else {
        try {
          session = await exchangeCode(params['code']!, redirectUri, verifier);
        } catch (e) {
          error = '$e';
        }
      }

      if (session != null) {
        html.write(_page(
          title: 'Giriş başarılı ✅',
          body: 'Google Drive hesabınız bağlandı.<br>'
              'Şimdi uygulamaya dönüp işleme devam edebilirsiniz.',
          appLink: true,
        ));
      } else {
        html.write(_page(
          title: 'Giriş tamamlanamadı',
          body: '${error ?? 'Bilinmeyen hata'}<br>'
              'Tarayıcıyı kapatıp uygulamaya dönebilirsiniz.',
        ));
      }

      try {
        request.response.statusCode = session != null ? 200 : 400;
        request.response.headers.contentType = ContentType.html;
        request.response.write(html.toString());
        await request.response.close();
      } catch (_) {
        // Tarayıcı kapandıysa yanıt gönderilemeyebilir.
      }

      if (session == null) {
        throw OAuthException(error ?? 'Giriş tamamlanamadı');
      }
      return session;
    } on TimeoutException {
      throw const OAuthException('Giriş zaman aşımına uğradı');
    } finally {
      await server.close(force: true);
    }
  }

  /// Erişim token'ını yeniler (Google için).
  static Future<OAuthSession> refresh({
    required String clientId,
    required String refreshToken,
    required Uri tokenEndpoint,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.postUrl(tokenEndpoint);
      req.headers.contentType =
          ContentType('application', 'x-www-form-urlencoded');
      req.write(
        'grant_type=refresh_token'
        '&refresh_token=${Uri.encodeQueryComponent(refreshToken)}'
        '&client_id=${Uri.encodeQueryComponent(clientId)}',
      );
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw OAuthException('Token yenileme başarısız (${resp.statusCode}): '
            '${_errorOf(body)}');
      }
      final map = jsonDecode(body) as Map<String, Object?>;
      final access = map['access_token'] as String?;
      if (access == null) throw const OAuthException('Token alınamadı');
      return OAuthSession(
        accessToken: access,
        refreshToken: refreshToken,
        expiresAt: DateTime.now().add(
          Duration(seconds: ((map['expires_in'] as num?)?.toInt() ?? 3600)),
        ),
      );
    } finally {
      client.close(force: true);
    }
  }

  static String _errorOf(String body) {
    try {
      final map = jsonDecode(body) as Map<String, Object?>;
      return '${map['error_description'] ?? map['error'] ?? body}';
    } catch (_) {
      return body;
    }
  }

  /// Tarayıcıda gösterilen sonuç sayfası.
  static String _page({
    required String title,
    required String body,
    bool appLink = false,
  }) {
    // Başlık/gövde sağlayıcı yanıtından gelebilir (hata metni); HTML'e
    // yazılmadan önce kaçışlanır.
    final safeTitle = htmlEscape.convert(title);
    final safeBody = htmlEscape.convert(body);
    return '<!doctype html><html lang="tr"><head>'
        '<meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1">'
        '<title>$safeTitle</title>'
        '<style>body{font-family:system-ui,sans-serif;background:#00897B;'
        'color:#fff;display:flex;align-items:center;justify-content:center;'
        'min-height:100vh;margin:0;text-align:center}'
        '.c{background:rgba(255,255,255,.14);padding:32px;border-radius:16px;'
        'max-width:420px}h1{font-size:22px;margin:0 0 12px}p{line-height:1.5;'
        'margin:0 0 16px}a{color:#fff;font-weight:700}</style>'
        '</head><body><div class="c"><h1>$safeTitle</h1><p>$safeBody</p>'
        '${appLink ? '<a href="makayfm://oauth">Uygulamaya dön</a>' : ''}'
        '</div></body></html>';
  }

  /// Güvenli rastgele token (state / PKCE doğrulayıcı).
  static String _randomToken(int bytes) {
    final rnd = Random.secure();
    final data = List<int>.generate(bytes, (_) => rnd.nextInt(256));
    return _base64Url(data);
  }

  static String _base64Url(List<int> bytes) => base64Url
      .encode(bytes)
      .replaceAll('=', '')
      .replaceAll('+', '-')
      .replaceAll('/', '_');
}

/// Sağlayıcı isteği zaman aşımına uğrayabilir; açık hata mesajı için.
class OAuthException implements Exception {
  const OAuthException(this.message);

  final String message;

  @override
  String toString() => message;
}
