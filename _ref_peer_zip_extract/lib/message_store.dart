// In MessageStore class, add:

late PeerMetadataManager _peerMetadataManager;

/// Initialize metadata manager after DB is opened.
/// 
/// Add this to MessageStore.init() after openDatabase:
Future<void> _initializeMetadataManager() async {
  _peerMetadataManager = PeerMetadataManager(db: _db);
  await _peerMetadataManager.createMetadataTable();
}

/// Record peer verification when first contacted.
/// 
/// Call from connection_service when peer connects.
Future<void> recordPeerVerification({
  required String peerId,
  String? deviceUuid,
  String? hardwareHash,
  String? currentIp,
  int? currentPort,
}) async {
  await _peerMetadataManager.recordPeerVerification(
    peerId: peerId,
    deviceUuid: deviceUuid,
    hardwareHash: hardwareHash,
    currentIp: currentIp,
    currentPort: currentPort,
  );
}

/// Get peer verification info.
Future<PeerVerificationInfo?> getPeerVerificationInfo(String peerId) {
  return _peerMetadataManager.getVerificationInfo(peerId);
}

/// Find potential duplicate peers.
Future<List<String>> findPotentialDuplicates(String hardwareHash) {
  return _peerMetadataManager.findPotentialDuplicates(hardwareHash);
}

/// Cleanup old metadata periodically.
/// 
/// Call this when app goes to background:
Future<int> cleanupOldMetadata() {
  return _peerMetadataManager.cleanupOldMetadata();
}