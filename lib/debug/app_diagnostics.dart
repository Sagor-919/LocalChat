import 'dart:collection';

import 'package:flutter/foundation.dart';

// ---------------------------------------------------------------------------
// Master switch — set to false to disable all diagnostic capture at compile
// time (log() becomes a no-op). Remove this file and imports when no longer
// needed, or leave switch false.
// ---------------------------------------------------------------------------
const bool kAppDiagnosticsEnabled = true;

/// Ring buffer entry shown in the in-app diagnostics panel.
class DiagnosticEntry {
  DiagnosticEntry({
    required this.at,
    required this.category,
    required this.message,
  });

  final DateTime at;
  final String category;
  final String message;

  String get line =>
      '${at.toIso8601String().substring(11, 23)} [$category] $message';
}

/// Central timeline for LAN/TCP/discovery issues. Lightweight when logging
/// is off ([kAppDiagnosticsEnabled] or [loggingAllowed] false).
class AppDiagnostics extends ChangeNotifier {
  AppDiagnostics._();
  static final AppDiagnostics instance = AppDiagnostics._();

  static const int maxEntries = 500;

  final ListQueue<DiagnosticEntry> _entries = ListQueue<DiagnosticEntry>();

  /// Prefs + master switch; updated by [AppSettings].
  bool loggingAllowed = true;

  UnmodifiableListView<DiagnosticEntry> get entries =>
      UnmodifiableListView<DiagnosticEntry>(_entries);

  static bool get _active => kAppDiagnosticsEnabled;

  /// Call when settings toggle changes.
  void setLoggingAllowed(bool allowed) {
    loggingAllowed = allowed;
    notifyListeners();
  }

  void log(String category, String message) {
    if (!_active || !loggingAllowed) return;
    final e = DiagnosticEntry(
      at: DateTime.now(),
      category: category,
      message: message,
    );
    _entries.addLast(e);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
    notifyListeners();
    if (kDebugMode) {
      debugPrint('[diag] ${e.line}');
    }
  }

  void logError(String category, Object error, [StackTrace? stack]) {
    final buf = StringBuffer(error.toString());
    if (stack != null && kDebugMode) {
      buf.write('\n');
      buf.write(stack);
    }
    log(category, buf.toString());
  }

  void clear() {
    if (!_active) return;
    _entries.clear();
    notifyListeners();
  }

  String exportText() {
    final b = StringBuffer();
    for (final e in _entries) {
      b.writeln(e.line);
    }
    return b.toString();
  }
}

/// Short alias for call sites: `diag('TCP', 'connect ok …')`
@pragma('vm:prefer-inline')
void diag(String category, String message) =>
    AppDiagnostics.instance.log(category, message);

@pragma('vm:prefer-inline')
void diagError(String category, Object error, [StackTrace? stack]) =>
    AppDiagnostics.instance.logError(category, error, stack);
