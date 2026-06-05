import 'dart:async';

import 'package:flutter/material.dart';

import 'transfer_manager.dart';

/// Global list of active, paused, and failed file transfers (QA item 6).
class TransferCenterScreen extends StatefulWidget {
  const TransferCenterScreen({super.key});

  @override
  State<TransferCenterScreen> createState() => _TransferCenterScreenState();
}

class _TransferCenterScreenState extends State<TransferCenterScreen> {
  StreamSubscription<void>? _transferSub;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _transferSub = TransferManager.instance.transferUpdates.listen((_) {
      if (!mounted) return;
      _refreshTimer?.cancel();
      _refreshTimer = Timer(const Duration(milliseconds: 250), () {
        if (mounted) setState(() {});
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _transferSub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tm = TransferManager.instance;
    final all = tm.transfers.values.toList()
      ..sort((a, b) {
        int rank(TransferState t) {
          if (t.error != null) return 2;
          if (t.isPaused) return 1;
          return 0;
        }
        final ra = rank(a);
        final rb = rank(b);
        if (ra != rb) return ra.compareTo(rb);
        return a.fileName.compareTo(b.fileName);
      });

    return Scaffold(
      appBar: AppBar(title: const Text('Transfers')),
      body: all.isEmpty
          ? const Center(child: Text('No file transfers'))
          : ListView.builder(
              padding: const EdgeInsets.all(12),
              itemCount: all.length,
              itemBuilder: (context, i) {
                final t = all[i];
                final pct = (t.progress * 100).round();
                final status = t.error != null
                    ? 'Failed'
                    : t.isPaused
                        ? 'Paused'
                        : t.outgoingPhase == OutgoingTransferPhase.preparing
                            ? 'Preparing'
                            : 'Active';
                return Card(
                  child: ListTile(
                    title: Text(t.fileName, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '$status · ${t.isSending ? 'Sending' : 'Receiving'} · $pct%',
                    ),
                    trailing: t.error != null
                        ? IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () => tm.dismiss(t.fileId),
                            tooltip: 'Dismiss',
                          )
                        : t.isPaused
                            ? IconButton(
                                icon: const Icon(Icons.play_arrow),
                                onPressed: () {
                                  if (t.isSending) {
                                    tm.resumeOutgoing(t.fileId);
                                  } else {
                                    tm.resumeIncoming(t.fileId);
                                  }
                                },
                              )
                            : IconButton(
                                icon: const Icon(Icons.pause),
                                onPressed: () {
                                  if (t.isSending) {
                                    tm.pauseOutgoing(t.fileId);
                                  } else {
                                    tm.pauseIncoming(t.fileId);
                                  }
                                },
                              ),
                  ),
                );
              },
            ),
    );
  }
}
