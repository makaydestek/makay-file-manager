import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'ntlm.dart';

/// Makay Dosya Yöneticisi — gömülü mini SMB2 sunucusu (Windows paylaşımı).
///
/// Saf Dart implementasyonu; SMB 2.0.2 dialeği. Okuma + yazma (yükleme,
/// klasör oluşturma, silme, yeniden adlandırma) desteklenir.
/// NTLMv2 kimlik doğrulama zorunludur ([username] / [password]); yanlış
/// parola `STATUS_LOGON_FAILURE` ile reddedilir. Yalnızca güvendiğiniz
/// Wi-Fi'de açın.
///
/// Kullanım (PC'den): `\\<telefon-ip>\makay`
class MiniSmbServer {
  MiniSmbServer({
    required this.rootPath,
    this.port = 445,
    this.shareName = 'makay',
    this.showHidden = false,
    this.username = 'admin',
    this.password = '',
  });

  final String rootPath;
  final int port;
  final String shareName;
  final bool showHidden;

  /// NTLMv2 ile doğrulanacak kullanıcı adı (büyük/küçük harf duyarsız).
  final String username;

  /// NTLMv2 ile doğrulanacak parola. Boş bırakılırsa tüm oturumlar reddedilir.
  final String password;

  // Paylaşımın kozmetik disk bilgisi (Explorer'da görünen alanlar).
  static const int totalUnits = 0x4000000; // 64 GiB / 4 KiB
  static const int freeUnits = 0x2000000; // 32 GiB / 4 KiB

  bool get running => _control != null;
  ServerSocket? _control;
  final _log = StreamController<String>.broadcast();
  final _random = Random.secure();

  /// Sunucunun gerçekten dinlendiği port.
  ///
  /// Yapıcıya `0` verilirse işletim sistemi boş bir port tahsis eder; test
  /// "boş port bul → kapat → bağlan" yarışını tamamen ortadan kaldırır.
  int get boundPort => _control?.port ?? port;

  /// Sunucu günlüğü (ekranda gösterilir).
  Stream<String> get log => _log.stream;

  Future<void> start() async {
    if (running) return;
    final control = await ServerSocket.bind(InternetAddress.anyIPv4, port);
    _control = control;
    _log.add('SMB2 sunucusu başladı: port ${control.port}, paylaşım: '
        '\\\\$shareName');
    // Dinleyici düzeyindeki soket hataları asla süreci sonlandırmamalı:
    // onError'a ulaşmayan geç hatalar bölgeye düşer ve burada yutulur.
    runZonedGuarded<void>(() {
      control.listen(
        (socket) => unawaited(_handleClient(socket)),
        onError: (Object e) => _log.add('SMB dinleyici hatası: $e'),
      );
    }, (Object e, StackTrace s) {
      _log.add('SMB dinleyici hatası (yutuldu): $e');
    });
  }

  Future<void> stop() async {
    await _control?.close();
    _control = null;
    _log.add('SMB sunucusu durdu.');
  }

  Future<void> _handleClient(Socket socket) async {
    final session = _SmbSession(this, socket);
    try {
      await session.run();
    } catch (_) {
      // Kapanan bağlantılar yutulur.
    } finally {
      socket.destroy();
    }
  }

  Uint8List randomFileId() =>
      Uint8List.fromList(List.generate(16, (_) => _random.nextInt(256)));
}

// ---------------------------------------------------------------------------
// SMB2 sabitleri
// ---------------------------------------------------------------------------

const int _cmdNegotiate = 0x0000;
const int _cmdSessionSetup = 0x0001;
const int _cmdLogoff = 0x0002;
const int _cmdTreeConnect = 0x0003;
const int _cmdTreeDisconnect = 0x0004;
const int _cmdCreate = 0x0005;
const int _cmdClose = 0x0006;
const int _cmdFlush = 0x0007;
const int _cmdRead = 0x0008;
const int _cmdWrite = 0x0009;
const int _cmdQueryDirectory = 0x000e;
const int _cmdQueryInfo = 0x0010;
const int _cmdSetInfo = 0x0011;
const int _cmdEcho = 0x0013;

const int _statusSuccess = 0x00000000;
const int _statusEndOfFile = 0xC0000011;
const int _statusMoreProcessing = 0xC0000016;
const int _statusAccessDenied = 0xC0000022;
const int _statusObjectNameNotFound = 0xC0000034;
const int _statusLogonFailure = 0xC000006D;
const int _statusNoMoreFiles = 0x80000006;
const int _statusInvalidParameter = 0xC000000D;
const int _statusNotSupported = 0xC00000BB;
const int _statusInfoLengthMismatch = 0xC0000004;

