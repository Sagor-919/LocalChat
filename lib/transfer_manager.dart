import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'connection_service.dart';
import 'file_transfer_service.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'package:path/path.dart' as p;

import 'android_share_inbound.dart';
import 'app_settings.dart';
import 'attachment_prepare.dart';
import 'deferred_staged_file.dart';
import 'client_platform.dart';
import 'file_transfer_auth.dart';
import 'folder_send.dart';
import 'storage_usage.dart';

enum OutgoingTransferPhase { preparing, transferring }

class TransferState {
  final String fileId;
  final String peerId;
  String fileName;
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
  /// User tapped Pause — do not auto-resume on transient [TransferPausedException].
  bool userPaused = false;
  FileSender? sender;
  Process? prepProcess;
  final List<String> tempPathsForCleanup = [];
  OutgoingTransferPhase outgoingPhase;
  final Stopwatch stopwatch = Stopwatch()..start();
  /// Shown in chat while [outgoingPhase] is [OutgoingTransferPhase.preparing].
  String preparingStatus = '';
  /// AES-GCM file bytes on the file TCP socket (shown in chat as secure transfer).
  bool encrypted = false;

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
  final String? folderRoot;
  /// When set, bytes attach to an existing chat message (folder direct extras).
  final String? batchMessageId;
  /// Full folder size for the first file in a direct folder batch.
  final int? batchTotalSize;

  const _PendingReceive(
    this.peerId,
    this.fileName,
    this.fileSize, {
    this.folderRoot,
    this.batchMessageId,
    this.batchTotalSize,
  });
}

