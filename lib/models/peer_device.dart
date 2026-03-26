class PeerDevice {
  final String userId;
  final String displayName;
  final String ipAddress;
  final int wsPort;

  DateTime lastSeen;

  PeerDevice({
    required this.userId,
    required this.displayName,
    required this.ipAddress,
    required this.wsPort,
    required this.lastSeen,
  });
}

