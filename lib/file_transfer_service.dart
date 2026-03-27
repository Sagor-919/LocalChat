import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int kFileTransferPort = 4042;
const int kChunkSize = 65536; // 64 KB

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
  }) async {
    final socket = await Socket.connect(host, kFileTransferPort,
        timeout: const Duration(seconds: 6));
    socket.setOption(SocketOption.tcpNoDelay, true);

    try {
      final header = jsonEncode({
        'id': fileId,
        'name': fileName,
        'size': fileSize,
      });
      socket.write('$header\n');
      await socket.flush();

      // Wait for START
      await _waitForStart(socket);

      // Stream file bytes
      final raf = await file.open();
      try {
        bytesSent = 0;
        while (bytesSent < fileSize) {
          if (_cancelled) throw const _CancelledException();

          final remaining = fileSize - bytesSent;
          final toRead = remaining < kChunkSize ? remaining : kChunkSize;
          final buf = await raf.read(toRead);
          if (buf.isEmpty) break;

          socket.add(buf);
          await socket.flush();
          bytesSent += buf.length;
          onProgress(bytesSent, fileSize);
        }
      } finally {
        await raf.close();
      }

      await socket.close();
    } catch (_) {
      try { await socket.close(); } catch (_) {}
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
      onError: (Object e) { if (!c.isCompleted) c.completeError(e); },
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
// ---------------------------------------------------------------------------
class FileReceiver {
  ServerSocket? _server;
  bool _cancelled = false;
  int bytesReceived = 0;

  void Function(String fileId, String fileName, int fileSize)? onFileStarted;
  void Function(int received, int total)? onProgress;
  void Function(String fileId, String savedPath)? onFileComplete;
  void Function(String fileId, String error)? onFileError;

  void cancel() => _cancelled = true;

  Future<void> startServer() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, kFileTransferPort);
    _server!.listen(_handleSocket);
  }

  void _handleSocket(Socket socket) {
    _receiveFile(socket);
  }

  Future<void> _receiveFile(Socket socket) async {
    final headerBuf = StringBuffer();
    final headerCompleter = Completer<Map<String, dynamic>>();
    final done = Completer<void>();

    bool headerDone = false;
    bool setupDone = false;
    RandomAccessFile? raf;
    int totalBytes = 0;
    String fileId = '';

    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (data) async {
        if (done.isCompleted) return;

        // Phase 1: read header
        if (!headerDone) {
          headerBuf.write(utf8.decode(data, allowMalformed: true));
          final content = headerBuf.toString();
          final nl = content.indexOf('\n');
          if (nl >= 0) {
            headerDone = true;
            try {
              final json = jsonDecode(content.substring(0, nl))
                  as Map<String, dynamic>;
              headerCompleter.complete(json);
            } catch (e) {
              headerCompleter.completeError(e);
            }
            sub.pause();
          }
          return;
        }

        // Phase 2: write file data
        if (!setupDone) return;

        if (_cancelled) {
          if (!done.isCompleted) done.completeError(const _CancelledException());
          return;
        }

        sub.pause();
        try {
          await raf!.writeFrom(data);
          bytesReceived += data.length;
          onProgress?.call(bytesReceived, totalBytes);
        } finally {
          if (!done.isCompleted) sub.resume();
        }
      },
      onDone: () { if (!done.isCompleted) done.complete(); },
      onError: (Object e) { if (!done.isCompleted) done.completeError(e); },
      cancelOnError: true,
    );

    try {
      final header = await headerCompleter.future
          .timeout(const Duration(seconds: 8));

      fileId = header['id'] as String? ?? '';
      final fileName = header['name'] as String? ?? 'file';
      totalBytes = (header['size'] as num?)?.toInt() ?? 0;

      final dir = Directory.systemTemp;
      final safeName = fileName.replaceAll(RegExp(r'[/\\]'), '_');
      final savePath =
          '${dir.path}/${DateTime.now().millisecondsSinceEpoch}-$safeName';
      final saveFile = File(savePath);
      raf = await saveFile.open(mode: FileMode.write);

      onFileStarted?.call(fileId, fileName, totalBytes);
      bytesReceived = 0;

      // Tell sender to start streaming
      socket.write('START\n');
      await socket.flush();

      setupDone = true;
      sub.resume();

      await done.future;

      await raf.close();
      raf = null;

      if (bytesReceived >= totalBytes) {
        onFileComplete?.call(fileId, savePath);
      } else {
        onFileError?.call(fileId,
            'Incomplete: $bytesReceived/$totalBytes bytes');
      }
    } catch (e) {
      onFileError?.call(fileId, e.toString());
    } finally {
      try { await sub.cancel(); } catch (_) {}
      try { await raf?.close(); } catch (_) {}
      try { await socket.close(); } catch (_) {}
    }
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
