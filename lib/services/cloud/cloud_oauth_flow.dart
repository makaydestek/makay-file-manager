import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../oauth_service.dart';
import '../secure_store.dart';
import 'cloud_http_client.dart';
import 'cloud_types.dart';

/// Dropbox / OneDrive / Box için ortak OAuth2 katmanı.
///
/// SharedPreferences'ta saklanan token/client ID yönetimi, authorization
/// code + PKCE değiş tokuşu, token yenileme ve süresi dolmak üzere olan
/// erişim token'ını veren [token] mantığını barındırır. Sağlayıcıya özgü
/// uç adresleri, varsayılan süre ve hata çevirisi kurucuda verilir.
class CloudOAuthClient {
  CloudOAuthClient({
    required this.provider,
    required this.clientLabel,
    required this.tokensKey,
    required this.clientIdKey,
    required this.tokenEndpoint,
    required this.defaultExpirySeconds,
    required this.friendlyMessage,
  });

  /// Kısa sağlayıcı adı (hata önekleri ve "bağlı değil" mesajları).
  final String provider;

  /// Client ID eksik mesajındaki ad, ör. 'OneDrive (Microsoft)'.
  final String clientLabel;

  /// SharedPreferences token deposu anahtarı (JSON gövde).
  final String tokensKey;

  /// SharedPreferences client ID anahtarı.
  final String clientIdKey;

  /// Token uç noktası (authorization_code ve refresh_token için).
  final Uri tokenEndpoint;

  /// Token yanıtında expires_in yoksa varsayılan süre (saniye).
  final int defaultExpirySeconds;

  /// 401+ hatalarda kullanılacak sağlayıcıya özgü Türkçe hata çevirici.
  final String Function(int status, String body) friendlyMessage;

  // -------------------------------------------------------------------------
  // Client ID deposu
  // -------------------------------------------------------------------------

