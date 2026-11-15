import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../utils/debug_log.dart';
import 'cloud/cloud_oauth_flow.dart';
import 'cloud/cloud_types.dart';
import 'oauth_service.dart';

// Ortak bulut tipleri (CloudItem / CloudApiException / cloudMimeOf) eski
// import yollarını korumak için yeniden dışa aktarılır.
export 'cloud/cloud_types.dart' show CloudApiException, CloudItem, cloudMimeOf;

/// Dropbox REST v2 istemcisi (OAuth 2.0 + PKCE, tarayıcı tabanlı giriş).
///
/// Token'lar ve client ID [SharedPreferences] içinde saklanır; erişim
/// token'ının süresi dolarsa yenileme token'ı ile sessizce yenilenir.
/// Ortak OAuth/HTTP mantığı [CloudOAuthClient] üzerinde yürür.
class DropboxService {
  DropboxService._();

  static const _kScope = 'files.content.read files.content.write';

  static final _authorizeEndpoint = Uri.parse(
    'https://www.dropbox.com/oauth2/authorize',
  );
  static final _apiBase = Uri.parse('https://api.dropboxapi.com/2/');
  static final _contentBase = Uri.parse('https://content.dropboxapi.com/2/');

  /// Dropbox OAuth/HTTP katmanı (token deposu + yenileme + yetkili istek).
  static final _api = CloudOAuthClient(
    provider: 'Dropbox',
    clientLabel: 'Dropbox',
    tokensKey: 'dropbox_tokens',
    clientIdKey: 'dropbox_client_id',
    tokenEndpoint: Uri.parse('https://api.dropboxapi.com/oauth2/token'),
    defaultExpirySeconds: 14400,
    friendlyMessage: friendlyMessage,
  );

  // -------------------------------------------------------------------------
  // Ayarlar / oturum durumu
  // -------------------------------------------------------------------------

  static Future<void> saveClientSecret(String id) => _api.saveClientId(id);

  static Future<String?> loadClientSecret() => _api.loadClientId();

  /// Kullanıcı daha önce bağlandı mı (erişim veya yenileme token'ı var mı)?
  static Future<bool> hasTokens() => _api.hasTokens();

  /// Yerel oturumu siler (yenileme token'ı da geçersiz olur).
  static Future<void> disconnect() => _api.disconnect();

  // -------------------------------------------------------------------------
  // Bağlantı (tarayıcı akışı)
  // -------------------------------------------------------------------------

  /// Tarayıcıda Dropbox girişini başlatır ve oturumu kaydeder.
  ///
  /// [clientId] boşsa kayıtlı client ID kullanılır; ikisi de yoksa
  /// [CloudApiException] fırlatır (ücretsiz kurulum adımları ekranda gösterilir).
  static Future<void> connect(String clientId) async {
    final id = await _api.requireClientId(clientId);
    final session = await OAuthService.authorize(
      buildAuthorizeUrl: (redirectUri, state, challenge) =>
          _authorizeEndpoint.replace(
            queryParameters: {
              'client_id': id,
              'redirect_uri': redirectUri,
              'response_type': 'code',
              'token_access_type': 'offline',
              'scope': _kScope,
              'state': state,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
            },
          ),
      exchangeCode: (code, redirectUri, verifier) => _api.exchangeCode(
        clientId: id,
        code: code,
        redirectUri: redirectUri,
        verifier: verifier,
      ),
    );
    await _api.saveTokens(session);
  }

  /// Token yanıtının JSON'unu ayrıştırır (ağ erişimi yok, test edilebilir).
  @visibleForTesting
  static OAuthSession parseTokenJson(String body) => _api.parseTokenJson(body);

  /// Erişim token'ını yenileme token'ı ile tazeler; olamazsa false döner.
  static Future<bool> refresh() => _api.refresh();

  // -------------------------------------------------------------------------
  // Dropbox API
  // -------------------------------------------------------------------------

  /// Klasör içeriğini listeler; [folderId] verilmezse kök listelenir.
  static Future<List<CloudItem>> list({String? folderId}) async {
    final items = <CloudItem>[];
    var cursor = '';
    var first = true;
    // Sonsuz döngü koruması: bozuk/kötü niyetli yanıt `has_more` için
    // sürekli true döndürürse liste sayfaları sonsuza kadar çekilmesin.
    for (var page = 0; page < 200; page++) {
      final Map<String, Object?> data;
      if (first) {
        first = false;
        data = await _api.json(
          _apiBase.replace(path: '${_apiBase.path}files/list_folder'),
          method: 'POST',
          body: {'path': folderId ?? '', 'limit': 500},
        );
      } else {
        data = await _api.json(
          _apiBase.replace(path: '${_apiBase.path}files/list_folder/continue'),
          method: 'POST',
          body: {'cursor': cursor},
        );
      }
      items.addAll(cloudItemsOf(data['entries']));
      if (data['has_more'] != true) break;
      final next = data['cursor'] as String? ?? '';
      if (next.isEmpty || next == cursor) break;
      cursor = next;
    }
    return items;
  }