const int _fileAttrReadonly = 0x00000001;
const int _fileAttrDirectory = 0x00000010;
const int _fileAttrNormal = 0x00000080;

/// NTLMSSP mekanizma OID'si (1.3.6.1.4.1.311.2.2.10).
final List<int> _ntlmOid = [
  0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04,
];

/// SPNEGO NegTokenInit (yalnızca NTLMSSP mekanizması).
final Uint8List _spnegoInit = Uint8List.fromList([
  0x60, 0x1c, 0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02, //
  0xa1, 0x12, 0x30, 0x10, 0xa0, 0x0e, 0x30, 0x0c, //
  ..._ntlmOid,
]);

// ---------------------------------------------------------------------------
// Bayt yardımcıları
// ---------------------------------------------------------------------------

class _Buf {
  final _b = BytesBuilder();

  void u8(int v) => _b.addByte(v & 0xff);
  void u16(int v) {
    _b.addByte(v & 0xff);
    _b.addByte((v >> 8) & 0xff);
  }

  void u32(int v) {
    for (var i = 0; i < 4; i++) {
      _b.addByte((v >> (8 * i)) & 0xff);
    }
  }

  void u64(int v) {
    for (var i = 0; i < 8; i++) {
      _b.addByte((v >> (8 * i)) & 0xff);
    }
  }

  void bytes(List<int> d) => _b.add(d);
  void zeros(int n) => _b.add(List.filled(n, 0));
  void utf16(String s) =>
      _b.add(Uint16List.fromList(s.codeUnits).buffer.asUint8List());
  int get length => _b.length;
  Uint8List take() => _b.takeBytes();
}

class _Reader {
  _Reader(this._data) : _bd = ByteData.sublistView(_data);

  final Uint8List _data;
  final ByteData _bd;
  int off = 0;

  int u8() => _bd.getUint8(off++);
  int u16() {
    final v = _bd.getUint16(off, Endian.little);
    off += 2;
    return v;
  }

  int u32() {
    final v = _bd.getUint32(off, Endian.little);
    off += 4;
    return v;
  }

  int u64() {
    final v = _bd.getUint64(off, Endian.little);
    off += 8;
    return v;
  }

  Uint8List take(int n) {
    final v = Uint8List.sublistView(_data, off, off + n);
    off += n;
    return v;
  }

  /// Belirtilen konumdan UTF-16LE metin okur (imetçiyi ilerletmez).
  String utf16At(int offset, int n) {
    final codes = <int>[];
    final view = ByteData.sublistView(_data, offset, offset + n);
    for (var i = 0; i < n; i += 2) {
      codes.add(view.getUint16(i, Endian.little));
    }
    return String.fromCharCodes(codes);
  }
}

int _filetime(DateTime dt) =>
    (dt.microsecondsSinceEpoch + 11644473600000000) * 10;

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

// ---------------------------------------------------------------------------
// Dizin girdisi ve tutamaç modelleri
// ---------------------------------------------------------------------------

class _DirItem {
  _DirItem(this.name, this.isDir, this.entity, this.stat);

  final String name;
  final bool isDir;
  final FileSystemEntity entity;
  final FileStat stat;
}

class _SmbHandle {
  _SmbHandle(this.entity, this.isDir);

  FileSystemEntity entity;
  final bool isDir;
  bool deleteOnClose = false;

  /// Dizin gezinme durumu (QUERY_DIRECTORY imleci).
  List<_DirItem>? listing;
  int cursor = 0;
}

// ---------------------------------------------------------------------------
// Oturum
// ---------------------------------------------------------------------------

class _SmbSession {
  _SmbSession(this.server, this.socket);

  final MiniSmbServer server;
  final Socket socket;

  bool _authenticated = false;
  bool _treeConnected = false;
  /// Oturuma özel NTLM Tip-2 meydanı (8 bayt); tip-3 doğrulamasında kullanılır.
  Uint8List? _serverChallenge;
  final _handles = <String, _SmbHandle>{};

  Future<void> run() async {
    final iterator = StreamIterator(socket);
    var remainder = <int>[];

    Future<List<int>> readExact(int n) async {
      while (remainder.length < n) {
        if (!await iterator.moveNext()) {
          throw const SocketException('bağlantı kapandı');
        }
        remainder = [...remainder, ...iterator.current];
      }
      final out = Uint8List.fromList(remainder.sublist(0, n));
      remainder = remainder.sublist(n);
      return out;
    }

    while (true) {
      final head = await readExact(4);
      final type = head[0];
      final len = (head[1] << 16) | (head[2] << 8) | head[3];
      if (type != 0x00) {
        // Keep-alive (0x85) vb. atlanır.
        await readExact(len);
        continue;
      }
      final payload = Uint8List.fromList(await readExact(len));
      final response = _handleRequest(payload);
      if (response == null) continue;
      // NetBIOS oturum mesajı çerçevelemesi.
      final frame = Uint8List(4 + response.length);
      frame[1] = (response.length >> 16) & 0xff;
      frame[2] = (response.length >> 8) & 0xff;
      frame[3] = response.length & 0xff;
      frame.setAll(4, response);
      socket.add(frame);
      await socket.flush();
    }
  }

