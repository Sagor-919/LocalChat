import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';

/// One file materialized on disk by Android (cache copy of a content:// share).
class SharedInboundFile {
  final String path;
  final String name;
  const SharedInboundFile(this.path, this.name);
}

/// Routes SEND / SEND_MULTIPLE intents from [MainActivity] into an open chat composer.
class AndroidShareInbound {
  AndroidShareInbound._();

  static const MethodChannel _channel = MethodChannel('local_chat/share');

  static final List<SharedInboundFile> _queued = [];
  static final ValueNotifier<int> pendingRevision = ValueNotifier<int>(0);
  static final Lock _shareLock = Lock();

  static void Function(List<SharedInboundFile>)? _chatConsumer;

  /// While a chat is open, shared files are passed here (after post-frame).
  static void attachChat(void Function(List<SharedInboundFile>) onFiles) {
    unawaited(() async {
      List<SharedInboundFile>? batch;
      await _shareLock.synchronized(() async {
        _chatConsumer = onFiles;
        if (_queued.isNotEmpty) {
          batch = List<SharedInboundFile>.from(_queued);
          _queued.clear();
          pendingRevision.value++;
        }
      });
      if (batch != null && batch!.isNotEmpty) {
        _scheduleDeliver(onFiles, batch!);
      }
    }());
  }

  static void detachChat() {
    unawaited(_shareLock.synchronized(() async {
      _chatConsumer = null;
    }));
  }

  static int get queuedCount => _queued.length;

  /// Drop queued files if the user dismisses the home banner.
  static void clearQueued() {
    unawaited(_shareLock.synchronized(() async {
      if (_queued.isEmpty) return;
      _queued.clear();
      pendingRevision.value++;
    }));
  }

  static void _scheduleDeliver(
    void Function(List<SharedInboundFile>) onFiles,
    List<SharedInboundFile> files,
  ) {
    if (files.isEmpty) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      onFiles(files);
    });
  }

  /// Copies content URIs to app cache on the native side, then returns paths.
  /// Call on cold start (post-frame), on resume, and when opening a chat.
  static Future<void> syncFromNative() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final raw = await _channel
          .invokeMethod<List<dynamic>>('getPendingShareMaterialized');
      if (raw == null || raw.isEmpty) return;
      final files = <SharedInboundFile>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final path = m['path'] as String?;
        final name = m['name'] as String?;
        if (path != null &&
            path.isNotEmpty &&
            name != null &&
            name.isNotEmpty) {
          files.add(SharedInboundFile(path, name));
        }
      }
      if (files.isEmpty) return;
      void Function(List<SharedInboundFile>)? consumer;
      await _shareLock.synchronized(() async {
        consumer = _chatConsumer;
        if (consumer == null) {
          _queued.addAll(files);
          pendingRevision.value++;
        }
      });
      if (consumer != null) {
        _scheduleDeliver(consumer!, files);
      }
    } catch (e, st) {
      debugPrint('AndroidShareInbound.syncFromNative: $e\n$st');
    }
  }
}
