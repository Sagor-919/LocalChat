class DiscoveryDeduplicator {
  /// Detects if a peer message is from same device with different IP
  /// (e.g., WiFi to Bluetooth switch)
  static bool isSamePeerDifferentInterface(
    PeerDevice existing,
    String incomingUserId,
    String incomingName,
    String incomingIp,
    int incomingPort,
  ) {
    // Same name + similar port = likely same device
    if (existing.name == incomingName && 
        (existing.port == incomingPort || 
         (existing.port - incomingPort).abs() <= 1)) {
      return true;
    }
    
    // Same userId on different subnet = likely reconnect
    // (Don't treat as different device)
    return false;
  }

  /// Merges duplicate peer entries, keeping best source
  static PeerDevice mergePeers(
    PeerDevice primary,
    PeerDevice incoming,
    DateTime lastSeen,
  ) {
    // Prefer name from discovery (more recent)
    final name = incoming.name.isEmpty ? primary.name : incoming.name;
    
    // Prefer most recent IP/port
    final ip = incoming.ip.isNotEmpty ? incoming.ip : primary.ip;
    final port = incoming.port > 0 ? incoming.port : primary.port;

    return PeerDevice(
      userId: primary.userId,
      name: name,
      ip: ip,
      port: port,
      lastSeen: lastSeen,
    );
  }
}