/// Manual accept UI when [AppSettings.autoAcceptIncomingFiles] is false.
typedef IncomingFileOfferDialog = Future<bool> Function({
  required String peerId,
  required String peerDisplayName,
  required String fileId,
  required String fileLabel,
  required int fileSizeBytes,
  bool folderBatch,
});

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
  static const _incomingOfferNotifId = 99998;
  static const _largeOfferNotifBytes = 5 * 1024 * 1024;

  int _outboundSendSlots = 0;

  /// Receiver-side partial path for resume (same [fileId]).
  final Map<String, String> _receivePathByFileId = {};

  /// Sub-file TCP id → batch chat message id (folder direct receive).
  final Map<String, String> _receiveBatchParent = {};
  final Map<String, int> _receiveBatchFileSize = {};
  final Map<String, int> _batchCompletedBytes = {};
  final Set<String> _folderBatchRootIds = {};

  final Map<String, Completer<bool>> _acceptWaiters = {};

  /// Expected TCP auth token per incoming [fileId] (from [registerIncoming]).
  final Map<String, String> _expectedTokenByFileId = {};
  final Map<String, String> _tokenPeerByFileId = {};

  IncomingFileOfferDialog? incomingFileOfferDialog;

  Future<void> init({
    required ConnectionService connections,
    required MessageStore store,
    required String myId,
    FlutterLocalNotificationsPlugin? notificationsPlugin,
  }) async {
    _connections = connections;
    _store = store;
    _myId = myId;
    assert(myId.isNotEmpty);
    if (!kIsWeb && Platform.isAndroid) {
      _notifPlugin = notificationsPlugin;
    }

    _receiver = FileReceiver();
    _receiver!.resumePathResolver = _resolveResumeReceivePath;
    _receiver!.validateTransferToken = _validateIncomingTransferToken;
    _receiver!.isIncomingRegistered = _isIncomingRegistered;
    _receiver!.localPeerId = _myId;
    _receiver!.onFileStarted = _onReceiveStarted;
    _receiver!.onProgress = _onReceiveProgress;
    _receiver!.onFileComplete = _onReceiveComplete;
    _receiver!.onFileError = _onReceiveError;
    _receiver!.onFilePaused = _onReceivePaused;
    await _receiver!.startServer();
  }

  void dispose() {
    _notifTimer?.cancel();
    _notifTimer = null;
    _receiver?.stop();
    if (!_transferUpdates.isClosed) _transferUpdates.close();
    if (!_fileMessages.isClosed) _fileMessages.close();
  }

  /// Called from main.dart when a file_notify arrives over the chat TCP.
  /// Pre-registers the expected incoming transfer so we can map fileId -> peerId.
  void registerIncoming(
    String peerId,
    String fileId,
    String fileName,
    int fileSize, {
    String? folderRoot,
    String? batchMessageId,
    int? batchTotalSize,
  }) {
    _tokenPeerByFileId[fileId] = peerId;
    _expectedTokenByFileId[fileId] =
        FileTransferAuth.token(_myId, peerId, fileId);
    final pending = _PendingReceive(
      peerId,
      fileName,
      fileSize,
      folderRoot: folderRoot,
      batchMessageId: batchMessageId,
      batchTotalSize: batchTotalSize,
    );
    final waiter = _waiters.remove(fileId);
    if (waiter != null) {
      waiter.completer.complete(pending);
    } else {
      _pending[fileId] = pending;
    }
  }

  void _clearIncomingToken(String fileId) {
    _expectedTokenByFileId.remove(fileId);
    _tokenPeerByFileId.remove(fileId);
  }

  Future<bool> _isIncomingRegistered(String fileId) async =>
      _tokenPeerByFileId.containsKey(fileId);

  Future<bool> _validateIncomingTransferToken(
    String fileId,
    String? token,
    String? senderPeerId,
  ) async {
    final peerId = _tokenPeerByFileId[fileId];
    if (peerId == null) return false;
    if (senderPeerId == null || senderPeerId.isEmpty) return false;
    if (senderPeerId != peerId) return false;
    return FileTransferAuth.verify(_myId, peerId, fileId, token);
  }

  String _outboundToken(String peerId, String fileId) =>
      FileTransferAuth.token(_myId, peerId, fileId);

  void onFileAccept(String peerId, String fileId) {
    _acceptWaiters.remove(_acceptKey(peerId, fileId))?.complete(true);
  }

  void onFileReject(String peerId, String fileId) {
    _acceptWaiters.remove(_acceptKey(peerId, fileId))?.complete(false);
  }

  static String _acceptKey(String peerId, String fileId) => '$peerId|$fileId';

  Future<void> onIncomingFileOffer(
    String peerId,
    Map<String, dynamic> json, {
    required String peerDisplayName,
  }) async {
    final fileId = json['id'] as String? ?? '';
    if (fileId.isEmpty) return;
    final name = json['name'] as String? ?? 'file';
    final size = (json['size'] as num?)?.toInt() ?? 0;
    final folderBatch = json['folderBatch'] == true;

    var accept = false;
    if (AppSettings.instance.autoAcceptIncomingFiles.value) {
      final pre = await preflightReceiveDestination(
        downloadPath: AppSettings.instance.downloadPath.value,
        requiredBytes: size,
      );
      accept = pre.ok;
      if (!accept) {
        _connections.sendJson(peerId, {
          'type': 'file_reject',
          'id': fileId,
          'reason': pre.reason ?? 'Cannot receive file',
        });
        return;
      }
    } else {
      if (size >= _largeOfferNotifBytes) {
        unawaited(_showIncomingOfferNotification(
          peerDisplayName: peerDisplayName,
          fileLabel: name,
          fileSizeBytes: size,
        ));
      }
      final dialog = incomingFileOfferDialog;
      if (dialog == null) {
        _connections.sendJson(peerId, {
          'type': 'file_reject',
          'id': fileId,
          'reason': 'Receiver cannot prompt for acceptance',
        });
        return;
      }
      accept = await dialog(
        peerId: peerId,
        peerDisplayName: peerDisplayName,
        fileId: fileId,
        fileLabel: name,
        fileSizeBytes: size,
        folderBatch: folderBatch,
      );
    }

    _connections.sendJson(peerId, {
      'type': accept ? 'file_accept' : 'file_reject',
      'id': fileId,
      if (!accept) 'reason': 'Declined',
    });
  }

  Future<bool> _sendOfferAndWait({
    required String peerId,
    required String fileId,
    required String name,
    required int size,
    bool folderBatch = false,
  }) async {
    final key = _acceptKey(peerId, fileId);
    final waiter = Completer<bool>();
    _acceptWaiters[key] = waiter;

    final sent = _connections.sendJson(peerId, {
      'type': 'file_offer',
      'id': fileId,
      'name': name,
      'size': size,
      if (folderBatch) 'folderBatch': true,
    });
    if (!sent) {
      _acceptWaiters.remove(key);
      return false;
    }

    try {
      return await waiter.future.timeout(
        const Duration(minutes: 30),
        onTimeout: () => false,
      );
    } finally {
      _acceptWaiters.remove(key);
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

  void _enforceMaxAttachmentSize(int bytes) {
    final maxBytes = AppSettings.instance.maxAttachmentSizeBytes;
    if (maxBytes != null && bytes > maxBytes) {
      throw StateError(
        'File exceeds maximum size (${AppSettings.instance.maxAttachmentSizeMb.value} MB)',
      );
    }
  }

  /// [initialMessage] must already be in [MessageStore]. Prepares file (copy / folder zip), then sends.
  Future<void> _acquireSendSlot() async {
    final max = AppSettings.instance.maxConcurrentSends.value;
    while (_outboundSendSlots >= max) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    _outboundSendSlots++;
  }

  void _releaseSendSlot() {
    if (_outboundSendSlots > 0) _outboundSendSlots--;
  }

  Future<void> prepareAndSendOutbound({
    required ChatMessage initialMessage,
    required String peerId,
    required String peerIp,
    String? peerDisplayName,
    required String sourcePath,
    String? androidContentUri,
    required StagedSourceKind kind,
    required bool duplicatePathInBatch,
    String? peerPlatform,
    bool? forceFolderAsZip,
  }) async {
    final id = initialMessage.id;
    final maxBytes = AppSettings.instance.maxAttachmentSizeBytes;
    final attachSize = initialMessage.attachmentSize ?? 0;
    if (maxBytes != null && attachSize > 0 && attachSize > maxBytes) {
      final t = TransferState(
        fileId: id,
        peerId: peerId,
        fileName: initialMessage.attachmentName!,
        totalBytes: attachSize,
        isSending: true,
        filePath: null,
        outgoingPhase: OutgoingTransferPhase.preparing,
      )..error =
          'File exceeds maximum size (${AppSettings.instance.maxAttachmentSizeMb.value} MB)';
      transfers[id] = t;
      _notify();
      return;
    }
    final hasContentUri =
        androidContentUri != null && androidContentUri.isNotEmpty;
    final preparing = kind == StagedSourceKind.folderToZip ||
        duplicatePathInBatch ||
        hasContentUri;
    final encryptOutbound =
        AppSettings.instance.encryptFileTransfers.value;
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
    )..encrypted = encryptOutbound;
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
      peerPlatform: peerPlatform,
      forceFolderAsZip: forceFolderAsZip,
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
    String? peerPlatform,
    bool? forceFolderAsZip,
  }) async {
    final t = transfers[initialMessage.id];
    if (t == null) return;

    try {
      late String sendPath;
      late int sendSize;

      if (kind == StagedSourceKind.folderToZip) {
        final useZip = forceFolderAsZip ??
            (AppSettings.instance.folderSendAsZip.value ||
                !peerReceivesFolderAsFiles(peerPlatform));
        if (!useZip) {
          await _runPrepareAndSendFolderDirect(
            initialMessage: initialMessage,
            peerId: peerId,
            peerIp: peerIp,
            sourcePath: sourcePath,
          );
          return;
        }

        t.outgoingPhase = OutgoingTransferPhase.preparing;
        t.totalBytes = 0;
        t.transferredBytes = 0;
        t.progress = 0;
        t.preparingStatus = 'Zipping folder in background…';
        _notify();

        final normalized = sourcePath.replaceAll(RegExp(r'[/\\]+$'), '');
        final folderName = p.basename(normalized);
        final estBytes = await estimateDirectoryByteSize(normalized);
        final tempRoot = Directory.systemTemp.path;
        final free = await freeBytesForPath(tempRoot);
        if (free != null && free < estBytes + kFolderZipHeadroomBytes) {
          throw AttachmentPrepareException(
            'Not enough free space to build ZIP (need about '
            '${formatStorageBytes(estBytes + kFolderZipHeadroomBytes)}, '
            'have about ${formatStorageBytes(free)} on temp drive)',
          );
        }

        final zipPath = p.join(
          tempRoot,
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
        _enforceMaxAttachmentSize(sendSize);
      } else {
        var workPath = sourcePath;
        final uri = androidContentUri;
        if (uri != null && uri.isNotEmpty) {
          t.outgoingPhase = OutgoingTransferPhase.preparing;
          t.totalBytes = 0;
          t.transferredBytes = 0;
          t.progress = 0;
          t.preparingStatus = 'Reading shared file…';
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
          t.preparingStatus = 'Copying for send…';
          t.stopwatch.reset();
          t.stopwatch.start();
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
        _enforceMaxAttachmentSize(sendSize);
      }

      if (t.cancelRequested) throw const AttachmentPrepareCancelled();

      // Temp prep paths (content URI, duplicate batch, zip) are deleted after send; DB must
      // reference a permanent copy so thumbnails and open keep working.
      var outboundPath = sendPath;
      if (t.tempPathsForCleanup.contains(sendPath)) {
        t.preparingStatus = 'Saving to device…';
        _notify();
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
        transferEncrypted: t.encrypted,
      );

      final updated = initialMessage.copyWith(
        attachmentPath: outboundPath,
        attachmentSize: sendSize,
        transferEncrypted: t.encrypted,
      );
      _fileMessages.add(FileMessageEvent(peerId, updated));

      t.filePath = outboundPath;
      t.totalBytes = sendSize;
      t.transferredBytes = 0;
      t.progress = 0;
      t.outgoingPhase = OutgoingTransferPhase.transferring;
      t.preparingStatus = '';
      t.stopwatch.reset();
      t.stopwatch.start();
      _notify();

      final accepted = await _sendOfferAndWait(
        peerId: peerId,
        fileId: initialMessage.id,
        name: t.fileName,
        size: sendSize,
      );
      if (!accepted) {
        t.error = 'Recipient declined or did not accept the file';
        _notify();
        return;
      }

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
      t2.preparingStatus = '';
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

  Future<void> _runPrepareAndSendFolderDirect({
    required ChatMessage initialMessage,
    required String peerId,
    required String peerIp,
    required String sourcePath,
  }) async {
    final t = transfers[initialMessage.id];
    if (t == null) return;

    try {
      final normalized = sourcePath.replaceAll(RegExp(r'[/\\]+$'), '');
      final folderName = p.basename(normalized);
      final entries = await listFolderEntries(normalized);
      if (entries.isEmpty) {
        throw AttachmentPrepareException('Folder is empty');
      }
      final total = totalFolderBytes(entries);
      final label = '$folderName (${entries.length} files)';

      t.outgoingPhase = OutgoingTransferPhase.preparing;
      t.preparingStatus = 'Preparing folder (${entries.length} files)…';
      t.totalBytes = total;
      t.transferredBytes = 0;
      t.progress = 0;
      _notify();

      await _store.updateOutboundAttachment(
        peerId,
        initialMessage.id,
        size: total,
        transferEncrypted: t.encrypted,
      );
      final updated = initialMessage.copyWith(
        attachmentName: label,
        attachmentSize: total,
        transferEncrypted: t.encrypted,
      );
      _fileMessages.add(FileMessageEvent(peerId, updated));
      t.fileName = label;

      if (t.cancelRequested) throw const AttachmentPrepareCancelled();

      final accepted = await _sendOfferAndWait(
        peerId: peerId,
        fileId: initialMessage.id,
        name: label,
        size: total,
        folderBatch: true,
      );
      if (!accepted) {
        t.error = 'Recipient declined or did not accept the folder';
        _notify();
        return;
      }

      t.outgoingPhase = OutgoingTransferPhase.transferring;
      t.preparingStatus = '';
      t.stopwatch.reset();
      t.stopwatch.start();
      _notify();

      final targetIp = _resolveFileTransferHost(peerId, peerIp);
      var batchSent = 0;

      for (var i = 0; i < entries.length; i++) {
        if (t.cancelRequested) throw const AttachmentPrepareCancelled();
        final e = entries[i];
        final subId = i == 0 ? initialMessage.id : '${initialMessage.id}_f$i';

        final notified = _connections.sendJson(peerId, {
          'type': 'file_notify',
          'id': subId,
          'name': i == 0 ? label : e.relativePath,
          'size': e.sizeBytes,
          'offset': 0,
          'folderRoot': folderName,
          if (i > 0) 'batchMessageId': initialMessage.id,
          if (i == 0) 'batchTotalSize': total,
        });
        if (!notified) {
          throw StateError('Lost connection while sending folder');
        }

        final subState = TransferState(
          fileId: subId,
          peerId: peerId,
          fileName: e.relativePath,
          totalBytes: e.sizeBytes,
          isSending: true,
          filePath: e.absolutePath,
        )..encrypted = t.encrypted;
        await _runSend(
          subState,
          targetIp,
          tcpFileName: e.relativePath,
          folderRoot: folderName,
          onChunkSent: (sent) {
            batchSent += sent;
            t.transferredBytes = batchSent.clamp(0, total);
            t.progress = total == 0 ? 0 : t.transferredBytes / total;
            _notify();
          },
        );
        if (subState.error != null) {
          throw StateError(subState.error!);
        }
      }

      transfers.remove(initialMessage.id);
      _notify();
    } catch (e) {
      final t2 = transfers[initialMessage.id];
      if (t2 == null) return;
      t2.preparingStatus = '';
      if (e is AttachmentPrepareCancelled || t2.cancelRequested) {
        t2.error = 'Cancelled';
        t2.cancelled = true;
      } else {
        t2.error = e.toString();
      }
      _notify();
      await _emitStoredFileMessageForPreview(peerId, initialMessage.id);
    } finally {
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

  Future<void> _runSend(
    TransferState t,
    String peerIp, {
    String? tcpFileName,
    String? folderRoot,
    void Function(int bytesDelta)? onChunkSent,
    int? previousSent,
  }) async {
    final sender = FileSender();
    t.sender = sender;
    final startOff = t.transferredBytes;
    var lastReported = previousSent ?? startOff;

    await _acquireSendSlot();
    try {
      final settings = AppSettings.instance;
      await sender.send(
        host: peerIp,
        fileId: t.fileId,
        fileName: tcpFileName ?? t.fileName,
        fileSize: t.totalBytes,
        file: File(t.filePath!),
        startOffset: startOff,
        folderRoot: folderRoot,
        token: _outboundToken(t.peerId, t.fileId),
        senderPeerId: _myId,
        encryptPeerId: t.peerId,
        encryptPayload: settings.encryptFileTransfers.value,
        throttleBytesPerSec: settings.transferThrottleBytesPerSec,
        appendChecksum: settings.fileTransferChecksum.value &&
            !settings.encryptFileTransfers.value,
        onProgress: (sent, total) {
          if (onChunkSent != null) {
            final delta = sent - lastReported;
            if (delta > 0) onChunkSent(delta);
            lastReported = sent;
          } else {
            t.transferredBytes = sent;
            t.progress = total == 0 ? 0 : sent / total;
            _notify();
          }
        },
      );
      t.isPaused = false;
      if (onChunkSent == null) {
        await _store.updateOutboundAttachment(
          t.peerId,
          t.fileId,
          transferEncrypted: t.encrypted,
        );
        _cleanupOutgoingTemps(t);
        transfers.remove(t.fileId);
        _notify();
      }
    } catch (e) {
      if (e is TransferPausedException) {
        t.isPaused = true;
        t.error = null;
        t.sender = null;
        _notify();
        if (!t.userPaused) {
          Future<void>.delayed(const Duration(milliseconds: 400), () {
            final t2 = transfers[t.fileId];
            if (t2 != null &&
                t2.isPaused &&
                !t2.userPaused &&
                t2.isSending &&
                t2.error == null &&
                !t2.cancelled) {
              resumeOutgoing(t.fileId);
            }
          });
        }
      } else {
        t.isPaused = false;
        t.error = e.toString();
        _notify();
      }
    } finally {
      _releaseSendSlot();
      if (onChunkSent == null) {
        await _emitStoredFileMessageForPreview(t.peerId, t.fileId);
      }
    }
  }

  Future<void> _showIncomingOfferNotification({
    required String peerDisplayName,
    required String fileLabel,
    required int fileSizeBytes,
  }) async {
    final plugin = _notifPlugin;
    if (plugin == null) return;
    final mb = (fileSizeBytes / (1024 * 1024)).toStringAsFixed(1);
    await plugin.show(
      _incomingOfferNotifId,
      'Incoming file from $peerDisplayName',
      '$fileLabel ($mb MB) — open app to accept or decline',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'incoming_offers',
          'Incoming file offers',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
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
    t.userPaused = false;
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
    t.userPaused = true;
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
    t.userPaused = true;
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

  /// Receiver is ready again — continue sending from [transferredBytes].
  void handleRemoteResumeOutgoing(String fileId) {
    resumeOutgoing(fileId);
  }

  /// Sender will send again — clear local receive pause gate.
  void handleRemoteResumeIncoming(String fileId) {
    _receiver?.resumeReceive(fileId);
    final t = transfers[fileId];
    if (t != null && !t.isSending) {
      t.isPaused = false;
      t.userPaused = false;
      _notify();
    }
  }

  /// Resume sending after [TransferPausedException] / pause.
  void resumeIncoming(String fileId) {
    final t = transfers[fileId];
    if (t == null || t.isSending || !t.isPaused || t.error != null) return;
    t.userPaused = false;
    t.isPaused = false;
    _connections.sendJson(t.peerId, {
      'type': 'file_control',
      'id': fileId,
      'pause': false,
      'from': 'receiver',
    });
    _notify();
  }

  void resumeOutgoing(String fileId) {
    final t = transfers[fileId];
    if (t == null || !t.isSending || !t.isPaused) return;
    if (t.filePath == null) return;
    final peerId = t.peerId;
    if (!_connections.isConnected(peerId)) return;
    final peerSocket = _connections.getSocket(peerId);
    if (peerSocket == null) return;

    t.userPaused = false;
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
      if (t.isPaused && t.transferredBytes > 0) {
        resumeIncoming(fileId);
        t.error = null;
        _notify();
        return;
      }
      transfers.remove(fileId);
      _notify();
      return;
    }

    if (t.filePath == null) return;

    final peerId = t.peerId;
    if (!_connections.isConnected(peerId)) return;

    final peerSocket = _connections.getSocket(peerId);
    if (peerSocket == null) return;

    t.error = null;
    t.cancelled = false;
    t.userPaused = false;

    if (t.transferredBytes > 0) {
      t.isPaused = true;
      resumeOutgoing(fileId);
      return;
    }

    _connections.sendJson(peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': t.fileName,
      'size': t.totalBytes,
      'offset': 0,
    });

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
    String finalPath,
    String writePath,
    int resumeOffset,
    bool encrypted,
  ) async {
    _receivePathByFileId[fileId] = writePath;

    if (resumeOffset > 0) {
      final existing = transfers[fileId];
      if (existing != null) {
        existing.isPaused = false;
        existing.error = null;
        existing.transferredBytes = resumeOffset;
        existing.progress =
            fileSize == 0 ? 0 : resumeOffset / fileSize;
        if (encrypted) existing.encrypted = true;
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
            .timeout(const Duration(milliseconds: 800));
      } catch (_) {
        _waiters.remove(fileId);
      }
    }
    if (pending == null) {
      await deletePartialDownloadFile(writePath);
      _clearIncomingToken(fileId);
      _receiver?.cancelReceive(fileId);
      return;
    }
    final peerId = pending.peerId;
    final batchId = pending.batchMessageId;

    if (batchId != null) {
      _receiveBatchParent[fileId] = batchId;
      _receiveBatchFileSize[fileId] = fileSize;
      if (encrypted) {
        final batch = transfers[batchId];
        if (batch != null) batch.encrypted = true;
      }
      _notify();
      return;
    }

    if (pending.batchTotalSize != null) {
      _folderBatchRootIds.add(fileId);
    }

    final msg = ChatMessage(
      id: fileId,
      senderId: peerId,
      text: 'File: $fileName',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: false,
      attachmentName: fileName,
      attachmentSize: pending.batchTotalSize ?? fileSize,
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

    final batchTotal = pending.batchTotalSize;
    transfers[fileId] = TransferState(
      fileId: fileId,
      peerId: peerId,
      fileName: fileName,
      totalBytes: batchTotal ?? fileSize,
      isSending: false,
    )..encrypted = encrypted;
    _notify();
  }

  Future<void> _finishFolderBatchReceive(
    TransferState batch,
    String lastSavedPath,
  ) async {
    final peerId = batch.peerId;
    final batchId = batch.fileId;
    _folderBatchRootIds.remove(batchId);
    transfers.remove(batchId);
    _batchCompletedBytes.remove(batchId);
    _clearIncomingToken(batchId);
    final folderPath = p.dirname(lastSavedPath);
    await _store.updateAttachmentPath(
      peerId,
      batchId,
      folderPath,
      transferEncrypted: batch.encrypted,
    );
    final updated = ChatMessage(
      id: batchId,
      senderId: peerId,
      text: 'File: ${batch.fileName}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: false,
      attachmentName: batch.fileName,
      attachmentPath: folderPath,
      attachmentSize: batch.totalBytes,
      transferEncrypted: batch.encrypted,
    );
    _fileMessages.add(FileMessageEvent(peerId, updated));
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
    if (_folderBatchRootIds.contains(fileId)) {
      final batch = transfers[fileId];
      if (batch != null) {
        final base = _batchCompletedBytes[fileId] ?? 0;
        batch.transferredBytes = base + received;
        batch.progress = batch.totalBytes == 0
            ? 0
            : batch.transferredBytes / batch.totalBytes;
      }
      _notify();
      return;
    }

    final batchId = _receiveBatchParent[fileId];
    if (batchId != null) {
      final batch = transfers[batchId];
      if (batch != null) {
        final base = _batchCompletedBytes[batchId] ?? 0;
        batch.transferredBytes = base + received;
        batch.progress = batch.totalBytes == 0
            ? 0
            : batch.transferredBytes / batch.totalBytes;
      }
      _notify();
      return;
    }

    final t = transfers[fileId];
    if (t == null) return;
    t.transferredBytes = received;
    t.progress = total == 0 ? 0 : received / total;
    _notify();
  }

  Future<void> _onReceiveComplete(String fileId, String savedPath) async {
    if (_folderBatchRootIds.contains(fileId)) {
      final added = _receiveBatchFileSize.remove(fileId) ??
          transfers[fileId]?.totalBytes ??
          0;
      _batchCompletedBytes[fileId] = added;
      final batch = transfers[fileId];
      if (batch != null) {
        batch.transferredBytes = added;
        batch.progress = batch.totalBytes == 0
            ? 0
            : added / batch.totalBytes;
      }
      _receivePathByFileId.remove(fileId);
      _clearIncomingToken(fileId);
      if (batch != null && added >= batch.totalBytes) {
        await _finishFolderBatchReceive(batch, savedPath);
      }
      _notify();
      return;
    }

    final batchId = _receiveBatchParent.remove(fileId);
    if (batchId != null) {
      final added = _receiveBatchFileSize.remove(fileId) ?? 0;
      final done = (_batchCompletedBytes[batchId] ?? 0) + added;
      _batchCompletedBytes[batchId] = done;
      final batch = transfers[batchId];
      if (batch != null) {
        batch.transferredBytes = done;
        batch.progress = batch.totalBytes == 0
            ? 0
            : done / batch.totalBytes;
        if (done >= batch.totalBytes) {
          _receivePathByFileId.remove(fileId);
          _clearIncomingToken(fileId);
          await _finishFolderBatchReceive(batch, savedPath);
        }
      }
      _notify();
      return;
    }

    final t = transfers[fileId];
    if (t == null) return;
    final peerId = t.peerId;
    _receivePathByFileId.remove(fileId);
    _clearIncomingToken(fileId);

    transfers.remove(fileId);
    _notify();

    await _store.updateAttachmentPath(
      peerId,
      fileId,
      savedPath,
      transferEncrypted: t.encrypted,
    );

    final updated = ChatMessage(
      id: fileId,
      senderId: peerId,
      text: 'File: ${t.fileName}',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: false,
      attachmentName: t.fileName,
      attachmentPath: savedPath,
      attachmentSize: t.totalBytes,
      transferEncrypted: t.encrypted,
    );
    _fileMessages.add(FileMessageEvent(peerId, updated));
  }

  void _onReceiveError(String fileId, String error, String? savePath) {
    _clearIncomingToken(fileId);
    final t = transfers[fileId];
    if (t == null) {
      _notify();
      return;
    }
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
    _syncAndroidTransferWakelock();
  }

  void _syncAndroidTransferWakelock() {
    if (kIsWeb || !Platform.isAndroid) return;
    final busy = transfers.values.any(
      (t) =>
          t.error == null &&
          !t.cancelled &&
          (!t.isPaused ||
              t.outgoingPhase == OutgoingTransferPhase.preparing),
    );
    if (busy) {
      unawaited(WakelockPlus.enable());
    } else {
      unawaited(WakelockPlus.disable());
    }
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
