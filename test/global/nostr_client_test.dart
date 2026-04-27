import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_chat/global/nostr_client.dart';

void main() {
  group('NostrEvent', () {
    test('event id computation matches NIP-01 serialization', () {
      final id = NostrEvent.computeId(
        pubkey:
            '6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93',
        createdAt: 1714328400,
        kind: 22242,
        tags: const <List<String>>[
          <String>['d', 'topic'],
          <String>[
            'p',
            'f7234bd4c1394dda46d09f35bd384dd30cc552ad5541990f98844fb06676e9ca',
          ],
        ],
        content: 'payload',
      );

      expect(
        id,
        'cb6c7870dcb45ca3b8c14eedb0122e4efd98deffead5a204d4f438665562e482',
      );
    });

    test('Ed25519 event signatures verify and detect tampering', () async {
      final keyPair = await Ed25519().newKeyPairFromSeed(
        List<int>.filled(32, 7),
      );
      final signed = await NostrEvent.sign(
        keyPair: await keyPair.extract(),
        createdAt: 1714328400,
        kind: 22242,
        tags: const <List<String>>[
          <String>['d', 'topic'],
        ],
        content: 'payload',
      );

      expect(await signed.verifySignature(), isTrue);
      final tampered = NostrEvent(
        id: signed.id,
        pubkey: signed.pubkey,
        createdAt: signed.createdAt,
        kind: signed.kind,
        tags: signed.tags,
        content: 'changed',
        sig: signed.sig,
      );
      expect(await tampered.verifySignature(), isFalse);
    });
  });

  group('Nip44Payload', () {
    test('payload encryption matches published NIP-44 v2 vector', () async {
      final conversationKey = NostrHex.decode(
        'c41c775356fd92eadc63ff5a0dc1da211b268cbea22316767095b2871ea1412d',
      );
      final nonce = NostrHex.decode(
        '0000000000000000000000000000000000000000000000000000000000000001',
      );
      final payload = await Nip44Payload.encryptWithConversationKey(
        'a',
        conversationKey,
        nonce: nonce,
      );

      expect(
        payload,
        'AgAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABee0G5VSK0/9YypIObAtDKfYEAjD35uVkHyB0F4DwrcNaCXlCWZKaArsGrY6M9wnuTMxWfp1RTN9Xga8no+kF5Vsb',
      );
      expect(
        await Nip44Payload.decryptWithConversationKey(payload, conversationKey),
        'a',
      );
    });

    test('X25519 conversation keys are symmetric', () async {
      final alice = await X25519().newKeyPairFromSeed(List<int>.filled(32, 1));
      final bob = await X25519().newKeyPairFromSeed(List<int>.filled(32, 2));
      final alicePriv = await alice.extractPrivateKeyBytes();
      final bobPriv = await bob.extractPrivateKeyBytes();
      final alicePub = (await alice.extractPublicKey()).bytes;
      final bobPub = (await bob.extractPublicKey()).bytes;

      final aliceKey = await Nip44Payload.getConversationKey(
        myXPriv: alicePriv,
        theirXPub: bobPub,
      );
      final bobKey = await Nip44Payload.getConversationKey(
        myXPriv: bobPriv,
        theirXPub: alicePub,
      );

      expect(bobKey, aliceKey);
    });

    test('encrypt/decrypt helper round-trips over X25519 keys', () async {
      final alice = await X25519().newKeyPairFromSeed(List<int>.filled(32, 3));
      final bob = await X25519().newKeyPairFromSeed(List<int>.filled(32, 4));
      final alicePriv = await alice.extractPrivateKeyBytes();
      final bobPriv = await bob.extractPrivateKeyBytes();
      final alicePub = (await alice.extractPublicKey()).bytes;
      final bobPub = (await bob.extractPublicKey()).bytes;

      final payload = await NostrClient.encrypt(
        'hello from phase 2',
        myXPriv: alicePriv,
        theirXPub: bobPub,
      );

      expect(
        await NostrClient.decrypt(
          payload,
          myXPriv: bobPriv,
          theirXPub: alicePub,
        ),
        'hello from phase 2',
      );
    });
  });
}
