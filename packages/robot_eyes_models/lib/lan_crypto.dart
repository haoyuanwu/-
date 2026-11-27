import 'dart:convert';

import 'package:cryptography/cryptography.dart';

class LanCrypto {
  LanCrypto._(this._pair, this.publicKey);

  final KeyPair _pair;
  final String publicKey;
  static final _x25519 = X25519();
  static final _cipher = AesGcm.with256bits();
  static final _kdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);

  static bool validKey(Object? value) =>
      value is String && RegExp(r'^[A-Za-z0-9_-]{43}=$').hasMatch(value);

  static Future<LanCrypto> fromSeed(String seed) async {
    if (!validKey(seed)) throw const FormatException('Invalid LAN seed');
    final pair = await _x25519.newKeyPairFromSeed(base64Url.decode(seed));
    final public = await pair.extractPublicKey();
    return LanCrypto._(pair, base64UrlEncode(public.bytes));
  }

  Future<LanBox> withPeer(String peer) async {
    if (!validKey(peer)) throw const FormatException('Invalid LAN public key');
    final secret = await _x25519.sharedSecretKey(
      keyPair: _pair,
      remotePublicKey: SimplePublicKey(
        base64Url.decode(peer),
        type: KeyPairType.x25519,
      ),
    );
    if ((await secret.extractBytes()).every((byte) => byte == 0)) {
      throw const FormatException('Invalid LAN shared key');
    }
    return LanBox._(
      await _kdf.deriveKey(
        secretKey: secret,
        info: utf8.encode('Robot Eyes LAN pairing and model settings v1'),
      ),
    );
  }
}

class LanBox {
  LanBox._(this._secret);
  final SecretKey _secret;

  Future<Map<String, String>> seal(
    Map<String, Object?> data,
    String context,
  ) async {
    final box = await LanCrypto._cipher.encrypt(
      utf8.encode(jsonEncode(data)),
      secretKey: _secret,
      aad: utf8.encode(context),
    );
    return {'box': base64UrlEncode(box.concatenation())};
  }

  Future<Map<String, Object?>> open(Object? envelope, String context) async {
    final encoded = envelope is Map ? envelope['box'] : null;
    if (encoded is! String || encoded.length > 3 * 1024 * 1024) {
      throw const FormatException('Invalid LAN envelope');
    }
    try {
      final bytes = base64Url.decode(encoded);
      if (bytes.length < 28)
        throw const FormatException('Invalid LAN envelope');
      final box = SecretBox.fromConcatenation(
        bytes,
        nonceLength: 12,
        macLength: 16,
      );
      final plain = await LanCrypto._cipher.decrypt(
        box,
        secretKey: _secret,
        aad: utf8.encode(context),
      );
      final result = jsonDecode(utf8.decode(plain));
      if (result is! Map<String, Object?>)
        throw const FormatException('Invalid LAN payload');
      return result;
    } on SecretBoxAuthenticationError {
      throw const FormatException('Invalid LAN authentication');
    }
  }
}
