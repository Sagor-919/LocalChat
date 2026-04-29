/// Detects and resolves duplicate peer entries from discovery.
///
/// Scenarios:
/// 1. Same device, same interface → no change
/// 2. Same device, different interface → update IP/port, keep history
/// 3. New device, coincidental name match → treat as new device
/// 4. Device reset → new UUID, keep old entry for history
///
/// Deduplication uses device name + port as weak signal,
/// combined with network stability analysis.
class DiscoveryDeduplicator {
  /// Check if incoming peer broadcast is from same device as existing peer.
  ///
  /// Parameters:
  /// - existing: current peer entry in database
  /// - incomingUserId: userId from broadcast
  /// - incomingName: name from broadcast
  /// - incomingIp: source IP of broadcast
  /// - incomingPort: port from broadcast
  ///
  /// Returns: true if likely same device (e.g., interface change)
  ///
  /// Heuristics (in order of strength):
  /// 1. Same name + similar port = VERY LIKELY same device
  ///    (port rarely changes, name explicit)
  /// 2. Same name + no port = LIKELY same device
  /// 3. Different IP + recent last activity = interface change
  ///
  /// Note: userId comparison is NOT used here because we're detecting
  /// duplicates from SAME userId already. This is for interface switches.
  static bool isSamePeerDifferentInterface(
    PeerDevice existing,
    String incomingName,
    String incomingIp,
    int incomingPort,
  ) {
    // Same name is strongest signal
    if (existing.name != incomingName) {
      return false;
    }

    // If port same, definitely same device
    if (existing.port == incomingPort) {
      return true;
    }

    // If port only differs by 1 (e.g., 4041 vs 4042),
    // could be port mapping or running multiple instances
    // Allow this as "same device"
    if ((existing.port - incomingPort).abs() == 1) {
      return true;
    }

    // If name same but port differs more,
    // still assume same device (might be configuration change)
    // Only block if port dramatically different (e.g., >10)
    if ((existing.port - incomingPort).abs() >= 10) {
      return false;
    }

    // Name match + similar port = same device
    return true;
  }

  /// Merge two peer entries, keeping best data from each.
  ///
  /// Merge strategy:
  /// - Name: prefer incoming (more recent)
  /// - IP: prefer incoming (current interface)
  /// - Port: prefer incoming (current config)
  /// - lastSeen: always set to now
  /// - Keep all message history via same userId
  ///
  /// Parameters:
  /// - primary: existing peer entry
  /// - incoming: new peer data from discovery
  /// - now: current timestamp
  ///
  /// Returns: merged peer device
  static PeerDevice mergePeers(
    PeerDevice primary,
    String incomingName,
    String incomingIp,
    int incomingPort,
    DateTime now,
  ) {
    // Use incoming name if not empty (more recent)
    final name = incomingName.isNotEmpty ? incomingName : primary.name;

    // Always use incoming IP (current connection source)
    final ip = incomingIp.isNotEmpty ? incomingIp : primary.ip;

    // Use incoming port if valid
    final port = incomingPort > 0 ? incomingPort : primary.port;

    // Keep userId from primary (consistent identity)
    return PeerDevice(
      userId: primary.userId,
      name: name,
      ip: ip,
      port: port,
      lastSeen: now,
    );
  }

  /// Detect if this looks like a device reset by comparing:
  /// - Same name but very different IP subnet
  /// - Same name but different device type indicators
  ///
  /// Used to warn user that history may not be recoverable.
  static bool looksLikeDeviceReset(
    PeerDevice existing,
    String incomingName,
    String incomingIp,
  ) {
    // Same name is needed
    if (existing.name != incomingName) {
      return false;
    }

    // Extract subnet from IPs
    final existingSubnet = _getSubnet(existing.ip);
    final incomingSubnet = _getSubnet(incomingIp);

    // If on different subnets, could be device reset
    // (user moved to different WiFi network)
    if (existingSubnet != incomingSubnet && existingSubnet != null) {
      return true;
    }

    return false;
  }

  /// Extract subnet from IPv4 address (e.g., 192.168.1.x from 192.168.1.100).
  static String? _getSubnet(String ip) {
    try {
      final parts = ip.split('.');
      if (parts.length != 4) return null;

      return '${parts[0]}.${parts[1]}.${parts[2]}';
    } catch (_) {
      return null;
    }
  }

  /// Check if two IPs are likely from same local network.
  static bool isLocalNetworkAddress(String ip) {
    try {
      final parts = ip.split('.').map(int.parse).toList();
      if (parts.length != 4) return false;

      // Private IP ranges:
      // 10.0.0.0 - 10.255.255.255 (10/8)
      // 172.16.0.0 - 172.31.255.255 (172.16/12)
      // 192.168.0.0 - 192.168.255.255 (192.168/16)
      // 127.0.0.0 - 127.255.255.255 (127/8 loopback)

      if (parts[0] == 10) return true;
      if (parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31) return true;
      if (parts[0] == 192 && parts[1] == 168) return true;
      if (parts[0] == 127) return true;

      return false;
    } catch (_) {
      return false;
    }
  }

  /// Generate a hash of device characteristics for duplication detection.
  ///
  /// Used to detect when same physical device appears with different UUIDs
  /// (unlikely but possible in edge cases).
  ///
  /// Components:
  /// - Device name (strongest)
  /// - Network context (subnet)
  /// - Port (if non-standard)
  static String generateDeviceFingerprint(
    String name,
    String ip,
    int port,
  ) {
    final subnet = _getSubnet(ip) ?? 'unknown';
    final portStr = port != 4041 ? ':$port' : '';

    // Create fingerprint: name@subnet:port
    return '$name@$subnet$portStr'.toLowerCase();
  }
}