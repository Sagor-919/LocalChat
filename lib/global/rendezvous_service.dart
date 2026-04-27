import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'global_peer_store.dart';
import 'identity.dart';
import 'nostr_client.dart';

const localChatRendezvousKind = 22241;

class RendezvousService {
  RendezvousService({
    required this.identity,
    required this.nostr,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final LocalIdentity identity;
  final NostrClient nostr;
  final DateTime Function() _now;
  final StreamController<RendezvousMessage> _messages =
      StreamController<RendezvousMessage>.broadcast();
  final List<NostrSubscription> _subscriptions = [];
  final Set<String> _seenMessageKeys = <String>{};

  Stream<RendezvousMessage> get messages => _messages.stream;

  NostrSubscription subscribeForPeer(GlobalPeer peer) {
    final topic = rendezvousTopic(identity.edPub, peer.edPub);
    final subscription = nostr.subscribe(
      <String, Object?>{
        'kinds': <int>[localChatRendezvousKind],
        '#d': <String>[topic],
      },
      (event) async {
        final message = await decodePeerEvent(peer, event);
        if (message != null && !_messages.isClosed) {
          _messages.add(message);
        }
      },
    );
    _subscriptions.add(subscription);
    return subscription;
  }

  Future<void> sendOffer(GlobalPeer peer, String sdp, String sessionId) {
    return _send(
      peer,
      RendezvousMessage(
        kind: RendezvousMessageKind.webrtcOffer,
        from: identity.edPubHex,
        to: peer.edPubHex,
        ts: _secondsNow(),
        session: sessionId,
        sdp: sdp,
      ),
    );
  }

  Future<void> sendAnswer(GlobalPeer peer, String sdp, String sessionId) {
    return _send(
      peer,
      RendezvousMessage(
        kind: RendezvousMessageKind.webrtcAnswer,
        from: identity.edPubHex,
        to: peer.edPubHex,
        ts: _secondsNow(),
        session: sessionId,
        sdp: sdp,
      ),
    );
  }

  Future<void> sendIce(
    GlobalPeer peer,
    Map<String, Object?> candidate,
    String sessionId,
  ) {
    return _send(
      peer,
      RendezvousMessage(
        kind: RendezvousMessageKind.iceCandidate,
        from: identity.edPubHex,
        to: peer.edPubHex,
        ts: _secondsNow(),
        session: sessionId,
        candidate: candidate,
      ),
    );
  }

  Future<void> sendPresence(GlobalPeer peer, String sessionId) {
    return _send(
      peer,
      RendezvousMessage(
        kind: RendezvousMessageKind.presence,
        from: identity.edPubHex,
        to: peer.edPubHex,
        ts: _secondsNow(),
        session: sessionId,
      ),
    );
  }

  Future<RendezvousMessage?> decodePeerEvent(
    GlobalPeer peer,
    NostrEvent event,
  ) async {
    if (event.kind != localChatRendezvousKind) return null;
    if (event.pubkey != peer.edPubHex) return null;
    if (!await event.verifySignature()) return null;
    final topic = rendezvousTopic(identity.edPub, peer.edPub);
    if (!event.tags.any(
      (tag) => tag.length >= 2 && tag[0] == 'd' && tag[1] == topic,
    )) {
      return null;
    }

    try {
      final plaintext = await NostrClient.decrypt(
        event.content,
        myXPriv: identity.xPriv,
        theirXPub: peer.xPub,
      );
      final message = RendezvousMessage.fromJson(
        jsonDecode(plaintext) as Map<String, dynamic>,
      );
      if (message.from != peer.edPubHex || message.to != identity.edPubHex) {
        return null;
      }
      if ((_secondsNow() - message.ts).abs() > 120) return null;
      final dedupeKey = message.dedupeKey;
      if (!_seenMessageKeys.add(dedupeKey)) return null;
      return message;
    } catch (_) {
      return null;
    }
  }

  Future<void> _send(GlobalPeer peer, RendezvousMessage message) async {
    final topic = rendezvousTopic(identity.edPub, peer.edPub);
    final encrypted = await NostrClient.encrypt(
      jsonEncode(message.toJson()),
      myXPriv: identity.xPriv,
      theirXPub: peer.xPub,
    );
    final event = await NostrEvent.sign(
      keyPair: identity.edKeyPair,
      kind: localChatRendezvousKind,
      tags: <List<String>>[
        <String>['d', topic],
        <String>['p', peer.edPubHex],
      ],
      content: encrypted,
      createdAt: _secondsNow(),
    );
    nostr.publish(event);
  }

  Future<void> close() async {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    await _messages.close();
  }

  int _secondsNow() => _now().millisecondsSinceEpoch ~/ 1000;

  static String rendezvousTopic(List<int> aEdPub, List<int> bEdPub) {
    final sorted = <List<int>>[aEdPub, bEdPub]..sort(_compareBytes);
    final bytes = <int>[
      ...utf8.encode('lc-rdv-v1'),
      ...sorted[0],
      ...sorted[1],
    ];
    return crypto.sha256.convert(bytes).toString();
  }

  static int _compareBytes(List<int> a, List<int> b) {
    final len = a.length < b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final diff = a[i].compareTo(b[i]);
      if (diff != 0) return diff;
    }
    return a.length.compareTo(b.length);
  }
}

enum RendezvousMessageKind {
  webrtcOffer('webrtc_offer'),
  webrtcAnswer('webrtc_answer'),
  iceCandidate('ice_candidate'),
  presence('presence');

  const RendezvousMessageKind(this.wireName);

  final String wireName;

  static RendezvousMessageKind? fromWireName(String? name) {
    for (final kind in values) {
      if (kind.wireName == name) return kind;
    }
    return null;
  }
}

class RendezvousMessage {
  const RendezvousMessage({
    required this.kind,
    required this.from,
    required this.to,
    required this.ts,
    required this.session,
    this.sdp,
    this.candidate,
  });

  final RendezvousMessageKind kind;
  final String from;
  final String to;
  final int ts;
  final String session;
  final String? sdp;
  final Map<String, Object?>? candidate;

  String get dedupeKey {
    final payload = jsonEncode(<String, Object?>{
      'kind': kind.wireName,
      'from': from,
      'to': to,
      'session': session,
      'sdp': sdp,
      'candidate': candidate,
    });
    return crypto.sha256.convert(utf8.encode(payload)).toString();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': 1,
    'kind': kind.wireName,
    'from': from,
    'to': to,
    'ts': ts,
    'session': session,
    if (sdp != null) 'sdp': sdp,
    if (candidate != null) 'candidate': candidate,
  };

  factory RendezvousMessage.fromJson(Map<String, dynamic> json) {
    if (json['v'] != 1) {
      throw const FormatException('unsupported rendezvous message version');
    }
    final kind = RendezvousMessageKind.fromWireName(json['kind'] as String?);
    if (kind == null) {
      throw const FormatException('unknown rendezvous message kind');
    }
    final candidateJson = json['candidate'];
    return RendezvousMessage(
      kind: kind,
      from: json['from'] as String? ?? '',
      to: json['to'] as String? ?? '',
      ts: (json['ts'] as num?)?.toInt() ?? 0,
      session: json['session'] as String? ?? '',
      sdp: json['sdp'] as String?,
      candidate: candidateJson is Map
          ? Map<String, Object?>.from(candidateJson)
          : null,
    );
  }
}
