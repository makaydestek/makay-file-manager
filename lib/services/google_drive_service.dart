import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud/cloud_http_client.dart';
import 'cloud/cloud_types.dart';
import 'oauth_service.dart';
import 'secure_store.dart';

/// Google Drive API hata mesajı.
class DriveException implements Exception {
  const DriveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Drive üzerindeki bir dosya/klasör.
class DriveFile {
  DriveFile({
    required this.id,
    required this.name,
    required this.mimeType,
    this.size,
    this.modified,
  });

  final String id;
  final String name;
  final String mimeType;

  /// Bayt; Google belgelerinde null (dışa aktarma gerekir).
  final int? size;
  final DateTime? modified;

  bool get isFolder => mimeType == 'application/vnd.google-apps.folder';

  /// Google belgeleri (Docs/Sheets) indirilebilir değil; dışa aktarılır.
  bool get isGoogleDoc =>
      mimeType.startsWith('application/vnd.google-apps.') && !isFolder;

  factory DriveFile.fromJson(Map<String, Object?> json) => DriveFile(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    mimeType: json['mimeType'] as String? ?? '',
    size: (json['size'] as num?)?.toInt(),
    modified: json['modifiedTime'] is String
        ? DateTime.tryParse(json['modifiedTime'] as String)
        : null,
  );
}

/// Bağlı Google Drive hesabı özeti.
class DriveAccount {
  DriveAccount({
    required this.email,
    required this.quotaBytes,
    required this.usageBytes,
  });

  final String email;
  final int quotaBytes;
  final int usageBytes;
}

/// Google Drive REST v3 istemcisi (OAuth 2.0 + PKCE).
///
/// Akış: tarayıcıda Google girişi → döngü arayüzüne dönen kod → token.
/// OAuth jetonları [SecureStore]'da; client ID / e-posta prefs'te tutulur.
/// Erişim token'ının süresi dolarsa yenileme token'ı ile sessizce yenilenir.
class GoogleDriveService {
  GoogleDriveService._();

  static const _kClientId = 'gdrive_client_id';
  static const _kAccess = 'gdrive_access_token';
  static const _kRefresh = 'gdrive_refresh_token';
  static const _kExpiry = 'gdrive_expiry';
  static const _kEmail = 'gdrive_email';

  static const _kScope = 'https://www.googleapis.com/auth/drive';
  static final _authorizeEndpoint = Uri.parse(
    'https://accounts.google.com/o/oauth2/v2/auth',
  );
  static final _tokenEndpoint = Uri.parse(
    'https://oauth2.googleapis.com/token',
  );
  static final _apiBase = Uri.parse('https://www.googleapis.com/drive/v3/');

  // -------------------------------------------------------------------------
  // Ayarlar / oturum durumu
  // -------------------------------------------------------------------------

  static Future<String?> clientId() async =>
      (await SharedPreferences.getInstance()).getString(_kClientId);

  static Future<void> setClientId(String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value.trim().isEmpty) {
      await prefs.remove(_kClientId);
    } else {
      await prefs.setString(_kClientId, value.trim());
    }
  }

  /// Kullanıcı daha önce bağlandı mı (erişim veya yenileme token'ı var mı)?
  static Future<bool> get hasSession async {
    await _migrateTokensIfNeeded();
    final access = await SecureStore.read(_kAccess);
    final refresh = await SecureStore.read(_kRefresh);
    return (access != null && access.isNotEmpty) ||
        (refresh != null && refresh.isNotEmpty);
  }

  static Future<String?> accountEmail() async =>
      (await SharedPreferences.getInstance()).getString(_kEmail);

  static Future<void> disconnect() async {
    await SecureStore.delete(_kAccess);
    await SecureStore.delete(_kRefresh);
    final prefs = await SharedPreferences.getInstance();
    for (final key in [_kAccess, _kRefresh, _kExpiry, _kEmail]) {
      await prefs.remove(key);
    }
  }

  // -------------------------------------------------------------------------
  // Bağlantı (tarayıcı akışı)
  // -------------------------------------------------------------------------

  /// Tarayıcıda Google girişini başlatır ve oturumu kaydeder.
  ///
  /// [clientID] verilmezse kayıtlı client ID kullanılır; ikisi de yoksa
  /// [DriveException] fırlatır (kullanıcıya ücretsiz kurulum adımları
  /// gösterilmelidir).
  static Future<void> connect({String? clientID}) async {
    final id = (clientID ?? await clientId())?.trim();
    if (id == null || id.isEmpty) {
      throw const DriveException(
        'Google Drive client ID gerekli — Ayarlar > Google Drive bölümünden ücretsiz oluşturup yapıştırın.',
      );
    }
    if (clientID != null && clientID.trim().isNotEmpty) {
      await setClientId(clientID);
    }

    final session = await OAuthService.authorize(
      buildAuthorizeUrl: (redirectUri, state, challenge) =>
          _authorizeEndpoint.replace(
            queryParameters: {
              'client_id': id,
              'redirect_uri': redirectUri,
              'response_type': 'code',
              'scope': _kScope,
              'state': state,
              'code_challenge': challenge,
              'code_challenge_method': 'S256',
              'access_type': 'offline',
              'prompt': 'consent',
              'include_granted_scopes': 'true',
              'hl': 'tr',
            },
          ),
      exchangeCode: (code, redirectUri, verifier) =>
          _exchange(id, code, redirectUri, verifier),
    );

    await _saveSession(session);
  }

