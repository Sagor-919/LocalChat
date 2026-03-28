import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'app_settings.dart';
import 'connection_service.dart';
import 'file_transfer_crypto.dart';
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

  /// Secure mode (ECDH + AES-GCM); matches [file_notify] / TCP header.
  final bool encrypted;

  /// Populated after X25519 handshake.
  Uint8List? fileSessionKey;

  /// Bytes are on the wire; waiting for [file_transfer_result] from receiver (chat TCP).
  bool awaitingRemoteAck = false;

  TransferState({
    required this.fileId,
    required this.peerId,
    required this.fileName,
    required this.totalBytes,
    required this.isSending,
    this.filePath,
    this.encrypted = false,
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
  final bool encrypted;
  const _PendingReceive(
    this.peerId,
    this.fileName,
    this.fileSize, {
    this.encrypted = false,
  });
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

  /// Limits UI rebuilds during large transfers (Android jank).
  DateTime? _lastTransferProgressNotify;

  void _resetProgressThrottle() {
    _lastTransferProgressNotify = null;
  }

  void _notifyTransferProgress(TransferState t) {
    final now = DateTime.now();
    final done = t.totalBytes > 0 && t.transferredBytes >= t.totalBytes;
    // Receiving redraws the chat progress bar; coalesce more aggressively than
    // outgoing sends (per-bubble updates still benefit from lower frequency).
    final minGap = t.isSending
        ? const Duration(milliseconds: 300)
        : const Duration(milliseconds: 800);
    if (done) {
      _lastTransferProgressNotify = now;
      _notify();
      return;
    }
    if (_lastTransferProgressNotify == null ||
        now.difference(_lastTransferProgressNotify!) >= minGap) {
      _lastTransferProgressNotify = now;
      _notify();
    }
  }

  Stream<void> get transferUpdates => _transferUpdates.stream;
  Stream<FileMessageEvent> get fileMessages => _fileMessages.stream;

  late ConnectionService _connections;
  late MessageStore _store;
  late String _myId;
  FileReceiver? _receiver;
  FlutterLocalNotificationsPlugin? _notifPlugin;
  Timer? _notifTimer;
  static const _transferNotifId = 99999;

  /// Outgoing secure handshake: wait for peer ephemeral pub (chat TCP).
  final Map<String, Completer<Uint8List>> _senderPeerPubCompleters = {};

  /// Sender keeps X25519 key pair until handshake completes.
  final Map<String, SimpleKeyPair> _senderHandshakeKeyPairs = {};

  /// Receiver: AES-256 key material per [fileId] after ECDH (until transfer ends).
  final Map<String, Uint8List> _receiveFileSessionKeys = {};

  /// Completes when [fileId]'s session key is ready (event-driven; no polling).
  final Map<String, Completer<Uint8List>> _receiveKeyWaiters = {};

  /// Sender: assume success if [file_transfer_result] never arrives (chat lossy).
  final Map<String, Timer> _remoteAckTimers = {};

  void Function(String peerId, String fileId, String error)? _onRemoteTransferFailed;

  Future<void> init({
    required ConnectionService connections,
    required MessageStore store,
    required String myId,
    FlutterLocalNotificationsPlugin? notificationsPlugin,
    void Function(String peerId, String fileId, String error)? onRemoteTransferFailed,
  }) async {
    _connections = connections;
    _store = store;
    _myId = myId;
    if (!kIsWeb && Platform.isAndroid) {
      _notifPlugin = notificationsPlugin;
    }
    _onRemoteTransferFailed = onRemoteTransferFailed;

    _receiver = FileReceiver();
    _receiver!.onFileStarted = _onReceiveStarted;
    _receiver!.onProgress = _onReceiveProgress;
    _receiver!.onFileComplete = _onReceiveComplete;
    _receiver!.onFileError = _onReceiveError;
    _receiver!.resolveFileSessionKey = _resolveReceiveFileSessionKey;
    await _receiver!.startServer();
  }

  /// Peer's ephemeral X25519 public key (chat TCP); completes sender handshake.
  void handleFileTransferKey(String peerId, Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final b64 = json['eph_pub_b64'] as String?;
    if (id == null || id.isEmpty || b64 == null || b64.isEmpty) return;
    try {
      final bytes = base64Decode(b64);
      final c = _senderPeerPubCompleters[id];
      if (c != null && !c.isCompleted) {
        c.complete(Uint8List.fromList(bytes));
      }
    } catch (_) {}
  }

  /// Receiver reports success/failure over chat TCP so the sender can show errors
  /// (e.g. checksum mismatch) after the file socket has already closed.
  void handleFileTransferResult(String peerId, Map<String, dynamic> json) {
    final id = json['id'] as String?;
    if (id == null || id.isEmpty) return;
    final ok = json['ok'] == true;
    final errRaw = json['error'];
    final err = errRaw is String && errRaw.trim().isNotEmpty
        ? errRaw.trim()
        : null;

    final t = transfers[id];
    if (t != null && t.peerId != peerId) {
      return;
    }

    if (ok) {
      if (t == null || !t.isSending) return;
      _cancelRemoteAckTimer(id);
      _cleanupSecureHandshake(id);
      transfers.remove(id);
      _notify();
      unawaited(_emitStoredFileMessageForPreview(peerId, id));
      return;
    }

    final message = err ?? 'Receiver rejected the file';
    if (t != null && t.isSending) {
      _cancelRemoteAckTimer(id);
      t.sender?.cancel();
      t.sender = null;
      t.awaitingRemoteAck = false;
      t.error = message;
      _notify();
      unawaited(_emitStoredFileMessageForPreview(peerId, id));
      return;
    }

    _onRemoteTransferFailed?.call(peerId, id, message);
  }

  void _sendFileTransferResultToPeer(
    String peerId,
    String fileId, {
    required bool ok,
    String? error,
  }) {
    final payload = <String, dynamic>{
      'type': 'file_transfer_result',
      'id': fileId,
      'ok': ok,
    };
    if (error != null && error.isNotEmpty) {
      payload['error'] = error;
    }
    _connections.sendJson(peerId, payload);
  }

  void _cancelRemoteAckTimer(String fileId) {
    _remoteAckTimers.remove(fileId)?.cancel();
  }

  void _scheduleRemoteAckTimer(String fileId) {
    _cancelRemoteAckTimer(fileId);
    _remoteAckTimers[fileId] = Timer(const Duration(seconds: 15), () {
      _remoteAckTimers.remove(fileId);
      final t = transfers[fileId];
      if (t == null || !t.isSending || !t.awaitingRemoteAck) return;
      _cleanupSecureHandshake(fileId);
      transfers.remove(fileId);
      _notify();
      unawaited(_emitStoredFileMessageForPreview(t.peerId, fileId));
    });
  }

  void _cleanupSecureHandshake(String fileId) {
    _senderPeerPubCompleters.remove(fileId);
    _senderHandshakeKeyPairs.remove(fileId);
  }

  void _completeReceiveKeyWaiter(String fileId) {
    final k = _receiveFileSessionKeys[fileId];
    if (k == null || k.length != 32) return;
    final c = _receiveKeyWaiters.remove(fileId);
    if (c != null && !c.isCompleted) c.complete(k);
  }

  Future<Uint8List?> _resolveReceiveFileSessionKey(String fileId) async {
    final k = _receiveFileSessionKeys[fileId];
    if (k != null && k.length == 32) return k;
    final c = _receiveKeyWaiters.putIfAbsent(fileId, () => Completer<Uint8List>());
    try {
      return await c.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _receiveKeyWaiters.remove(fileId);
      final k2 = _receiveFileSessionKeys[fileId];
      return (k2 != null && k2.length == 32) ? k2 : null;
    }
  }

  /// Called from main.dart when a file_notify arrives over the chat TCP.
  /// Pre-registers the expected incoming transfer so we can map fileId -> peerId.
  Future<void> registerIncoming(
    String peerId,
    String fileId,
    String fileName,
    int fileSize, {
    bool encrypted = false,
    String? senderEphPubB64,
  }) async {
    if (encrypted &&
        senderEphPubB64 != null &&
        senderEphPubB64.isNotEmpty) {
      try {
        final senderPubBytes = base64Decode(senderEphPubB64);
        final kp = await X25519().newKeyPair();
        final pub = await kp.extractPublicKey();
        final sessionKey = await deriveFileSessionKeyFromEcdh(
          localKeyPair: kp,
          remotePublicKeyBytes: senderPubBytes,
        );
        _receiveFileSessionKeys[fileId] = sessionKey;
        _completeReceiveKeyWaiter(fileId);
        final ok = _connections.sendJson(peerId, {
          'type': 'file_transfer_key',
          'id': fileId,
          'eph_pub_b64': base64Encode(pub.bytes),
        });
        if (!ok) {
          _receiveFileSessionKeys.remove(fileId);
        }
      } catch (e) {
        _receiveFileSessionKeys.remove(fileId);
      }
    }

    final pending = _PendingReceive(
      peerId,
      fileName,
      fileSize,
      encrypted: encrypted,
    );
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
    final secure = AppSettings.instance.secureFileTransfer.value;

    final msg = ChatMessage(
      id: fileId,
      senderId: _myId,
      text: 'File: $fileName',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: true,
      attachmentName: fileName,
      attachmentPath: filePath,
      attachmentSize: fileSize,
      attachmentEncrypted: secure,
    );

    await _store.add(
      peerId,
      msg,
      peerDisplayName: peerDisplayName,
      peerIp: peerIp,
      peerTcpPort: ConnectionService.tcpPort,
    );
    _fileMessages.add(FileMessageEvent(peerId, msg));

    final t = TransferState(
      fileId: fileId,
      peerId: peerId,
      fileName: fileName,
      totalBytes: fileSize,
      isSending: true,
      filePath: filePath,
      encrypted: secure,
    );
    transfers[fileId] = t;
    _resetProgressThrottle();

    final targetIp = _resolveFileTransferHost(peerId, peerIp);

    if (secure) {
      unawaited(_startSecureHandshakeSend(t, targetIp, fileName));
      return;
    }

    final notified = _connections.sendJson(peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': fileName,
      'size': fileSize,
      'offset': 0,
    });

    if (!notified) {
      t.error =
          'Not connected — wait for peer or pull down to refresh peers, then retry.';
      _notify();
      return;
    }
    _notify();

    unawaited(_runSend(t, targetIp));
  }

  Future<void> _startSecureHandshakeSend(
    TransferState t,
    String peerIp,
    String fileName,
  ) async {
    final peerId = t.peerId;
    final fileId = t.fileId;
    try {
      final kp = await X25519().newKeyPair();
      final pub = await kp.extractPublicKey();
      _senderHandshakeKeyPairs[fileId] = kp;
      final c = Completer<Uint8List>();
      _senderPeerPubCompleters[fileId] = c;

      final notified = _connections.sendJson(peerId, {
        'type': 'file_notify',
        'id': fileId,
        'name': fileName,
        'size': t.totalBytes,
        'offset': 0,
        'encrypted': true,
        'eph_pub_b64': base64Encode(pub.bytes),
      });

      if (!notified) {
        _cleanupSecureHandshake(fileId);
        t.error =
            'Not connected — wait for peer or pull down to refresh peers, then retry.';
        _notify();
        await _emitStoredFileMessageForPreview(peerId, fileId);
        return;
      }
      _notify();

      final peerPub = await c.future.timeout(const Duration(seconds: 30));
      final key = await deriveFileSessionKeyFromEcdh(
        localKeyPair: kp,
        remotePublicKeyBytes: peerPub,
      );
      t.fileSessionKey = key;
      _cleanupSecureHandshake(fileId);
      await _runSend(t, peerIp, keyMaterial: key);
    } catch (e, _) {
      _cleanupSecureHandshake(fileId);
      t.error = 'Secure handshake failed: $e';
      _notify();
      await _emitStoredFileMessageForPreview(peerId, fileId);
    }
  }

  /// Prefer the address from the live chat TCP socket.
  String _resolveFileTransferHost(String peerId, String discoveryIp) {
    final sock = _connections.getSocket(peerId);
    if (sock != null) {
      final addr = sock.remoteAddress.address;
      if (addr.isNotEmpty) return addr;
    }
    return discoveryIp.trim();
  }

  Future<void> _emitStoredFileMessageForPreview(
    String peerId,
    String fileId,
  ) async {
    final list = await _store.load(peerId);
    for (final m in list) {
      if (m.id == fileId) {
        _fileMessages.add(FileMessageEvent(peerId, m));
        break;
      }
    }
  }

  Future<void> _runSend(
    TransferState t,
    String peerIp, {
    Uint8List? keyMaterial,
  }) async {
    final sender = FileSender();
    t.sender = sender;
    final enc = keyMaterial != null;

    try {
      await sender.send(
        host: peerIp,
        fileId: t.fileId,
        fileName: t.fileName,
        fileSize: t.totalBytes,
        file: File(t.filePath!),
        encrypted: enc,
        fileKeyMaterial: keyMaterial,
        onProgress: (sent, total) {
          t.transferredBytes = sent;
          t.progress = total == 0 ? 0 : sent / total;
          _notifyTransferProgress(t);
        },
      );
      t.sender = null;
      t.awaitingRemoteAck = true;
      t.progress = 1.0;
      t.transferredBytes = t.totalBytes;
      _scheduleRemoteAckTimer(t.fileId);
      _notify();
    } catch (e, _) {
      t.error = e.toString();
      _notify();
    } finally {
      await _emitStoredFileMessageForPreview(t.peerId, t.fileId);
    }
  }

  void cancel(String fileId) {
    final t = transfers[fileId];
    if (t == null) return;
    _cancelRemoteAckTimer(fileId);
    _cleanupSecureHandshake(fileId);
    if (t.isSending) {
      t.sender?.cancel();
    } else {
      _receiver?.cancelReceive(fileId);
    }
    _receiveFileSessionKeys.remove(fileId);
    t.awaitingRemoteAck = false;
    t.error = 'Cancelled';
    t.cancelled = true;
    _notify();
  }

  void dismiss(String fileId) {
    _cancelRemoteAckTimer(fileId);
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

  // ---------------------------------------------------------------------------
  // FileReceiver callbacks
  // ---------------------------------------------------------------------------
  Future<void> _onReceiveStarted(
    String fileId,
    String fileName,
    int fileSize,
    String savePath,
  ) async {
    var pending = _pending.remove(fileId);
    if (pending == null) {
      final waiter = _PendingWaiter();
      _waiters[fileId] = waiter;
      try {
        pending = await waiter.completer.future.timeout(
          const Duration(seconds: 15),
        );
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
      attachmentEncrypted: pending?.encrypted ?? false,
    );

    final sockIp = _connections.getSocket(peerId)?.remoteAddress.address ?? '';
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
      encrypted: pending?.encrypted ?? false,
    );
    _resetProgressThrottle();
    _notify();
  }

  void _onReceiveProgress(String fileId, int received, int total) {
    final t = transfers[fileId];
    if (t == null) return;
    t.transferredBytes = received;
    t.progress = total == 0 ? 0 : received / total;
    _notifyTransferProgress(t);
  }

  void _onReceiveComplete(String fileId, String savedPath) {
    final t = transfers[fileId];
    if (t == null) return;
    final peerId = t.peerId;
    _sendFileTransferResultToPeer(peerId, fileId, ok: true);

    transfers.remove(fileId);
    _receiveFileSessionKeys.remove(fileId);
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
      attachmentEncrypted: t.encrypted,
    );
    _fileMessages.add(FileMessageEvent(peerId, updated));
  }

  void _onReceiveError(String fileId, String error, String? savePath) {
    var t = transfers[fileId];
    if (t == null) {
      final pending = _pending.remove(fileId);
      if (pending == null) {
        _receiveFileSessionKeys.remove(fileId);
        return;
      }
      final created = TransferState(
        fileId: fileId,
        peerId: pending.peerId,
        fileName: pending.fileName,
        totalBytes: pending.fileSize,
        isSending: false,
        encrypted: pending.encrypted,
      )..error = error;
      transfers[fileId] = created;
      t = created;
    } else {
      t.error = error;
    }
    final peerId = t.peerId;
    _sendFileTransferResultToPeer(peerId, fileId, ok: false, error: error);
    _receiveFileSessionKeys.remove(fileId);
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
    _notifTimer = Timer(
      const Duration(milliseconds: 1500),
      _updateTransferNotification,
    );
  }

  Future<void> _updateTransferNotification() async {
    if (_notifPlugin == null) return;
    final active = transfers.values
        .where((t) => t.error == null && !t.awaitingRemoteAck)
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
          'transfers',
          'File Transfers',
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
