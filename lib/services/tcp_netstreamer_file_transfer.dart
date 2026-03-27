import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// Header format (one line, UTF-8):
//   FILE|localId|fileId|fileName|fileSize|startOffset\n
//
// Receiver replies with:
//   START\n
//
// Then sender streams raw bytes from startOffset to fileSize.
// Socket close by sender = transfer complete.

// ---------------------------------------------------------------------------
// Sender
// ---------------------------------------------------------------------------
class FileSender {
  Future<void> send({
    required InternetAddress host,
    required int port,
    required String localId,
    required String fileId,
    required String fileName,
    required int fileSize,
    required File file,
    int startOffset = 0,
    int bufferSize = 65535,
    Duration handshakeTimeout = const Duration(seconds: 8),
    required void Function(int sentBytes, int totalBytes) onProgress,
    required bool Function() isCancelled,
  }) async {
    final socket = await Socket.connect(host, port,
        timeout: const Duration(seconds: 6));
    socket.setOption(SocketOption.tcpNoDelay, true);

    try {
      final header = _encodeHeader(
        localId: localId,
        fileId: fileId,
        fileName: fileName,
        fileSize: fileSize,
        startOffset: startOffset,
      );
      socket.add(utf8.encode(header));
      await socket.flush();

      await _waitForStart(socket, timeout: handshakeTimeout);

      final raf = await file.open();
      try {
        if (startOffset > 0) await raf.setPosition(startOffset);

        int position = startOffset;
        int lastProgressBytes = startOffset;
        int idleCount = 0;
        const maxIdle = 40;

        while (position < fileSize) {
          if (isCancelled()) throw const FileTransferCancelledException();

          final remaining = fileSize - position;
          final toRead = remaining < bufferSize ? remaining : bufferSize;
          final buf = await raf.read(toRead);
          if (buf.isEmpty) break;

          socket.add(buf);
          position += buf.length;
          onProgress(position, fileSize);

          if (((position - startOffset) ~/ bufferSize) % 8 == 0) {
            await socket.flush();
          }

          if (position == lastProgressBytes) {
            if (++idleCount > maxIdle) throw const SocketIdleTimeoutException();
          } else {
            lastProgressBytes = position;
            idleCount = 0;
          }
        }

        await socket.flush();
      } finally {
        await raf.close();
      }

      await socket.close();
    } catch (_) {
      try { await socket.close(); } catch (_) {}
      rethrow;
    }
  }

  Future<void> _waitForStart(Socket socket, {required Duration timeout}) async {
    final c = Completer<void>();
    final buf = BytesBuilder(copy: false);
    late final StreamSubscription<Uint8List> sub;

    sub = socket.listen(
      (data) {
        if (c.isCompleted) return;
        buf.add(data);
        if (utf8.decode(buf.toBytes(), allowMalformed: true).contains('START')) {
          c.complete();
        }
      },
      onError: (Object e) { if (!c.isCompleted) c.completeError(e); },
      onDone: () {
        if (!c.isCompleted) {
          c.completeError(const SocketException('Closed before START'));
        }
      },
      cancelOnError: true,
    );

    try {
      await c.future.timeout(timeout);
    } finally {
      await sub.cancel();
    }
  }
}