  static Future<OAuthSession> _exchange(
    String clientId,
    String code,
    String redirectUri,
    String verifier,
  ) {
    return CloudHttpClient.exchangeCode(
      tokenEndpoint: _tokenEndpoint,
      clientId: clientId,
      code: code,
      redirectUri: redirectUri,
      verifier: verifier,
      errorOf: (status, body) => 'Google reddetti ($status): ${_errorOf(body)}',
      parse: (body) {
        final map = jsonDecode(body) as Map<String, Object?>;
        final access = map['access_token'] as String?;
        if (access == null) throw const DriveException('Token alınamadı');
        return OAuthSession(
          accessToken: access,
          refreshToken: map['refresh_token'] as String?,
          expiresAt: DateTime.now().add(
            Duration(seconds: ((map['expires_in'] as num?)?.toInt() ?? 3600)),
          ),
        );
      },
    );
  }

  static Future<void> _saveSession(OAuthSession session) async {
    await SecureStore.write(_kAccess, session.accessToken);
    if (session.refreshToken != null) {
      await SecureStore.write(_kRefresh, session.refreshToken!);
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kExpiry, session.expiresAt.millisecondsSinceEpoch);
    // Eski düz metin jetonları temizle.
    await prefs.remove(_kAccess);
    await prefs.remove(_kRefresh);
  }

