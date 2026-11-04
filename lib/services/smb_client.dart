import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'ntlm.dart';
import 'remote_service.dart';

/// SMB gezinti girdisi.
class SmbEntry {
  SmbEntry({
    required this.name,
    required this.isDir,
    required this.size,
    this.modified,
  });

  final String name;
  final bool isDir;
  final int size;
  final DateTime? modified;
}

/// SMB hatası (durum kodu + Türkçe açıklama).
class SmbException implements Exception {
  SmbException(this.message, [this.status = 0]);

  final String message;
  final int status;

  static String describe(int status) {
    switch (status & 0xffffffff) {
      case 0xC000006D:
      case 0xC0000064:
      case 0xC000006A:
        return 'Kullanıcı adı veya şifre hatalı';
      case 0xC0000022:
        return 'Erişim reddedildi';
      case 0xC0000034:
      case 0xC000000F:
        return 'Dosya veya klasör bulunamadı';
      case 0xC00000CC:
        return 'Sunucu bulunamadı (paylaşım adı hatalı olabilir)';
      case 0xC0000205:
        return 'Sunucu meşgul, tekrar deneyin';
      default:
        return 'SMB hatası: 0x${status.toRadixString(16).toUpperCase()}';
    }
  }

  @override
  String toString() => message;
}

/// SMB2 istemcisi (dialect 2.0.2+, NTLMv2 kimlik doğrulama).
///
/// Windows/Samba paylaşımlarına bağlanır; paylaşım adı [RemoteLocation.share]
/// içinde verilir (boşsa `C$` denenir). Listeleme, indirme, yükleme, klasör
/// oluşturma, silme ve yeniden adlandırma desteklenir.
class SmbClient {
  SmbClient._(this._socket, this._loc, this._share)
      : _iterator = StreamIterator<List<int>>(_socket);

  final Socket _socket;
  final RemoteLocation _loc;
  final String _share;

  final StreamIterator<List<int>> _iterator;
  var _remainder = <int>[];
  int _messageId = 1;
  int _treeId = 0;
  int _sessionId = 0;
  int _maxRead = 65536;
  int _maxWrite = 65536;
  bool _closed = false;

  static const _accessRead = 0x00120089; // FILE_GENERIC_READ
  static const _accessWrite = 0x00120116; // FILE_GENERIC_WRITE
  static const _accessReadWrite = 0x0012019F; // read|write|delete attributes
  static const _accessDelete = 0x00010000; // DELETE
  static const _dispOpen = 1;
  static const _dispCreate = 2;
  static const _dispOverwriteIf = 5;

  static const _statusSuccess = 0x00000000;
  static const _statusEndOfFile = 0xC0000011;
  static const _statusMoreProcessing = 0xC0000016;
  static const _statusNoMoreFiles = 0x80000006;
  static const _statusNoSuchFile = 0xC000000F;

  /// Sunucuya bağlanır ve oturumu doğrular.
  static Future<SmbClient> connect(RemoteLocation loc) async {
    final share = loc.share.trim().isEmpty ? r'C$' : loc.share.trim();
    final socket = await Socket.connect(
      loc.cleanHost,
      loc.effectivePort,
      timeout: const Duration(seconds: 15),
    );
    socket.setOption(SocketOption.tcpNoDelay, true);
    final client = SmbClient._(socket, loc, share);
    try {
      await client._negotiate();
      await client._sessionSetup();
      await client._treeConnect();
      return client;
    } catch (e) {
      client.destroy();
      if (e is SmbException) rethrow;
      throw SmbException('Bağlantı kurulamadı: $e');
    }
  }

  // -- Altyapı -----------------------------------------------------------------

  Future<List<int>> _readExact(int n) async {
    while (_remainder.length < n) {
      if (!await _iterator.moveNext()) {
        throw SmbException('Bağlantı kapatıldı');
      }
      _remainder = [..._remainder, ..._iterator.current];
    }
    final out = _remainder.sublist(0, n);
    _remainder = _remainder.sublist(n);
    return out;
  }

