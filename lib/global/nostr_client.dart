import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

const defaultNostrRelays = <String>[
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.nostr.band',
  'wss://nostr.wine',
  'wss://relay.snort.social',
];

typedef NostrFilter = Map<String, Object?>;
typedef NostrEventCallback = void Function(NostrEvent event);

class NostrClient {
  NostrClient({Duration connectTimeout = const Duration(seconds: 5)})
    : _connectTimeout = connectTimeout;

  final Duration _connectTimeout;
  final List<_RelayConnection> _relays = [];
  final Map<String, NostrEventCallback> _subscriptions = {};
  final Set<String> _seenEventIds = <String>{};
  int _subscriptionCounter = 0;

  Future<void> connect(List<String> relayUrls) async {
    await close();
    await Future.wait<void>(relayUrls.map(_connectRelay));
  }

  Future<void> _connectRelay(String relayUrl) async {
    final uri = Uri.tryParse(relayUrl);
    if (uri == null || (uri.scheme != 'wss' && uri.scheme != 'ws')) {
      return;
    }
    try {
      final channel = WebSocketChannel.connect(uri);
      await channel.ready.timeout(_connectTimeout);
      late final StreamSubscription<dynamic> streamSub;
      streamSub = channel.stream.listen(
        _handleRelayMessage,
        onError: (_) {},
        onDone: () => _relays.removeWhere((relay) => relay.uri == uri),
        cancelOnError: false,
      );
      _relays.add(_RelayConnection(uri, channel, streamSub));
    } catch (_) {
      // Public relays are best-effort. Later phases surface aggregate errors.
    }
  }

  void publish(NostrEvent event) {
    final wire = jsonEncode(<Object?>['EVENT', event.toJson()]);
    for (final relay in _relays) {
      relay.channel.sink.add(wire);
    }
  }

  NostrSubscription subscribe(
    NostrFilter filter,
    NostrEventCallback callback, {
    String? id,
  }) {
    final subscriptionId = id ?? _nextSubscriptionId();
    _subscriptions[subscriptionId] = callback;
    final wire = jsonEncode(<Object?>['REQ', subscriptionId, filter]);
    for (final relay in _relays) {
      relay.channel.sink.add(wire);
    }
    return NostrSubscription._(subscriptionId, () {
      _subscriptions.remove(subscriptionId);
      final closeWire = jsonEncode(<Object?>['CLOSE', subscriptionId]);
      for (final relay in _relays) {
        relay.channel.sink.add(closeWire);
      }
    });
  }

  Future<void> close() async {
    _subscriptions.clear();
    _seenEventIds.clear();
    final relays = List<_RelayConnection>.from(_relays);
    _relays.clear();
    for (final relay in relays) {
      await relay.subscription.cancel();
      await relay.channel.sink.close();
    }
  }

  static Future<String> encrypt(
    String plaintext, {
    required List<int> theirXPub,
    required List<int> myXPriv,
  }) {
    return Nip44Payload.encrypt(
      plaintext,
      theirXPub: theirXPub,
      myXPriv: myXPriv,
    );
  }

  static Future<String> decrypt(
    String payload, {
    required List<int> theirXPub,
    required List<int> myXPriv,
  }) {
    return Nip44Payload.decrypt(
      payload,
      theirXPub: theirXPub,
      myXPriv: myXPriv,
    );
  }

  void _handleRelayMessage(dynamic raw) {
    if (raw is! String) return;
    final decoded = jsonDecode(raw);
    if (decoded is! List || decoded.isEmpty) return;
    if (decoded.first != 'EVENT' || decoded.length < 3) return;

    final subscriptionId = decoded[1] as String?;
    final callback = _subscriptions[subscriptionId];
    if (callback == null) return;

    final eventJson = decoded[2];
    if (eventJson is! Map) return;
    final event = NostrEvent.fromJson(Map<String, Object?>.from(eventJson));
    if (!_seenEventIds.add(event.id)) return;
    callback(event);
  }