  Uint8List? _handleRequest(Uint8List payload) {
    if (payload.length < 64) return null;
    final r = _Reader(payload);
    if (r.u32() != 0x424d53fe) {
      // SMB1 isteği gelirse SMB2 dialeği önerilir.
      return _statusMsg(0, _statusSuccess, 0,
          body: _buf((b) {
            b.u16(65);
            b.u16(1);
          }));
    }
    r.u16(); // structure size
    final creditCharge = r.u16();
    r.u32(); // istemci tarafı durum
    final command = r.u16();
    final creditReq = r.u16();
    r.u32(); // flags
    r.u32(); // next command
    final messageId = r.u64();
    r.u32(); // process id
    r.u32(); // tree id (oturum durumundan)
    final sessionId = r.u64();

    int sid() => _authenticated ? 1 : 0;
    int tid() => _treeConnected ? 1 : 0;

    switch (command) {
      case _cmdNegotiate:
        return _onNegotiate(command, messageId, creditCharge, creditReq);
      case _cmdSessionSetup:
        return _onSessionSetup(command, messageId, creditCharge, creditReq, r);
      case _cmdTreeConnect:
        return _onTreeConnect(command, messageId, creditCharge, creditReq, r);
      case _cmdCreate:
        return _onCreate(command, messageId, creditCharge, creditReq, r);
      case _cmdRead:
        return _onRead(command, messageId, creditCharge, creditReq, r);
      case _cmdWrite:
        return _onWrite(command, messageId, creditCharge, creditReq, r);
      case _cmdQueryDirectory:
        return _onQueryDirectory(command, messageId, creditCharge, creditReq, r);
      case _cmdQueryInfo:
        return _onQueryInfo(command, messageId, creditCharge, creditReq, r);
      case _cmdSetInfo:
        return _onSetInfo(command, messageId, creditCharge, creditReq, r);
      case _cmdClose:
        return _onClose(command, messageId, creditCharge, creditReq, r);
      case _cmdFlush:
      case _cmdEcho:
      case _cmdLogoff:
        return _statusMsg(command, _statusSuccess, messageId,
            creditCharge: creditCharge, creditReq: creditReq,
            treeId: tid(), sessionId: sid());
      case _cmdTreeDisconnect:
        _treeConnected = false;
        _handles.clear();
        return _statusMsg(command, _statusSuccess, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 0);
      default:
        server._log.add(
            'Desteklenmeyen SMB komutu: 0x${command.toRadixString(16)} '
            '(session=$sessionId)');
        return _statusMsg(command, _statusNotSupported, messageId,
            creditCharge: creditCharge, creditReq: creditReq,
            treeId: tid(), sessionId: sid());
    }
  }

  // -- Yanıt oluşturucular ------------------------------------------------

  Uint8List _statusMsg(int command, int status, int messageId,
      {int creditCharge = 1, int creditReq = 1, int treeId = 0, int sessionId = 0, Uint8List? body}) {
    final credits = creditReq > 0 ? (creditReq > 15 ? 15 : creditReq) : 1;
    final b = _Buf();
    b.u32(0x424d53fe); // 'FE SMB'
    b.u16(64); // structure size
    b.u16(creditCharge > 0 ? creditCharge : 1);
    b.u32(status);
    b.u16(command);
    b.u16(credits);
    b.u32(0x40000000); // SERVER_TO_REDIR
    b.u32(0); // next command
    b.u64(messageId);
    b.u32(0); // process id
    b.u32(treeId);
    b.u64(sessionId);
    b.zeros(16); // imza (imzalama gerekmiyor)
    b.bytes(body ?? const []);
    return b.take();
  }

