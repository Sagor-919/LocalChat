path = r"k:\GitRepos\LocalChat\lib\transfer_manager.dart"
with open(path, encoding="utf-8") as f:
    s = f.read()

old = """  /// Initiate sending a file to a peer. Creates the ChatMessage, stores it,
  /// sends file_notify, and runs the FileSender in the background.
  Future<void> sendFile({
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
    required String fileId,
    required String fileName,
    required String filePath,
    required int fileSize,
    int? timestamp,
  }) async {
    final msg = ChatMessage(
      id: fileId,
      senderId: _myId,
      text: 'File: $fileName',
      timestamp: timestamp ?? DateTime.now().millisecondsSinceEpoch,
      isMine: true,
      attachmentName: fileName,
      attachmentPath: filePath,
      attachmentSize: fileSize,
    );

    await _store.add(
      peerId,
      msg,
      peerDisplayName: peerDisplayName,
      peerIp: peerIp,
      peerTcpPort: ConnectionService.tcpPort,
    );
    _fileMessages.add(FileMessageEvent(peerId, msg));

    final notified = _connections.sendJson(peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': fileName,
      'size': fileSize,
      'offset': 0,
    });

    final t = TransferState(
      fileId: fileId,
      peerId: peerId,
      fileName: fileName,
      totalBytes: fileSize,
      isSending: true,
      filePath: filePath,
    );
    transfers[fileId] = t;
    if (!notified) {
      t.error =
          'Not connected — wait for peer or pull down to refresh peers, then retry.';
      _notify();
      return;
    }
    _notify();

    final targetIp = _resolveFileTransferHost(peerId, peerIp);
    unawaited(_runSend(t, targetIp));
  }
"""

new = r'''  void _cleanupOutgoingTemps(TransferState t) {
    for (final path in t.tempPathsForCleanup) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    t.tempPathsForCleanup.clear();
  }

  /// [initialMessage] must already be in [MessageStore]. Prepares file (copy / folder zip), then sends.
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
  }

  Future<void> _runPrepareAndSend({
    required ChatMessage initialMessage,
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
    required String sourcePath,
    required StagedSourceKind kind,
    required bool duplicatePathInBatch,
  }) async {
    final t = transfers[initialMessage.id];
    if (t == null) return;

    try {
      late String sendPath;
      late int sendSize;

      if (kind == StagedSourceKind.folderToZip) {
        t.outgoingPhase = OutgoingTransferPhase.preparing;
        t.totalBytes = 0;
        t.transferredBytes = 0;
        t.progress = 0;
        _notify();

        final normalized = sourcePath.replaceAll(RegExp(r'[/\\]+$'), '');
        final folderName = p.basename(normalized);
        final zipPath = p.join(
          Directory.systemTemp.path,
          '${initialMessage.id}_$folderName.zip',
        );
        t.tempPathsForCleanup.add(zipPath);

        await createFolderZip(
          directoryPath: normalized,
          folderName: folderName,
          zipOutPath: zipPath,
          isCancelled: () => t.cancelRequested,
          onProcessStarted: (proc) => t.prepProcess = proc,
        );
        t.prepProcess = null;

        if (t.cancelRequested) throw const AttachmentPrepareCancelled();

        sendPath = zipPath;
        sendSize = await File(zipPath).length();
      } else {
        final f = File(sourcePath);
        if (!await f.exists()) {
          throw AttachmentPrepareException('File not found: $sourcePath');
        }

        if (duplicatePathInBatch) {
          t.outgoingPhase = OutgoingTransferPhase.preparing;
          final len = await f.length();
          t.totalBytes = len;
          t.transferredBytes = 0;
          t.progress = 0;
          _notify();

          final dest = uniqueTempPath(
            Directory.systemTemp.path,
            initialMessage.id,
            initialMessage.attachmentName!,
          );
          t.tempPathsForCleanup.add(dest);

          await copyFileChunked(
            sourcePath,
            dest,
            onProgress: (copied, total) {
              t.transferredBytes = copied;
              t.progress = total == 0 ? 0 : copied / total;
              _notify();
            },
            isCancelled: () => t.cancelRequested,
          );

          if (t.cancelRequested) throw const AttachmentPrepareCancelled();

          sendPath = dest;
          sendSize = await File(dest).length();
        } else {
          sendPath = sourcePath;
          sendSize = await f.length();
        }
      }

      if (t.cancelRequested) throw const AttachmentPrepareCancelled();

      await _store.updateOutboundAttachment(
        peerId,
        initialMessage.id,
        path: sendPath,
        size: sendSize,
      );

      final updated = initialMessage.copyWith(
        attachmentPath: sendPath,
        attachmentSize: sendSize,
      );
      _fileMessages.add(FileMessageEvent(peerId, updated));

      t.filePath = sendPath;
      t.totalBytes = sendSize;
      t.transferredBytes = 0;
      t.progress = 0;
      t.outgoingPhase = OutgoingTransferPhase.transferring;
      t.stopwatch.reset();
      t.stopwatch.start();
      _notify();

      final notified = _connections.sendJson(peerId, {
        'type': 'file_notify',
        'id': initialMessage.id,
        'name': t.fileName,
        'size': sendSize,
        'offset': 0,
      });

      if (!notified) {
        t.error =
            'Not connected — wait for peer or pull down to refresh peers, then retry.';
        _notify();
        return;
      }

      final targetIp = _resolveFileTransferHost(peerId, peerIp);
      unawaited(_runSend(t, targetIp));
    } catch (e) {
      final t2 = transfers[initialMessage.id];
      if (t2 == null) return;
      if (e is AttachmentPrepareCancelled || t2.cancelRequested) {
        t2.error = 'Cancelled';
        t2.cancelled = true;
      } else {
        t2.error = e.toString();
      }
      t2.prepProcess = null;
      _cleanupOutgoingTemps(t2);
      _notify();
      await _emitStoredFileMessageForPreview(peerId, initialMessage.id);
    }
  }
'''

if old not in s:
    raise SystemExit('sendFile block not found')
s = s.replace(old, new, 1)
with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(s)
print('ok2')
