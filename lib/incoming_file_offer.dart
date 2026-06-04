import 'package:flutter/material.dart';

import 'storage_usage.dart';

/// Shown when [AppSettings.autoAcceptIncomingFiles] is false.
Future<bool> showIncomingFileOfferDialog({
  required BuildContext context,
  required String peerDisplayName,
  required String fileLabel,
  required int fileSizeBytes,
  String? detailLine,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: const Text('Incoming file'),
      content: Text(
        '$peerDisplayName wants to send:\n\n'
        '$fileLabel\n'
        '${formatStorageBytes(fileSizeBytes)}'
        '${detailLine != null ? '\n\n$detailLine' : ''}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Decline'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Accept'),
        ),
      ],
    ),
  );
  return result == true;
}
