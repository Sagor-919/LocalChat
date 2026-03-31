import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';

import 'connection_service.dart';
import 'file_transfer_service.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'package:path/path.dart' as p;

import 'android_share_inbound.dart';
import 'attachment_prepare.dart';
import 'deferred_staged_file.dart';

enum OutgoingTransferPhase { preparing, transferring }

class TransferState {
  final String fileId;
  final String peerId;
  final String fileName;
  int totalBytes;
  final bool isSending;
  String? filePath;

  int transferredBytes = 0;
  double progress = 0;
  String? error;
  bool cancelled = false;
  bool cancelRequested = false;
  /// Paused mid-transfer (local); not an error — partial file kept on receiver.
  bool isPaused = false;
  FileSender? sender;
  Process? prepProcess;
  final List<String> tempPathsForCleanup = [];
  OutgoingTransferPhase outgoingPhase;
  final Stopwatch stopwatch = Stopwatch()..start();

  TransferState({
    required this.fileId,
    required this.peerId,
    required this.fileName,
    required this.totalBytes,
    required this.isSending,
    this.filePath,
    this.outgoingPhase = OutgoingTransferPhase.transferring,
  });

  double get currentSpeed {
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed < 300 || transferredBytes == 0) return 0;
    return transferredBytes / (elapsed / 1000);
  }
}

class FileMessageEvent {
  final String peerId;
  final ChatMessage message;
  const FileMessageEvent(this.peerId, this.message);
}

class _PendingReceive {
  final String peerId;
  final String fileName;
  final int fileSize;
  const _PendingReceive(this.peerId, this.fileName, this.fileSize);
}

class _PendingWaiter {
  final Completer<_PendingReceive> completer = Completer();
}

class TransferManager {
  static final instance = TransferManager._();
  TransferManager._();

  final Map<String, TransferState> transfers = {};
  final Map<String, _PendingReceive> _pending = {};
  final Map<String, _PendingWaiter> _waiters = {};

  final _transferUpdates = StreamController<void>.broadcast();
  final _fileMessages = StreamController<FileMessageEvent>.broadcast();

  Stream<void> get transferUpdates => _transferUpdates.stream;
  Stream<FileMessageEvent> get fileMessages => _fileMessages.stream;

  late ConnectionService _connections;
  late MessageStore _store;
  FileReceiver? _receiver;
  FlutterLocalNotificationsPlugin? _notifPlugin;
  Timer? _notifTimer;
  static const _transferNotifId = 99999;

  /// Receiver-side partial path for resume (same [fileId]).
  final Map<String, String> _receivePathByFileId = {};

  Future<void> init({
    required ConnectionService connections,
    required MessageStore store,
    required String myId,
    FlutterLocalNotificationsPlugin? notificationsPlugin,
  }) async {
    _connections = connections;
    _store = store;
    assert(myId.isNotEmpty);
    if (!kIsWeb && Platform.isAndroid) {
      _notifPlugin = notificationsPlugin;
    }

    _receiver = FileReceiver();
    _receiver!.resumePathResolver = _resolveResumeReceivePath;
    _receiver!.onFileStarted = _onReceiveStarted;
    _receiver!.onProgress = _onReceiveProgress;
    _receiver!.onFileComplete = _onReceiveComplete;
    _receiver!.onFileError = _onReceiveError;
    _receiver!.onFilePaused = _onReceivePaused;
    await _receiver!.startServer();
  }

  /// Called from main.dart when a file_notify arrives over the chat TCP.
  /// Pre-registers the expected incoming transfer so we can map fileId -> peerId.
  void registerIncoming(
    String peerId,
    String fileId,
    String fileName,
    int fileSize,
  ) {
    final pending = _PendingReceive(peerId, fileName, fileSize);
    final waiter = _waiters.remove(fileId);
    if (waiter != null) {
      waiter.completer.complete(pending);
    } else {
      _pending[fileId] = pending;
    }
  }

