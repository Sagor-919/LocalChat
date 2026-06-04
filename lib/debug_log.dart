import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// In-memory ring buffer for diagnostics (QA item 26).
class DebugLog {
  DebugLog._();
  static final instance = DebugLog._();

  static const _maxLines = 500;
  final _lines = Queue<String>();

  void log(String message) {
    final line =
        '${DateTime.now().toIso8601String()} $message';
    _lines.addLast(line);
    while (_lines.length > _maxLines) {
      _lines.removeFirst();
    }
    if (kDebugMode) {
      debugPrint('[LocalChat] $message');
    }
  }

  List<String> snapshot() => List.unmodifiable(_lines);

  Future<File> exportToTempFile() async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/localchat_debug_${DateTime.now().millisecondsSinceEpoch}.log',
    );
    await file.writeAsString(_lines.join('\n'));
    return file;
  }
}