  /// İstek gönderir; (durum, yanıt tamponu) döndürür. Tampon: 64 bayt başlık +
  /// gövde. Yanıt başlığındaki treeId/sessionId otomatik güncellenir.
  Future<(int, Uint8List)> _request(int command, Uint8List body) async {
    if (_closed) throw SmbException('Oturum kapalı');
    final mid = _messageId++;
    final header = ByteData(64);
    header.setUint32(0, 0x424d53fe, Endian.little);
    header.setUint16(4, 64, Endian.little);
    header.setUint16(6, command == 0 ? 0 : 1, Endian.little); // credit charge
    header.setUint16(12, command, Endian.little);
    header.setUint16(14, 8, Endian.little); // credit request
    header.setUint64(24, mid, Endian.little);
    header.setUint32(36, _treeId, Endian.little);
    header.setUint64(40, _sessionId, Endian.little);

    final payload = Uint8List(64 + body.length);
    payload.setAll(0, header.buffer.asUint8List());
    payload.setAll(64, body);

    final frame = Uint8List(4 + payload.length);
    frame[1] = (payload.length >> 16) & 0xff;
    frame[2] = (payload.length >> 8) & 0xff;
    frame[3] = payload.length & 0xff;
    frame.setAll(4, payload);
    _socket.add(frame);
    await _socket.flush();

    final head = await _readExact(4);
    if (head[0] != 0x00) {
      // Keep-alive (0x85) vb. mesajlar: atla ve tekrar oku.
      final len = (head[1] << 16) | (head[2] << 8) | head[3];
      await _readExact(len);
      return _request(command, body);
    }
    final len = (head[1] << 16) | (head[2] << 8) | head[3];
    final resp = Uint8List.fromList(await _readExact(len));
    final bd = ByteData.sublistView(resp);
    final status = bd.getUint32(8, Endian.little);
    _treeId = bd.getUint32(36, Endian.little);
    _sessionId = bd.getUint64(40, Endian.little);
    return (status, resp);
  }

  void _check(int status, {List<int> ok = const []}) {
    final st = status & 0xffffffff;
    if (ok.contains(st)) return;
    if (st != _statusSuccess) {
      throw SmbException(SmbException.describe(status), status);
    }
  }

