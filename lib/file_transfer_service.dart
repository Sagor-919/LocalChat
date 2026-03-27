import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_settings.dart';

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

      await _waitForStart(socket);

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
      try {
        await socket.close();
      } catch (_) {}
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

  Future<void> Function(String fileId, String fileName, int fileSize)? onFileStarted;
  void Function(String fileId, int received, int total)? onProgress;
  void Function(String fileId, String savedPath)? onFileComplete;
  void Function(String fileId, String error)? onFileError;

  void cancelReceive(String fileId) => _cancelledIds.add(fileId);

  Future<void> startServer() async {
    _server =
        await ServerSocket.bind(InternetAddress.anyIPv4, kFileTransferPort);
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
    int received = 0;
    String fileId = '';

    late StreamSubscription<List<int>> sub;
    sub = socket.listen(
      (data) async {
        if (done.isCompleted) return;

        if (!headerDone) {
          headerBuf.write(utf8.decode(data, allowMalformed: true));
          final content = headerBuf.toString();
          final nl = content.indexOf('\n');
          if (nl >= 0) {
            headerDone = true;
            try {
              final json =
                  jsonDecode(content.substring(0, nl)) as Map<String, dynamic>;
              headerCompleter.complete(json);
            } catch (e) {
              headerCompleter.completeError(e);
            }
            sub.pause();
          }
          return;
        }

        if (!setupDone) return;

        if (_cancelledIds.contains(fileId)) {
          if (!done.isCompleted) {
            done.completeError(const _CancelledException());
          }
          return;
        }

        sub.pause();
        try {
          await raf!.writeFrom(data);
          received += data.length;
          onProgress?.call(fileId, received, totalBytes);
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

      final safeName = fileName.replaceAll(RegExp(r'[/\\]'), '_');
      final savePath = await _resolveSavePath(safeName);
      final saveFile = File(savePath);
      raf = await saveFile.open(mode: FileMode.write);

      await onFileStarted?.call(fileId, fileName, totalBytes);
      received = 0;

      socket.write('START\n');
      await socket.flush();

      setupDone = true;
      sub.resume();

      await done.future;

      await raf.close();
      raf = null;

      _cancelledIds.remove(fileId);

      if (received >= totalBytes) {
        onFileComplete?.call(fileId, savePath);
      } else {
        onFileError?.call(
            fileId, 'Incomplete: $received/$totalBytes bytes');
      }
    } catch (e) {
      _cancelledIds.remove(fileId);
      onFileError?.call(fileId, e.toString());
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