  String _nextSubscriptionId() {
    _subscriptionCounter += 1;
    final millis = DateTime.now().millisecondsSinceEpoch;
    return 'lc-${millis.toRadixString(36)}-${_subscriptionCounter.toRadixString(36)}';
  }
}

class NostrSubscription {
  NostrSubscription._(this.id, this._cancel);

  final String id;
  final void Function() _cancel;
  bool _isCancelled = false;

  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    _cancel();
  }
}

class NostrEvent {
  const NostrEvent({
    required this.id,
    required this.pubkey,
    required this.createdAt,
    required this.kind,
    required this.tags,
    required this.content,
    required this.sig,
  });

  final String id;
  final String pubkey;
  final int createdAt;
  final int kind;
  final List<List<String>> tags;
  final String content;
  final String sig;

  static Future<NostrEvent> sign({
    required SimpleKeyPairData keyPair,
    required int kind,
    required String content,
    List<List<String>> tags = const <List<String>>[],
    int? createdAt,
  }) async {
    final publicKey = await keyPair.extractPublicKey();
    final pubkey = NostrHex.encode(publicKey.bytes);
    final timestamp =
        createdAt ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final id = computeId(
      pubkey: pubkey,
      createdAt: timestamp,
      kind: kind,
      tags: tags,
      content: content,
    );
    final signature = await Ed25519().sign(
      NostrHex.decode(id),
      keyPair: keyPair,
    );
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: timestamp,
      kind: kind,
      tags: _copyTags(tags),
      content: content,
      sig: NostrHex.encode(signature.bytes),
    );
  }

  factory NostrEvent.fromJson(Map<String, Object?> json) {
    final rawTags = json['tags'] as List<dynamic>? ?? const <dynamic>[];
    return NostrEvent(
      id: json['id'] as String? ?? '',
      pubkey: json['pubkey'] as String? ?? '',
      createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
      kind: (json['kind'] as num?)?.toInt() ?? 0,
      tags: rawTags
          .whereType<List<dynamic>>()
          .map((tag) => tag.map((part) => part.toString()).toList())
          .toList(),
      content: json['content'] as String? ?? '',
      sig: json['sig'] as String? ?? '',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'pubkey': pubkey,
    'created_at': createdAt,
    'kind': kind,
    'tags': tags,
    'content': content,
    'sig': sig,
  };

  Future<bool> verifySignature() async {
    if (id !=
        computeId(
          pubkey: pubkey,
          createdAt: createdAt,
          kind: kind,
          tags: tags,
          content: content,
        )) {
      return false;
    }
    try {
      return Ed25519().verify(
        NostrHex.decode(id),
        signature: Signature(
          NostrHex.decode(sig),
          publicKey: SimplePublicKey(
            NostrHex.decode(pubkey),
            type: KeyPairType.ed25519,
          ),
        ),
      );
    } on FormatException {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  static String computeId({
    required String pubkey,
    required int createdAt,
    required int kind,
    required List<List<String>> tags,
    required String content,
  }) {
    final serialized = jsonEncode(<Object?>[
      0,
      pubkey,
      createdAt,
      kind,
      tags,
      content,
    ]);
    return crypto.sha256.convert(utf8.encode(serialized)).toString();
  }

  static List<List<String>> _copyTags(List<List<String>> tags) =>
      tags.map((tag) => List<String>.from(tag)).toList();
}

class Nip44Payload {
  static const _version = 2;
  static final _secureRandom = Random.secure();
  static final _chacha20 = Chacha20(macAlgorithm: MacAlgorithm.empty);
  static final _hmac = Hmac.sha256();

  static Future<String> encrypt(
    String plaintext, {
    required List<int> theirXPub,
    required List<int> myXPriv,
  }) async {
    final conversationKey = await getConversationKey(
      myXPriv: myXPriv,
      theirXPub: theirXPub,
    );
    return encryptWithConversationKey(plaintext, conversationKey);
  }

  static Future<String> decrypt(
    String payload, {
    required List<int> theirXPub,
    required List<int> myXPriv,
  }) async {
    final conversationKey = await getConversationKey(
      myXPriv: myXPriv,
      theirXPub: theirXPub,
    );
    return decryptWithConversationKey(payload, conversationKey);
  }

  static Future<String> encryptWithConversationKey(
    String plaintext,
    List<int> conversationKey, {
    List<int>? nonce,
  }) async {
    final msgNonce = nonce ?? _randomBytes(32);
    final keys = await _messageKeys(conversationKey, msgNonce);
    final padded = _pad(utf8.encode(plaintext));
    final box = await _chacha20.encrypt(
      padded,
      secretKey: SecretKey(keys.chachaKey),
      nonce: keys.chachaNonce,
    );
    final mac = await _hmacAad(keys.hmacKey, box.cipherText, msgNonce);
    final bytes = <int>[_version, ...msgNonce, ...box.cipherText, ...mac];
    return base64Encode(bytes);
  }

  static Future<String> decryptWithConversationKey(
    String payload,
    List<int> conversationKey,
  ) async {
    final decoded = _decodePayload(payload);
    final keys = await _messageKeys(conversationKey, decoded.nonce);
    final calculatedMac = await _hmacAad(
      keys.hmacKey,
      decoded.ciphertext,
      decoded.nonce,
    );
    if (!_constantTimeEquals(calculatedMac, decoded.mac)) {
      throw const FormatException('invalid NIP-44 MAC');
    }
    final padded = await _chacha20.decrypt(
      SecretBox(decoded.ciphertext, nonce: keys.chachaNonce, mac: Mac.empty),
      secretKey: SecretKey(keys.chachaKey),
    );
    return utf8.decode(_unpad(padded));
  }

  static Future<List<int>> getConversationKey({
    required List<int> myXPriv,
    required List<int> theirXPub,
  }) async {
    _checkLength(myXPriv, 32, 'myXPriv');
    _checkLength(theirXPub, 32, 'theirXPub');
    final keyPair = await X25519().newKeyPairFromSeed(myXPriv);
    final sharedSecret = await X25519().sharedSecretKey(
      keyPair: keyPair,
      remotePublicKey: SimplePublicKey(theirXPub, type: KeyPairType.x25519),
    );
    return _hkdfExtract(
      utf8.encode('nip44-v2'),
      await sharedSecret.extractBytes(),
    );
  }

  static int calcPaddedLen(int unpaddedLen) {
    if (unpaddedLen < 1 || unpaddedLen > 65535) {
      throw RangeError.range(unpaddedLen, 1, 65535, 'unpaddedLen');
    }
    if (unpaddedLen <= 32) return 32;
    final nextPower = 1 << (_log2Floor(unpaddedLen - 1) + 1);
    final chunk = nextPower <= 256 ? 32 : nextPower ~/ 8;
    return chunk * (((unpaddedLen - 1) ~/ chunk) + 1);
  }

  static Future<_Nip44MessageKeys> _messageKeys(
    List<int> conversationKey,
    List<int> nonce,
  ) async {
    _checkLength(conversationKey, 32, 'conversationKey');
    _checkLength(nonce, 32, 'nonce');
    final keys = await _hkdfExpand(conversationKey, nonce, 76);
    return _Nip44MessageKeys(
      chachaKey: keys.sublist(0, 32),
      chachaNonce: keys.sublist(32, 44),
      hmacKey: keys.sublist(44, 76),
    );
  }

  static Future<List<int>> _hkdfExtract(List<int> salt, List<int> ikm) async {
    final mac = await _hmac.calculateMac(ikm, secretKey: SecretKey(salt));
    return mac.bytes;
  }

  static Future<List<int>> _hkdfExpand(
    List<int> prk,
    List<int> info,
    int length,
  ) async {
    final result = BytesBuilder(copy: false);
    var previous = <int>[];
    var block = 1;
    while (result.length < length) {
      final sink = await _hmac.newMacSink(secretKey: SecretKey(prk));
      sink.add(previous);
      sink.add(info);
      sink.add(<int>[block]);
      sink.close();
      final mac = await sink.mac();
      previous = mac.bytes;
      result.add(previous);
      block += 1;
    }
    return result.toBytes().sublist(0, length);
  }

  static Future<List<int>> _hmacAad(
    List<int> key,
    List<int> message,
    List<int> aad,
  ) async {
    _checkLength(aad, 32, 'aad');
    final mac = await _hmac.calculateMac(<int>[
      ...aad,
      ...message,
    ], secretKey: SecretKey(key));
    return mac.bytes;
  }

  static List<int> _pad(List<int> plaintext) {
    final length = plaintext.length;
    final paddedLength = calcPaddedLen(length);
    return <int>[
      (length >> 8) & 0xff,
      length & 0xff,
      ...plaintext,
      ...List<int>.filled(paddedLength - length, 0),
    ];
  }

  static List<int> _unpad(List<int> padded) {
    if (padded.length < 34) {
      throw const FormatException('invalid NIP-44 padding');
    }
    final unpaddedLength = (padded[0] << 8) | padded[1];
    final expectedLength = 2 + calcPaddedLen(unpaddedLength);
    if (padded.length != expectedLength) {
      throw const FormatException('invalid NIP-44 padding length');
    }
    final plaintext = padded.sublist(2, 2 + unpaddedLength);
    final suffix = padded.sublist(2 + unpaddedLength);
    if (suffix.any((byte) => byte != 0)) {
      throw const FormatException('invalid NIP-44 padding bytes');
    }
    return plaintext;
  }

  static _Nip44DecodedPayload _decodePayload(String payload) {
    if (payload.isEmpty || payload.codeUnitAt(0) == '#'.codeUnitAt(0)) {
      throw const FormatException('unknown NIP-44 payload version');
    }
    if (payload.length < 132 || payload.length > 87472) {
      throw const FormatException('invalid NIP-44 payload size');
    }
    final data = base64Decode(payload);
    if (data.length < 99 || data.length > 65603) {
      throw const FormatException('invalid NIP-44 decoded size');
    }
    if (data[0] != _version) {
      throw FormatException('unsupported NIP-44 version ${data[0]}');
    }
    return _Nip44DecodedPayload(
      nonce: data.sublist(1, 33),
      ciphertext: data.sublist(33, data.length - 32),
      mac: data.sublist(data.length - 32),
    );
  }

  static List<int> _randomBytes(int length) =>
      List<int>.generate(length, (_) => _secureRandom.nextInt(256));

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static int _log2Floor(int value) {
    var result = 0;
    while (value > 1) {
      value >>= 1;
      result += 1;
    }
    return result;
  }

  static void _checkLength(List<int> value, int length, String name) {
    if (value.length != length) {
      throw ArgumentError.value(value, name, 'must be $length bytes');
    }
  }
}

class NostrHex {
  const NostrHex._();

  static String encode(List<int> bytes) {
    final buffer = StringBuffer();
    for (final byte in bytes) {
      buffer.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }

  static List<int> decode(String hex) {
    if (hex.length.isOdd) {
      throw const FormatException('hex string must have an even length');
    }
    final bytes = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < bytes.length; i++) {
      final start = i * 2;
      final value = int.tryParse(hex.substring(start, start + 2), radix: 16);
      if (value == null) {
        throw FormatException('invalid hex byte at offset $start');
      }
      bytes[i] = value;
    }
    return bytes;
  }
}

class _RelayConnection {
  _RelayConnection(this.uri, this.channel, this.subscription);

  final Uri uri;
  final WebSocketChannel channel;
  final StreamSubscription<dynamic> subscription;
}

class _Nip44MessageKeys {
  _Nip44MessageKeys({
    required this.chachaKey,
    required this.chachaNonce,
    required this.hmacKey,
  });

  final List<int> chachaKey;
  final List<int> chachaNonce;
  final List<int> hmacKey;
}

class _Nip44DecodedPayload {
  _Nip44DecodedPayload({
    required this.nonce,
    required this.ciphertext,
    required this.mac,
  });

  final List<int> nonce;
  final List<int> ciphertext;
  final List<int> mac;
}