  void _cleanupOutgoingTemps(TransferState t) {
    for (final path in t.tempPathsForCleanup) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    t.tempPathsForCleanup.clear();
  }

  static String _sanitizeOutboundFilename(String name) {
    final s = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (s.isEmpty) return 'file';
    return s.length > 120 ? s.substring(0, 120) : s;
  }

  /// Copy to app documents so we never store a path that [cleanupOutgoingTemps] will delete later.
  Future<String> _persistOutboundFileToDocuments(
    String sourcePath,
    String messageId,
    String attachmentName,
  ) async {
    final root = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(root.path, 'outbound_attachments'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final ext = p.extension(attachmentName);
    final base = _sanitizeOutboundFilename(p.basenameWithoutExtension(attachmentName));
    final destPath = p.join(dir.path, '${messageId}_$base$ext');
    await File(sourcePath).copy(destPath);
    return destPath;
  }

  /// [initialMessage] must already be in [MessageStore]. Prepares file (copy / folder zip), then sends.
  Future<void> prepareAndSendOutbound({
    required ChatMessage initialMessage,
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
    required String sourcePath,
    String? androidContentUri,
    required StagedSourceKind kind,
    required bool duplicatePathInBatch,
  }) async {
    final id = initialMessage.id;
    final hasContentUri =
        androidContentUri != null && androidContentUri.isNotEmpty;
    final preparing = kind == StagedSourceKind.folderToZip ||
        duplicatePathInBatch ||
        hasContentUri;
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
    await _runPrepareAndSend(
      initialMessage: initialMessage,
      peerId: peerId,
      peerIp: peerIp,
      peerDisplayName: peerDisplayName,
      sourcePath: sourcePath,
      androidContentUri: androidContentUri,
      kind: kind,
      duplicatePathInBatch: duplicatePathInBatch,
    );
  }

  Future<void> _runPrepareAndSend({
    required ChatMessage initialMessage,
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
    required String sourcePath,
    String? androidContentUri,
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
        var workPath = sourcePath;
        final uri = androidContentUri;
        if (uri != null && uri.isNotEmpty) {
          t.outgoingPhase = OutgoingTransferPhase.preparing;
          t.totalBytes = 0;
          t.transferredBytes = 0;
          t.progress = 0;
          _notify();
          final mat = uniqueTempPath(
            Directory.systemTemp.path,
            '${initialMessage.id}_share',
            initialMessage.attachmentName!,
          );
          t.tempPathsForCleanup.add(mat);
          await AndroidShareInbound.materializeContentUriToFile(
            contentUri: uri,
            destPath: mat,
          );
          if (t.cancelRequested) throw const AttachmentPrepareCancelled();
          workPath = mat;
        }

        final f = File(workPath);
        if (!await f.exists()) {
          throw AttachmentPrepareException('File not found: $workPath');
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
            workPath,
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
          sendPath = workPath;
          sendSize = await f.length();
        }
      }

      if (t.cancelRequested) throw const AttachmentPrepareCancelled();

      // Temp prep paths (content URI, duplicate batch, zip) are deleted after send; DB must
      // reference a permanent copy so thumbnails and open keep working.
      var outboundPath = sendPath;
      if (t.tempPathsForCleanup.contains(sendPath)) {
        outboundPath = await _persistOutboundFileToDocuments(
          sendPath,
          initialMessage.id,
          initialMessage.attachmentName!,
        );
      }

      await _store.updateOutboundAttachment(
        peerId,
        initialMessage.id,
        path: outboundPath,
        size: sendSize,
      );

      final updated = initialMessage.copyWith(
        attachmentPath: outboundPath,
        attachmentSize: sendSize,
      );
      _fileMessages.add(FileMessageEvent(peerId, updated));

      t.filePath = outboundPath;
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

  /// Prefer the address from the live chat TCP socket (matches successful retry path).
  String _resolveFileTransferHost(String peerId, String discoveryIp) {
    final sock = _connections.getSocket(peerId);
    if (sock != null) {
      final addr = sock.remoteAddress.address;
      if (addr.isNotEmpty) return addr;
    }
    return discoveryIp.trim();
  }

  Future<void> _emitStoredFileMessageForPreview(
      String peerId, String fileId) async {
    final list = await _store.load(peerId);
    for (final m in list) {
      if (m.id == fileId) {
        _fileMessages.add(FileMessageEvent(peerId, m));
        break;
      }
    }
  }

  Future<void> _runSend(TransferState t, String peerIp) async {
    final sender = FileSender();
    t.sender = sender;
    final startOff = t.transferredBytes;

    try {
      await sender.send(
        host: peerIp,
        fileId: t.fileId,
        fileName: t.fileName,
        fileSize: t.totalBytes,
        file: File(t.filePath!),
        startOffset: startOff,
        onProgress: (sent, total) {
          t.transferredBytes = sent;
          t.progress = total == 0 ? 0 : sent / total;
          _notify();
        },
      );
      t.isPaused = false;
      _cleanupOutgoingTemps(t);
      transfers.remove(t.fileId);
      _notify();
    } catch (e) {
      if (e is TransferPausedException) {
        t.isPaused = true;
        t.error = null;
        t.sender = null;
        _notify();
        // No Pause/Resume in UI — auto-continue outgoing sends after a brief pause.
        Future<void>.delayed(const Duration(milliseconds: 400), () {
          final t2 = transfers[t.fileId];
          if (t2 != null &&
              t2.isPaused &&
              t2.isSending &&
              t2.error == null &&
              !t2.cancelled) {
            resumeOutgoing(t.fileId);
          }
        });
      } else {
        t.isPaused = false;
        t.error = e.toString();
        _notify();
      }
    } finally {
      await _emitStoredFileMessageForPreview(t.peerId, t.fileId);
    }
  }

  void cancel(String fileId) {
    final t = transfers[fileId];
    if (t == null) return;
    t.cancelRequested = true;
    try {
      t.prepProcess?.kill(ProcessSignal.sigkill);
    } catch (_) {}
    t.prepProcess = null;
    if (t.isSending) {
      t.sender?.cancel();
    } else {
      _receiver?.cancelReceive(fileId);
    }
    t.error = 'Cancelled';
    t.cancelled = true;
    t.isPaused = false;
    _notify();
  }

  /// Local user paused an outgoing transfer (we are sender).
  void pauseOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null ||
        !t.isSending ||
        t.error != null ||
        t.outgoingPhase == OutgoingTransferPhase.preparing) {
      return;
    }
    final peerId = t.peerId;
    _connections.sendJson(peerId, {
      'type': 'file_control',
      'id': fileId,
      'pause': true,
      'from': 'sender',
    });
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      t.sender?.pause();
    });
  }

  /// Local user paused an incoming transfer (we are receiver) — asks peer to pause sending.
  void pauseIncoming(String fileId) {
    final t = transfers[fileId];
    if (t == null || t.isSending || t.error != null) return;
    final peerId = t.peerId;
    _connections.sendJson(peerId, {
      'type': 'file_control',
      'id': fileId,
      'pause': true,
      'from': 'receiver',
    });
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      _receiver?.pauseReceive(fileId);
    });
  }

  /// Remote peer paused their send — we are receiving; stop our file socket.
  void handleRemotePauseIncoming(String fileId) {
    _receiver?.pauseReceive(fileId);
  }

  /// Remote peer paused their receive — we are sending; stop our file socket.
  void handleRemotePauseOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null ||
        !t.isSending ||
        t.outgoingPhase == OutgoingTransferPhase.preparing) {
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 80), () {
      t.sender?.pause();
    });
  }

  /// Resume sending after [TransferPausedException] / pause.
  void resumeOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null || !t.isSending || !t.isPaused) return;
    if (t.filePath == null) return;
    final peerId = t.peerId;
    if (!_connections.isConnected(peerId)) return;
    final peerSocket = _connections.getSocket(peerId);
    if (peerSocket == null) return;

    _connections.sendJson(peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': t.fileName,
      'size': t.totalBytes,
      'offset': t.transferredBytes,
    });

    t.isPaused = false;
    t.error = null;
    t.cancelled = false;
    _notify();

    unawaited(_runSend(t, peerSocket.remoteAddress.address));
  }

  void dismiss(String fileId) {
    final t = transfers.remove(fileId);
    _notify();
    if (t == null) return;
    if (t.isSending) {
      _cleanupOutgoingTemps(t);
    }
    unawaited(_persistDismissedTransfer(t.peerId, fileId));
  }

  Future<void> _persistDismissedTransfer(String peerId, String fileId) async {
    await _store.updateTransferDismissed(peerId, fileId);
    final list = await _store.load(peerId);
    ChatMessage? found;
    for (final m in list) {
      if (m.id == fileId) {
        found = m;
        break;
      }
    }
    if (found != null) {
      _fileMessages.add(FileMessageEvent(peerId, found));
    }
  }

  void retry(String fileId) {
    final t = transfers[fileId];
    if (t == null) return;

    if (!t.isSending) {
      transfers.remove(fileId);
      _notify();
      return;
    }

    if (t.filePath == null) return;

    final peerId = t.peerId;
    if (!_connections.isConnected(peerId)) return;

    final peerSocket = _connections.getSocket(peerId);
    if (peerSocket == null) return;

    _connections.sendJson(peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': t.fileName,
      'size': t.totalBytes,
      'offset': 0,
    });

    t.error = null;
    t.cancelled = false;
    t.isPaused = false;
    t.transferredBytes = 0;
    t.progress = 0;
    t.stopwatch.reset();
    t.stopwatch.start();
    _notify();

    unawaited(_runSend(t, peerSocket.remoteAddress.address));
  }

  Future<String?> _resolveResumeReceivePath(
    String fileId,
    int offset,
    String safeName,
  ) async {
    final p = _receivePathByFileId[fileId];
    if (p == null || p.isEmpty) return null;
    final f = File(p);
    if (!await f.exists()) return null;
    final len = await f.length();
    if (len != offset) return null;
    return p;
  }

  // ---------------------------------------------------------------------------
  // FileReceiver callbacks
  // ---------------------------------------------------------------------------
  Future<void> _onReceiveStarted(
    String fileId,
    String fileName,
    int fileSize,
    String savePath,
    int resumeOffset,
  ) async {
    _receivePathByFileId[fileId] = savePath;

    if (resumeOffset > 0) {
      final existing = transfers[fileId];
      if (existing != null) {
        existing.isPaused = false;
        existing.error = null;
        existing.transferredBytes = resumeOffset;
        existing.progress =
            fileSize == 0 ? 0 : resumeOffset / fileSize;
      }
      _notify();
      return;
    }

    var pending = _pending.remove(fileId);
    if (pending == null) {
      final waiter = _PendingWaiter();
      _waiters[fileId] = waiter;
      try {
        pending = await waiter.completer.future
            .timeout(const Duration(seconds: 3));
      } catch (_) {
        _waiters.remove(fileId);
      }
    }
    final peerId = pending?.peerId ?? 'unknown';

    final msg = ChatMessage(
      id: fileId,
      senderId: peerId,
      text: 'File: $fileName',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: false,
      attachmentName: fileName,
      attachmentSize: fileSize,
    );

    final sockIp =
        _connections.getSocket(peerId)?.remoteAddress.address ?? '';
    await _store.add(
      peerId,
      msg,
      peerIp: sockIp,
      peerTcpPort: ConnectionService.tcpPort,
    );
    _fileMessages.add(FileMessageEvent(peerId, msg));

    transfers[fileId] = TransferState(
      fileId: fileId,
      peerId: peerId,
      fileName: fileName,
      totalBytes: fileSize,
      isSending: false,
    );
    _notify();
  }

  void _onReceivePaused(String fileId, String savePath, int bytesReceived) {
    final t = transfers[fileId];
    if (t == null) return;
    _receivePathByFileId[fileId] = savePath;
    t.isPaused = true;
    t.error = null;
    t.transferredBytes = bytesReceived;
    t.progress = t.totalBytes == 0 ? 0 : bytesReceived / t.totalBytes;
    _notify();
    unawaited(_emitStoredFileMessageForPreview(t.peerId, fileId));
  }

  void _onReceiveProgress(String fileId, int received, int total) {
    final t = transfers[fileId];
    if (t == null) return;
    t.transferredBytes = received;
    t.progress = total == 0 ? 0 : received / total;
    _notify();
  }

  void _onReceiveComplete(String fileId, String savedPath) {
    final t = transfers[fileId];
    if (t == null) return;
    final peerId = t.peerId;
    _receivePathByFileId.remove(fileId);

    transfers.remove(fileId);
    _notify();

    _store.updateAttachmentPath(peerId, fileId, savedPath);

    final updated = ChatMessage(
      id: fileId,
      senderId: peerId,
      text: 'File: ${t.fileName}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: false,
      attachmentName: t.fileName,
      attachmentPath: savedPath,
      attachmentSize: t.totalBytes,
    );
    _fileMessages.add(FileMessageEvent(peerId, updated));
  }

  void _onReceiveError(String fileId, String error, String? savePath) {
    final t = transfers[fileId];
    if (t == null) return;
    final peerId = t.peerId;
    t.isPaused = false;
    t.error = error;
    _receivePathByFileId.remove(fileId);
    _notify();
    unawaited(_emitStoredFileMessageForPreview(peerId, fileId));
  }

  void _notify() {
    _transferUpdates.add(null);
    _scheduleNotifUpdate();
  }

  void _scheduleNotifUpdate() {
    if (_notifPlugin == null) return;
    if (_notifTimer?.isActive ?? false) return;
    _notifTimer = Timer(const Duration(milliseconds: 500), _updateTransferNotification);
  }

  Future<void> _updateTransferNotification() async {
    if (_notifPlugin == null) return;
    final active = transfers.values
        .where((t) => t.error == null && !t.isPaused)
        .toList();
    if (active.isEmpty) {
      await _notifPlugin!.cancel(_transferNotifId);
      return;
    }

    final count = active.length;
    int totalBytes = 0;
    int doneBytes = 0;
    double speedSum = 0;
    for (final t in active) {
      totalBytes += t.totalBytes;
      doneBytes += t.transferredBytes;
      speedSum += t.currentSpeed;
    }
    final pct = totalBytes > 0 ? (doneBytes / totalBytes * 100).round() : 0;
    final speedStr = _fmtSpeed(speedSum);
    final remaining = speedSum > 0
        ? _fmtDuration(((totalBytes - doneBytes) / speedSum).round())
        : '';

    final body = count == 1
        ? '${active.first.fileName} — $pct% $speedStr${remaining.isNotEmpty ? ' ($remaining left)' : ''}'
        : '$count transfers — $pct% $speedStr${remaining.isNotEmpty ? ' ($remaining left)' : ''}';

    await _notifPlugin!.show(
      _transferNotifId,
      'File Transfer',
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'transfers', 'File Transfers',
          importance: Importance.low,
          priority: Priority.low,
          ongoing: true,
          autoCancel: false,
          showProgress: true,
          maxProgress: 100,
          progress: pct.clamp(0, 100),
          onlyAlertOnce: true,
        ),
      ),
    );
  }

  static String _fmtSpeed(double bytesPerSec) {
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    final kb = bytesPerSec / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB/s';
    final mb = kb / 1024;
    return '${mb.toStringAsFixed(1)} MB/s';
  }

  static String _fmtDuration(int seconds) {
    if (seconds < 60) return '${seconds}s';
    if (seconds < 3600) return '${seconds ~/ 60}m ${seconds % 60}s';
    return '${seconds ~/ 3600}h ${(seconds % 3600) ~/ 60}m';
  }
}
