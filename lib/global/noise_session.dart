import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'global_peer_store.dart';
import 'identity.dart';
import 'nostr_client.dart';

enum NoiseRole { initiator, responder }

class NoiseSession {
  NoiseSession._({
    required this.role,
    required this.identity,
    required this.peer,
  });

  factory NoiseSession.initiator(LocalIdentity identity, GlobalPeer peer) {
    return NoiseSession._(
      role: NoiseRole.initiator,
      identity: identity,
      peer: peer,
    );
  }

  factory NoiseSession.responder(LocalIdentity identity, GlobalPeer peer) {
    return NoiseSession._(
      role: NoiseRole.responder,
      identity: identity,
      peer: peer,
    );
  }

  static final _cipher = Chacha20.poly1305Aead();

  final NoiseRole role;
  final LocalIdentity identity;
  final GlobalPeer peer;

  SimpleKeyPairData? _ephemeralKeyPair;
  List<int>? _peerEphemeralPub;
  List<int>? _sendKey;
  List<int>? _receiveKey;
  var _sendNonce = 0;
  var _receiveNonce = 0;

  bool get isEstablished => _sendKey != null && _receiveKey != null;

  Future<void> handshake(
    Future<void> Function(List<int> message) send,
    Future<List<int>> Function() receive,
  ) async {
    if (role == NoiseRole.initiator) {
      await send(await startHandshakeMessage());
      await handleHandshakeMessage(await receive());
    } else {
      final response = await handleHandshakeMessage(await receive());
      if (response == null) {
        throw StateError('Responder did not produce a handshake response');
      }
      await send(response);
    }
  }

  Future<List<int>> startHandshakeMessage() async {
    if (role != NoiseRole.initiator) {
      throw StateError('Only an initiator can start the Noise handshake');
    }
    final ephemeral = await _newEphemeral();
    final ephemeralPub = (await ephemeral.extractPublicKey()).bytes;
    final message = await _signedHandshakeMessage(
      kind: 'init',
      ephemeralPub: ephemeralPub,
    );
    return utf8.encode(jsonEncode(message));
  }

  Future<List<int>?> handleHandshakeMessage(List<int> bytes) async {
    final message = _HandshakeMessage.parse(utf8.decode(bytes));
    await _verifyPeerMessage(message);
    _peerEphemeralPub = message.ePub;

    if (role == NoiseRole.responder && message.kind == 'init') {
      final ephemeral = await _newEphemeral();
      final ephemeralPub = (await ephemeral.extractPublicKey()).bytes;
      await _deriveCipherStates();
      final response = await _signedHandshakeMessage(
        kind: 'resp',
        ephemeralPub: ephemeralPub,
      );
      return utf8.encode(jsonEncode(response));
    }

    if (role == NoiseRole.initiator && message.kind == 'resp') {
      await _deriveCipherStates();
      return null;
    }

    throw StateError('Unexpected Noise handshake message ${message.kind}');
  }