  Future<void> saveClientId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id.trim().isEmpty) {
      await prefs.remove(clientIdKey);
    } else {
      await prefs.setString(clientIdKey, id.trim());
    }
  }

  Future<String?> loadClientId() async =>
      (await SharedPreferences.getInstance()).getString(clientIdKey);

  /// Verilen client ID'yi kaydeder (boşsa kayıtlı olanı kullanır);
  /// ikisi de yoksa [CloudApiException] fırlatır.
  Future<String> requireClientId(String given) async {
    var id = given.trim();
    if (id.isEmpty) {
      id = (await loadClientId())?.trim() ?? '';
    }
    if (id.isEmpty) {
      throw CloudApiException(
        '$clientLabel client ID gerekli — Bulut ekranındaki ücretsiz '
        'kurulum adımlarını izleyip yapıştırın.',
      );
    }
    await saveClientId(id);
    return id;
  }

  // -------------------------------------------------------------------------
  // Token deposu
  // -------------------------------------------------------------------------

  /// Kullanıcı daha önce bağlandı mı (erişim veya yenileme token'ı var mı)?
  Future<bool> hasTokens() async {
    final session = await loadTokens();
    return session != null &&
        (session.accessToken.isNotEmpty ||
            (session.refreshToken?.isNotEmpty ?? false));
  }

  /// Yerel oturumu siler (yenileme token'ı da geçersiz olur).
  Future<void> disconnect() async {
    await SecureStore.delete(tokensKey);
    // Eski düz metin tercihlerden de temizle.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokensKey);
  }

  Future<void> saveTokens(OAuthSession session) async {
    final payload = jsonEncode({
      'access_token': session.accessToken,
      'refresh_token': session.refreshToken,
      'expires_at': session.expiresAt.millisecondsSinceEpoch,
    });
    await SecureStore.write(tokensKey, payload);
    // Eski prefs kaydını kaldır (düz metin sızıntısı olmasın).
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(tokensKey);
  }

  Future<OAuthSession?> loadTokens() async {
    var raw = await SecureStore.read(tokensKey);
    if (raw == null || raw.isEmpty) {
      // Eski sürümlerden migrasyon: SharedPreferences → SecureStore.
      final prefs = await SharedPreferences.getInstance();
      raw = prefs.getString(tokensKey);
      if (raw != null && raw.isNotEmpty) {
        await SecureStore.write(tokensKey, raw);
        await prefs.remove(tokensKey);
      }
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, Object?>;
      final access = map['access_token'] as String? ?? '';
      final refresh = map['refresh_token'] as String?;
      if (access.isEmpty && refresh == null) return null;
      return OAuthSession(
        accessToken: access,
        refreshToken: refresh,
        expiresAt: DateTime.fromMillisecondsSinceEpoch(
          (map['expires_at'] as num?)?.toInt() ?? 0,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  /// Token yanıtının JSON'unu ayrıştırır (ağ erişimi yok, test edilebilir).
  OAuthSession parseTokenJson(String body) {
    final map = jsonDecode(body) as Map<String, Object?>;
    final access = map['access_token'] as String?;
    if (access == null || access.isEmpty) {
      throw CloudApiException('$provider token alınamadı');
    }
    return OAuthSession(
      accessToken: access,
      refreshToken: map['refresh_token'] as String?,
      expiresAt: DateTime.now().add(
        Duration(
          seconds: (map['expires_in'] as num?)?.toInt() ?? defaultExpirySeconds,
        ),
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Bağlantı / token akışı
  // -------------------------------------------------------------------------

  /// authorization_code + PKCE kodunu token'larla değiştirir.
  Future<OAuthSession> exchangeCode({
    required String clientId,
    required String code,
    required String redirectUri,
    required String verifier,
  }) {
    return CloudHttpClient.exchangeCode(
      tokenEndpoint: tokenEndpoint,
      clientId: clientId,
      code: code,
      redirectUri: redirectUri,
      verifier: verifier,
      errorOf: friendlyMessage,
      parse: parseTokenJson,
    );
  }

  /// Erişim token'ını yenileme token'ı ile tazeler; olamazsa false döner.
  Future<bool> refresh() async {
    final stored = await loadTokens();
    final rt = stored?.refreshToken;
    final clientId = await loadClientId();
    if (rt == null || clientId == null) return false;
    final fresh = await CloudHttpClient.refreshToken(
      tokenEndpoint: tokenEndpoint,
      clientId: clientId,
      refreshToken: rt,
      parse: parseTokenJson,
    );
    if (fresh == null) return false;
    await saveTokens(
      OAuthSession(
        accessToken: fresh.accessToken,
        refreshToken: fresh.refreshToken ?? rt,
        expiresAt: fresh.expiresAt,
      ),
    );
    return true;
  }

  /// Süresi dolmak üzere olan token'ı gerekirse yenileyerek döner.
  Future<String> token() async {
    final stored = await loadTokens();
    if (stored == null) {
      throw CloudApiException('$provider bağlı değil — önce bağlanın.');
    }
    final soon = DateTime.now().add(const Duration(seconds: 90));
    if (stored.accessToken.isNotEmpty && stored.expiresAt.isAfter(soon)) {
      return stored.accessToken;
    }
    if (await refresh()) {
      final next = await loadTokens();
      if (next != null && next.accessToken.isNotEmpty) {
        return next.accessToken;
      }
    }
    await disconnect();
    throw const CloudApiException('Oturum süresi doldu — tekrar bağlanın.');
  }

  // -------------------------------------------------------------------------
  // HTTP yardımcıları (ortak gövde)
  // -------------------------------------------------------------------------

  /// 401/403 alınırsa token'ı yeniler ve isteği bir kez tekrarlar.
  Future<HttpClientResponse> authorized(
    Future<HttpClientResponse> Function() send,
  ) {
    return CloudHttpClient.authorized(
      send,
      refresh: refresh,
      disconnect: disconnect,
    );
  }

  /// JSON gövdeli yetkili istek.
  Future<Map<String, Object?>> json(
    Uri uri, {
    String method = 'GET',
    Object? body,
  }) {
    return CloudHttpClient.json(
      uri,
      method: method,
      body: body,
      token: token,
      refresh: refresh,
      disconnect: disconnect,
      friendlyMessage: friendlyMessage,
    );
  }

  /// Yetki başlığı taşıyan istekle dosya indirme (Dropbox).
  Future<void> streamToFile(
    Future<HttpClientResponse> Function(HttpClient client, String token) send,
    File target,
    void Function(double) onProgress,
  ) {
    return CloudHttpClient.streamToFile(
      send,
      target,
      onProgress,
      token: token,
      refresh: refresh,
      disconnect: disconnect,
      friendlyMessage: friendlyMessage,
    );
  }

  /// Yetki başlığı olmadan imzalı adrese dosya indirme (OneDrive / Box).
  Future<void> streamUnsigned(
    Uri uri,
    File target,
    void Function(double) onProgress,
  ) {
    return CloudHttpClient.streamUnsigned(
      uri,
      target,
      onProgress,
      friendlyMessage: friendlyMessage,
    );
  }
}
