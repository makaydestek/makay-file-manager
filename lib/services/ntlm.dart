/// NTLMSSP yardımcıları: saf Dart MD4 + NTLMv2 yanıt üretimi.
///
/// SMB2 istemcisinin Windows/Samba sunucularına kimlik doğrulama
/// göndermesi için gereken parçalar (MS-NLMP).
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

final _random = Random.secure();

/// RFC 1320 saf Dart MD4. NTLM parola özeti bunu kullanır.
Uint8List md4(List<int> input) {
  final msg = List<int>.from(input);
  final bitLen = input.length * 8;
  msg.add(0x80);
  while (msg.length % 64 != 56) {
    msg.add(0);
  }
  for (var i = 0; i < 8; i++) {
    msg.add((bitLen >> (8 * i)) & 0xff);
  }
  final view = ByteData.sublistView(Uint8List.fromList(msg));

  int a = 0x67452301, b = 0xefcdab89, c = 0x98badcfe, d = 0x10325476;
  final x = List<int>.filled(16, 0);
  for (var off = 0; off < msg.length; off += 64) {
    for (var i = 0; i < 16; i++) {
      x[i] = view.getUint32(off + i * 4, Endian.little);
    }
    final aa = a, bb = b, cc = c, dd = d;

    // Tur 1: F(x,y,z) = (x & y) | (~x & z)
    for (var i = 0; i < 16; i += 4) {
      a = _rotl(a + ((b & c) | (~b & d)) + x[i], 3);
      d = _rotl(d + ((a & b) | (~a & c)) + x[i + 1], 7);
      c = _rotl(c + ((d & a) | (~d & b)) + x[i + 2], 11);
      b = _rotl(b + ((c & d) | (~c & a)) + x[i + 3], 19);
    }
    // Tur 2: G(x,y,z) = (x & y) | (x & z) | (y & z)
    const o2 = [0, 4, 8, 12, 1, 5, 9, 13, 2, 6, 10, 14, 3, 7, 11, 15];
    for (var i = 0; i < 16; i += 4) {
      a = _rotl(a + ((b & c) | (b & d) | (c & d)) + x[o2[i]] + 0x5a827999, 3);
      d = _rotl(
          d + ((a & b) | (a & c) | (b & c)) + x[o2[i + 1]] + 0x5a827999, 5);
      c = _rotl(
          c + ((d & a) | (d & b) | (a & b)) + x[o2[i + 2]] + 0x5a827999, 9);
      b = _rotl(
          b + ((c & d) | (c & a) | (d & a)) + x[o2[i + 3]] + 0x5a827999, 13);
    }
    // Tur 3: H(x,y,z) = x ^ y ^ z
    const o3 = [0, 8, 4, 12, 2, 10, 6, 14, 1, 9, 5, 13, 3, 11, 7, 15];
    for (var i = 0; i < 16; i += 4) {
      a = _rotl(a + (b ^ c ^ d) + x[o3[i]] + 0x6ed9eba1, 3);
      d = _rotl(d + (a ^ b ^ c) + x[o3[i + 1]] + 0x6ed9eba1, 9);
      c = _rotl(c + (d ^ a ^ b) + x[o3[i + 2]] + 0x6ed9eba1, 11);
      b = _rotl(b + (c ^ d ^ a) + x[o3[i + 3]] + 0x6ed9eba1, 15);
    }
    a = (a + aa) & 0xffffffff;
    b = (b + bb) & 0xffffffff;
    c = (c + cc) & 0xffffffff;
    d = (d + dd) & 0xffffffff;
  }
  final out = ByteData(16);
  out.setUint32(0, a, Endian.little);
  out.setUint32(4, b, Endian.little);
  out.setUint32(8, c, Endian.little);
  out.setUint32(12, d, Endian.little);
  return out.buffer.asUint8List();
}

int _rotl(int x, int n) {
  x &= 0xffffffff;
  return ((x << n) | (x >> (32 - n))) & 0xffffffff;
}

