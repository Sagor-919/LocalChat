import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'message_model.dart';
import 'message_store.dart';

/// Deletes on-disk attachment files referenced by chat history (QA item 10).
Future<int> deleteAttachmentFilesForMessages(List<ChatMessage> messages) async {
  if (kIsWeb) return 0;
  var deleted = 0;
  for (final m in messages) {
    final path = m.attachmentPath;
    if (path == null || path.isEmpty) continue;
    try {
      final entity = FileSystemEntity.typeSync(path);
      if (entity == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
        deleted++;
      } else if (entity == FileSystemEntityType.file) {
        await File(path).delete();
        deleted++;
      }
    } catch (_) {}
    final dir = p.dirname(path);
    if (dir.isNotEmpty && p.basename(dir) != '.') {
      try {
        final parent = Directory(dir);
        if (await parent.exists()) {
          final empty = !(await parent.list().any((_) => true));
          if (empty) await parent.delete(recursive: true);
        }
      } catch (_) {}
    }
  }
  return deleted;
}

Future<int> deleteAttachmentFilesForPeer(MessageStore store, String peerId) async {
  final messages = await store.load(peerId);
  return deleteAttachmentFilesForMessages(messages);
}

Future<int> deleteAllAttachmentFiles(MessageStore store) async {
  final peers = await store.loadAllPeerInfos();
  var total = 0;
  for (final peerId in peers.keys) {
    total += await deleteAttachmentFilesForPeer(store, peerId);
  }
  return total;
}
