import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/global/identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test(
    'first call generates 32-byte private keys and persists identity',
    () async {
      final first = await LocalIdentity.loadOrCreate();

      expect(first.edPriv, hasLength(32));
      expect(first.xPriv, hasLength(32));
      expect(first.edPub, hasLength(32));
      expect(first.xPub, hasLength(32));

      final prefs = await SharedPreferences.getInstance();
      expect(
        base64Decode(prefs.getString(LocalIdentity.edPrivKey)!),
        first.edPriv,
      );
      expect(
        base64Decode(prefs.getString(LocalIdentity.xPrivKey)!),
        first.xPriv,
      );

      final second = await LocalIdentity.loadOrCreate();
      expect(second.edPriv, first.edPriv);
      expect(second.edPub, first.edPub);
      expect(second.xPriv, first.xPriv);
      expect(second.xPub, first.xPub);
    },
  );

  test('edPub derives from edPriv', () async {
    final identity = await LocalIdentity.loadOrCreate();
    final keyPair = await Ed25519().newKeyPairFromSeed(identity.edPriv);
    final publicKey = await keyPair.extractPublicKey();

    expect(publicKey.bytes, identity.edPub);
  });

  test('xPub derives from xPriv', () async {
    final identity = await LocalIdentity.loadOrCreate();
    final keyPair = await X25519().newKeyPairFromSeed(identity.xPriv);
    final publicKey = await keyPair.extractPublicKey();

    expect(publicKey.bytes, identity.xPub);
  });
}
