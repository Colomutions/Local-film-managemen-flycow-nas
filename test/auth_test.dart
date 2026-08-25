import '../lib/src/auth.dart';

void main() {
  _expect(
    sha256Hex('abc') ==
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'SHA-256 matches its standard test vector',
  );
  _expect(constantTimeEquals('same', 'same'), 'equal values match');
  _expect(!constantTimeEquals('same', 'different'), 'different values do not match');
  _expect(newOpaqueSecret().length >= 40, 'opaque tokens have sufficient entropy encoding');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError('Assertion failed: $message');
}
