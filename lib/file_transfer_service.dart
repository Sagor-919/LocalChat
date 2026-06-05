import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;
import 'package:synchronized/synchronized.dart';

import 'app_settings.dart';
import 'file_transfer_crypto.dart';
import 'folder_send.dart';

const int kFileTransferPort = 4042;
const int kChunkSize = 65536; // 64 KB
// Max on-wire encrypted chunk: plaintext + GCM nonce(12) + tag(16) + slack.
const int kMaxEncChunkLen = kChunkSize + 12 + 16 + 64;

/// In-progress downloads use this suffix until the file is complete.
String partialDownloadWritePath(String finalPath) => '$finalPath.part';

/// Maps a `.part` write path back to the intended final file path.
String finalPathFromPartialWritePath(String writePath) {
  const suffix = '.part';
  if (writePath.endsWith(suffix)) {
    return writePath.substring(0, writePath.length - suffix.length);
  }
  return writePath;
}

Future<Socket> connectFileClient(String host, int port) async {
  final trimmed = host.trim();
  if (trimmed.isEmpty) {
    throw const SocketException('Empty host for file transfer');
  }
  final addr = InternetAddress.tryParse(trimmed);
  if (addr != null) {
    return Socket.connect(addr, port,
        timeout: const Duration(seconds: 12));
  }
  return Socket.connect(trimmed, port, timeout: const Duration(seconds: 12));
}

/// Best-effort delete of a partial download after failure or user cancel.
Future<void> deletePartialDownloadFile(String? path) async {
  if (path == null || path.isEmpty) return;
  try {
    final f = File(path);
    if (await f.exists()) await f.delete();
  } catch (_) {}
}

bool _looksLikeFileAccessDenied(Object error) {
  if (error is PathAccessException) return true;
  if (error is FileSystemException) {
    final ln =
        '${error.message} ${error.osError?.message ?? ''}'.toLowerCase();
    if (ln.contains('permission denied')) return true;
    if (ln.contains('access is denied')) return true;
    final c = error.osError?.errorCode;
    if (c == 13 || c == 1) return true; // EACCES / EPERM (incl. Android)
    if (c == 5 && Platform.isWindows) return true; // ERROR_ACCESS_DENIED
  }
  final s = error.toString().toLowerCase();
  return s.contains('permission denied') ||
      s.contains('errno = 13');
}

/// Turns raw [FileSystemException]s into a short hint (esp. Android scoped storage).
String humanizeFileReceiverError(Object error) {
  if (!_looksLikeFileAccessDenied(error)) {
    return error.toString();
  }
  if (Platform.isAndroid) {
    return 'Cannot write to your download folder — Android blocked access. '
        'Open this app’s Settings → Download Location → Change; allow “All files access” '
        'if the system asks, pick the folder again, then ask the sender to resend.';
  }
  if (Platform.isWindows) {
    return 'Cannot write to the download folder (access denied). '
        'Choose another folder under Settings → Download Location, then retry.';
  }
  return 'Cannot write to the download folder (permission denied). '
      'Change Download location in Settings, then retry.';
}

// ---------------------------------------------------------------------------
// Sender — opens a new TCP socket, sends header, waits for START, streams file
// ---------------------------------------------------------------------------
class FileSender {
  bool _cancelled = false;
  bool _pauseRequested = false;
  Socket? _socket;
  int bytesSent = 0;

  void cancel() => _cancelled = true;

  /// Stops the transfer without deleting partial state on the receiver (paired with chat `file_control`).
  void pause() {
    _pauseRequested = true;
    try {
      _socket?.destroy();
    } catch (_) {}
  }

  Future<void> send({
    required String host,
    required String fileId,
    required String fileName,
    required int fileSize,
    required File file,
    required void Function(int sent, int total) onProgress,
    int startOffset = 0,
    String? folderRoot,
    required String token,
    required String senderPeerId,
    String? encryptPeerId,
    bool encryptPayload = false,
    int? throttleBytesPerSec,
    bool appendChecksum = false,
  }) async {
    if (startOffset < 0 || startOffset > fileSize) {
      throw ArgumentError('Invalid startOffset');
    }
    final socket = await connectFileClient(host, kFileTransferPort);
    _socket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);

