import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/global/global_peer_store.dart';
import 'package:local_chat/global/identity.dart';
import 'package:local_chat/global/nostr_client.dart';
import 'package:local_chat/global/pairing_service.dart';
import 'package:local_chat/global/sas_emoji_table.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('SAS derivation is deterministic for a key pair', () async {
    final alice = await X25519().newKeyPairFromSeed(List<int>.filled(32, 1));
    final bob = await X25519().newKeyPairFromSeed(List<int>.filled(32, 2));
    final alicePriv = await alice.extractPrivateKeyBytes();
    final bobPub = (await bob.extractPublicKey()).bytes;

    final first = await PairingService.deriveSas(
      myXPriv: alicePriv,
      theirXPub: bobPub,
    );
    final second = await PairingService.deriveSas(
      myXPriv: alicePriv,
      theirXPub: bobPub,
    );

    expect(second, first);
    expect(sasEmojiTable.where(first.contains), hasLength(5));
  });

  test('SAS(A to B) equals SAS(B to A)', () async {
    final alice = await X25519().newKeyPairFromSeed(List<int>.filled(32, 3));
    final bob = await X25519().newKeyPairFromSeed(List<int>.filled(32, 4));
    final alicePriv = await alice.extractPrivateKeyBytes();
    final bobPriv = await bob.extractPrivateKeyBytes();
    final alicePub = (await alice.extractPublicKey()).bytes;
    final bobPub = (await bob.extractPublicKey()).bytes;

    final aToB = await PairingService.deriveSas(
      myXPriv: alicePriv,
      theirXPub: bobPub,
    );
    final bToA = await PairingService.deriveSas(
      myXPriv: bobPriv,
      theirXPub: alicePub,
    );

    expect(bToA, aToB);
  });

  test('confirm persists paired peer', () async {
    final store = GlobalPeerStore();
    final peer = GlobalPeer(
      userId: 'peer-ed',
      name: 'Peer',
      edPub: List<int>.filled(32, 5),
      xPub: List<int>.filled(32, 6),
      addedAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final session = PairingSession(
      code: '123-456-789',
      topic: 'topic',
      role: PairingRole.initiator,
      peer: peer,
      sas: 'abcde',
      remoteSas: 'abcde',
    );

    final service = PairingService(
      identity: LocalIdentity(
        edPriv: List<int>.filled(32, 1),
        edPub: List<int>.filled(32, 2),
        xPriv: List<int>.filled(32, 3),
        xPub: List<int>.filled(32, 4),
      ),
      displayName: 'unused',
      nostr: NostrClient(),
      peerStore: store,
    );
    await service.confirm(session);

    final peers = await store.loadPeers();
    expect(peers, hasLength(1));
    expect(peers.single.edPubHex, peer.edPubHex);
  });

  test('initiator republishes offer while waiting for responder', () async {
    final nostr = _CountingNostrClient();
    final service = PairingService(
      identity: await _identity(11, 12),
      displayName: 'Alice',
      nostr: nostr,
    );

    await expectLater(
      service.startAsInitiator(
        code: '123-456-789',
        timeout: const Duration(milliseconds: 90),
        retryInterval: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );

    expect(nostr.publishCount, greaterThan(1));
  });
}

class _CountingNostrClient extends NostrClient {
  var publishCount = 0;

  @override
  void publish(NostrEvent event) {
    publishCount++;
  }
}

Future<LocalIdentity> _identity(int edSeedByte, int xSeedByte) async {
  final edPair = await Ed25519().newKeyPairFromSeed(
    List<int>.filled(32, edSeedByte),
  );
  final xPair = await X25519().newKeyPairFromSeed(
    List<int>.filled(32, xSeedByte),
  );
  return LocalIdentity(
    edPriv: await edPair.extractPrivateKeyBytes(),
    edPub: (await edPair.extractPublicKey()).bytes,
    xPriv: await xPair.extractPrivateKeyBytes(),
    xPub: (await xPair.extractPublicKey()).bytes,
  );
}
