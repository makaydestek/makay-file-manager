import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:makay_file_manager/services/ntlm.dart';
import 'package:makay_file_manager/services/smb_server.dart';

/// Basit SMB2 istemcisi (test amaclı).
class _SmbTestClient {
  _SmbTestClient._(this._socket) {
    _iterator = StreamIterator(_socket);
  }

  final Socket _socket;
  late final StreamIterator<List<int>> _iterator;
  var _remainder = <int>[];
  int _messageId = 0;

  static Future<_SmbTestClient> connect(int port) async {
    final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
    return _SmbTestClient._(socket);
  }

  Future<List<int>> _readExact(int n) async {
    while (_remainder.length < n) {
      if (!await _iterator.moveNext()) {
        throw StateError('kapandi');
      }
      _remainder = [..._remainder, ..._iterator.current];
    }
    final out = _remainder.sublist(0, n);
    _remainder = _remainder.sublist(n);
    return out;
  }

  /// Istek gonderir; yanitin (durum, govde) ciftini dondurur.
  Future<(int, Uint8List)> request(
    int command,
    Uint8List body, {
    int treeId = 0,
    int sessionId = 0,
  }) async {
    final mid = _messageId++;
    final header = ByteData(64);
    header.setUint32(0, 0x424d53fe, Endian.little);
    header.setUint16(4, 64, Endian.little);
    header.setUint16(6, 1, Endian.little); // credit charge
    header.setUint16(12, command, Endian.little);
    header.setUint16(14, 1, Endian.little); // credit request
    header.setUint32(16, 0x00000001, Endian.little); // flags
    header.setUint64(24, mid, Endian.little);
    header.setUint32(36, treeId, Endian.little);
    header.setUint64(40, sessionId, Endian.little);

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
    final len = (head[1] << 16) | (head[2] << 8) | head[3];
    final resp = Uint8List.fromList(await _readExact(len));
    final bd = ByteData.sublistView(resp);
    final status = bd.getUint32(8, Endian.little);
    return (status, Uint8List.sublistView(resp, 64));
  }

  Future<void> close() async {
    await _socket.close();
  }
}

Uint8List _utf16(String s) =>
    Uint16List.fromList(s.codeUnits).buffer.asUint8List();

Future<void> _auth(_SmbTestClient c,
    {String user = 'admin', String pass = 'sifre'}) async {
  await c.request(0x0000, _negotiateBody());
  final (status1, body1) = await c.request(0x0001, _sessionSetupBody(ntlmType1()));
  expect(status1, 0xC0000016);
  // SESSION_SETUP yanıt gövdesi: structureSize(2)+flags(2)+secOffset(2)+secLen(2)+sec
  final secLen = ByteData.sublistView(body1).getUint16(6, Endian.little);
  final secOff = ByteData.sublistView(body1).getUint16(4, Endian.little);
  // secOffset SMB başından; gövde 64'ten sonra → gövde içi ofset = secOff - 64
  final secStart = secOff - 64;
  final sec = Uint8List.sublistView(body1, secStart, secStart + secLen);
  final challenge = NtlmChallenge.parse(sec);
  final t3 = ntlmType3(
    username: user,
    domain: '',
    workstation: 'TEST',
    password: pass,
    challenge: challenge,
  );
  final (status2, _) = await c.request(0x0001, _sessionSetupBody(t3));
  expect(status2, 0);
}

