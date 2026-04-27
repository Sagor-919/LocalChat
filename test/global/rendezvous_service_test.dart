import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/global/global_peer_store.dart';
import 'package:local_chat/global/identity.dart';
import 'package:local_chat/global/nostr_client.dart';
import 'package:local_chat/global/rendezvous_service.dart';

void main() {
  test('rendezvous topic is stable regardless of key order', () async {
    final a = await _identity(1, 2);
    final b = await _identity(3, 4);

    expect(
      RendezvousService.rendezvousTopic(a.edPub, b.edPub),
      RendezvousService.rendezvousTopic(b.edPub, a.edPub),
    );
  });

  test('valid encrypted offer decodes', () async {
    final local = await _identity(10, 11);
    final remote = await _identity(12, 13);
    final service = RendezvousService(
      identity: local,
      nostr: NostrClient(),
      now: () => DateTime.fromMillisecondsSinceEpoch(200000),
    );
    final peer = _peer(remote);
    final event = await _eventFromRemote(
      local: local,
      remote: remote,
      message: RendezvousMessage(
        kind: RendezvousMessageKind.webrtcOffer,
        from: remote.edPubHex,
        to: local.edPubHex,
        ts: 200,
        session: 'sess1',
        sdp: 'fakeSDP',
      ),
    );

    final decoded = await service.decodePeerEvent(peer, event);

    expect(decoded, isNotNull);
    expect(decoded!.kind, RendezvousMessageKind.webrtcOffer);
    expect(decoded.sdp, 'fakeSDP');
  });

  test(
    'malformed, unsigned, stale, and misaddressed events are dropped',
    () async {
      final local = await _identity(20, 21);
      final remote = await _identity(22, 23);
      final other = await _identity(24, 25);
      final service = RendezvousService(
        identity: local,
        nostr: NostrClient(),
        now: () => DateTime.fromMillisecondsSinceEpoch(500000),
      );
      final peer = _peer(remote);

      final validMessage = RendezvousMessage(
        kind: RendezvousMessageKind.presence,
        from: remote.edPubHex,
        to: local.edPubHex,
        ts: 500,
        session: 'sess2',
      );
      final validEvent = await _eventFromRemote(
        local: local,
        remote: remote,
        message: validMessage,
      );

      final malformed = NostrEvent(
        id: validEvent.id,
        pubkey: validEvent.pubkey,
        createdAt: validEvent.createdAt,
        kind: validEvent.kind,
        tags: validEvent.tags,
        content: 'not-base64',
        sig: validEvent.sig,
      );
      expect(await service.decodePeerEvent(peer, malformed), isNull);

      final badSig = NostrEvent(
        id: validEvent.id,
        pubkey: validEvent.pubkey,
        createdAt: validEvent.createdAt,
        kind: validEvent.kind,
        tags: validEvent.tags,
        content: validEvent.content,
        sig: '00' * 64,
      );
      expect(await service.decodePeerEvent(peer, badSig), isNull);

      final stale = await _eventFromRemote(
        local: local,
        remote: remote,
        message: RendezvousMessage(
          kind: RendezvousMessageKind.presence,
          from: remote.edPubHex,
          to: local.edPubHex,
          ts: 300,
          session: 'sess3',
        ),
      );
      expect(await service.decodePeerEvent(peer, stale), isNull);

      final misaddressed = await _eventFromRemote(
        local: other,
        remote: remote,
        message: RendezvousMessage(
          kind: RendezvousMessageKind.presence,
          from: remote.edPubHex,
          to: other.edPubHex,
          ts: 500,
          session: 'sess4',
        ),
      );
      expect(await service.decodePeerEvent(peer, misaddressed), isNull);
    },
  );
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

GlobalPeer _peer(LocalIdentity identity) {
  return GlobalPeer(
    userId: identity.edPubHex,
    name: 'Peer',
    edPub: identity.edPub,
    xPub: identity.xPub,
    addedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

Future<NostrEvent> _eventFromRemote({
  required LocalIdentity local,
  required LocalIdentity remote,
  required RendezvousMessage message,
}) async {
  final content = await NostrClient.encrypt(
    jsonEncode(message.toJson()),
    myXPriv: remote.xPriv,
    theirXPub: local.xPub,
  );
  return NostrEvent.sign(
    keyPair: remote.edKeyPair,
    kind: localChatRendezvousKind,
    tags: <List<String>>[
      <String>[
        'd',
        RendezvousService.rendezvousTopic(local.edPub, remote.edPub),
      ],
    ],
    content: content,
    createdAt: message.ts,
  );
}
