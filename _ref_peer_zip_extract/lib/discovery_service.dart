// In DiscoveryService, update _handleMessage method:

void _handleMessage(String raw, String senderIp) {
  if (!raw.startsWith('LOCALCHAT|')) return;
  final parts = raw.split('|');
  if (parts.length < 4) return;

  final userId = parts[1];
  final name = parts[2];
  final port = int.tryParse(parts[3]) ?? tcpPort;

  if (userId == me.userId) return;

  final existing = _peers[userId];
  if (existing != null) {
    // Peer already known - check for updates
    existing.lastSeen = DateTime.now();

    final nameChanged = existing.name != name;
    final ipChanged = existing.ip != senderIp;
    final portChanged = existing.port != port;

    if (nameChanged || ipChanged || portChanged) {
      // Check if this is same device switching interfaces
      // vs actually different device
      if (DiscoveryDeduplicator.isSamePeerDifferentInterface(
        existing,
        name,
        senderIp,
        port,
      )) {
        // Same device, different interface - just update connection info
        if (kDebugMode) {
          print('[Discovery] ${existing.name} interface switch: '
              '${existing.ip} → $senderIp');
        }

        existing.ip = senderIp;
        existing.port = port;
        if (name.isNotEmpty && name != existing.name) {
          existing.name = name;
        }
      } else {
        // Actually different device or significant change - create new entry
        if (kDebugMode) {
          print('[Discovery] ${existing.name} changed to $name - treating as update');
        }

        _peers[userId] = PeerDevice(
          userId: userId,
          name: name,
          ip: senderIp,
          port: port,
          lastSeen: DateTime.now(),
        );
      }

      onPeersChanged?.call();
    }
  } else {
    // New peer discovered
    _peers[userId] = PeerDevice(
      userId: userId,
      name: name,
      ip: senderIp,
      port: port,
      lastSeen: DateTime.now(),
    );

    if (kDebugMode) {
      print('[Discovery] New peer: $name ($userId)');
    }

    onPeersChanged?.call();
  }
}