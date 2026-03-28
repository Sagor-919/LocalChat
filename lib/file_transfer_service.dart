import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'app_settings.dart';
import 'file_transfer_crypto.dart';

/// Full-file SHA-256 (hex) off the calling isolate — avoids blocking UI during hashing.
Future<String> _sha256HexFile(File file) async {
  final path = file.path;
  return Isolate.run(() async {
    final digest = await sha256.bind(File(path).openRead()).first;
    return digest.toString();
  });
}

const int kFileTransferPort = 4042;
const int kChunkSize = 65536; // 64 KB

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

// ---------------------------------------------------------------------------
// Sender — opens a new TCP socket, sends header, waits for START, streams file
// ---------------------------------------------------------------------------
class FileSender {
  bool _cancelled = false;
  int bytesSent = 0;

  void cancel() => _cancelled = true;

  Future<void> send({
    required String host,
    required String fileId,
    required String fileName,
    required int fileSize,
    required File file,
    required void Function(int sent, int total) onProgress,
    bool encrypted = false,
    Uint8List? fileKeyMaterial,
  }) async {
    final socket = await connectFileClient(host, kFileTransferPort);
    socket.setOption(SocketOption.tcpNoDelay, true);

    try {
      // Header must be sent immediately — full-file hashing before the header
      // caused the receiver to hit its header timeout on multi-GB files.
      final header = jsonEncode({
        'id': fileId,
        'name': fileName,
        'size': fileSize,
        'offset': 0,
        'sha256': '',
        'encrypted': encrypted,
      });
      socket.write('$header\n');
      await socket.flush();

      await _waitForStart(socket);

      final raf = await file.open();
      try {
        bytesSent = 0;
        var bytesSinceFlush = 0;
        // Flushing every chunk hurts throughput on mobile TCP; batch to ~256 KiB.
        const flushEveryBytes = 262144;
        while (bytesSent < fileSize) {
          if (_cancelled) throw const _CancelledException();

          final remaining = fileSize - bytesSent;
          final toRead = remaining < kChunkSize ? remaining : kChunkSize;
          final buf = await raf.read(toRead);
          if (buf.isEmpty) break;

          if (encrypted && fileKeyMaterial != null) {
            final enc = await encryptFileChunkIsolate(buf, fileKeyMaterial);
            socket.add(frameLengthPrefix(enc.length));
            socket.add(enc);
            bytesSinceFlush += 4 + enc.length;
          } else {
            socket.add(buf);
            bytesSinceFlush += buf.length;
          }
          if (bytesSinceFlush >= flushEveryBytes) {
            await socket.flush();
            bytesSinceFlush = 0;
          }
          bytesSent += buf.length;
          onProgress(bytesSent, fileSize);
        }
        if (bytesSinceFlush > 0) {
          await socket.flush();
        }
      } finally {
        await raf.close();
      }

      // One full-file hash after payload (avoids SHA work in the hot send loop).
      final shaHex = await _sha256HexFile(file);
      socket.write('\n${jsonEncode({'sha256': shaHex})}\n');
      await socket.flush();

      await socket.close();
    } catch (e) {
      try {
        await socket.close();
      } catch (_) {}
      if (_cancelled) rethrow;
      rethrow;
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
        if (buf.toString().contains('START')) c.complete();
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

    try {
      await c.future.timeout(const Duration(seconds: 8));
    } finally {
      await sub.cancel();
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
  final Map<String, Socket> _socketsByFileId = {};

  Future<void> Function(
    String fileId,
    String fileName,
    int fileSize,
    String savePath,
  )? onFileStarted;
  void Function(String fileId, int received, int total)? onProgress;
  void Function(String fileId, String savedPath)? onFileComplete;
  void Function(String fileId, String error, String? savePath)? onFileError;

  /// When header has `encrypted: true`, returns 32-byte AES key from ECDH (TransferManager).
  Future<Uint8List?> Function(String fileId)? resolveFileSessionKey;

  void cancelReceive(String fileId) {
    _cancelledIds.add(fileId);
    _destroySocketFor(fileId);
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
    String fileId = '';
    String? savePath;

    final footerBuf = <int>[];
    String? footerShaHex;
    bool footerLineDone = false;

    Uint8List? sessionKeyMat;
    final rxCipher = <int>[];
    bool wireEncrypted = false;
    Future<void> Function(Uint8List)? dispatchPayload;

    late StreamSubscription<List<int>> sub;

    void tryParseFooterLine() {
      if (footerLineDone) return;
      // Sender writes: '\n${jsonEncode({"sha256": hex})}\n' — the first line
      // after payload is often empty; do not treat that as the checksum line.
      var i = 0;
      while (i < footerBuf.length && footerBuf[i] == 0x0A) {
        i++;
      }
      if (i >= footerBuf.length) {
        footerBuf.clear();
        return;
      }
      final nl = footerBuf.indexOf(0x0A, i);
      if (nl < 0) return;
      final lineBytes = footerBuf.sublist(i, nl);
      try {
        final obj = jsonDecode(utf8.decode(lineBytes)) as Map<String, dynamic>;
        final sha = obj['sha256'] as String?;
        if (sha == null || sha.isEmpty) return;
        footerShaHex = sha;
        footerLineDone = true;
        footerBuf.removeRange(0, nl + 1);
      } catch (_) {
        return;
      }
    }

    Future<void> processRaw(Uint8List data) async {
      if (!setupDone || raf == null) return;

      var offset = 0;
      while (offset < data.length) {
        if (_cancelledIds.contains(fileId)) {
          if (!done.isCompleted) {
            done.completeError(const _CancelledException());
          }
          return;
        }
        if (fileWritten < totalBytes) {
          final take = min(data.length - offset, totalBytes - fileWritten);
          final slice = data.sublist(offset, offset + take);
          await raf.writeFrom(slice);
          fileWritten += take;
          offset += take;
        } else {
          footerBuf.addAll(data.sublist(offset));
          offset = data.length;
          tryParseFooterLine();
        }
      }

      // One callback per TCP chunk — avoids hundreds of UI notifications when
      // one socket read is split into many small writes.
      onProgress?.call(fileId, fileWritten, totalBytes);
    }

    Future<void> processEnc(Uint8List data) async {
      if (!setupDone || raf == null) return;
      final key = sessionKeyMat;
      if (key == null || key.length != 32) {
        throw StateError('Secure file: session key missing');
      }

      if (fileWritten >= totalBytes) {
        footerBuf.addAll(data);
        tryParseFooterLine();
        return;
      }

      rxCipher.addAll(data);
      while (rxCipher.length >= 4) {
        if (_cancelledIds.contains(fileId)) {
          if (!done.isCompleted) {
            done.completeError(const _CancelledException());
          }
          return;
        }
        if (fileWritten >= totalBytes) {
          footerBuf.addAll(Uint8List.fromList(rxCipher));
          rxCipher.clear();
          tryParseFooterLine();
          return;
        }

        final frameLen = readU32Be(rxCipher, 0);
        if (frameLen < 28 || frameLen > kMaxEncryptedFrameBytes) {
          throw StateError('Invalid encrypted frame');
        }
        if (rxCipher.length < 4 + frameLen) return;

        final frame = Uint8List.fromList(rxCipher.sublist(4, 4 + frameLen));
        rxCipher.removeRange(0, 4 + frameLen);

        final plain = await decryptFileChunkIsolate(frame, key);
        var woff = 0;
        while (woff < plain.length && fileWritten < totalBytes) {
          final take = min(plain.length - woff, totalBytes - fileWritten);
          final slice = Uint8List.sublistView(plain, woff, woff + take);
          await raf.writeFrom(slice);
          fileWritten += take;
          woff += take;
        }

        if (woff < plain.length) {
          throw StateError('Encrypted chunk size mismatch');
        }
        onProgress?.call(fileId, fileWritten, totalBytes);
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

        if (!setupDone || dispatchPayload == null) return;
        final dp = dispatchPayload;

        sub.pause();
        try {
          await dp(Uint8List.fromList(data));
        } catch (e, st) {
          if (!done.isCompleted) done.completeError(e, st);
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
      final headerOff = (header['offset'] as num?)?.toInt() ?? 0;
      if (headerOff != 0) {
        onFileError?.call(
          fileId,
          'Partial transfer resume is not supported',
          null,
        );
        return;
      }

      wireEncrypted = header['encrypted'] == true;
      if (wireEncrypted) {
        sessionKeyMat = await resolveFileSessionKey?.call(fileId);
        final sk = sessionKeyMat;
        if (sk == null || sk.length != 32) {
          onFileError?.call(
            fileId,
            'Secure file: missing session key (peer must support ECDH)',
            null,
          );
          return;
        }
      }

      final safeName = fileName.replaceAll(RegExp(r'[/\\]'), '_');

      final path = await _resolveSavePath(safeName);
      savePath = path;
      raf = await File(path).open(mode: FileMode.write);
      fileWritten = 0;

      _socketsByFileId[fileId] = socket;

      dispatchPayload = wireEncrypted ? processEnc : processRaw;

      await onFileStarted?.call(fileId, fileName, totalBytes, path);

      socket.write('START\n');
      await socket.flush();

      setupDone = true;

      final pendingHdr = pendingAfterHeader;
      final dp2 = dispatchPayload;
      if (pendingHdr != null && pendingHdr.isNotEmpty) {
        pendingAfterHeader = null;
        await dp2(pendingHdr);
      }

      sub.resume();

      try {
        await done.future;
      } on _CancelledException catch (_) {
        try {
          await raf.close();
        } catch (_) {}
        raf = null;
        _socketsByFileId.remove(fileId);
        _cancelledIds.remove(fileId);
        await deletePartialDownloadFile(path);
        onFileError?.call(fileId, 'Transfer cancelled', path);
        return;
      }

      tryParseFooterLine();

      await raf.close();
      raf = null;

      _socketsByFileId.remove(fileId);
      final wasCancelled = _cancelledIds.remove(fileId);

      if (fileWritten >= totalBytes) {
        final headerSha = header['sha256'] as String?;
        final expectLegacy =
            headerSha != null && headerSha.isNotEmpty;

        if (footerLineDone && (footerShaHex?.isNotEmpty ?? false)) {
          final actual = await _sha256HexFile(File(path));
          if (actual != footerShaHex) {
            await deletePartialDownloadFile(path);
            onFileError?.call(fileId, 'File checksum mismatch', path);
            return;
          }
        } else if (expectLegacy) {
          final actual = await _sha256HexFile(File(path));
          if (actual != headerSha) {
            await deletePartialDownloadFile(path);
            onFileError?.call(fileId, 'File checksum mismatch', path);
            return;
          }
        } else if (totalBytes > 0) {
          await deletePartialDownloadFile(path);
          onFileError?.call(
              fileId, 'Missing or invalid checksum footer', path);
          return;
        }

        onFileComplete?.call(fileId, path);
      } else {
        if (wasCancelled) {
          await deletePartialDownloadFile(path);
          onFileError?.call(fileId, 'Transfer cancelled', path);
        } else {
          await deletePartialDownloadFile(path);
          onFileError?.call(
              fileId, 'Incomplete: $fileWritten/$totalBytes bytes', path);
        }
      }
    } catch (e) {
      _cancelledIds.remove(fileId);
      _socketsByFileId.remove(fileId);

      if (e is _CancelledException) {
        await deletePartialDownloadFile(savePath);
        onFileError?.call(fileId, e.toString(), savePath);
        return;
      }
      await deletePartialDownloadFile(savePath);
      onFileError?.call(fileId, e.toString(), savePath);
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

  static Future<String> _resolveSavePath(String safeName) async {
    final dlPath = AppSettings.instance.downloadPath.value;
    Directory dir;
    if (dlPath.isNotEmpty) {
      dir = Directory(dlPath);
      try {
        if (!await dir.exists()) await dir.create(recursive: true);
      } catch (_) {
        dir = Directory.systemTemp;
      }
    } else {
      dir = Directory.systemTemp;
    }

    final sep = Platform.pathSeparator;
    var path = '${dir.path}$sep$safeName';
    if (!await File(path).exists()) return path;

    final dot = safeName.lastIndexOf('.');
    final baseName = dot > 0 ? safeName.substring(0, dot) : safeName;
    final ext = dot > 0 ? safeName.substring(dot) : '';

    for (var i = 1; i < 10000; i++) {
      path = '${dir.path}$sep$baseName ($i)$ext';
      if (!await File(path).exists()) return path;
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}$sep$stamp-$safeName';
  }

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

class _CancelledException implements Exception {
  const _CancelledException();
  @override
  String toString() => 'Transfer cancelled';
}