  /// SharedPreferences'taki eski jetonları SecureStore'a taşır (bir kez).
  static Future<void> _migrateTokensIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final legacyAccess = prefs.getString(_kAccess);
    final legacyRefresh = prefs.getString(_kRefresh);
    if (legacyAccess == null && legacyRefresh == null) return;
    if (legacyAccess != null && legacyAccess.isNotEmpty) {
      await SecureStore.write(_kAccess, legacyAccess);
      await prefs.remove(_kAccess);
    }
    if (legacyRefresh != null && legacyRefresh.isNotEmpty) {
      await SecureStore.write(_kRefresh, legacyRefresh);
      await prefs.remove(_kRefresh);
    }
  }

  // -------------------------------------------------------------------------
  // Token yönetimi
  // -------------------------------------------------------------------------

  static Future<String> _token() async {
    await _migrateTokensIfNeeded();
    final prefs = await SharedPreferences.getInstance();
    final access = await SecureStore.read(_kAccess);
    final expiry = DateTime.fromMillisecondsSinceEpoch(
      prefs.getInt(_kExpiry) ?? 0,
    );
    if (access != null &&
        access.isNotEmpty &&
        DateTime.now().isBefore(expiry.subtract(const Duration(seconds: 90)))) {
      return access;
    }
    final refresh = await SecureStore.read(_kRefresh);
    final id = prefs.getString(_kClientId);
    if (refresh == null || refresh.isEmpty || id == null) {
      throw const DriveException('Oturum süresi doldu — tekrar bağlanın.');
    }
    final session = await OAuthService.refresh(
      clientId: id,
      refreshToken: refresh,
      tokenEndpoint: _tokenEndpoint,
    );
    await _saveSession(session);
    return session.accessToken;
  }

  // -------------------------------------------------------------------------
  // Drive API
  // -------------------------------------------------------------------------

  /// Hesap bilgisi + kota (başlıkta gösterilir).
  static Future<DriveAccount> account() async {
    final data = await _json(
      _apiBase.replace(
        path: '${_apiBase.path}about',
        queryParameters: {
          'fields': 'user(emailAddress,displayName),quotaBytes,usageBytes',
        },
      ),
    );
    final user = data['user'] as Map<String, Object?>?;
    final email = user?['emailAddress'] as String? ?? '';
    if (email.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kEmail, email);
    }
    return DriveAccount(
      email: email,
      quotaBytes: (data['quotaBytes'] as num?)?.toInt() ?? 0,
      usageBytes: (data['usageBytes'] as num?)?.toInt() ?? 0,
    );
  }

  /// Klasör içeriğini listeler.
  static Future<List<DriveFile>> list(String folderId) async {
    final q =
        "'${folderId.replaceAll("'", r"\'")}' in parents and trashed = false";
    final data = await _json(
      _apiBase.replace(
        path: '${_apiBase.path}files',
        queryParameters: {
          'q': q,
          'fields': 'files(id,name,mimeType,size,modifiedTime)',
          'orderBy': 'folder,name',
          'pageSize': '1000',
        },
      ),
    );
    final files = data['files'];
    if (files is! List) return const [];
    return files
        .whereType<Map<String, Object?>>()
        .map(DriveFile.fromJson)
        .toList();
  }

  /// Dosyayı yerel olarak indirir (Google belgeleri PDF olarak dışa aktarılır).
  static Future<void> download(
    DriveFile file,
    File target, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final uri = file.isGoogleDoc
        ? _apiBase.replace(
            path: '${_apiBase.path}files/${file.id}/export',
            queryParameters: {'mimeType': 'application/pdf'},
          )
        : _apiBase.replace(
            path: '${_apiBase.path}files/${file.id}',
            queryParameters: {'alt': 'media'},
          );
    await _streamTo(uri, target, onProgress: onProgress);
  }

  /// Yerel dosyayı Drive'a yükler.
  static Future<void> upload(
    String folderId,
    File source, {
    String? name,
    void Function(int sent, int? total)? onProgress,
  }) async {
    final fileName = name ?? source.uri.pathSegments.last;
    final mime = mimeOf(fileName);
    final token = await _token();
    final boundary = 'makayfm_${DateTime.now().millisecondsSinceEpoch}';
    final meta = jsonEncode({
      'name': fileName,
      'parents': [folderId],
      'mimeType': mime,
    });

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.postUrl(
        _apiBase.replace(
          scheme: 'https',
          host: 'www.googleapis.com',
          path: '/upload/drive/v3/files',
          queryParameters: {'uploadType': 'multipart'},
        ),
      );
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..set(
          HttpHeaders.contentTypeHeader,
          'multipart/related; boundary=$boundary',
        );
      req
        ..write(
          '--$boundary\r\n'
          'Content-Type: application/json; charset=UTF-8\r\n\r\n'
          '$meta\r\n',
        )
        ..write(
          '--$boundary\r\n'
          'Content-Type: $mime\r\n\r\n',
        );

      final stream = source.openRead();
      var sent = 0;
      await for (final chunk in stream) {
        sent += chunk.length;
        req.add(chunk);
        onProgress?.call(sent, await source.length());
      }
      req.write('\r\n--$boundary--\r\n');

      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode != 200) {
        throw DriveException(
          'Yükleme başarısız (${resp.statusCode}): ${_errorOf(body)}',
        );
      }
    } finally {
      client.close(force: true);
    }
  }

  /// Klasör oluşturur.
  static Future<void> createFolder(String parentId, String name) async {
    await _json(
      _apiBase.replace(path: '${_apiBase.path}files'),
      method: 'POST',
      body: {
        'name': name,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [parentId],
      },
    );
  }

  /// Dosyayı çöp kutusuna taşır.
  static Future<void> trash(String fileId) async {
    await _json(
      _apiBase.replace(path: '${_apiBase.path}files/$fileId'),
      method: 'PATCH',
      body: {'trashed': true},
    );
  }

  // -------------------------------------------------------------------------
  // HTTP yardımcıları
  // -------------------------------------------------------------------------

  static Future<Map<String, Object?>> _json(
    Uri uri, {
    String method = 'GET',
    Map<String, Object?>? body,
  }) async {
    final token = await _token();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.openUrl(method, uri);
      req.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..contentType = ContentType.json;
      if (body != null) req.write(jsonEncode(body));
      final resp = await req.close();
      final text = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 400) {
        throw DriveException(
          'Google Drive hatası (${resp.statusCode}): ${_errorOf(text)}',
        );
      }
      if (text.isEmpty) return const {};
      return jsonDecode(text) as Map<String, Object?>;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> _streamTo(
    Uri uri,
    File target, {
    void Function(int received, int? total)? onProgress,
  }) async {
    final token = await _token();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final resp = await req.close();
      if (resp.statusCode != 200) {
        final text = await resp.transform(utf8.decoder).join();
        throw DriveException(
          'İndirme başarısız (${resp.statusCode}): ${_errorOf(text)}',
        );
      }
      final total = int.tryParse(
        resp.headers.value(HttpHeaders.contentLengthHeader) ?? '',
      );
      var received = 0;
      final sink = target.openWrite();
      try {
        await for (final chunk in resp) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
    } catch (_) {
      if (target.existsSync()) {
        try {
          target.deleteSync();
        } catch (_) {
          // Yarım indirme temizlenemezse sonraki indirme benzersiz adla
          // yazılır; asıl hatan zaten rethrow ile yukarı taşındı.
        }
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  static String _errorOf(String body) {
    try {
      final map = jsonDecode(body) as Map<String, Object?>;
      final err = map['error'];
      if (err is Map<String, Object?>) {
        return '${err['message'] ?? body}';
      }
      return '${map['error_description'] ?? map['error'] ?? body}';
    } catch (_) {
      return body.length > 200 ? '${body.substring(0, 200)}…' : body;
    }
  }

  /// Basit uzantı → MIME eşlemesi (yüklemede kullanılır).
  @visibleForTesting
  static String mimeOf(String name) => cloudMimeOf(name);
}