    try {
      final header = <String, dynamic>{
        'id': fileId,
        'name': fileName,
        'size': fileSize,
        'offset': startOffset,
        'token': token,
        'senderPeerId': senderPeerId,
      };
      if (folderRoot != null && folderRoot.isNotEmpty) {
        header['folderRoot'] = folderRoot;
      }
      if (encryptPayload) {
        header['encrypted'] = true;
      }
      if (appendChecksum && !encryptPayload) {
        header['checksum'] = true;
      }
      socket.write('${jsonEncode(header)}\n');
      await socket.flush();

      await _waitForStart(socket);

      SecretKey? encKey;
      if (encryptPayload && encryptPeerId != null) {
        encKey = await FileTransferCrypto.secretKey(
          senderPeerId,
          encryptPeerId,
          fileId,
        );
      }
      var encSeq = 0;

      final raf = await file.open();
      try {
        if (startOffset > 0) {
          await raf.setPosition(startOffset);
        }
        bytesSent = 0;
        while (startOffset + bytesSent < fileSize) {
          if (_cancelled) throw const _CancelledException();
          if (_pauseRequested) throw const TransferPausedException();

          final remaining = fileSize - startOffset - bytesSent;
          final toRead = remaining < kChunkSize ? remaining : kChunkSize;
          final buf = await raf.read(toRead);
          if (buf.isEmpty) break;

          if (encKey != null) {
            final enc = await FileTransferCrypto.encryptChunk(
              encKey,
              encSeq++,
              buf,
            );
            socket.add(FileTransferCrypto.lengthPrefix(enc));
          } else {
            socket.add(buf);
          }
          await socket.flush();
          bytesSent += buf.length;
          onProgress(startOffset + bytesSent, fileSize);
          if (throttleBytesPerSec != null && throttleBytesPerSec > 0) {
            final us = buf.length * 1000000 ~/ throttleBytesPerSec;
            if (us > 0) {
              await Future<void>.delayed(Duration(microseconds: us));
            }
          }
        }
      } finally {
        await raf.close();
      }

      if (appendChecksum && encKey == null) {
        final digest = await sha256.bind(file.openRead()).first;
        socket.write('\nCHECKSUM:${digest.toString()}\n');
        await socket.flush();
      }

      await socket.close();
    } catch (e) {
      try {
        await socket.close();
      } catch (_) {}
      if (_cancelled) rethrow;
      if (_pauseRequested) {
        throw const TransferPausedException();
      }
      rethrow;
    } finally {
      _socket = null;
    }
  }

  Future<void> _waitForStart(Socket socket) async {
    final c = Completer<void>();
    final buf = StringBuffer();
    late StreamSubscription<List<int>> sub;

    sub = socket.listen(
      (data) {
        if (c.isCompleted) return;
        buf.write(utf8.decode(data, allowMalformed: true));
        final bufStr = buf.toString();
        if (bufStr.contains('START')) c.complete();
      },
      onError: (Object e) {
        if (!c.isCompleted) c.completeError(e);
      },
      onDone: () {
        if (!c.isCompleted) {
          c.completeError(const SocketException('Closed before START'));
        }
      },
      cancelOnError: true,
    );

    final timer = Timer(const Duration(seconds: 8), () {
      if (!c.isCompleted) {
        c.completeError(TimeoutException('Timed out waiting for START'));
      }
    });

    try {
      await c.future;
    } finally {
      timer.cancel();
      try {
        await sub.cancel();
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
// Receiver — TCP server accepts socket, reads header, sends START, writes file
// Concurrent-safe: each _receiveFile call uses local state only.
// ---------------------------------------------------------------------------
class FileReceiver {
  ServerSocket? _server;
  final Set<String> _cancelledIds = {};
  final Set<String> _pausedIds = {};
  final Map<String, Socket> _socketsByFileId = {};
  final Lock _transferIdsLock = Lock();

  /// When [offset] > 0, resolve path to existing partial file (same [fileId]).
  Future<String?> Function(String fileId, int offset, String safeName)?
      resumePathResolver;

  /// When set, incoming TCP must present a matching [token] and [senderPeerId].
  Future<bool> Function(
    String fileId,
    String? token,
    String? senderPeerId,
  )? validateTransferToken;

  /// When set, [fileId] must have a pending [file_notify] registration.
  Future<bool> Function(String fileId)? isIncomingRegistered;

  /// Local user id for decrypting encrypted file payloads.
  String? localPeerId;

  Future<void> Function(
    String fileId,
    String fileName,
    int fileSize,
    String finalPath,
    String writePath,
    int resumeOffset,
    bool encrypted,
  )? onFileStarted;
  void Function(String fileId, int received, int total)? onProgress;
  void Function(String fileId, String savedPath)? onFileComplete;
  void Function(String fileId, String error, String? savePath)? onFileError;
  void Function(String fileId, String savePath, int bytesReceived)? onFilePaused;

  void cancelReceive(String fileId) {
    unawaited(_transferIdsLock.synchronized(() async {
      _cancelledIds.add(fileId);
      _destroySocketFor(fileId);
    }));
  }

  void pauseReceive(String fileId) {
    unawaited(_transferIdsLock.synchronized(() async {
      _pausedIds.add(fileId);
      _destroySocketFor(fileId);
    }));
  }

  void resumeReceive(String fileId) {
    unawaited(_transferIdsLock.synchronized(() async {
      _pausedIds.remove(fileId);
    }));
  }

  void _destroySocketFor(String fileId) {
    try {
      _socketsByFileId[fileId]?.destroy();
    } catch (_) {}
  }

  Future<void> startServer() async {
    _server =
        await ServerSocket.bind(InternetAddress.anyIPv4, kFileTransferPort);
    _server!.listen(_handleSocket);
  }

  void _handleSocket(Socket socket) {
    _receiveFile(socket);
  }

  Future<void> _receiveFile(Socket socket) async {
    final headerLineBuf = <int>[];
    final headerCompleter = Completer<Map<String, dynamic>>();
    final done = Completer<void>();

    bool headerDone = false;
    bool setupDone = false;
    Uint8List? pendingAfterHeader;
    RandomAccessFile? raf;
    int totalBytes = 0;
    int fileWritten = 0;
    int resumeOffset = 0;
    String fileId = '';
    var writePath = '';
    var finalPath = '';
    var encrypted = false;
    var expectChecksum = false;
    SecretKey? decKey;
    final encBuffer = <int>[];
    var decSeq = 0;
    Digest? payloadDigest;
    final digestSink = _DigestCaptureSink((d) => payloadDigest = d);
    final payloadHasher = sha256.startChunkedConversion(digestSink);

    late StreamSubscription<List<int>> sub;

    Future<void> writePlain(Uint8List plain) async {
      if (raf == null) return;
      var offset = 0;
      while (offset < plain.length) {
        final (isCancelled, isPaused) = await _transferIdsLock.synchronized(
          () => (
            _cancelledIds.contains(fileId),
            _pausedIds.contains(fileId),
          ),
        );
        if (isCancelled) {
          if (!done.isCompleted) {
            done.completeError(const _CancelledException());
          }
          return;
        }
        if (isPaused) {
          if (!done.isCompleted) {
            done.completeError(const TransferPausedException());
          }
          return;
        }
        if (fileWritten < totalBytes) {
          final take = min(plain.length - offset, totalBytes - fileWritten);
          final slice = plain.sublist(offset, offset + take);
          payloadHasher.add(slice);
          await raf.writeFrom(slice);
          fileWritten += take;
          offset += take;
          onProgress?.call(fileId, fileWritten, totalBytes);
        } else {
          offset = plain.length;
        }
      }
    }

    Future<void> processEncryptedPayload(Uint8List data) async {
      encBuffer.addAll(data);
      while (encBuffer.length >= 4) {
        final len = ByteData.sublistView(
          Uint8List.fromList(encBuffer.sublist(0, 4)),
        ).getUint32(0);
        if (len > kMaxEncChunkLen) {
          // Length prefix is attacker/corruption controlled; refuse to buffer
          // an absurd amount of memory and abort the transfer.
          if (!done.isCompleted) {
            done.completeError(
              StateError('Encrypted chunk length $len exceeds maximum'),
            );
          }
          return;
        }
        if (encBuffer.length < 4 + len) break;
        final cipher = Uint8List.fromList(encBuffer.sublist(4, 4 + len));
        encBuffer.removeRange(0, 4 + len);
        if (decKey == null) {
          if (!done.isCompleted) {
            done.completeError(
              StateError('Encrypted transfer missing decryption key'),
            );
          }
          return;
        }
        final plain =
            await FileTransferCrypto.decryptChunk(decKey, decSeq++, cipher);
        await writePlain(plain);
      }
    }

    Future<void> processFilePayload(Uint8List data) async {
      if (!setupDone || raf == null) return;
      if (encrypted) {
        await processEncryptedPayload(data);
        return;
      }

      var offset = 0;
      while (offset < data.length) {
        final (isCancelled, isPaused) = await _transferIdsLock.synchronized(
          () => (
            _cancelledIds.contains(fileId),
            _pausedIds.contains(fileId),
          ),
        );
        if (isCancelled) {
          if (!done.isCompleted) {
            done.completeError(const _CancelledException());
          }
          return;
        }
        if (isPaused) {
          if (!done.isCompleted) {
            done.completeError(const TransferPausedException());
          }
          return;
        }

        if (fileWritten < totalBytes) {
          final take = min(data.length - offset, totalBytes - fileWritten);
          final slice = data.sublist(offset, offset + take);
          payloadHasher.add(slice);
          await raf.writeFrom(slice);
          fileWritten += take;
          offset += take;
          onProgress?.call(fileId, fileWritten, totalBytes);
        } else {
          encBuffer.addAll(data.sublist(offset));
          offset = data.length;
        }
      }
    }

    sub = socket.listen(
      (data) async {
        if (done.isCompleted) return;

        if (!headerDone) {
          headerLineBuf.addAll(data);
          final nl = headerLineBuf.indexOf(0x0A);
          if (nl < 0) return;
          final lineBytes = Uint8List.fromList(headerLineBuf.sublist(0, nl));
          final remainder = headerLineBuf.sublist(nl + 1);
          headerLineBuf.clear();
          headerDone = true;
          try {
            final json =
                jsonDecode(utf8.decode(lineBytes)) as Map<String, dynamic>;
            headerCompleter.complete(json);
          } catch (e) {
            headerCompleter.completeError(e);
          }
          if (remainder.isNotEmpty) {
            pendingAfterHeader = Uint8List.fromList(remainder);
          }
          sub.pause();
          return;
        }

        if (!setupDone) return;

        sub.pause();
        try {
          await processFilePayload(Uint8List.fromList(data));
        } finally {
          if (!done.isCompleted) sub.resume();
        }
      },
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        if (!done.isCompleted) done.completeError(e);
      },
      cancelOnError: true,
    );

    try {
      final header =
          await headerCompleter.future.timeout(const Duration(seconds: 8));

      fileId = header['id'] as String? ?? '';
      final fileName = header['name'] as String? ?? 'file';
      totalBytes = (header['size'] as num?)?.toInt() ?? 0;
      resumeOffset = (header['offset'] as num?)?.toInt() ?? 0;
      if (resumeOffset < 0) resumeOffset = 0;

      final validator = validateTransferToken;
      if (validator != null) {
        final headerToken = header['token'] as String?;
        final senderPeerId = header['senderPeerId'] as String?;
        final ok = await validator(fileId, headerToken, senderPeerId);
        if (!ok) {
          try {
            await socket.close();
          } catch (_) {}
          onFileError?.call(
            fileId,
            'Rejected: invalid or missing transfer token',
            null,
          );
          return;
        }
      }

      final regCheck = isIncomingRegistered;
      if (regCheck != null) {
        final registered = await regCheck(fileId);
        if (!registered) {
          try {
            await socket.close();
          } catch (_) {}
          onFileError?.call(
            fileId,
            'Rejected: no pending transfer for this file',
            null,
          );
          return;
        }
      }

      final folderRoot = header['folderRoot'] as String?;
      encrypted = header['encrypted'] == true;
      expectChecksum = header['checksum'] == true;
      final headerSender = header['senderPeerId'] as String?;
      final localId = localPeerId;
      if (encrypted &&
          headerSender != null &&
          headerSender.isNotEmpty &&
          localId != null &&
          localId.isNotEmpty) {
        decKey = await FileTransferCrypto.secretKey(
          headerSender,
          localId,
          fileId,
        );
      }

      if (encrypted && decKey == null) {
        try {
          await socket.close();
        } catch (_) {}
        onFileError?.call(
          fileId,
          'Rejected: encrypted transfer missing peer identity',
          null,
        );
        return;
      }

      if (resumeOffset > 0) {
        final resumeLabel = fileName.replaceAll(RegExp(r'[/\\]'), '_');
        final resolved =
            await resumePathResolver?.call(fileId, resumeOffset, resumeLabel);
        if (resolved == null || resolved.isEmpty) {
          onFileError?.call(fileId, 'Cannot resume: missing partial file', null);
          return;
        }
        writePath = resolved;
        finalPath = finalPathFromPartialWritePath(writePath);
        final len = await File(writePath).length();
        if (len != resumeOffset) {
          await deletePartialDownloadFile(writePath);
          onFileError?.call(
            fileId,
            'Cannot resume: partial size mismatch ($len vs $resumeOffset)',
            writePath,
          );
          return;
        }
        raf = await File(writePath).open(mode: FileMode.append);
        fileWritten = resumeOffset;
        // The sender's checksum covers the WHOLE file, but payloadHasher only
        // sees bytes written this session. Seed it with the already-on-disk
        // partial so the final digest matches and a resumed transfer is not
        // wrongly deleted as a checksum mismatch.
        if (expectChecksum && !encrypted && resumeOffset > 0) {
          final existing = await File(writePath).open(mode: FileMode.read);
          try {
            var remaining = resumeOffset;
            while (remaining > 0) {
              final take = remaining < 65536 ? remaining : 65536;
              final chunk = await existing.read(take);
              if (chunk.isEmpty) break;
              payloadHasher.add(chunk);
              remaining -= chunk.length;
            }
          } finally {
            await existing.close();
          }
        }
      } else {
        finalPath = await _resolveSavePath(fileName, folderRoot: folderRoot);
        writePath = partialDownloadWritePath(finalPath);
        raf = await File(writePath).open(mode: FileMode.write);
        fileWritten = 0;
      }

      _socketsByFileId[fileId] = socket;

      await onFileStarted?.call(
        fileId,
        fileName,
        totalBytes,
        finalPath,
        writePath,
        resumeOffset,
        encrypted,
      );

      socket.write('START\n');
      await socket.flush();

      setupDone = true;

      final pendingHdr = pendingAfterHeader;
      if (pendingHdr != null && pendingHdr.isNotEmpty) {
        pendingAfterHeader = null;
        await processFilePayload(pendingHdr);
      }

      sub.resume();

      try {
        await done.future;
      } on TransferPausedException catch (_) {
        try {
          await raf.close();
        } catch (_) {}
        raf = null;
        _socketsByFileId.remove(fileId);
        await _transferIdsLock.synchronized(() {
          _pausedIds.remove(fileId);
        });
        onFilePaused?.call(fileId, writePath, fileWritten);
        return;
      } on _CancelledException catch (_) {
        try {
          await raf.close();
        } catch (_) {}
        raf = null;
        _socketsByFileId.remove(fileId);
        await _transferIdsLock.synchronized(() {
          _cancelledIds.remove(fileId);
        });
        await deletePartialDownloadFile(writePath);
        onFileError?.call(fileId, 'Transfer cancelled', writePath);
        return;
      }

      await raf.close();
      raf = null;

      _socketsByFileId.remove(fileId);
      final (wasPaused, wasCancelled) = await _transferIdsLock.synchronized(
        () => (
          _pausedIds.remove(fileId),
          _cancelledIds.remove(fileId),
        ),
      );

      if (expectChecksum && !encrypted && encBuffer.isNotEmpty) {
        final tail = utf8.decode(encBuffer, allowMalformed: true);
        final m = RegExp(r'CHECKSUM:([a-f0-9]{64})').firstMatch(tail);
        if (m != null) {
          final expected = m.group(1)!;
          payloadHasher.close();
          digestSink.close();
          final actual = payloadDigest?.toString() ?? '';
          if (expected != actual) {
            await deletePartialDownloadFile(writePath);
            onFileError?.call(
              fileId,
              'Checksum mismatch after transfer',
              writePath,
            );
            return;
          }
        }
      }

      if (totalBytes == 0 ? fileWritten == 0 : fileWritten == totalBytes) {
        final completedPath =
            await _finalizePartialDownload(writePath, finalPath);
        onFileComplete?.call(fileId, completedPath);
      } else {
        if (wasPaused) {
          onFilePaused?.call(fileId, writePath, fileWritten);
        } else if (wasCancelled) {
          await deletePartialDownloadFile(writePath);
          onFileError?.call(fileId, 'Transfer cancelled', writePath);
        } else {
          await deletePartialDownloadFile(writePath);
          onFileError?.call(
            fileId,
            'Incomplete: $fileWritten/$totalBytes bytes',
            writePath,
          );
        }
      }
    } catch (e) {
      await _transferIdsLock.synchronized(() {
        _cancelledIds.remove(fileId);
        _pausedIds.remove(fileId);
      });
      _socketsByFileId.remove(fileId);

      if (e is _CancelledException) {
        await deletePartialDownloadFile(writePath);
        onFileError?.call(fileId, e.toString(), writePath);
        return;
      }
      if (e is TransferPausedException) {
        if (writePath.isNotEmpty) {
          onFilePaused?.call(fileId, writePath, fileWritten);
        }
        return;
      }
      await deletePartialDownloadFile(writePath);
      onFileError?.call(fileId, humanizeFileReceiverError(e), writePath);
    } finally {
      try {
        await sub.cancel();
      } catch (_) {}
      try {
        await raf?.close();
      } catch (_) {}
      try {
        await socket.close();
      } catch (_) {}
      if (fileId.isNotEmpty) {
        _socketsByFileId.remove(fileId);
      }
    }
  }

  static Future<String> _uniqueSiblingPath(String candidatePath) async {
    if (!await File(candidatePath).exists()) return candidatePath;
    final leaf = p.basename(candidatePath);
    final parent = p.dirname(candidatePath);
    final dot = leaf.lastIndexOf('.');
    final baseName = dot > 0 ? leaf.substring(0, dot) : leaf;
    final ext = dot > 0 ? leaf.substring(dot) : '';
    for (var i = 1; i < 100; i++) {
      final path = p.join(parent, '$baseName ($i)$ext');
      if (!await File(path).exists()) return path;
    }
    return p.join(parent, '${DateTime.now().millisecondsSinceEpoch}_$leaf');
  }

  static Future<String> _finalizePartialDownload(
    String writePath,
    String finalPath,
  ) async {
    if (writePath == finalPath) return finalPath;
    final part = File(writePath);
    if (!await part.exists()) return finalPath;
    var destPath = finalPath;
    if (await File(destPath).exists()) {
      destPath = await _uniqueSiblingPath(destPath);
    }
    await part.rename(destPath);
    return destPath;
  }

  static Future<String> _resolveSavePath(
    String fileName, {
    String? folderRoot,
  }) async {
    final dlPath = AppSettings.instance.downloadPath.value;
    Directory dir;
    if (dlPath.isNotEmpty) {
      dir = Directory(dlPath);
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (e) {
        throw FileSystemException(
          'Cannot access configured download folder',
          dlPath,
          e is OSError ? e : null,
        );
      }
      final sep = Platform.pathSeparator;
      final probePath =
          '${dir.path}$sep.localchat_write_probe_${DateTime.now().microsecondsSinceEpoch}';
      final probe = File(probePath);
      try {
        await probe.writeAsString('ok', flush: true);
      } catch (e) {
        throw FileSystemException(
          'Cannot write to configured download folder',
          dir.path,
          e is OSError ? e : null,
        );
      } finally {
        try {
          if (await probe.exists()) await probe.delete();
        } catch (_) {}
      }
    } else {
      dir = Directory.systemTemp;
    }

    final relative = _relativeSavePath(fileName, folderRoot: folderRoot);
    var path = p.join(dir.path, relative);
    await Directory(p.dirname(path)).create(recursive: true);

    if (!await File(path).exists()) return path;

    final leaf = p.basename(path);
    final parent = p.dirname(path);
    final dot = leaf.lastIndexOf('.');
    final baseName = dot > 0 ? leaf.substring(0, dot) : leaf;
    final ext = dot > 0 ? leaf.substring(dot) : '';

    const maxIterations = 100;
    for (var i = 1; i < maxIterations; i++) {
      path = p.join(parent, '$baseName ($i)$ext');
      if (!await File(path).exists()) return path;
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    return p.join(parent, '${stamp}_$leaf');
  }

  static String _relativeSavePath(String fileName, {String? folderRoot}) {
    if (folderRoot != null && folderRoot.isNotEmpty) {
      final safeRoot =
          folderRoot.replaceAll(RegExp(r'[/\\:*?"<>|]'), '_').trim();
      if (safeRoot.isEmpty) {
        return fileName.replaceAll(RegExp(r'[/\\]'), '_');
      }
      final rel = sanitizeFolderRelativePath(fileName.replaceAll('\\', '/'));
      if (rel != null) {
        return p.join(safeRoot, rel);
      }
      return p.join(safeRoot, fileName.replaceAll(RegExp(r'[/\\]'), '_'));
    }
    return fileName.replaceAll(RegExp(r'[/\\]'), '_');
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

class _DigestCaptureSink implements Sink<Digest> {
  _DigestCaptureSink(this._onDigest);
  final void Function(Digest) _onDigest;
  @override
  void add(Digest data) => _onDigest(data);
  @override
  void close() {}
}

class _CancelledException implements Exception {
  const _CancelledException();
  @override
  String toString() => 'Transfer cancelled';
}

/// Sender stopped mid-transfer (pause) or receiver socket closed while paused.
class TransferPausedException implements Exception {
  const TransferPausedException();
  @override
  String toString() => 'Transfer paused';
}
