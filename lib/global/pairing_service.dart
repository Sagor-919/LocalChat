import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

import 'global_peer_store.dart';
import 'identity.dart';
import 'nostr_client.dart';
import 'sas_emoji_table.dart';

const localChatPairingKind = 22240;
const pairingRetryInterval = Duration(seconds: 3);

class PairingService {
  PairingService({
    required this.identity,
    required this.displayName,
    required this.nostr,
    GlobalPeerStore peerStore = const GlobalPeerStore(),
    DateTime Function()? now,
  }) : _peerStore = peerStore,
       _now = now ?? DateTime.now;

  final LocalIdentity identity;
  final String displayName;
  final NostrClient nostr;
  final GlobalPeerStore _peerStore;
  final DateTime Function() _now;

  Future<PairingSession> startAsInitiator({
    String? code,
    Duration timeout = const Duration(seconds: 90),
    Duration retryInterval = pairingRetryInterval,
  }) async {
    final pairingCode = code == null
        ? generatePairingCode()
        : formatPairingCode(normalizePairingCode(code));
    final topic = pairingTopic(pairingCode);
    final completer = Completer<PairingSession>();
    late final NostrSubscription subscription;
    Timer? offerTimer;

    subscription = nostr.subscribe(
      _topicFilter(topic, since: _secondsNow() - 60),
      (event) {
        if (completer.isCompleted) return;
        final message = PairingMessage.tryParse(event.content);
        if (message == null ||
            message.kind != PairingMessageKind.accept ||
            !_messageIsFresh(message)) {
          return;
        }
        final peer = message.toPeer();
        _deriveSas(peer.xPub).then((sas) {
          if (!completer.isCompleted) {
            completer.complete(
              PairingSession(
                code: pairingCode,
                topic: topic,
                role: PairingRole.initiator,
                peer: peer,
                sas: sas,
                remoteSas: message.sas,
              ),
            );
          }
        }, onError: completer.completeError);
      },
    );

    Future<void> publishOffer() {
      return _publishPairingMessage(
        topic: topic,
        message: PairingMessage.offer(
          edPub: identity.edPub,
          xPub: identity.xPub,
          name: displayName,
          ts: _secondsNow(),
        ),
      );
    }

    await publishOffer();
    offerTimer = Timer.periodic(retryInterval, (_) {
      if (!completer.isCompleted) unawaited(publishOffer());
    });

    try {
      return await completer.future.timeout(timeout);
    } finally {
      offerTimer.cancel();
      subscription.cancel();
    }
  }

  Future<PairingSession> joinAsResponder(
    String code, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final normalized = normalizePairingCode(code);
    if (normalized.length != 9) {
      throw const FormatException('Pairing code must contain 9 digits');
    }
    final topic = pairingTopic(normalized);
    final completer = Completer<PairingSession>();
    late final NostrSubscription subscription;
    var acceptedOffer = false;

    subscription = nostr.subscribe(
      _topicFilter(topic, since: _secondsNow() - 60),
      (event) {
        if (completer.isCompleted || acceptedOffer) return;
        final message = PairingMessage.tryParse(event.content);
        if (message == null ||
            message.kind != PairingMessageKind.offer ||
            !_messageIsFresh(message)) {
          return;
        }
        acceptedOffer = true;
        final peer = message.toPeer();
        _deriveSas(peer.xPub).then((sas) async {
          await _publishAcceptBurst(topic: topic, sas: sas);
          if (!completer.isCompleted) {
            completer.complete(
              PairingSession(
                code: formatPairingCode(normalized),
                topic: topic,
                role: PairingRole.responder,
                peer: peer,
                sas: sas,
                remoteSas: null,
              ),
            );
          }
        }, onError: completer.completeError);
      },
    );

    try {
      return await completer.future.timeout(timeout);
    } finally {
      subscription.cancel();
    }
  }

