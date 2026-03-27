import 'package:flutter/foundation.dart';

/// Files received from Android “Share” / “Send to” before the user opens a chat.
class PendingShareAttachments {
  PendingShareAttachments._();
  static final instance = PendingShareAttachments._();

  final List<String> _paths = [];
  final ValueNotifier<int> epoch = ValueNotifier<int>(0);

  void addAll(List<String> paths) {
    var any = false;
    for (final p in paths) {
      if (p.isEmpty) continue;
      _paths.add(p);
      any = true;
    }
    if (any) epoch.value++;
  }

  List<String> takeAll() {
    final out = List<String>.from(_paths);
    _paths.clear();
    return out;
  }

  bool get isNotEmpty => _paths.isNotEmpty;
  int get length => _paths.length;
}
