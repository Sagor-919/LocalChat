path = r"k:\GitRepos\LocalChat\lib\transfer_manager.dart"
with open(path, encoding="utf-8") as f:
    s = f.read()
if len(s) < 10000:
    raise SystemExit("refusing: file too small")
old = """  /// [initialMessage] must already be in [MessageStore]. Prepares file (copy / folder zip), then sends.
  void prepareAndSendOutbound({
    required ChatMessage initialMessage,
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
    required String sourcePath,
    required StagedSourceKind kind,
    required bool duplicatePathInBatch,
  }) {
    final id = initialMessage.id;
    final preparing = kind == StagedSourceKind.folderToZip || duplicatePathInBatch;
    final t = TransferState(
      fileId: id,
      peerId: peerId,
      fileName: initialMessage.attachmentName!,
      totalBytes: initialMessage.attachmentSize ?? 0,
      isSending: true,
      filePath: null,
      outgoingPhase: preparing
          ? OutgoingTransferPhase.preparing
          : OutgoingTransferPhase.transferring,
    );
    transfers[id] = t;
    _notify();
    unawaited(_runPrepareAndSend(
      initialMessage: initialMessage,
      peerId: peerId,
      peerIp: peerIp,
      peerDisplayName: peerDisplayName,
      sourcePath: sourcePath,
      kind: kind,
      duplicatePathInBatch: duplicatePathInBatch,
    ));
  }"""
new = old.replace("  void prepareAndSendOutbound({", "  Future<void> prepareAndSendOutbound({")
new = new.replace("  }) {", "  }) async {", 1)
new = new.replace("    unawaited(_runPrepareAndSend(", "    await _runPrepareAndSend(")
new = new.replace("    ));", "    );", 1)
if old not in s:
    raise SystemExit("block not found")
s2 = s.replace(old, new, 1)
if len(s2) < 10000:
    raise SystemExit("result too small")
with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(s2)
print("async ok", len(s2))