  Future<void> _publishAcceptBurst({
    required String topic,
    required String sas,
  }) async {
    Future<void> publishAccept() {
      return _publishPairingMessage(
        topic: topic,
        message: PairingMessage.accept(
          edPub: identity.edPub,
          xPub: identity.xPub,
          name: displayName,
          sas: sas,
          ts: _secondsNow(),
        ),
      );
    }

    await publishAccept();
    for (final delay in const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 9),
    ]) {
      unawaited(Future<void>.delayed(delay, publishAccept));
    }
  }

  Future<void> confirm(PairingSession session) async {
    if (session.remoteSas != null && session.remoteSas != session.sas) {
      throw StateError('SAS mismatch');
    }
    await _peerStore.savePeer(session.peer);
  }

  Future<void> _publishPairingMessage({
    required String topic,
    required PairingMessage message,
  }) async {
    final event = await NostrEvent.sign(
      keyPair: identity.edKeyPair,
      kind: localChatPairingKind,
      tags: <List<String>>[
        <String>['d', topic],
      ],
      content: jsonEncode(message.toJson()),
      createdAt: _secondsNow(),
    );
    nostr.publish(event);
  }

  Future<String> _deriveSas(List<int> peerXPub) {
    return deriveSas(myXPriv: identity.xPriv, theirXPub: peerXPub);
  }

  bool _messageIsFresh(PairingMessage message) {
    final age = _secondsNow() - message.ts;
    return age >= 0 && age <= 60;
  }

  int _secondsNow() => _now().millisecondsSinceEpoch ~/ 1000;

  static NostrFilter _topicFilter(String topic, {int? since}) {
    final filter = <String, Object?>{
      'kinds': <int>[localChatPairingKind],
      '#d': <String>[topic],
    };
    if (since != null) filter['since'] = since;
    return filter;
  }

  static String normalizePairingCode(String raw) =>
      raw.replaceAll(RegExp(r'\D'), '');

  static String generatePairingCode() {
    final value = Random.secure().nextInt(1000000000);
    return formatPairingCode(value.toString().padLeft(9, '0'));
  }

  static String formatPairingCode(String raw) {
    final normalized = normalizePairingCode(raw).padLeft(9, '0');
    final clipped = normalized.substring(normalized.length - 9);
    return '${clipped.substring(0, 3)}-${clipped.substring(3, 6)}-${clipped.substring(6)}';
  }

  static String pairingTopic(String code) {
    final normalized = normalizePairingCode(code);
    final digest = crypto.sha256.convert(utf8.encode('lc-pair-v1$normalized'));
    return digest.toString();
  }

  static Future<String> deriveSas({
    required List<int> myXPriv,
    required List<int> theirXPub,
  }) async {
    final keyPair = await X25519().newKeyPairFromSeed(myXPriv);
    final shared = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(theirXPub, type: KeyPairType.x25519),
    );
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 10);
    final sasKey = await hkdf.deriveKey(
      secretKey: shared,
      nonce: utf8.encode('lc-sas-v1'),
    );
    final bytes = await sasKey.extractBytes();
    return List<String>.generate(
      5,
      (index) => sasEmojiTable[bytes[index] % sasEmojiTable.length],
    ).join();
  }
}

enum PairingRole { initiator, responder }

class PairingSession {
  const PairingSession({
    required this.code,
    required this.topic,
    required this.role,
    required this.peer,
    required this.sas,
    this.remoteSas,
  });

  final String code;
  final String topic;
  final PairingRole role;
  final GlobalPeer peer;
  final String sas;
  final String? remoteSas;
}

enum PairingMessageKind {
  offer('pair_offer'),
  accept('pair_accept');

  const PairingMessageKind(this.wireName);

  final String wireName;

  static PairingMessageKind? fromWireName(String? name) {
    for (final kind in values) {
      if (kind.wireName == name) return kind;
    }
    return null;
  }
}

class PairingMessage {
  const PairingMessage({
    required this.kind,
    required this.edPub,
    required this.xPub,
    required this.name,
    required this.ts,
    this.sas,
  });

  factory PairingMessage.offer({
    required List<int> edPub,
    required List<int> xPub,
    required String name,
    required int ts,
  }) {
    return PairingMessage(
      kind: PairingMessageKind.offer,
      edPub: edPub,
      xPub: xPub,
      name: name,
      ts: ts,
    );
  }

  factory PairingMessage.accept({
    required List<int> edPub,
    required List<int> xPub,
    required String name,
    required String sas,
    required int ts,
  }) {
    return PairingMessage(
      kind: PairingMessageKind.accept,
      edPub: edPub,
      xPub: xPub,
      name: name,
      ts: ts,
      sas: sas,
    );
  }

  final PairingMessageKind kind;
  final List<int> edPub;
  final List<int> xPub;
  final String name;
  final int ts;
  final String? sas;

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'kind': kind.wireName,
    'edPub': NostrHex.encode(edPub),
    'xPub': NostrHex.encode(xPub),
    'name': name.length > 64 ? name.substring(0, 64) : name,
    if (sas != null) 'sas': sas,
    'ts': ts,
  };

  GlobalPeer toPeer() {
    return GlobalPeer(
      userId: NostrHex.encode(edPub),
      name: name,
      edPub: edPub,
      xPub: xPub,
      addedAt: DateTime.fromMillisecondsSinceEpoch(ts * 1000),
    );
  }

  static PairingMessage? tryParse(String content) {
    try {
      final json = jsonDecode(content) as Map<String, dynamic>;
      if (json['v'] != 1) return null;
      final kind = PairingMessageKind.fromWireName(json['kind'] as String?);
      if (kind == null) return null;
      final edPub = NostrHex.decode(json['edPub'] as String? ?? '');
      final xPub = NostrHex.decode(json['xPub'] as String? ?? '');
      if (edPub.length != 32 || xPub.length != 32) return null;
      return PairingMessage(
        kind: kind,
        edPub: edPub,
        xPub: xPub,
        name: (json['name'] as String? ?? 'Peer').trim(),
        ts: (json['ts'] as num?)?.toInt() ?? 0,
        sas: json['sas'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}
