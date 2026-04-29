// Add to MessageStore._createSchema():

await db.execute('''
  CREATE TABLE peer_metadata (
    peer_id TEXT PRIMARY KEY,
    device_uuid TEXT NOT NULL,
    first_seen INTEGER NOT NULL,
    last_verified INTEGER NOT NULL,
    verification_hash TEXT,
    is_duplicate INTEGER DEFAULT 0
  )
''');

// When adding messages, also record peer verification:
Future<void> recordPeerVerification(
  String peerId,
  String deviceUuid,
  String verificationHash,
) async {
  await _db.insert(
    'peer_metadata',
    {
      'peer_id': peerId,
      'device_uuid': deviceUuid,
      'first_seen': DateTime.now().millisecondsSinceEpoch,
      'last_verified': DateTime.now().millisecondsSinceEpoch,
      'verification_hash': verificationHash,
      'is_duplicate': 0,
    },
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}