void main() {
  late MiniSmbServer server;
  late Directory root;
  late int port;

  setUpAll(() async {
    root = Directory.systemTemp.createTempSync('makay_smb_test');
    File('${root.path}${Platform.pathSeparator}dosya.txt')
        .writeAsStringSync('merhaba makay');
    Directory('${root.path}${Platform.pathSeparator}klasor').createSync();
    File(
            '${root.path}${Platform.pathSeparator}klasor${Platform.pathSeparator}ic.txt')
        .writeAsStringSync('icerik');

    server = MiniSmbServer(
      rootPath: root.path,
      port: 0,
      shareName: 'makay',
      username: 'admin',
      password: 'sifre',
    );
    await server.start();
    port = server.boundPort;
    expect(server.running, isTrue, reason: 'SMB sunucusu dinlemiyor');
  });

  tearDownAll(() async {
    await server.stop();
    root.deleteSync(recursive: true);
  });

  test('SMB2 tam oturum: negotiate, auth, tree, listele, oku', () async {
    final c = await _SmbTestClient.connect(port);
    await _auth(c);

    // TREE_CONNECT
    final path = _utf16(r'\\makay-server\makay');
    final tc = ByteData(8 + path.length);
    final tb = tc.buffer.asUint8List();
    tc.setUint16(0, 9, Endian.little);
    tc.setUint16(4, 72, Endian.little); // path offset (baştan)
    tc.setUint16(6, path.length, Endian.little);
    tb.setAll(8, path);
    final (status3, _) = await c.request(0x0003, tb, sessionId: 1);
    expect(status3, 0);

    // CREATE: kok dizin
    final (status4, createResp) =
        await c.request(0x0005, _createBody(r''), treeId: 1, sessionId: 1);
    expect(status4, 0);
    final fileId = Uint8List.sublistView(createResp, 64, 80);

    // QUERY_DIRECTORY
    final (status5, dirResp) = await c.request(
      0x000E,
      _queryDirBody(fileId),
      treeId: 1,
      sessionId: 1,
    );
    expect(status5, 0);
    final names = _parseDirEntries(dirResp);
    expect(names, contains('dosya.txt'));
    expect(names, contains('klasor'));

    // CREATE + READ
    final (status6, fileResp) = await c.request(
        0x0005, _createBody(r'\dosya.txt'),
        treeId: 1, sessionId: 1);
    expect(status6, 0);
    final fileId2 = Uint8List.sublistView(fileResp, 64, 80);
    final (status7, readResp) = await c.request(
        0x0008, _readBody(fileId2, 128),
        treeId: 1, sessionId: 1);
    expect(status7, 0);
    final bd = ByteData.sublistView(readResp);
    final dataLen = bd.getUint32(4, Endian.little);
    final dataOffset = bd.getUint8(2) - 64;
    final content = String.fromCharCodes(
        readResp.sublist(dataOffset, dataOffset + dataLen));
    expect(content, 'merhaba makay');

    // Alt klasor
    final (status8, subResp) =
        await c.request(0x0005, _createBody(r'\klasor'), treeId: 1, sessionId: 1);
    expect(status8, 0);
    final fileId3 = Uint8List.sublistView(subResp, 64, 80);
    final (status9, subDir) = await c.request(
      0x000E,
      _queryDirBody(fileId3),
      treeId: 1,
      sessionId: 1,
    );
    expect(status9, 0);
    expect(_parseDirEntries(subDir), contains('ic.txt'));

    final (status10, _) =
        await c.request(0x0006, _closeBody(fileId2), treeId: 1, sessionId: 1);
    expect(status10, 0);

    await c.close();
  });

  test('SMB2: yanlis sifre LOGON_FAILURE doner', () async {
    final c = await _SmbTestClient.connect(port);
    await c.request(0x0000, _negotiateBody());
    final (status1, body1) =
        await c.request(0x0001, _sessionSetupBody(ntlmType1()));
    expect(status1, 0xC0000016);
    final secLen = ByteData.sublistView(body1).getUint16(6, Endian.little);
    final secOff = ByteData.sublistView(body1).getUint16(4, Endian.little);
    final sec = Uint8List.sublistView(body1, secOff - 64, secOff - 64 + secLen);
    final challenge = NtlmChallenge.parse(sec);
    final t3 = ntlmType3(
      username: 'admin',
      domain: '',
      workstation: 'TEST',
      password: 'yanlis',
      challenge: challenge,
    );
    final (status2, _) = await c.request(0x0001, _sessionSetupBody(t3));
    expect(status2, 0xC000006D); // STATUS_LOGON_FAILURE
    await c.close();
  });

  test('SMB2: olmayan dosya OBJECT_NAME_NOT_FOUND doner', () async {
    final c = await _SmbTestClient.connect(port);
    await _auth(c);
    final path = _utf16(r'\\x\makay');
    final tc = ByteData(8 + path.length);
    final tb = tc.buffer.asUint8List();
    tc.setUint16(0, 9, Endian.little);
    tc.setUint16(4, 72, Endian.little);
    tc.setUint16(6, path.length, Endian.little);
    tb.setAll(8, path);
    await c.request(0x0003, tb, sessionId: 1);
    final (status, _) = await c.request(
        0x0005, _createBody(r'\yok_dosya.txt'),
        treeId: 1, sessionId: 1);
    expect(status, 0xC0000034);
    await c.close();
  });
}

