import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:synchronized/synchronized.dart';

import 'app_settings.dart';

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
    int tcpPort = kFileTransferPort,
  }) async {
    if (startOffset < 0 || startOffset > fileSize) {
      throw ArgumentError('Invalid startOffset');
    }
    final socket = await connectFileClient(host, tcpPort);
    _socket = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);

    try {
      final header = jsonEncode({
        'id': fileId,
        'name': fileName,
        'size': fileSize,
        'offset': startOffset,
      });
      socket.write('$header\n');
      await socket.flush();

      await _waitForStart(socket);

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

          socket.add(buf);
          await socket.flush();
          bytesSent += buf.length;
          onProgress(startOffset + bytesSent, fileSize);
        }
      } finally {
        await raf.close();
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

  Future<void> Function(
    String fileId,
    String fileName,
    int fileSize,
    String savePath,
    int resumeOffset,
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
    String? savePath;

    late StreamSubscription<List<int>> sub;

    Future<void> processFilePayload(Uint8List data) async {
      if (!setupDone || raf == null) return;

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
          await raf.writeFrom(slice);
          fileWritten += take;
          offset += take;
          onProgress?.call(fileId, fileWritten, totalBytes);
        } else {
          // Ignore trailing bytes (e.g. legacy checksum footer from older clients).
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

      final safeName = fileName.replaceAll(RegExp(r'[/\\]'), '_');

      late final String path;
      if (resumeOffset > 0) {
        final resolved =
            await resumePathResolver?.call(fileId, resumeOffset, safeName);
        if (resolved == null || resolved.isEmpty) {
          onFileError?.call(fileId, 'Cannot resume: missing partial file', null);
          return;
        }
        path = resolved;
        savePath = path;
        final len = await File(path).length();
        if (len != resumeOffset) {
          await deletePartialDownloadFile(path);
          onFileError?.call(
            fileId,
            'Cannot resume: partial size mismatch ($len vs $resumeOffset)',
            path,
          );
          return;
        }
        raf = await File(path).open(mode: FileMode.append);
        fileWritten = resumeOffset;
      } else {
        path = await _resolveSavePath(safeName);
        savePath = path;
        raf = await File(path).open(mode: FileMode.write);
        fileWritten = 0;
      }

      _socketsByFileId[fileId] = socket;

      await onFileStarted?.call(
          fileId, fileName, totalBytes, path, resumeOffset);

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
        onFilePaused?.call(fileId, path, fileWritten);
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
        await deletePartialDownloadFile(path);
        onFileError?.call(fileId, 'Transfer cancelled', path);
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

      if (totalBytes == 0 ? fileWritten == 0 : fileWritten == totalBytes) {
        onFileComplete?.call(fileId, path);
      } else {
        if (wasPaused) {
          onFilePaused?.call(fileId, path, fileWritten);
        } else if (wasCancelled) {
          await deletePartialDownloadFile(path);
          onFileError?.call(fileId, 'Transfer cancelled', path);
        } else {
          await deletePartialDownloadFile(path);
          onFileError?.call(
              fileId, 'Incomplete: $fileWritten/$totalBytes bytes', path);
        }
      }
    } catch (e) {
      await _transferIdsLock.synchronized(() {
        _cancelledIds.remove(fileId);
        _pausedIds.remove(fileId);
      });
      _socketsByFileId.remove(fileId);

      if (e is _CancelledException) {
        await deletePartialDownloadFile(savePath);
        onFileError?.call(fileId, e.toString(), savePath);
        return;
      }
      if (e is TransferPausedException) {
        if (savePath != null && savePath.isNotEmpty) {
          onFilePaused?.call(fileId, savePath, fileWritten);
        }
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

    const maxIterations = 100;
    for (var i = 1; i < maxIterations; i++) {
      path = '${dir.path}$sep$baseName ($i)$ext';
      if (!await File(path).exists()) return path;
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    return '${dir.path}$sep${stamp}_$safeName';
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

/// Sender stopped mid-transfer (pause) or receiver socket closed while paused.
class TransferPausedException implements Exception {
  const TransferPausedException();
  @override
  String toString() => 'Transfer paused';
}
