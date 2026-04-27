import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'nostr_client.dart';

class GlobalPeer {
  const GlobalPeer({
    required this.userId,
    required this.name,
    required this.edPub,
    required this.xPub,
    required this.addedAt,
  });

  final String userId;
  final String name;
  final List<int> edPub;
  final List<int> xPub;
  final DateTime addedAt;

  String get edPubHex => NostrHex.encode(edPub);
  String get xPubHex => NostrHex.encode(xPub);

  Map<String, Object?> toJson() => <String, Object?>{
    'userId': userId,
    'name': name,
    'edPub': edPubHex,
    'xPub': xPubHex,
    'addedAt': addedAt.toUtc().toIso8601String(),
  };

  factory GlobalPeer.fromJson(Map<String, Object?> json) {
    return GlobalPeer(
      userId: json['userId'] as String? ?? '',
      name: json['name'] as String? ?? 'Peer',
      edPub: NostrHex.decode(json['edPub'] as String? ?? ''),
      xPub: NostrHex.decode(json['xPub'] as String? ?? ''),
      addedAt:
          DateTime.tryParse(json['addedAt'] as String? ?? '')?.toLocal() ??
          DateTime.now(),
    );
  }
}

class GlobalPeerStore {
  static const peersKey = 'gd.peers';

  const GlobalPeerStore();

  Future<List<GlobalPeer>> loadPeers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(peersKey);
    if (raw == null || raw.isEmpty) return const <GlobalPeer>[];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .whereType<Map>()
          .map((entry) => GlobalPeer.fromJson(Map<String, Object?>.from(entry)))
          .where(
            (peer) =>
                peer.userId.isNotEmpty &&
                peer.edPub.length == 32 &&
                peer.xPub.length == 32,
          )
          .toList();
    } catch (_) {
      return const <GlobalPeer>[];
    }
  }

  Future<void> savePeer(GlobalPeer peer) async {
    final peers = await loadPeers();
    final merged = <GlobalPeer>[
      for (final existing in peers)
        if (existing.edPubHex != peer.edPubHex) existing,
      peer,
    ];
    await _saveAll(merged);
  }

  Future<void> removePeer(String edPubHex) async {
    final peers = await loadPeers();
    await _saveAll(peers.where((peer) => peer.edPubHex != edPubHex).toList());
  }

  Future<void> _saveAll(List<GlobalPeer> peers) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      peersKey,
      jsonEncode(peers.map((peer) => peer.toJson()).toList()),
    );
  }
}