Uint8List utf16le(String s) => Uint16List.fromList(s.codeUnits).buffer.asUint8List();

/// NTLM parola özeti: MD4(UTF-16LE(parola)).
Uint8List ntlmHash(String password) => md4(utf16le(password));

Uint8List _u64le(int v) {
  final b = ByteData(8)..setUint64(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _randomBytes(int n) =>
    Uint8List.fromList(List.generate(n, (_) => _random.nextInt(256)));

/// NTLMSSP Tip-1 (negotiate) mesajı — 32 bayt (payload'suz).
Uint8List ntlmType1() {
  final flags = 0x00000001 | // UNICODE
      0x00000004 | // REQUEST_TARGET
      0x00000200 | // NTLM
      0x00008000 | // ALWAYS_SIGN
      0x00080000 | // EXTENDED_SESSIONSECURITY
      0x20000000; // 128-bit
  final b = BytesBuilder();
  b.add(utf8.encode('NTLMSSP'));
  b.addByte(0);
  b.add(_u32le(1));
  b.add(_u32le(flags));
  // DomainNameFields (boş): len=0, maxLen=0, offset=0
  b.add(_u16le(0));
  b.add(_u16le(0));
  b.add(_u32le(0));
  // WorkstationNameFields (boş)
  b.add(_u16le(0));
  b.add(_u16le(0));
  b.add(_u32le(0));
  return b.takeBytes();
}

Uint8List _u16le(int v) {
  final b = ByteData(2)..setUint16(0, v, Endian.little);
  return b.buffer.asUint8List();
}

Uint8List _u32le(int v) {
  final b = ByteData(4)..setUint32(0, v, Endian.little);
  return b.buffer.asUint8List();
}

/// Sunucudan gelen NTLMSSP Tip-2 (challenge) mesajının çözülmüş hali.
class NtlmChallenge {
  NtlmChallenge({
    required this.flags,
    required this.serverChallenge,
    required this.targetInfo,
  });

  final int flags;
  final Uint8List serverChallenge; // 8 bayt
  final Uint8List targetInfo; // AV çiftleri (boş olabilir)

  /// [message] tip-2 mesajı; NTLM imzası içeren herhangi bir tamponda
  /// (SPNEGO sarmalayıcılı ya da çıplak) aranır.
  factory NtlmChallenge.parse(Uint8List message) {
    var start = -1;
    for (var i = 0; i + 12 <= message.length; i++) {
      if (message[i] == 0x4e &&
          message[i + 1] == 0x54 &&
          message[i + 2] == 0x4c &&
          message[i + 3] == 0x4d &&
          message[i + 4] == 0x53 &&
          message[i + 5] == 0x53 &&
          message[i + 6] == 0x50 &&
          message[i + 7] == 0x00) {
        start = i;
        break;
      }
    }
    if (start < 0) {
      throw const FormatException('NTLMSSP challenge bulunamadı');
    }
    final m = Uint8List.sublistView(message, start);
    final bd = ByteData.sublistView(m);
    final type = bd.getUint32(8, Endian.little);
    if (type != 2) {
      throw FormatException('Beklenmeyen NTLM mesajı tipi: $type');
    }
    final flags = bd.getUint32(20, Endian.little);
    final challenge = Uint8List.sublistView(m, 24, 32);
    var info = Uint8List(0);
    if (m.length >= 48) {
      final infoLen = bd.getUint16(40, Endian.little);
      final infoOff = bd.getUint32(44, Endian.little);
      if (infoLen > 0 && infoOff + infoLen <= m.length) {
        info = Uint8List.sublistView(m, infoOff, infoOff + infoLen);
      }
    }
    return NtlmChallenge(
      flags: flags,
      serverChallenge: Uint8List.fromList(challenge),
      targetInfo: Uint8List.fromList(info),
    );
  }
}

/// NTOWFv2 anahtarı (MS-NLMP 3.3.2 / 4.2.4.1.1 vektörü):
/// HMAC-MD5(NT-özet, UTF-16LE(BÜYÜT(kullanıcı) + alan)).
Uint8List ntlmV2Key(Uint8List ntHash, String user, String domain) =>
    Uint8List.fromList(Hmac(md5, ntHash)
        .convert(utf16le('${user.toUpperCase()}$domain'))
        .bytes);

/// NTLMv2 yanıt üretimi (MS-NLMP 3.3.2):
/// NTProofStr = HMAC-MD5(anahtar, sunucu_meydan_okuması + blob);
/// yanıt = proof + blob. [responseKey] NTOWFv2 anahtarıdır.
Uint8List ntlmV2Response({
  required Uint8List responseKey,
  required Uint8List serverChallenge,
  required Uint8List targetInfo,
  DateTime? time,
  Uint8List? clientChallenge,
}) {
  final now = time ?? DateTime.now().toUtc();
  final fileTime = (now.microsecondsSinceEpoch + 11644473600000000) * 10;
  final cc = clientChallenge ?? _randomBytes(8);
  final blob = BytesBuilder();
  blob.add(const [0x01, 0x01, 0, 0, 0, 0, 0, 0]); // resp type + reserved
  blob.add(_u64le(fileTime));
  blob.add(cc);
  blob.add(const [0, 0, 0, 0]); // reserved
  blob.add(targetInfo);
  blob.add(const [0, 0, 0, 0]); // reserved
  final blobBytes = blob.takeBytes();
  final proof = Hmac(md5, responseKey)
      .convert([...serverChallenge, ...blobBytes])
      .bytes;
  return Uint8List.fromList([...proof, ...blobBytes]);
}

/// NTLMv2 LM yanıtı (24 bayt):
/// HMAC-MD5(anahtar, sunucu_meydan + istemci_meydan) + istemci_meydan.
Uint8List lmV2Response({
  required Uint8List responseKey,
  required Uint8List serverChallenge,
  required Uint8List clientChallenge,
}) {
  final mac =
      Hmac(md5, responseKey).convert([...serverChallenge, ...clientChallenge]);
  return Uint8List.fromList([...mac.bytes, ...clientChallenge]);
}

/// NTLMSSP Tip-3 (authenticate) mesajı.
Uint8List ntlmType3({
  required String username,
  required String domain,
  required String workstation,
  required String password,
  required NtlmChallenge challenge,
}) {
  final ntHash = ntlmHash(password);
  final key = ntlmV2Key(ntHash, username, domain);
  final clientChallenge = _randomBytes(8);
  final ntResponse = ntlmV2Response(
    responseKey: key,
    serverChallenge: challenge.serverChallenge,
    targetInfo: challenge.targetInfo,
    clientChallenge: clientChallenge,
  );
  final lmResponse = lmV2Response(
    responseKey: key,
    serverChallenge: challenge.serverChallenge,
    clientChallenge: clientChallenge,
  );
  final dom = utf16le(domain);
  final user = utf16le(username);
  final ws = utf16le(workstation);

  // Alanlar payload içinde ardışık; ofsetler 64'ten başlar.
  var off = 64;
  final domOff = off;
  off += dom.length;
  final userOff = off;
  off += user.length;
  final wsOff = off;
  off += ws.length;
  final lmOff = off;
  off += lmResponse.length;
  final ntOff = off;

  final flags = 0x00000001 | // UNICODE
      0x00000004 | // REQUEST_TARGET
      0x00000200 | // NTLM
      0x00008000 | // ALWAYS_SIGN
      0x00080000 | // EXTENDED_SESSIONSECURITY
      0x00800000 | // TARGET_INFO
      0x20000000; // 128-bit

  final b = BytesBuilder();
  b.add(utf8.encode('NTLMSSP'));
  b.addByte(0);
  b.add(_u32le(3));
  void fields(int len, int offset) {
    b.add(_u16le(len));
    b.add(_u16le(len));
    b.add(_u32le(offset));
  }

  fields(lmResponse.length, lmOff); // LMChallengeResponse
  fields(ntResponse.length, ntOff); // NtChallengeResponse
  fields(dom.length, domOff); // DomainName
  fields(user.length, userOff); // UserName
  fields(ws.length, wsOff); // Workstation
  fields(0, 0); // EncryptedRandomSessionKey
  b.add(_u32le(flags));
  b.add(dom);
  b.add(user);
  b.add(ws);
  b.add(lmResponse);
  b.add(ntResponse);
  return b.takeBytes();
}

// ---------------------------------------------------------------------------
// SPNEGO sarmalayıcıları (DER)
// ---------------------------------------------------------------------------

Uint8List _der(int tag, List<int> content) {
  final len = content.length;
  final out = BytesBuilder();
  out.addByte(tag);
  if (len < 0x80) {
    out.addByte(len);
  } else if (len < 0x100) {
    out.addByte(0x81);
    out.addByte(len);
  } else {
    out.addByte(0x82);
    out.addByte((len >> 8) & 0xff);
    out.addByte(len & 0xff);
  }
  out.add(content);
  return out.takeBytes();
}

/// NTLMSSP mekanizma OID'si (1.3.6.1.4.1.311.2.2.10).
const List<int> _ntlmOid = [
  0x06, 0x0a, 0x2b, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01, 0x04,
];

/// SPNEGO NegTokenInit: GSS-API (0x60) + SPNEGO OID + [NegTokenInit]
/// (mechTypes NTLMSSP + mechToken = tip-1 mesaj).
Uint8List spnegoNegTokenInit(Uint8List ntlmToken) {
  final mechTypes = _der(0x30, _der(0xa0, _der(0x30, _ntlmOid)));
  final mechToken = _der(0xa1, _der(0x04, ntlmToken));
  final negInit = _der(0x30, [...mechTypes, ...mechToken]);
  final spnegoOid = [0x06, 0x06, 0x2b, 0x06, 0x01, 0x05, 0x05, 0x02];
  return _der(0x60, [...spnegoOid, ..._der(0xa0, negInit)]);
}

/// SPNEGO NegTokenResp: [1] SEQUENCE { [1] mechToken = tip-3 mesaj }.
Uint8List spnegoNegTokenResp(Uint8List ntlmToken) {
  final respToken = _der(0xa1, _der(0x04, ntlmToken));
  return _der(0xa1, _der(0x30, respToken));
}

/// Sunucu tarafı NTLMSSP Tip-2 (challenge) mesajı üretir.
Uint8List ntlmType2(Uint8List serverChallenge, {Uint8List? targetInfo}) {
  if (serverChallenge.length != 8) {
    throw ArgumentError('serverChallenge 8 bayt olmalı');
  }
  final info = targetInfo ?? Uint8List(0);
  final flags = 0x00000001 | // UNICODE
      0x00000200 | // NTLM
      0x00080000 | // EXTENDED_SESSIONSECURITY
      0x00800000 | // TARGET_INFO
      0x20000000; // 128-bit
  final b = BytesBuilder();
  b.add(utf8.encode('NTLMSSP'));
  b.addByte(0);
  b.add(_u32le(2));
  // TargetName boş; payload Tip-2 başlığından sonra (48) başlar.
  b.add(_u16le(0));
  b.add(_u16le(0));
  b.add(_u32le(48));
  b.add(_u32le(flags));
  b.add(serverChallenge);
  b.add(List.filled(8, 0)); // reserved
  // TargetInfoFields
  b.add(_u16le(info.length));
  b.add(_u16le(info.length));
  b.add(_u32le(48));
  b.add(info);
  return b.takeBytes();
}

/// Tip-2 mesajını SPNEGO NegTokenResp içinde sarar (sunucu → istemci).
Uint8List spnegoChallengeToken(Uint8List ntlmChallengeMsg) {
  final inner = _der(0xa0, _der(0x04, ntlmChallengeMsg)); // responseToken
  return _der(0xa1, _der(0x30, inner));
}

/// Tip-3 mesajındaki alanları çözer (SPNEGO sarmalayıcılı veya çıplak).
class NtlmAuthenticate {
  NtlmAuthenticate({
    required this.username,
    required this.domain,
    required this.ntResponse,
  });

  final String username;
  final String domain;
  final Uint8List ntResponse;

  factory NtlmAuthenticate.parse(Uint8List message) {
    var start = -1;
    for (var i = 0; i + 12 <= message.length; i++) {
      if (message[i] == 0x4e &&
          message[i + 1] == 0x54 &&
          message[i + 2] == 0x4c &&
          message[i + 3] == 0x4d &&
          message[i + 4] == 0x53 &&
          message[i + 5] == 0x53 &&
          message[i + 6] == 0x50 &&
          message[i + 7] == 0x00) {
        start = i;
        break;
      }
    }
    if (start < 0) {
      throw const FormatException('NTLMSSP authenticate bulunamadı');
    }
    final m = Uint8List.sublistView(message, start);
    final bd = ByteData.sublistView(m);
    if (bd.getUint32(8, Endian.little) != 3) {
      throw const FormatException('Beklenen NTLM tip-3 mesajı değil');
    }
    if (m.length < 52) {
      throw const FormatException('NTLM tip-3 mesajı çok kısa');
    }
    Uint8List field(int lenOff, int offOff) {
      final len = bd.getUint16(lenOff, Endian.little);
      final off = bd.getUint32(offOff, Endian.little);
      if (len == 0) return Uint8List(0);
      if (off + len > m.length) {
        throw const FormatException('NTLM tip-3 alan ofseti geçersiz');
      }
      return Uint8List.sublistView(m, off, off + len);
    }

    String utf16Field(Uint8List raw) {
      final codes = <int>[];
      final view = ByteData.sublistView(raw);
      for (var i = 0; i + 1 < raw.length; i += 2) {
        codes.add(view.getUint16(i, Endian.little));
      }
      return String.fromCharCodes(codes);
    }

    // MS-NLMP Tip-3 ofsetleri:
    // 12 LM, 20 NT, 28 Domain, 36 User, 44 Workstation
    final nt = field(20, 24);
    final domain = utf16Field(field(28, 32));
    final user = utf16Field(field(36, 40));
    return NtlmAuthenticate(username: user, domain: domain, ntResponse: nt);
  }
}

/// Tip-3 NTLMv2 yanıtını beklenen kullanıcı/parola ile doğrular.
///
/// [serverChallenge] oturumun Tip-2'de gönderdiği 8 bayttır.
bool verifyNtlmType3({
  required Uint8List message,
  required Uint8List serverChallenge,
  required String expectedUsername,
  required String expectedPassword,
}) {
  if (serverChallenge.length != 8) return false;
  late final NtlmAuthenticate auth;
  try {
    auth = NtlmAuthenticate.parse(message);
  } catch (_) {
    return false;
  }
  if (auth.username.toLowerCase() != expectedUsername.toLowerCase()) {
    return false;
  }
  // NTLMv2: NT yanıtı ≥ 16 bayt proof + blob; blob 0x01 0x01 ile başlar.
  if (auth.ntResponse.length < 16) return false;
  final proof = auth.ntResponse.sublist(0, 16);
  final blob = auth.ntResponse.sublist(16);
  if (blob.length >= 2 && blob[0] == 0x01 && blob[1] == 0x01) {
    final key = ntlmV2Key(
      ntlmHash(expectedPassword),
      auth.username,
      auth.domain,
    );
    final expected = Hmac(md5, key)
        .convert([...serverChallenge, ...blob])
        .bytes;
    return _constEq(proof, expected);
  }
  // NTLMv1 (24 bayt): DES tabanlı; desteklemiyoruz — reddet.
  return false;
}

bool _constEq(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