  static void _w16(BytesBuilder b, int v) =>
      b.add((ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List());
  static void _w32(BytesBuilder b, int v) =>
      b.add((ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List());
  static void _w64(BytesBuilder b, int v) =>
      b.add((ByteData(8)..setUint64(0, v, Endian.little)).buffer.asUint8List());

  // -- Protokol adımları -------------------------------------------------------

  Future<void> _negotiate() async {
    final guid = List.generate(16, (_) => Random.secure().nextInt(256));
    final dialects = [0x0202, 0x0210, 0x0300];
    final body = BytesBuilder();
    _w16(body, 36); // structure size
    _w16(body, dialects.length);
    _w16(body, 0x01); // signing enabled (zorunlu değil)
    _w16(body, 0); // reserved
    _w32(body, 0); // capabilities
    body.add(guid);
    _w32(body, 0); // negotiate context offset
    _w16(body, 0); // context count
    _w16(body, 0); // reserved
    _w16(body, 128); // security buffer offset
    _w16(body, 0); // security buffer length (boş)
    for (final d in dialects) {
      _w16(body, d);
    }

    final (status, resp) = await _request(0x0000, body.takeBytes());
    _check(status);
    final bd = ByteData.sublistView(resp, 64);
    final securityMode = bd.getUint16(2, Endian.little);
    final dialect = bd.getUint16(4, Endian.little);
    if (dialect < 0x0202) {
      throw SmbException(
          'Sunucu yalnızca eski SMB1 destekliyor', dialect);
    }
    if ((securityMode & 0x02) != 0) {
      throw SmbException(
          'Sunucu oturum imzalamayı zorunlu kılıyor. Paylaşım '
          'politikanızda imzalamayı "etkin ama zorunlu değil" yapın');
    }
    final maxRead = bd.getUint32(32, Endian.little);
    _maxRead = (maxRead <= 0 || maxRead > 1 << 20) ? 65536 : maxRead;
    if (resp.length >= 64 + 40) {
      final maxWrite = bd.getUint32(36, Endian.little);
      _maxWrite = (maxWrite <= 0 || maxWrite > 1 << 20) ? 65536 : maxWrite;
    }
  }

  Future<void> _sessionSetup() async {
    Future<(int, Uint8List)> leg(Uint8List blob) async {
      final body = BytesBuilder();
      _w16(body, 25); // structure size
      body.addByte(0); // flags
      body.addByte(0x01); // security mode: signing enabled
      _w32(body, 0); // capabilities
      _w32(body, 0); // channel
      // MS-SMB2: sabit alanlar 24 bayt → tampon SMB başından 64+24=88.
      _w16(body, 0x58); // security buffer offset
      _w16(body, blob.length);
      _w64(body, 0); // previous session id
      body.add(blob);
      return _request(0x0001, body.takeBytes());
    }

    // Faz 1: NTLM tip-1 (SPNEGO NegTokenInit içinde).
    var (status, resp) = await leg(spnegoNegTokenInit(ntlmType1()));
    if ((status & 0xffffffff) != _statusMoreProcessing) {
      _check(status);
      // Bazı sunucular tek adımda kabul eder (misafir erişimi).
      return;
    }

    // Meydan okuma (tip-2) mesajını güvenlik tamponundan çıkar.
    final bd = ByteData.sublistView(resp, 64);
    final secOffset = bd.getUint16(4, Endian.little);
    final secLen = bd.getUint16(6, Endian.little);
    if (secLen == 0 || secOffset + secLen > resp.length) {
      throw SmbException('Sunucu NTLM meydan okuması vermedi');
    }
    final secBuf =
        Uint8List.sublistView(resp, secOffset, secOffset + secLen);
    final challenge = NtlmChallenge.parse(secBuf);

    // Faz 2: NTLM tip-3 (SPNEGO NegTokenResp içinde).
    final t3 = ntlmType3(
      username: _loc.username,
      domain: '',
      workstation: 'MAKAY',
      password: _loc.password,
      challenge: challenge,
    );
    (status, resp) = await leg(spnegoNegTokenResp(t3));
    _check(status);
  }

  Future<void> _treeConnect() async {
    final path = '\\\\${_loc.cleanHost}\\$_share';
    final encoded = utf16le(path);
    final body = BytesBuilder();
    _w16(body, 9); // structure size
    _w16(body, 0); // reserved
    _w16(body, 0x48); // path offset
    _w16(body, encoded.length);
    body.add(encoded);
    final (status, _) = await _request(0x0003, body.takeBytes());
    _check(status);
  }

  // -- Genel API ---------------------------------------------------------------

  /// [path] dizinini listeler ('/' ve '\' ayırt edilir; kök için '' veya '/').
  Future<List<SmbEntry>> list(String path) async {
    final name = _normalize(path);
    final dirId = await _open(
      name,
      isDir: true,
      desiredAccess: _accessRead,
      disposition: _dispOpen,
    );
    try {
      final entries = <SmbEntry>[];
      var first = true;
      while (true) {
        final body = BytesBuilder();
        _w16(body, 33); // structure size
        body.addByte(37); // FileIdBothDirectoryInformation
        body.addByte(first ? 0x10 : 0); // flags: REOPEN (ilk çağrı)
        _w32(body, 0); // file index
        body.add(dirId);
        _w16(body, 0x60); // file name offset
        _w16(body, 0); // file name length
        _w32(body, 65536); // output buffer length
        final (status, resp) = await _request(0x000e, body.takeBytes());
        first = false;
        final st = status & 0xffffffff;
        if (st == _statusNoMoreFiles || st == _statusNoSuchFile) break;
        _check(status);
        final bd = ByteData.sublistView(resp);
        // Yanıt gövdesi: StructureSize(2), OutputOffset(2), OutputLength(4), Buffer.
        final dataOffset = bd.getUint16(64 + 2, Endian.little);
        final dataLen = bd.getUint32(64 + 4, Endian.little);
        if (dataLen == 0) break;
        final data =
            Uint8List.sublistView(resp, dataOffset, dataOffset + dataLen);
        entries.addAll(_parseDirEntries(data));
      }
      return entries;
    } finally {
      await _closeHandle(dirId);
    }
  }

  /// [path] dosyasını yerel [target] dosyasına indirir.
  Future<void> download(String path, File target) async {
    final name = _normalize(path);
    final id = await _open(
      name,
      isDir: false,
      desiredAccess: _accessRead,
      disposition: _dispOpen,
    );
    try {
      final raf = await target.open(mode: FileMode.write);
      try {
        var offset = 0;
        while (true) {
          final body = BytesBuilder();
          _w16(body, 49); // structure size
          body.addByte(0); // padding
          body.addByte(0); // flags
          _w32(body, _maxRead);
          _w64(body, offset);
          body.add(id);
          _w32(body, 0); // minimum count
          _w32(body, 0); // channel
          _w32(body, 0); // remaining bytes
          _w16(body, 0); // read channel info length
          _w16(body, 0); // read channel info offset
          final (status, resp) = await _request(0x0008, body.takeBytes());
          final st = status & 0xffffffff;
          if (st == _statusEndOfFile) break;
          _check(status);
          final bd = ByteData.sublistView(resp);
          final dataOffset = bd.getUint8(64 + 2);
          final dataLen = bd.getUint32(64 + 4, Endian.little);
          if (dataLen == 0) break;
          final data =
              Uint8List.sublistView(resp, dataOffset, dataOffset + dataLen);
          await raf.writeFrom(data);
          offset += dataLen;
          if (dataLen < _maxRead) break;
        }
      } finally {
        await raf.close();
      }
    } finally {
      await _closeHandle(id);
    }
  }

  /// Yerel [source] dosyasını uzak [path] konumuna yükler (üzerine yazar).
  Future<void> upload(String path, File source) async {
    final name = _normalize(path);
    final id = await _open(
      name,
      isDir: false,
      desiredAccess: _accessWrite,
      disposition: _dispOverwriteIf,
      createOptions: 0x00000040, // FILE_NON_DIRECTORY_FILE
    );
    try {
      final raf = await source.open();
      try {
        var offset = 0;
        while (true) {
          final chunk = await raf.read(_maxWrite);
          if (chunk.isEmpty) break;
          await _write(id, offset, chunk);
          offset += chunk.length;
          if (chunk.length < _maxWrite) break;
        }
      } finally {
        await raf.close();
      }
    } finally {
      await _closeHandle(id);
    }
  }

  /// Uzak [path] klasörünü oluşturur.
  Future<void> mkdir(String path) async {
    final name = _normalize(path);
    final id = await _open(
      name,
      isDir: true,
      desiredAccess: _accessReadWrite,
      disposition: _dispCreate,
      createOptions: 0x00000001, // FILE_DIRECTORY_FILE
    );
    await _closeHandle(id);
  }

  /// Uzak dosya veya klasörü siler.
  Future<void> delete(String path, {required bool isDir}) async {
    final name = _normalize(path);
    final id = await _open(
      name,
      isDir: isDir,
      desiredAccess: _accessDelete | _accessReadWrite,
      disposition: _dispOpen,
      createOptions: isDir ? 0x00000001 : 0x00000040,
    );
    try {
      // FileDispositionInformation (info class 13): DeleteFile = 1
      final info = Uint8List(1)..[0] = 1;
      final (status, _) = await _setInfo(id, infoClass: 13, buffer: info);
      _check(status);
    } finally {
      await _closeHandle(id);
    }
  }

  /// Uzak dosya/klasörü yeniden adlandırır ([from] → [to], tam yollar).
  Future<void> rename(String from, String to) async {
    final src = _normalize(from);
    final dst = _normalize(to);
    // Kaynak türünü bilmiyoruz; önce dosya, olmazsa klasör dene.
    Object? last;
    for (final isDir in [false, true]) {
      try {
        final id = await _open(
          src,
          isDir: isDir,
          desiredAccess: _accessDelete | _accessReadWrite,
          disposition: _dispOpen,
          createOptions: isDir ? 0x00000001 : 0x00000040,
        );
        try {
          final encoded = utf16le(dst);
          // FileRenameInformation: ReplaceIfExists(1)+Reserved(7)+Root(8)+Len(4)+Name
          final info = BytesBuilder();
          info.addByte(1); // replace if exists
          info.add(Uint8List(7));
          _w64(info, 0); // root directory
          _w32(info, encoded.length);
          info.add(encoded);
          final (status, _) =
              await _setInfo(id, infoClass: 10, buffer: info.takeBytes());
          _check(status);
          return;
        } finally {
          await _closeHandle(id);
        }
      } catch (e) {
        last = e;
      }
    }
    if (last is SmbException) throw last;
    throw SmbException('Yeniden adlandırılamadı: $last');
  }

  /// SMB2 SET_INFO (MS-SMB2 2.2.39).
  Future<(int, Uint8List)> _setInfo(
    Uint8List id, {
    required int infoClass,
    required List<int> buffer,
  }) async {
    final body = BytesBuilder();
    _w16(body, 33); // structure size
    body.addByte(1); // SMB2_0_INFO_FILE
    body.addByte(infoClass);
    _w32(body, buffer.length);
    _w16(body, 0x60); // buffer offset (header+32)
    _w16(body, 0); // reserved
    body.add(id);
    // 64 + 28 = 92; 0x60=96 → 4 bayt hizalama.
    body.add(Uint8List(4));
    body.add(buffer);
    return _request(0x0011, body.takeBytes());
  }

  Future<void> _write(Uint8List id, int offset, List<int> data) async {
    final body = BytesBuilder();
    _w16(body, 49); // structure size
    _w16(body, 0x70); // data offset (header 64 + fixed 48)
    _w32(body, data.length);
    _w64(body, offset);
    body.add(id);
    _w32(body, 0); // channel
    _w32(body, 0); // remaining bytes
    _w16(body, 0); // write channel info offset
    _w16(body, 0); // write channel info length
    _w32(body, 0); // flags
    body.add(data);
    final (status, _) = await _request(0x0009, body.takeBytes());
    _check(status);
  }

  /// Oturumu kapatır.
  Future<void> close() async {
    if (_closed) return;
    try {
      final body = BytesBuilder();
      _w16(body, 4); // structure size
      _w32(body, 0); // reserved
      await _request(0x0002, body.takeBytes()); // logoff
    } catch (_) {
      // Kapanış hataları yutulur.
    }
    destroy();
  }

  /// Bağlantıyı anında kapatır (hata yolları için).
  void destroy() {
    _closed = true;
    _socket.destroy();
  }

  // -- Dahili yardımcılar -------------------------------------------------------

  static String _normalize(String path) {
    var p = path.replaceAll('/', r'\');
    return p.replaceAll(RegExp(r'^\\+|\\+$'), '');
  }

  Future<Uint8List> _open(
    String name, {
    required bool isDir,
    int desiredAccess = _accessRead,
    int disposition = _dispOpen,
    int? createOptions,
  }) async {
    final encoded = utf16le(name);
    final body = BytesBuilder();
    _w16(body, 57); // structure size
    body.addByte(0); // security flags
    body.addByte(0); // oplock level
    _w32(body, 2); // impersonation level: IMPERSONATION
    _w64(body, 0); // smb create flags
    _w64(body, 0); // reserved
    _w32(body, desiredAccess);
    _w32(body, isDir ? 0x10 : 0); // file attributes
    _w32(body, 7); // share access: read|write|delete
    _w32(body, disposition);
    _w32(
      body,
      createOptions ?? (isDir ? 0x00000001 : 0x00000040),
    );
    _w16(body, 120); // name offset (64 + 56)
    _w16(body, encoded.length);
    _w32(body, 0); // contexts offset
    _w32(body, 0); // contexts length
    body.add(encoded);
    final (status, resp) = await _request(0x0005, body.takeBytes());
    _check(status);
    // FileId gövde ofseti 64'te başlar (MS-SMB2 CREATE Response).
    return Uint8List.fromList(resp.sublist(64 + 64, 64 + 80));
  }

  Future<void> _closeHandle(Uint8List id) async {
    try {
      final body = BytesBuilder();
      _w16(body, 24); // structure size
      body.addByte(0); // flags
      body.addByte(0); // reserved
      _w32(body, 0); // reserved
      body.add(id);
      await _request(0x0006, body.takeBytes());
    } catch (_) {
      // Kapama hataları yutulur.
    }
  }

  List<SmbEntry> _parseDirEntries(Uint8List data) {
    final entries = <SmbEntry>[];
    final bd = ByteData.sublistView(data);
    var pos = 0;
    while (pos + 104 <= data.length) {
      final next = bd.getUint32(pos, Endian.little);
      final changeTime = bd.getUint64(pos + 32, Endian.little);
      final eof = bd.getUint64(pos + 40, Endian.little);
      final attrs = bd.getUint32(pos + 56, Endian.little);
      final nameLen = bd.getUint32(pos + 60, Endian.little);
      if (nameLen > 0 && pos + 104 + nameLen <= data.length) {
        final name = _decodeUtf16(data, pos + 104, nameLen);
        if (name != '.' && name != '..') {
          entries.add(SmbEntry(
            name: name,
            isDir: (attrs & 0x10) != 0,
            size: eof,
            modified: _filetimeToDateTime(changeTime),
          ));
        }
      }
      if (next == 0) break;
      pos += next;
    }
    entries.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  static DateTime? _filetimeToDateTime(int ft) {
    if (ft == 0) return null;
    try {
      return DateTime.fromMicrosecondsSinceEpoch(
        (ft ~/ 10) - 11644473600000000,
        isUtc: true,
      ).toLocal();
    } catch (_) {
      return null;
    }
  }

  /// UTF-16LE metin çözümleyici (hizasız ofsetlerde güvenli).
  static String _decodeUtf16(Uint8List data, int offset, int len) {
    final bd = ByteData.sublistView(data, offset, offset + len);
    final codes = <int>[];
    for (var i = 0; i + 1 < len; i += 2) {
      codes.add(bd.getUint16(i, Endian.little));
    }
    return String.fromCharCodes(codes);
  }
}
