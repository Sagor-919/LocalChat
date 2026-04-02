import 'dart:io';

import 'package:flutter/foundation.dart';

/// Files dropped on the home screen (desktop / Android with desktop_drop).
/// Open a chat to [takeAll] into the composer, similar to Android share-inbound.
class DesktopDropQueue {
  DesktopDropQueue._();

  static final List<String> _paths = [];
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static int get count => _paths.length;

  static void enqueue(Iterable<String> paths) {
    if (kIsWeb) return;
    final ok = paths.where((p) => p.isNotEmpty && File(p).existsSync()).toList();
    if (ok.isEmpty) return;
    _paths.addAll(ok);
    revision.value++;
  }

  static List<String> takeAll() {
    if (_paths.isEmpty) return const [];
    final out = List<String>.from(_paths);
    _paths.clear();
    revision.value++;
    return out;
  }

  static void clear() {
    if (_paths.isEmpty) return;
    _paths.clear();
    revision.value++;
  }
}