  /// Dosyayı [destPath] konumuna indirir; [onProgress] 0..1 arası ilerleme.
  static Future<void> download(
    String id,
    String name,
    String destPath,
    void Function(double) onProgress,
  ) async {
    await _api.streamToFile(
      (client, token) async {
        final req = await client.postUrl(
          _contentBase.replace(path: '${_contentBase.path}files/download'),
        );
        req.headers
          ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
          ..set('Dropbox-API-Arg', jsonEncode({'path': id}));
        return req.close();
      },
      File(destPath),
      onProgress,
    );
  }

  /// Yerel dosyayı [folderId] klasörüne yükler.
  static Future<void> upload(
    String folderId,
    String srcPath, {
    void Function(double)? onProgress,
  }) async {
    final src = File(srcPath);
    if (!src.existsSync()) {
      throw CloudApiException('Dosya bulunamadı: $srcPath');
    }
    final name = src.uri.pathSegments.last;
    final total = await src.length();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 60);
    try {
      final req = await client.postUrl(
        _contentBase.replace(path: '${_contentBase.path}files/upload'),
      );
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer ${await _api.token()}')
        ..set(
          'Dropbox-API-Arg',
          jsonEncode({
            'path': _joinPath(folderId, name),
            'mode': 'add',
            'autorename': true,
            'mute': false,
          }),
        )
        ..contentType = ContentType.parse(cloudMimeOf(name));
      var sent = 0;
      await for (final chunk in src.openRead()) {
        sent += chunk.length;
        req.add(chunk);
        if (total > 0) {
          onProgress?.call((sent / total).clamp(0.0, 1.0).toDouble());
        }
      }
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw CloudApiException(friendlyMessage(resp.statusCode, text));
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Klasör oluşturur.
  static Future<void> createFolder(String parentFolderId, String name) async {
    await _api.json(
      _apiBase.replace(path: '${_apiBase.path}files/create_folder_v2'),
      method: 'POST',
      body: {'path': _joinPath(parentFolderId, name), 'autorename': false},
    );
  }

  /// Dosyayı veya klasörü kalıcı olarak siler.
  static Future<void> remove(String id, {bool isFolder = false}) async {
    // delete_v2 hem dosya hem klasör için çalışır; isFolder imzası için.
    await _api.json(
      _apiBase.replace(path: '${_apiBase.path}files/delete_v2'),
      method: 'POST',
      body: {'path': id},
    );
  }

  /// Kullanılan / toplam depolama bilgisi.
  static Future<({int used, int total})?> about() async {
    final data = await _api.json(
      _apiBase.replace(path: '${_apiBase.path}users/get_space_usage'),
      method: 'POST',
      body: const <String, Object?>{},
    );
    final used = (data['used'] as num?)?.toInt() ?? 0;
    final allocation = data['allocation'];
    final total = allocation is Map<String, Object?>
        ? (allocation['allocated'] as num?)?.toInt() ?? used
        : used;
    return (used: used, total: total);
  }

  /// Dropbox hata yanıtını Türkçe, okunabilir metne çevirir.
  @visibleForTesting
  static String friendlyMessage(int status, String body) {
    var detail = body;
    try {
      final map = jsonDecode(body) as Map<String, Object?>;
      final error = map['error'];
      detail =
          '${map['error_summary'] ?? (error is Map<String, Object?> ? error['.tag'] ?? body : error ?? body)}';
    } catch (e) {
      logSwallowed('dropbox: hata gövdesi ayrıştırma', e);
    }
    if (status == 401 || status == 403) {
      return 'Oturum süresi doldu veya erişim reddedildi — tekrar bağlanın';
    }
    if (detail.contains('not_found')) return 'Öğe bulunamadı veya silinmiş';
    if (detail.contains('conflict')) return 'Aynı adlı bir öğe zaten var';
    if (detail.contains('too_many')) {
      return 'İstek limiti aşıldı — biraz bekleyip tekrar deneyin';
    }
    if (status >= 500) return 'Dropbox sunucu hatası ($status)';
    return 'Dropbox hatası ($status): $detail';
  }

  /// Kök ('' veya '/') ile dosya adını birleştirir.
  static String _joinPath(String parent, String name) {
    if (parent.isEmpty) return '/$name';
    if (parent.endsWith('/')) return '$parent$name';
    return '$parent/$name';
  }
}
