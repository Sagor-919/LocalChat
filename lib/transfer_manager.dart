import 'dart:async';
import 'dart:io';

import 'connection_service.dart';
import 'file_transfer_service.dart';
import 'message_model.dart';
import 'message_store.dart';

class TransferState {
  final String fileId;
  final String peerId;
  final String fileName;
  final int totalBytes;
  final bool isSending;
  String? filePath;

  int transferredBytes = 0;
  double progress = 0;
  String? error;
  FileSender? sender;
  final Stopwatch stopwatch = Stopwatch()..start();

  TransferState({
    required this.fileId,
    required this.peerId,
    required this.fileName,
    required this.totalBytes,
    required this.isSending,
    this.filePath,
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

class TransferManager {
  static final instance = TransferManager._();
  TransferManager._();

  final Map<String, TransferState> transfers = {};
  final Map<String, _PendingReceive> _pending = {};

  final _transferUpdates = StreamController<void>.broadcast();
  final _fileMessages = StreamController<FileMessageEvent>.broadcast();

  Stream<void> get transferUpdates => _transferUpdates.stream;
  Stream<FileMessageEvent> get fileMessages => _fileMessages.stream;

  late ConnectionService _connections;
  late MessageStore _store;
  late String _myId;
  FileReceiver? _receiver;

  Future<void> init({
    required ConnectionService connections,
    required MessageStore store,
    required String myId,
  }) async {
    _connections = connections;
    _store = store;
    _myId = myId;

    _receiver = FileReceiver();
    _receiver!.onFileStarted = _onReceiveStarted;
    _receiver!.onProgress = _onReceiveProgress;
    _receiver!.onFileComplete = _onReceiveComplete;
    _receiver!.onFileError = _onReceiveError;
    await _receiver!.startServer();
  }

  /// Called from main.dart when a file_notify arrives over the chat TCP.
  /// Pre-registers the expected incoming transfer so we can map fileId → peerId.
  void registerIncoming(
      String peerId, String fileId, String fileName, int fileSize) {
    _pending[fileId] = _PendingReceive(peerId, fileName, fileSize);
  }

  /// Initiate sending a file to a peer. Creates the ChatMessage, stores it,
  /// sends file_notify, and runs the FileSender in the background.
  Future<void> sendFile({
    required String peerId,
    required String peerIp,
    required String fileId,
    required String fileName,
    required String filePath,
    required int fileSize,
  }) async {
    final msg = ChatMessage(
      id: fileId,
      senderId: _myId,
      text: 'File: $fileName',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: true,
      attachmentName: fileName,
      attachmentPath: filePath,
      attachmentSize: fileSize,
    );

    await _store.add(peerId, msg);
    _fileMessages.add(FileMessageEvent(peerId, msg));

    _connections.sendJson(peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': fileName,
      'size': fileSize,
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
    _notify();

    unawaited(_runSend(t, peerIp));
  }

  Future<void> _runSend(TransferState t, String peerIp) async {
    final sender = FileSender();
    t.sender = sender;

    try {
      await sender.send(
        host: peerIp,
        fileId: t.fileId,
        fileName: t.fileName,
        fileSize: t.totalBytes,
        file: File(t.filePath!),
        onProgress: (sent, total) {
          t.transferredBytes = sent;
          t.progress = total == 0 ? 0 : sent / total;
          _notify();
        },
      );
      transfers.remove(t.fileId);
      _notify();
    } catch (e) {
      t.error = e.toString();
      _notify();
    }
  }

  void cancel(String fileId) {
    final t = transfers[fileId];
    if (t == null) return;
    if (t.isSending) {
      t.sender?.cancel();
    } else {
      _receiver?.cancelReceive(fileId);
    }
    transfers.remove(fileId);
    _notify();
  }

  /// Retry a failed outgoing transfer.
  void retry(String fileId) {
    final t = transfers[fileId];
    if (t == null || !t.isSending || t.filePath == null) return;

    final peerId = t.peerId;
    final peer = _connections.isConnected(peerId);
    if (!peer) return;

    final peerSocket = _connections.getSocket(peerId);
    if (peerSocket == null) return;

    t.error = null;
    t.transferredBytes = 0;
    t.progress = 0;
    t.stopwatch.reset();
    t.stopwatch.start();
    _notify();

    unawaited(_runSend(t, peerSocket.remoteAddress.address));
  }

  // ---------------------------------------------------------------------------
  // FileReceiver callbacks
  // ---------------------------------------------------------------------------
  void _onReceiveStarted(String fileId, String fileName, int fileSize) {
    final pending = _pending.remove(fileId);
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

    _store.add(peerId, msg);
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

  void _onReceiveError(String fileId, String error) {
    final t = transfers[fileId];
    if (t == null) return;
    t.error = error;
    _notify();
  }

  void _notify() {
    _transferUpdates.add(null);
  }
}
