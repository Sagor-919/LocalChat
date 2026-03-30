path = r"k:\GitRepos\LocalChat\lib\transfer_manager.dart"
with open(path, encoding="utf-8") as f:
    s = f.read()

s = s.replace(
    "import 'message_store.dart';\n\nclass TransferState {",
    """import 'message_store.dart';
import 'package:path/path.dart' as p;

import 'attachment_prepare.dart';
import 'deferred_staged_file.dart';

enum OutgoingTransferPhase { preparing, transferring }

class TransferState {""",
    1,
)

old_ts = """class TransferState {
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
  /// Paused mid-transfer (local); not an error — partial file kept on receiver.
  bool isPaused = false;
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
}"""

new_ts = """class TransferState {
  final String fileId;
  final String peerId;
  final String fileName;
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
  FileSender? sender;
  Process? prepProcess;
  final List<String> tempPathsForCleanup = [];
  OutgoingTransferPhase outgoingPhase;
  final Stopwatch stopwatch = Stopwatch()..start();

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
}"""

# After first replace, class is "class TransferState {" broken - I made error

