import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/global/global_peer_store.dart';
import 'package:local_chat/global/identity.dart';
import 'package:local_chat/global/noise_session.dart';

void main() {
  test('Noise sessions self-interoperate after handshake', () async {
    final alice = await _identity(1, 2);
    final bob = await _identity(3, 4);
    final initiator = NoiseSession.initiator(alice, _peer(bob));
    final responder = NoiseSession.responder(bob, _peer(alice));

    final initMessage = await initiator.startHandshakeMessage();
    final response = await responder.handleHandshakeMessage(initMessage);
    expect(response, isNotNull);
    await initiator.handleHandshakeMessage(response!);

    expect(initiator.isEstablished, isTrue);
    expect(responder.isEstablished, isTrue);

    final frame = await initiator.encrypt(utf8.encode('hello'));
    expect(utf8.decode(await responder.decrypt(frame)), 'hello');

    final reply = await responder.encrypt(utf8.encode('hi back'));
    expect(utf8.decode(await initiator.decrypt(reply)), 'hi back');
  });

  test('wrong peer pubkey aborts handshake', () async {
    final alice = await _identity(5, 6);
    final bob = await _identity(7, 8);
    final wrong = await _identity(9, 10);
    final initiator = NoiseSession.initiator(alice, _peer(bob));
    final responder = NoiseSession.responder(bob, _peer(wrong));

    final initMessage = await initiator.startHandshakeMessage();

    await expectLater(
      responder.handleHandshakeMessage(initMessage),
      throwsStateError,
    );
  });

  test('replaying a frame is rejected by strict nonce order', () async {
    final alice = await _identity(11, 12);
    final bob = await _identity(13, 14);
    final initiator = NoiseSession.initiator(alice, _peer(bob));
    final responder = NoiseSession.responder(bob, _peer(alice));
    final response = await responder.handleHandshakeMessage(
      await initiator.startHandshakeMessage(),
    );
    await initiator.handleHandshakeMessage(response!);

    final frame = await initiator.encrypt(utf8.encode('once'));
    expect(utf8.decode(await responder.decrypt(frame)), 'once');
    await expectLater(responder.decrypt(frame), throwsA(isA<Exception>()));
  });
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
