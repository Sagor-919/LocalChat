import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

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
  bool cancelled = false;
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
  late String _myId;
  FileReceiver? _receiver;
  FlutterLocalNotificationsPlugin? _notifPlugin;
  Timer? _notifTimer;
  static const _transferNotifId = 99999;

  Future<void> init({
    required ConnectionService connections,
    required MessageStore store,
    required String myId,
    FlutterLocalNotificationsPlugin? notificationsPlugin,
  }) async {
    _connections = connections;
    _store = store;
    _myId = myId;
    if (!kIsWeb && Platform.isAndroid) {
      _notifPlugin = notificationsPlugin;
    }

    _receiver = FileReceiver();
    _receiver!.onFileStarted = _onReceiveStarted;
    _receiver!.onProgress = _onReceiveProgress;
    _receiver!.onFileComplete = _onReceiveComplete;
    _receiver!.onFileError = _onReceiveError;
    await _receiver!.startServer();
  }

  /// Called from main.dart when a file_notify arrives over the chat TCP.
  /// Pre-registers the expected incoming transfer so we can map fileId -> peerId.
  void registerIncoming(
      String peerId, String fileId, String fileName, int fileSize) {
    final pending = _PendingReceive(peerId, fileName, fileSize);
    final waiter = _waiters.remove(fileId);
    if (waiter != null) {
      waiter.completer.complete(pending);
    } else {
      _pending[fileId] = pending;
    }
  }

  /// Initiate sending a file to a peer. Creates the ChatMessage, stores it,
  /// sends file_notify, and runs the FileSender in the background.
  Future<void> sendFile({
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
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
    } finally {
      await _emitStoredFileMessageForPreview(t.peerId, t.fileId);
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
    t.error = 'Cancelled';
    t.cancelled = true;
    _notify();
  }

  void dismiss(String fileId) {
    final t = transfers.remove(fileId);
    _notify();
    if (t == null) return;
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
    });

    t.error = null;
    t.cancelled = false;
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
  Future<void> _onReceiveStarted(
      String fileId, String fileName, int fileSize) async {
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
    final peerId = t.peerId;
    t.error = error;
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
    final active = transfers.values.where((t) => t.error == null).toList();
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
