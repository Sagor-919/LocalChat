import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shows local peer id for manual verification (QA item 19).
Future<void> showPeerIdentitySheet(
  BuildContext context, {
  required String userId,
  required String displayName,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(displayName, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Peer ID (share to verify on LAN):',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          SelectableText(userId, style: const TextStyle(fontFamily: 'monospace')),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: userId));
              Navigator.pop(ctx);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Peer ID copied')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy peer ID'),
          ),
        ],
      ),
    ),
  );
}
