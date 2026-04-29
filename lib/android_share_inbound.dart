import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:synchronized/synchronized.dart';

import 'attachment_prepare.dart';

/// One inbound share row. [path] is set for `file://` shares; [contentUri] for
/// `content://` shares (no copy until send — see [materializeContentUriToFile]).
class SharedInboundFile {
  final String name;
  final String? path;
  final String? contentUri;

  SharedInboundFile({
    required this.name,
    this.path,
    this.contentUri,
  }) : assert(
          (path?.isNotEmpty ?? false) ||
              (contentUri?.isNotEmpty ?? false),
        );
}

/// Routes SEND / SEND_MULTIPLE intents from [MainActivity] into an open chat composer.
///
/// **`content://` shares:** Native only queues the URI + display name (fast). The heavy
/// copy runs when the user taps Send ([TransferManager] → [materializeContentUriToFile]).
///
/// **No chat open:** Dart enqueues descriptors and the home screen shows a banner
/// (*"open a chat to attach"*). **Chat open:** [attachChat] registers the consumer;
/// [syncFromNative] delivers [SharedInboundFile] rows into the composer as
/// [DeferredStagedFile] entries ([ChatScreen]).
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

  /// Copies a `content://` URI to [destPath] on the native side (used at send time).
  static Future<void> materializeContentUriToFile({
    required String contentUri,
    required String destPath,
  }) async {
    if (kIsWeb || !Platform.isAndroid) {
      throw UnsupportedError('materializeContentUriToFile is Android-only');
    }
    try {
      await _channel.invokeMethod<void>('materializeContentUri', {
        'uri': contentUri,
        'destPath': destPath,
      });
    } on PlatformException catch (e) {
      throw AttachmentPrepareException(
        e.message?.trim().isNotEmpty == true
            ? e.message!
            : 'Could not read shared file',
      );
    }
  }

  /// Drains pending intents: `file` → [path]; `content` → [contentUri] only (instant).
  /// Call on cold start (post-frame), on resume, and when opening a chat.
  static Future<void> syncFromNative() async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final raw =
          await _channel.invokeMethod<List<dynamic>>('drainPendingShares');
      if (raw == null || raw.isEmpty) return;
      final files = <SharedInboundFile>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final name = m['name'] as String?;
        if (name == null || name.isEmpty) continue;
        final path = m['path'] as String?;
        final contentUri = m['contentUri'] as String?;
        if (path != null && path.isNotEmpty) {
          files.add(SharedInboundFile(name: name, path: path));
        } else if (contentUri != null && contentUri.isNotEmpty) {
          files.add(SharedInboundFile(name: name, contentUri: contentUri));
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