  Uint8List _onNegotiate(
      int command, int messageId, int creditCharge, int creditReq) {
    final now = DateTime.now();
    final body = _Buf();
    body.u16(65);
    body.u16(0x0001); // signing enabled (zorunlu değil)
    body.u16(0x0202); // SMB 2.0.2
    body.u16(0); // negotiate context count
    body.bytes(List.generate(16, (i) => 0x4d + i)); // ServerGuid
    body.u32(0); // capabilities
    body.u32(65536); // max transact
    body.u32(65536); // max read
    body.u32(65536); // max write
    body.u64(_filetime(now)); // system time
    body.u64(_filetime(now)); // server start time
    body.u16(64 + 64); // security buffer offset (baştan itibaren)
    body.u16(_spnegoInit.length);
    body.u32(0); // negotiate context offset
    body.bytes(_spnegoInit);
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, body: body.take());
  }

  Uint8List _onSessionSetup(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16(); // structure size
    r.u8(); // flags
    r.u8(); // security mode
    r.u32(); // capabilities
    r.u32(); // channel
    final secOffset = r.u16();
    final secLen = r.u16();

    final secBuf = (secLen > 0 && secOffset + secLen <= r._data.length)
        ? Uint8List.sublistView(r._data, secOffset, secOffset + secLen)
        : Uint8List(0);

    // NTLMSSP tip bayrağını bul (8 bayt imza + 4 bayt tip).
    var ntlmType = 0;
    for (var i = 0; i + 12 <= secBuf.length; i++) {
      if (secBuf[i] == 0x4e &&
          secBuf[i + 1] == 0x54 &&
          secBuf[i + 2] == 0x4c &&
          secBuf[i + 3] == 0x4d &&
          secBuf[i + 4] == 0x53 &&
          secBuf[i + 5] == 0x53 &&
          secBuf[i + 6] == 0x50 &&
          secBuf[i + 7] == 0x00) {
        ntlmType = ByteData.sublistView(secBuf, i + 8, i + 12)
            .getUint32(0, Endian.little);
        break;
      }
    }

    final body = _Buf();
    if (ntlmType == 3) {
      final challenge = _serverChallenge;
      final ok = challenge != null &&
          server.password.isNotEmpty &&
          verifyNtlmType3(
            message: secBuf,
            serverChallenge: challenge,
            expectedUsername: server.username,
            expectedPassword: server.password,
          );
      if (!ok) {
        server._log.add('SMB oturum reddedildi (yanlış kullanıcı/şifre).');
        body.u16(9);
        body.u16(0);
        body.u16(64 + 8);
        body.u16(0);
        return _statusMsg(command, _statusLogonFailure, messageId,
            creditCharge: creditCharge, creditReq: creditReq, sessionId: 0,
            body: body.take());
      }
      _authenticated = true;
      body.u16(9);
      body.u16(0); // session flags (guest değil)
      body.u16(64 + 8);
      body.u16(0); // boş güvenlik tamponu
      return _statusMsg(command, _statusSuccess, messageId,
          creditCharge: creditCharge, creditReq: creditReq, sessionId: 1,
          body: body.take());
    }

    // Faz-1: oturuma özel NTLM Tip-2 meydanı.
    final challenge = Uint8List.fromList(
        List.generate(8, (_) => server._random.nextInt(256)));
    _serverChallenge = challenge;
    final spnego = spnegoChallengeToken(ntlmType2(challenge));
    body.u16(9);
    body.u16(0);
    body.u16(64 + 8);
    body.u16(spnego.length);
    body.bytes(spnego);
    return _statusMsg(command, _statusMoreProcessing, messageId,
        creditCharge: creditCharge, creditReq: creditReq, sessionId: 1,
        body: body.take());
  }

  Uint8List _onTreeConnect(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    if (!_authenticated) {
      return _statusMsg(command, _statusAccessDenied, messageId,
          creditCharge: creditCharge, creditReq: creditReq);
    }
    r.off = 64;
    r.u16(); // structure size
    r.u16(); // flags
    r.u16(); // path offset
    final pathLen = r.u16();
    r.take(pathLen); // paylaşım yolu (tek paylaşım)
    _treeConnected = true;

    final body = _Buf();
    body.u16(16);
    body.u8(0x01); // disk paylaşımı
    body.u8(0);
    body.u32(0); // share flags
    body.u32(0); // capabilities
    body.u32(0x00120089); // maximal access: FILE_GENERIC_READ
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }

  Uint8List _onCreate(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16(); // structure size
    r.u8(); // security flags
    r.u8(); // requested oplock
    r.u32(); // impersonation level
    r.u64(); // smb create flags
    r.u64(); // reserved
    r.u32(); // desired access
    r.u32(); // file attributes
    r.u32(); // share access
    final disposition = r.u32();
    final createOptions = r.u32();
    final nameOffset = r.u16();
    final nameLen = r.u16();

    var name = '';
    if (nameLen > 0 && nameOffset + nameLen <= r._data.length) {
      name = r.utf16At(nameOffset, nameLen);
    }
    name = name.replaceAll('/', r'\').replaceAll(RegExp(r'^\\+|\\+$'), '');
    if (name == '.' || name == '..') name = '';

    final wantDir = (createOptions & 0x1) != 0;
    String? path;
    List<String> segments = const [];
    if (name.isEmpty) {
      path = server.rootPath;
    } else {
      segments =
          name.split(r'\').where((s) => s.isNotEmpty && s != '.').toList();
      if (segments.any((s) => s == '..')) {
        return _statusMsg(command, _statusObjectNameNotFound, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      path = '${server.rootPath}${Platform.pathSeparator}'
          '${segments.join(Platform.pathSeparator)}';
    }

    FileSystemEntity? entity;
    var createAction = 1; // FILE_OPENED
    final type = FileSystemEntity.typeSync(path);

    switch (disposition) {
      case 1: // FILE_OPEN
        if (type == FileSystemEntityType.file) {
          entity = File(path);
        } else if (type == FileSystemEntityType.directory) {
          entity = Directory(path);
        } else {
          return _statusMsg(command, _statusObjectNameNotFound, messageId,
              creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
        }
      case 2: // FILE_CREATE
        if (type != FileSystemEntityType.notFound) {
          return _statusMsg(command, _statusAccessDenied, messageId,
              creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
        }
        if (wantDir) {
          entity = Directory(path)..createSync(recursive: true);
        } else {
          Directory(File(path).parent.path).createSync(recursive: true);
          entity = File(path)..createSync();
        }
        createAction = 2; // FILE_CREATED
      case 5: // FILE_OVERWRITE_IF
        if (wantDir) {
          return _statusMsg(command, _statusAccessDenied, messageId,
              creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
        }
        Directory(File(path).parent.path).createSync(recursive: true);
        final f = File(path);
        if (f.existsSync()) {
          f.writeAsBytesSync(const []);
          createAction = 3; // FILE_OVERWRITTEN
        } else {
          f.createSync();
          createAction = 2;
        }
        entity = f;
      default:
        return _statusMsg(command, _statusAccessDenied, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }

    final isDir = entity is Directory;
    final stat = entity.statSync();
    final id = server.randomFileId();
    _handles[_hex(id)] = _SmbHandle(entity, isDir);

    final body = _Buf();
    body.u16(89);
    body.u8(0); // oplock: yok
    body.u8(0); // flags
    body.u32(createAction);
    body.u64(_filetime(stat.changed));
    body.u64(_filetime(stat.accessed));
    body.u64(_filetime(stat.modified));
    body.u64(_filetime(stat.changed));
    final size = isDir ? 0 : stat.size;
    body.u64(((size + 4095) ~/ 4096) * 4096); // allocation size
    body.u64(size); // end of file
    body.u32(isDir ? _fileAttrDirectory : _fileAttrNormal);
    body.u32(0);
    body.bytes(id);
    body.u32(0); // contexts offset
    body.u32(0); // contexts length
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }

  Uint8List _onWrite(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16(); // structure size
    final dataOffset = r.u16();
    final length = r.u32();
    final offset = r.u64();
    final id = r.take(16);

    final handle = _handles[_hex(id)];
    if (handle == null || handle.isDir || handle.entity is! File) {
      return _statusMsg(command, _statusAccessDenied, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }
    if (dataOffset + length > r._data.length) {
      return _statusMsg(command, _statusInvalidParameter, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }
    final data =
        Uint8List.sublistView(r._data, dataOffset, dataOffset + length);
    final file = handle.entity as File;
    // append modu dosyayı silmez; çok parçalı yazmada kritik.
    final raf = file.openSync(mode: FileMode.append);
    try {
      raf.setPositionSync(offset);
      raf.writeFromSync(data);
    } finally {
      raf.closeSync();
    }

    final body = _Buf();
    body.u16(17);
    body.u16(0); // reserved
    body.u32(length); // count
    body.u32(0); // remaining
    body.u16(0); // write channel info offset
    body.u16(0); // write channel info length
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }

  Uint8List _onSetInfo(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    // MS-SMB2 2.2.39: StructureSize, InfoType, FileInfoClass, BufferLength,
    // BufferOffset(2), Reserved(2), FileId(16), Buffer.
    r.off = 64;
    r.u16(); // structure size
    final infoType = r.u8();
    final infoClass = r.u8();
    final bufferLen = r.u32();
    final bufferOffset = r.u16();
    r.u16(); // reserved
    final id = r.take(16);

    final handle = _handles[_hex(id)];
    if (handle == null) {
      return _statusMsg(command, _statusInvalidParameter, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }
    if (infoType != 1) {
      return _statusMsg(command, _statusNotSupported, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }
    if (bufferOffset + bufferLen > r._data.length) {
      return _statusMsg(command, _statusInvalidParameter, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }

    if (infoClass == 13 && bufferLen >= 1) {
      // FileDispositionInformation
      final del = r._data[bufferOffset];
      if (del != 0) handle.deleteOnClose = true;
      return _statusMsg(command, _statusSuccess, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
          body: _buf((b) => b.u16(2)));
    }

    if (infoClass == 10 && bufferLen >= 20) {
      // FileRenameInformation
      final nameLen = ByteData.sublistView(r._data)
          .getUint32(bufferOffset + 16, Endian.little);
      if (bufferOffset + 20 + nameLen > r._data.length) {
        return _statusMsg(command, _statusInvalidParameter, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      final newName = r.utf16At(bufferOffset + 20, nameLen)
          .replaceAll('/', r'\')
          .replaceAll(RegExp(r'^\\+|\\+$'), '');
      final segments =
          newName.split(r'\').where((s) => s.isNotEmpty && s != '.').toList();
      if (segments.isEmpty || segments.any((s) => s == '..')) {
        return _statusMsg(command, _statusInvalidParameter, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      final dest = '${server.rootPath}${Platform.pathSeparator}'
          '${segments.join(Platform.pathSeparator)}';
      try {
        Directory(File(dest).parent.path).createSync(recursive: true);
        if (handle.isDir) {
          (handle.entity as Directory).renameSync(dest);
          handle.entity = Directory(dest);
        } else {
          (handle.entity as File).renameSync(dest);
          handle.entity = File(dest);
        }
      } catch (_) {
        return _statusMsg(command, _statusAccessDenied, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      return _statusMsg(command, _statusSuccess, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
          body: _buf((b) => b.u16(2)));
    }

    return _statusMsg(command, _statusNotSupported, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
  }

  Uint8List _onRead(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16();
    r.u8();
    r.u8();
    final length = r.u32();
    final offset = r.u64();
    final id = r.take(16);

    final handle = _handles[_hex(id)];
    if (handle == null || handle.isDir || handle.entity is! File) {
      return _statusMsg(command, _statusEndOfFile, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }
    final file = handle.entity as File;
    final size = file.lengthSync();
    if (offset >= size) {
      return _statusMsg(command, _statusEndOfFile, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }
    final toRead = (offset + length > size) ? size - offset : length;
    final raf = file.openSync(mode: FileMode.read);
    Uint8List data;
    try {
      raf.setPositionSync(offset);
      data = raf.readSync(toRead);
    } finally {
      raf.closeSync();
    }

    final body = _Buf();
    body.u16(17);
    body.u8(64 + 16); // data offset
    body.u8(0);
    body.u32(data.length);
    body.u32(0); // data remaining
    body.u32(0); // flags
    body.bytes(data);
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }

  Uint8List _onQueryDirectory(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16();
    final infoClass = r.u8();
    final flags = r.u8();
    r.u32(); // file index
    final id = r.take(16);
    r.u16(); // file name offset
    r.u16(); // file name length
    final outLen = r.u32();

    final handle = _handles[_hex(id)];
    if (handle == null || !handle.isDir) {
      return _statusMsg(command, _statusInvalidParameter, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }

    // Yeniden başlatma: REOPEN bayrağı veya ilk çağrı.
    if ((flags & 0x10) != 0 || handle.listing == null) {
      handle.listing = _listDir(handle.entity as Directory);
      handle.cursor = 0;
    }
    final listing = handle.listing!;

    if (handle.cursor >= listing.length) {
      return _statusMsg(command, _statusNoMoreFiles, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }

    // Girdileri tampona sığdır.
    final entries = <Uint8List>[];
    var total = 0;
    for (var i = handle.cursor; i < listing.length; i++) {
      final entry = _dirEntry(infoClass, listing[i], i);
      if (entry == null) {
        return _statusMsg(command, _statusInvalidParameter, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      final aligned = (entry.length + 7) & ~7;
      if (entries.isEmpty) {
        if (entry.length > outLen) {
          return _statusMsg(command, _statusInfoLengthMismatch, messageId,
              creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
        }
        entries.add(entry);
        total = entry.length;
      } else {
        if (total + aligned > outLen) break;
        entries.add(entry);
        total += aligned;
      }
      if ((flags & 0x01) != 0) break; // SINGLE_ENTRY
    }
    handle.cursor += entries.length;

    // Çıktıyı kur: her girdiden sonra 8 bayta hizala, son girdi 0.
    final out = BytesBuilder();
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (i < entries.length - 1) {
        final aligned = (entry.length + 7) & ~7;
        final padded = Uint8List(aligned);
        padded.setAll(0, entry);
        ByteData.sublistView(padded).setUint32(0, aligned, Endian.little);
        out.add(padded);
      } else {
        out.add(entry); // NextEntryOffset = 0
      }
    }

    final data = out.takeBytes();
    final body = _Buf();
    body.u16(9);
    body.u16(64 + 8);
    body.u32(data.length);
    body.bytes(data);
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }

  List<_DirItem> _listDir(Directory dir) {
    final items = <_DirItem>[];
    final entities = dir.listSync(followLinks: false);
    for (final e in entities) {
      final segments =
          e.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      final name = segments.isEmpty ? e.path : segments.last;
      if (!server.showHidden && name.startsWith('.')) continue;
      try {
        final stat = e.statSync();
        if (e is File) {
          items.add(_DirItem(name, false, e, stat));
        } else if (e is Directory) {
          items.add(_DirItem(name, true, e, stat));
        }
      } catch (_) {
        // Erişilemeyen girdiler atlanır.
      }
    }
    items.sort((a, b) {
      if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return items;
  }

  int _attrsOf(_DirItem item) =>
      item.isDir ? _fileAttrDirectory | _fileAttrReadonly : _fileAttrNormal;

  Uint8List? _dirEntry(int infoClass, _DirItem item, int index) {
    final nameLen = item.name.length * 2;
    final size = item.isDir ? 0 : item.stat.size;
    final alloc = ((size + 4095) ~/ 4096) * 4096;
    final b = _Buf();
    b.u32(0); // next entry offset (sonra yamalanır)
    b.u32(index); // file index
    void timesAndSizes() {
      b.u64(_filetime(item.stat.changed));
      b.u64(_filetime(item.stat.accessed));
      b.u64(_filetime(item.stat.modified));
      b.u64(_filetime(item.stat.changed));
      b.u64(size); // end of file
      b.u64(alloc); // allocation size
    }

    switch (infoClass) {
      case 1: // FileDirectoryInformation
        timesAndSizes();
        b.u32(_attrsOf(item));
        b.u32(nameLen);
      case 2: // FileFullDirectoryInformation
        timesAndSizes();
        b.u32(_attrsOf(item));
        b.u32(nameLen);
        b.u32(0); // ea size
      case 3: // FileBothDirectoryInformation
        timesAndSizes();
        b.u32(_attrsOf(item));
        b.u32(nameLen);
        b.u32(0); // ea size
        b.u8(0); // short name length
        b.u8(0);
        b.zeros(24); // short name
      case 12: // FileNamesInformation
        b.u32(nameLen);
      case 37: // FileIdBothDirectoryInformation
        timesAndSizes();
        b.u32(_attrsOf(item));
        b.u32(nameLen);
        b.u32(0); // ea size
        b.u8(0);
        b.u8(0);
        b.zeros(24);
        b.u16(0); // reserved (MS-FSCC: 2 bayt)
        b.u64(index + 1); // file id
      case 38: // FileIdFullDirectoryInformation
        timesAndSizes();
        b.u32(_attrsOf(item));
        b.u32(nameLen);
        b.u32(0); // ea size
        b.u32(0); // reserved
        b.u64(index + 1); // file id
      default:
        return null;
    }
    b.utf16(item.name);
    return b.take();
  }

  Uint8List _onQueryInfo(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16();
    final infoType = r.u8();
    final infoClass = r.u8();
    final outLen = r.u32();
    r.u16(); // input buffer offset
    r.u16(); // reserved
    r.u32(); // input buffer length
    r.u32(); // additional information
    r.u8(); // security flags
    r.take(3); // reserved
    final id = r.take(16);

    Uint8List data;
    if (infoType == 0x01) {
      // Dosya bilgisi.
      final handle = _handles[_hex(id)];
      if (handle == null) {
        return _statusMsg(command, _statusInvalidParameter, messageId,
            creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      final isDir = handle.isDir;
      final stat = handle.entity.statSync();
      final size = isDir ? 0 : stat.size;
      final alloc = ((size + 4095) ~/ 4096) * 4096;
      final attrs = isDir
          ? _fileAttrDirectory | _fileAttrReadonly
          : _fileAttrNormal | _fileAttrReadonly;
      final b = _Buf();
      switch (infoClass) {
        case 4: // FileBasicInformation
          b.u64(_filetime(stat.changed));
          b.u64(_filetime(stat.accessed));
          b.u64(_filetime(stat.modified));
          b.u64(_filetime(stat.changed));
          b.u32(attrs);
          b.u32(0);
        case 5: // FileStandardInformation
          b.u64(alloc);
          b.u64(size);
          b.u32(1); // link count
          b.u8(0); // delete pending
          b.u8(isDir ? 1 : 0);
          b.u16(0);
        case 6: // FileInternalInformation
          b.u64(0);
        case 7: // FileEaInformation
          b.u32(0);
        case 8: // FileAccessInformation
          b.u32(0x00120089); // FILE_GENERIC_READ
        case 14: // FilePositionInformation
          b.u64(0);
        case 16: // FileModeInformation
          b.u32(0);
        case 17: // FileAlignmentInformation
          b.u32(0);
        case 18: // FileAllInformation
          b.u64(_filetime(stat.changed));
          b.u64(_filetime(stat.accessed));
          b.u64(_filetime(stat.modified));
          b.u64(_filetime(stat.changed));
          b.u32(attrs);
          b.u32(0);
          b.u64(alloc);
          b.u64(size);
          b.u32(1);
          b.u8(0);
          b.u8(isDir ? 1 : 0);
          b.u16(0);
          b.u64(0); // internal index
          b.u32(0); // ea size
          b.u32(0x00120089); // access
          b.u64(0); // position
          b.u32(0); // mode
          b.u32(0); // alignment
        case 21: // FileAlternateNameInformation
          b.u32(0);
        case 22: // FileStreamInformation (tek veri akışı)
          const streamName = '\u0000:\$DATA';
          final streamNameLen = streamName.length * 2;
          b.u32(0); // next
          b.u32(0); // reserved
          b.u32(streamNameLen);
          b.u64(size);
          b.u64(alloc);
          b.utf16(streamName);
        case 34: // FileNetworkOpenInformation
          b.u64(_filetime(stat.changed));
          b.u64(_filetime(stat.accessed));
          b.u64(_filetime(stat.modified));
          b.u64(_filetime(stat.changed));
          b.u64(alloc);
          b.u64(size);
          b.u32(attrs);
          b.u32(0);
        case 35: // FileAttributeTagInformation
          b.u32(attrs);
          b.u32(0); // reparse tag
        default:
          return _statusMsg(command, _statusInvalidParameter, messageId,
              creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      data = b.take();
    } else if (infoType == 0x02) {
      // Dosya sistemi bilgisi.
      final b = _Buf();
      switch (infoClass) {
        case 1: // FileFsVolumeInformation
          b.u64(_filetime(DateTime(2026)));
          b.u32(0x4d4b5901); // serial
          b.u32(10); // etiket uzunluğu ("MAKAY")
          b.u8(1); // nesneleri destekler
          b.u8(0);
          b.utf16('MAKAY');
        case 3: // FileFsSizeInformation
          b.u64(MiniSmbServer.totalUnits);
          b.u64(MiniSmbServer.freeUnits);
          b.u32(1); // sectors per allocation unit
          b.u32(4096); // bytes per sector
        case 5: // FileFsAttributeInformation
          b.u32(0x00000006); // case sensitive search | unicode on disk
          b.u32(255); // max component name
          b.u32(10); // fs name length
          b.utf16('MAKAY');
        case 7: // FileFsFullSizeInformation
          b.u64(MiniSmbServer.totalUnits);
          b.u64(MiniSmbServer.freeUnits);
          b.u64(MiniSmbServer.freeUnits);
          b.u32(1);
          b.u32(4096);
        case 13: // FileFsSectorSizeInformation
          b.u32(4096);
          b.u32(4096);
          b.u32(4096);
          b.u32(4096);
          b.u32(0);
          b.u64(0);
          b.u64(0);
        default:
          return _statusMsg(command, _statusInvalidParameter, messageId,
              creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
      }
      data = b.take();
    } else {
      // Güvenlik/kota sorguları reddedilir (salt okunur paylaşım).
      return _statusMsg(command, _statusAccessDenied, messageId,
          creditCharge: creditCharge, creditReq: creditReq, treeId: 1);
    }

    final sendLen = data.length > outLen ? outLen : data.length;
    final body = _Buf();
    body.u16(9);
    body.u16(64 + 8);
    body.u32(sendLen);
    body.bytes(Uint8List.sublistView(data, 0, sendLen));
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }

  Uint8List _onClose(int command, int messageId, int creditCharge,
      int creditReq, _Reader r) {
    r.off = 64;
    r.u16();
    r.u8();
    r.u8();
    r.u32();
    final id = r.take(16);
    final handle = _handles.remove(_hex(id));
    if (handle != null && handle.deleteOnClose) {
      try {
        if (handle.isDir) {
          (handle.entity as Directory).deleteSync(recursive: true);
        } else {
          (handle.entity as File).deleteSync();
        }
      } catch (_) {
        // Silme hataları kapanışı bozmaz.
      }
    }
    final body = _Buf();
    body.u16(24);
    body.u8(0);
    body.u8(0);
    body.u32(0);
    body.zeros(16);
    return _statusMsg(command, _statusSuccess, messageId,
        creditCharge: creditCharge, creditReq: creditReq, treeId: 1,
        body: body.take());
  }
}

Uint8List _buf(void Function(_Buf) build) {
  final b = _Buf();
  build(b);
  return b.take();
}
