import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

class LocalIdentity {
  static const edPrivKey = 'gd.identity.ed25519.priv';
  static const edPubKey = 'gd.identity.ed25519.pub';
  static const xPrivKey = 'gd.identity.x25519.priv';
  static const xPubKey = 'gd.identity.x25519.pub';

  LocalIdentity({
    required List<int> edPriv,
    required List<int> edPub,
    required List<int> xPriv,
    required List<int> xPub,
  }) : edPriv = Uint8List.fromList(edPriv),
       edPub = Uint8List.fromList(edPub),
       xPriv = Uint8List.fromList(xPriv),
       xPub = Uint8List.fromList(xPub);

  final Uint8List edPriv;
  final Uint8List edPub;
  final Uint8List xPriv;
  final Uint8List xPub;

  String get edPubHex => _hex(edPub);
  String get xPubHex => _hex(xPub);

  SimpleKeyPairData get edKeyPair => SimpleKeyPairData(
    edPriv,
    publicKey: SimplePublicKey(edPub, type: KeyPairType.ed25519),
    type: KeyPairType.ed25519,
  );

  SimpleKeyPairData get xKeyPair => SimpleKeyPairData(
    xPriv,
    publicKey: SimplePublicKey(xPub, type: KeyPairType.x25519),
    type: KeyPairType.x25519,
  );

  static Future<LocalIdentity> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final storedEdPriv = _read32BytePref(prefs, edPrivKey);
    final storedXPriv = _read32BytePref(prefs, xPrivKey);

    if (storedEdPriv != null && storedXPriv != null) {
      final identity = await _fromPrivateKeys(storedEdPriv, storedXPriv);
      await identity._persist(prefs);
      return identity;
    }

    final edPair = await Ed25519().newKeyPair();
    final xPair = await X25519().newKeyPair();
    final identity = LocalIdentity(
      edPriv: await edPair.extractPrivateKeyBytes(),
      edPub: (await edPair.extractPublicKey()).bytes,
      xPriv: await xPair.extractPrivateKeyBytes(),
      xPub: (await xPair.extractPublicKey()).bytes,
    );
    await identity._persist(prefs);
    return identity;
  }

  static Future<LocalIdentity> _fromPrivateKeys(
    List<int> edPriv,
    List<int> xPriv,
  ) async {
    final edPair = await Ed25519().newKeyPairFromSeed(edPriv);
    final xPair = await X25519().newKeyPairFromSeed(xPriv);
    return LocalIdentity(
      edPriv: edPriv,
      edPub: (await edPair.extractPublicKey()).bytes,
      xPriv: xPriv,
      xPub: (await xPair.extractPublicKey()).bytes,
    );
  }

  Future<void> _persist(SharedPreferences prefs) async {
    await prefs.setString(edPrivKey, base64Encode(edPriv));
    await prefs.setString(edPubKey, base64Encode(edPub));
    await prefs.setString(xPrivKey, base64Encode(xPriv));
    await prefs.setString(xPubKey, base64Encode(xPub));
  }

  static List<int>? _read32BytePref(SharedPreferences prefs, String key) {
    final encoded = prefs.getString(key);
    if (encoded == null) return null;
    try {
      final bytes = base64Decode(encoded);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }

  static String _hex(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
