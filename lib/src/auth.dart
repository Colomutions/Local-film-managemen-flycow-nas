import 'dart:convert';
import 'dart:math';

String newOpaqueSecret() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

String newUuidV4() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes
      .map((value) => value.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex.substring(0, 8)}-'
      '${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

bool constantTimeEquals(String left, String right) {
  var difference = left.length ^ right.length;
  final length = left.length < right.length ? left.length : right.length;
  for (var index = 0; index < length; index++) {
    difference |= left.codeUnitAt(index) ^ right.codeUnitAt(index);
  }
  return difference == 0;
}

String sha256Hex(String value) {
  final message = List<int>.from(utf8.encode(value));
  final bitLength = message.length * 8;
  message.add(0x80);
  while (message.length % 64 != 56) {
    message.add(0);
  }
  for (var shift = 56; shift >= 0; shift -= 8) {
    message.add((bitLength >> shift) & 0xff);
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  for (var offset = 0; offset < message.length; offset += 64) {
    final words = List<int>.filled(64, 0);
    for (var index = 0; index < 16; index++) {
      final start = offset + index * 4;
      words[index] = (message[start] << 24) |
          (message[start + 1] << 16) |
          (message[start + 2] << 8) |
          message[start + 3];
    }
    for (var index = 16; index < 64; index++) {
      final s0 = _rotateRight(words[index - 15], 7) ^
          _rotateRight(words[index - 15], 18) ^
          (words[index - 15] >> 3);
      final s1 = _rotateRight(words[index - 2], 17) ^
          _rotateRight(words[index - 2], 19) ^
          (words[index - 2] >> 10);
      words[index] = _uint32(words[index - 16] + s0 + words[index - 7] + s1);
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;
    for (var index = 0; index < 64; index++) {
      final sum1 = _rotateRight(e, 6) ^ _rotateRight(e, 11) ^ _rotateRight(e, 25);
      final choose = (e & f) ^ ((~e) & g);
      final temp1 = _uint32(h + sum1 + choose + _sha256Constants[index] + words[index]);
      final sum0 = _rotateRight(a, 2) ^ _rotateRight(a, 13) ^ _rotateRight(a, 22);
      final majority = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = _uint32(sum0 + majority);
      h = g;
      g = f;
      f = e;
      e = _uint32(d + temp1);
      d = c;
      c = b;
      b = a;
      a = _uint32(temp1 + temp2);
    }
    h0 = _uint32(h0 + a);
    h1 = _uint32(h1 + b);
    h2 = _uint32(h2 + c);
    h3 = _uint32(h3 + d);
    h4 = _uint32(h4 + e);
    h5 = _uint32(h5 + f);
    h6 = _uint32(h6 + g);
    h7 = _uint32(h7 + h);
  }

  return [h0, h1, h2, h3, h4, h5, h6, h7]
      .map((value) => value.toUnsigned(32).toRadixString(16).padLeft(8, '0'))
      .join();
}

int _uint32(int value) => value & 0xffffffff;
int _rotateRight(int value, int amount) =>
    _uint32(value).toUnsigned(32) >> amount |
    (_uint32(value) << (32 - amount));

const _sha256Constants = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];