// ---------------------------------------------------------------------------
// Receiver — single subscription for both header + data phases
// ---------------------------------------------------------------------------
class FileReceiver {
  /// Receives a file over [socket].
  ///
  /// [onHeader] is called once the FILE header has been parsed. It should
  /// return the save-path for the file, or `null` to reject the transfer.
  /// This lets the caller look up the transfer by `header.fileId` before
  /// data streaming begins.
  Future<FileTransferHeader> receive({
    required Socket socket,
    required Future<String?> Function(FileTransferHeader header) onHeader,
    required void Function(int receivedBytes, int totalBytes) onProgress,
    required bool Function() isCancelled,
  }) async {
    final headerBuf = BytesBuilder(copy: false);
    final headerCompleter = Completer<FileTransferHeader>();
    final done = Completer<void>();

    bool headerDone = false;
    bool setupDone = false;
    late FileTransferHeader header;
    RandomAccessFile? raf;
    int receivedBytes = 0;
    int lastProgressBytes = 0;
    int idleCount = 0;
    const maxIdle = 40;

    late StreamSubscription<Uint8List> sub;
    sub = socket.listen(
      (data) async {
        if (done.isCompleted) return;

        // ---------- Phase 1: header ----------
        if (!headerDone) {
          headerBuf.add(data);
          final bytes = headerBuf.toBytes();
          if (bytes.length > 8192) {
            if (!headerCompleter.isCompleted) {
              headerCompleter.completeError(
                  const FormatException('Header too large'));
            }
            return;
          }
          final nl = bytes.indexOf(10);
          if (nl >= 0) {
            headerDone = true;
            try {
              header = FileTransferHeader.parse(
                  utf8.decode(bytes.sublist(0, nl)));
              headerCompleter.complete(header);
            } catch (e) {
              if (!headerCompleter.isCompleted) {
                headerCompleter.completeError(e);
              }
            }
            // Pause until the caller sets up the file and sends START.
            sub.pause();
          }
          return;
        }

        // ---------- Phase 2: data ----------
        if (!setupDone) return;

        if (isCancelled()) {
          if (!done.isCompleted) {
            done.completeError(const FileTransferCancelledException());
          }
          return;
        }

        sub.pause();
        try {
          await raf!.writeFrom(data);
          receivedBytes += data.length;
          onProgress(receivedBytes, header.fileSize);

          if (receivedBytes == lastProgressBytes) {
            if (++idleCount > maxIdle) {
              if (!done.isCompleted) {
                done.completeError(const SocketIdleTimeoutException());
              }
              return;
            }
          } else {
            lastProgressBytes = receivedBytes;
            idleCount = 0;
          }
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
      header = await headerCompleter.future.timeout(
          const Duration(seconds: 8));

      final savePath = await onHeader(header);
      if (savePath == null) {
        throw const FileTransferCancelledException();
      }

      final startOffset = header.startOffset;
      receivedBytes = startOffset;
      lastProgressBytes = startOffset;

      final saveFile = File(savePath);
      await saveFile.parent.create(recursive: true);
      raf = await saveFile.open(
        mode: startOffset > 0 ? FileMode.writeOnlyAppend : FileMode.write,
      );
      if (startOffset > 0) await raf.setPosition(startOffset);

      socket.add(utf8.encode('START\n'));
      await socket.flush();

      setupDone = true;
      sub.resume();

      await done.future;

      if (receivedBytes < header.fileSize) {
        throw FileTransferIncompleteException(
          expectedBytes: header.fileSize,
          receivedBytes: receivedBytes,
        );
      }

      return header;
    } finally {
      try { await sub.cancel(); } catch (_) {}
      try { await raf?.close(); } catch (_) {}
      try { await socket.close(); } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------
class FileTransferHeader {
  final String localId;
  final String fileId;
  final String fileName;
  final int fileSize;
  final int startOffset;

  const FileTransferHeader({
    required this.localId,
    required this.fileId,
    required this.fileName,
    required this.fileSize,
    required this.startOffset,
  });

  static FileTransferHeader parse(String line) {
    if (!line.startsWith('FILE|')) {
      throw const FormatException('Not a FILE header');
    }
    final p = line.split('|');
    if (p.length < 6) throw const FormatException('Incomplete FILE header');
    return FileTransferHeader(
      localId: p[1],
      fileId: p[2],
      fileName: p[3],
      fileSize: int.parse(p[4]),
      startOffset: int.parse(p[5]),
    );
  }
}

String _encodeHeader({
  required String localId,
  required String fileId,
  required String fileName,
  required int fileSize,
  required int startOffset,
}) {
  final safe = fileName.replaceAll('|', '_');
  return 'FILE|$localId|$fileId|$safe|$fileSize|$startOffset\n';
}

// ---------------------------------------------------------------------------
// Exceptions
// ---------------------------------------------------------------------------
class SocketIdleTimeoutException implements Exception {
  const SocketIdleTimeoutException();
  @override
  String toString() => 'SocketIdleTimeoutException';
}

class FileTransferCancelledException implements Exception {
  const FileTransferCancelledException();
  @override
  String toString() => 'FileTransferCancelledException';
}

class FileTransferIncompleteException implements Exception {
  final int expectedBytes;
  final int receivedBytes;
  const FileTransferIncompleteException({
    required this.expectedBytes,
    required this.receivedBytes,
  });
  @override
  String toString() =>
      'FileTransferIncompleteException($receivedBytes/$expectedBytes)';
}