Uint8List _negotiateBody() {
  final negBody = ByteData(38);
  final nb = negBody.buffer.asUint8List();
  negBody.setUint16(0, 36, Endian.little);
  negBody.setUint16(2, 1, Endian.little);
  negBody.setUint16(4, 1, Endian.little);
  negBody.setUint16(36, 0x0202, Endian.little);
  return nb;
}

Uint8List _sessionSetupBody(Uint8List sec) {
  final b = ByteData(24 + sec.length);
  final u8 = b.buffer.asUint8List();
  b.setUint16(0, 25, Endian.little);
  b.setUint16(12, 88, Endian.little); // security buffer offset (baştan)
  b.setUint16(14, sec.length, Endian.little);
  u8.setAll(24, sec);
  return u8;
}

Uint8List _createBody(String name) {
  final n = _utf16(name);
  final b = ByteData(56 + n.length);
  final u8 = b.buffer.asUint8List();
  b.setUint16(0, 57, Endian.little);
  b.setUint32(32, 0x00000007, Endian.little); // share access
  b.setUint32(36, 1, Endian.little); // create disposition: FILE_OPEN
  b.setUint16(44, 120, Endian.little); // name offset (baştan itibaren)
  b.setUint16(46, n.length, Endian.little);
  u8.setAll(56, n);
  return u8;
}

Uint8List _queryDirBody(Uint8List fileId) {
  final b = ByteData(34);
  final u8 = b.buffer.asUint8List();
  b.setUint16(0, 33, Endian.little);
  u8[2] = 1; // FileDirectoryInformation
  u8[3] = 0; // flags
  u8.setAll(8, fileId);
  b.setUint16(24, 96, Endian.little); // file name offset
  b.setUint16(26, 2, Endian.little); // file name length
  b.setUint32(28, 65536, Endian.little); // output buffer length
  u8[32] = 0x2a; // '*'
  u8[33] = 0;
  return u8;
}

Uint8List _readBody(Uint8List fileId, int length) {
  final b = ByteData(48);
  final u8 = b.buffer.asUint8List();
  b.setUint16(0, 49, Endian.little);
  b.setUint32(4, length, Endian.little);
  u8.setAll(16, fileId);
  return u8;
}

Uint8List _closeBody(Uint8List fileId) {
  final b = ByteData(24);
  final u8 = b.buffer.asUint8List();
  b.setUint16(0, 24, Endian.little);
  u8.setAll(8, fileId);
  return u8;
}

List<String> _parseDirEntries(Uint8List body) {
  final names = <String>[];
  final bd = ByteData.sublistView(body);
  var offset = 8; // govde baslangici (structure size + offset + length)
  while (offset + 64 <= body.length) {
    final next = bd.getUint32(offset, Endian.little);
    final nameLen = bd.getUint32(offset + 60, Endian.little);
    if (nameLen == 0 || offset + 64 + nameLen > body.length) break;
    final codes = <int>[];
    final view = ByteData.sublistView(body, offset + 64, offset + 64 + nameLen);
    for (var i = 0; i < nameLen; i += 2) {
      codes.add(view.getUint16(i, Endian.little));
    }
    names.add(String.fromCharCodes(codes));
    if (next == 0) break;
    offset += next;
  }
  return names;
}