  Future<List<int>> encrypt(List<int> plaintext) async {
    final key = _sendKey;
    if (key == null) throw StateError('Noise session is not established');
    final box = await _cipher.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: _nonceBytes(_sendNonce),
    );
    _sendNonce += 1;
    final body = <int>[...box.cipherText, ...box.mac.bytes];
    return <int>[
      (body.length >> 24) & 0xff,
      (body.length >> 16) & 0xff,
      (body.length >> 8) & 0xff,
      body.length & 0xff,
      ...body,
    ];
  }

  Future<List<int>> decrypt(List<int> frame) async {
    final key = _receiveKey;
    if (key == null) throw StateError('Noise session is not established');
    if (frame.length < 4) throw const FormatException('short Noise frame');
    final length =
        (frame[0] << 24) | (frame[1] << 16) | (frame[2] << 8) | frame[3];
    if (length <= 16 || frame.length != 4 + length) {
      throw const FormatException('invalid Noise frame length');
    }
    final body = frame.sublist(4);
    final ciphertext = body.sublist(0, body.length - 16);
    final mac = body.sublist(body.length - 16);
    final plaintext = await _cipher.decrypt(
      SecretBox(ciphertext, nonce: _nonceBytes(_receiveNonce), mac: Mac(mac)),
      secretKey: SecretKey(key),
    );
    _receiveNonce += 1;
    return plaintext;
  }

  Future<SimpleKeyPairData> _newEphemeral() async {
    final keyPair = await X25519().newKeyPair();
    final extracted = await keyPair.extract();
    _ephemeralKeyPair = extracted;
    return extracted;
  }

  Future<Map<String, Object?>> _signedHandshakeMessage({
    required String kind,
    required List<int> ephemeralPub,
  }) async {
    final input = _signatureInput(
      kind: kind,
      edPub: identity.edPub,
      xPub: identity.xPub,
      ePub: ephemeralPub,
      peerEdPub: peer.edPub,
    );
    final signature = await Ed25519().sign(input, keyPair: identity.edKeyPair);
    return <String, Object?>{
      'v': 1,
      'kind': kind,
      'edPub': identity.edPubHex,
      'xPub': identity.xPubHex,
      'ePub': NostrHex.encode(ephemeralPub),
      'sig': NostrHex.encode(signature.bytes),
    };
  }

  Future<void> _verifyPeerMessage(_HandshakeMessage message) async {
    if (message.edPubHex != peer.edPubHex || message.xPubHex != peer.xPubHex) {
      throw StateError('Noise peer identity mismatch');
    }
    final input = _signatureInput(
      kind: message.kind,
      edPub: message.edPub,
      xPub: message.xPub,
      ePub: message.ePub,
      peerEdPub: identity.edPub,
    );
    final ok = await Ed25519().verify(
      input,
      signature: Signature(
        message.sig,
        publicKey: SimplePublicKey(message.edPub, type: KeyPairType.ed25519),
      ),
    );
    if (!ok) throw StateError('Noise peer signature failed');
  }

  Future<void> _deriveCipherStates() async {
    final ephemeral = _ephemeralKeyPair;
    final peerEphemeralPub = _peerEphemeralPub;
    if (ephemeral == null || peerEphemeralPub == null) {
      throw StateError('Noise handshake is missing ephemeral keys');
    }
    final initiatorEdPub = role == NoiseRole.initiator
        ? identity.edPub
        : peer.edPub;
    final responderEdPub = role == NoiseRole.initiator
        ? peer.edPub
        : identity.edPub;

    final material = <int>[
      ...await _shared(identity.xKeyPair, peer.xPub),
      ...await _shared(ephemeral, peerEphemeralPub),
      if (role == NoiseRole.initiator) ...[
        ...await _shared(ephemeral, peer.xPub),
        ...await _shared(identity.xKeyPair, peerEphemeralPub),
      ] else ...[
        ...await _shared(identity.xKeyPair, peerEphemeralPub),
        ...await _shared(ephemeral, peer.xPub),
      ],
      ...initiatorEdPub,
      ...responderEdPub,
    ];
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 64);
    final keyBytes = await (await hkdf.deriveKey(
      secretKey: SecretKey(material),
      nonce: utf8.encode('lc-noise-ik-v1'),
    )).extractBytes();
    final first = keyBytes.sublist(0, 32);
    final second = keyBytes.sublist(32, 64);
    if (role == NoiseRole.initiator) {
      _sendKey = first;
      _receiveKey = second;
    } else {
      _sendKey = second;
      _receiveKey = first;
    }
  }

  static Future<List<int>> _shared(
    SimpleKeyPairData keyPair,
    List<int> remotePub,
  ) async {
    final secret = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(remotePub, type: KeyPairType.x25519),
    );
    return secret.extractBytes();
  }

  static List<int> _signatureInput({
    required String kind,
    required List<int> edPub,
    required List<int> xPub,
    required List<int> ePub,
    required List<int> peerEdPub,
  }) {
    return utf8.encode(
      [
        'lc-noise-ik-v1',
        kind,
        NostrHex.encode(edPub),
        NostrHex.encode(xPub),
        NostrHex.encode(ePub),
        NostrHex.encode(peerEdPub),
      ].join('|'),
    );
  }

  static List<int> _nonceBytes(int value) {
    final bytes = Uint8List(12);
    var n = value;
    for (var i = 11; i >= 0; i--) {
      bytes[i] = n & 0xff;
      n >>= 8;
    }
    return bytes;
  }
}

class _HandshakeMessage {
  const _HandshakeMessage({
    required this.kind,
    required this.edPub,
    required this.xPub,
    required this.ePub,
    required this.sig,
  });

  final String kind;
  final List<int> edPub;
  final List<int> xPub;
  final List<int> ePub;
  final List<int> sig;

  String get edPubHex => NostrHex.encode(edPub);
  String get xPubHex => NostrHex.encode(xPub);

  static _HandshakeMessage parse(String raw) {
    final json = jsonDecode(raw) as Map<String, dynamic>;
    if (json['v'] != 1) {
      throw const FormatException('unsupported Noise handshake version');
    }
    return _HandshakeMessage(
      kind: json['kind'] as String? ?? '',
      edPub: NostrHex.decode(json['edPub'] as String? ?? ''),
      xPub: NostrHex.decode(json['xPub'] as String? ?? ''),
      ePub: NostrHex.decode(json['ePub'] as String? ?? ''),
      sig: NostrHex.decode(json['sig'] as String? ?? ''),
    );
  }
}
