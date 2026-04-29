import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'deferred_staged_file.dart';

/// Android SAF picker that returns URI + metadata only (no copy at pick time).
///
/// The `file_picker` plugin copies every `content://` selection into app cache before
/// returning; we use native [ACTION_OPEN_DOCUMENT] instead so heavy I/O runs on Send
/// ([TransferManager] → [AndroidShareInbound.materializeContentUriToFile]).
class AndroidAttachmentPicker {
  AndroidAttachmentPicker._();

  static const MethodChannel _channel =
      MethodChannel('local_chat/attachments');

  /// Returns staged rows, or empty list if cancelled / nothing selected.
  static Future<List<DeferredStagedFile>> pickFiles() async {
    if (kIsWeb || !Platform.isAndroid) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('pickFiles');
      if (raw == null || raw.isEmpty) return const [];
      final out = <DeferredStagedFile>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final name = m['name'] as String?;
        if (name == null || name.isEmpty) continue;
        final path = m['path'] as String?;
        final contentUri = m['contentUri'] as String?;
        final sizeRaw = m['size'];
        int? knownSizeBytes;
        if (sizeRaw is int) {
          knownSizeBytes = sizeRaw;
        } else if (sizeRaw is num) {
          knownSizeBytes = sizeRaw.toInt();
        }
        if (contentUri != null && contentUri.isNotEmpty) {
          out.add(DeferredStagedFile(
            androidContentUri: contentUri,
            displayName: name,
            knownSizeBytes: knownSizeBytes,
          ));
        } else if (path != null && path.isNotEmpty) {
          out.add(DeferredStagedFile(
            sourcePath: path,
            displayName: name,
            knownSizeBytes: knownSizeBytes,
          ));
        }
      }
      return out;
    } on PlatformException catch (e) {
      debugPrint('AndroidAttachmentPicker.pickFiles: $e');
      return const [];
    }
  }

  /// Resolves DISPLAY_NAME (and a MIME-derived extension fallback) for a `content://` URI.
  /// Used to recover extensions after Android drag-and-drop, where dropped names often
  /// arrive without one (e.g. media providers return doc IDs / display names sans suffix).
  static Future<String?> resolveContentName(String uri) async {
    if (kIsWeb || !Platform.isAndroid) return null;
    if (uri.isEmpty) return null;
    try {
      final res = await _channel
          .invokeMethod<String>('resolveContentName', {'uri': uri});
      if (res == null || res.isEmpty) return null;
      return res;
    } on PlatformException catch (e) {
      debugPrint('AndroidAttachmentPicker.resolveContentName: $e');
      return null;
    }
  }
}
