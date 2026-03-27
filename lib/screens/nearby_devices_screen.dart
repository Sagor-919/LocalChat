import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../models/peer_device.dart';
import '../screens/chat_screen.dart';
import '../screens/settings_screen.dart';
import '../services/ws_connection_service.dart';

class NearbyDevicesScreen extends StatefulWidget {
  final AppServices services;

  const NearbyDevicesScreen({
    super.key,
    required this.services,
  });

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen> {
  final Map<String, PeerDevice> _peersById = {};
  Timer? _pollTimer;

  final TextEditingController _displayNameController =
      TextEditingController();

  bool _loading = true;
  String? _error;
  String _status = 'Starting...';
  bool _showingConsent = false;

  static const Duration _discoverTimeout = Duration(seconds: 2);
  static const Duration _pollInterval = Duration(seconds: 2);
  static const Duration _pruneAfter = Duration(seconds: 6);

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    setState(() {
      _loading = true;
      _error = null;
      _status = 'Loading identity...';
    });

    try {
      final me = widget.services.identity;
      final presence = widget.services.presence;
      final connections = widget.services.connections;
      if (me == null || presence == null || connections == null) {
        throw StateError('App services not started.');
      }
      _displayNameController.text = me.displayName;

      connections.onConnectionChanged = (_, _) {
        if (!mounted) return;
        setState(() {});
      };
      connections.onIncomingConnectionRequested = (peerId, state) {
        if (!mounted) return;
        final peer = state.peer;
        if (_showingConsent) return;
        _showingConsent = true;
        unawaited(_promptIncoming(peerId, peer));
      };

      _status = 'Searching nearby devices...';

      // First discovery immediately.
      await _pollOnce();
      _pollTimer?.cancel();
      _pollTimer = Timer.periodic(_pollInterval, (_) => _pollOnce());
    } catch (e) {
      _error = e.toString();
      _status = 'Some features may not work.';
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _pollOnce() async {
    final presence = widget.services.presence;
    final me = widget.services.identity;
    if (presence == null || me == null) return;

    final now = DateTime.now();

    try {
      final discovered = await presence.discoverOnce(
        timeout: _discoverTimeout,
      );

      for (final peer in discovered) {
        _peersById[peer.userId] = peer;
      }

      // Prune peers that haven't been seen recently.
      _peersById.removeWhere(
        (_, peer) => now.difference(peer.lastSeen) > _pruneAfter,
      );

      if (!mounted) return;
      setState(() {
        _status = 'Searching nearby devices...';
      });
    } catch (_) {
      // Best-effort: ignore transient network failures.
      if (!mounted) return;
      setState(() {
        _status = 'Discovery failed; retrying...';
      });
    }
  }

  Future<void> _saveDisplayName() async {
    final newName = _displayNameController.text.trim();
    if (newName.isEmpty) return;

    await widget.services.setDisplayName(newName);
    await _pollOnce();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _promptIncoming(String peerId, PeerDevice peer) async {
    if (!mounted) return;
    final connections = widget.services.connections;
    final me = widget.services.identity;
    if (connections == null || me == null) return;

    final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) {
            return AlertDialog(
              title: const Text('Connection request'),
              content: Text('${peer.displayName} wants to chat with you.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('Decline'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('Accept'),
                ),
              ],
            );
          },
        ) ??
        false;

    _showingConsent = false;
    if (!mounted) return;

    if (accepted) {
      connections.acceptIncoming(peerId);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            me: me,
            peer: peer,
            connections: connections,
            downloadDir: widget.services.settings?.downloadDir,
          ),
        ),
      );
    } else {
      connections.rejectIncoming(peerId);
    }
  }

  Future<void> _connectTo(PeerDevice peer) async {
    final connections = widget.services.connections;
    if (connections == null) return;

    setState(() {
      _status = 'Connecting to ${peer.displayName}...';
    });

    final state = await connections.connectToPeer(peer);

    if (!mounted) return;
    setState(() {
      _status = 'Searching nearby devices...';
    });

    final me = widget.services.identity;
    if (state.status == PeerConnectionStatus.connected && me != null) {
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
            me: me,
            peer: peer,
            connections: connections,
            downloadDir: widget.services.settings?.downloadDir,
          ),
        ),
      );
    }
  }

  Widget _statusChipForPeer(PeerDevice peer) {
    final state = widget.services.connections?.getConnection(peer.userId);
    final status = state?.status ?? PeerConnectionStatus.disconnected;

    Color bg;
    Color fg;
    String label;

    switch (status) {
      case PeerConnectionStatus.connected:
        bg = Colors.green.withValues(alpha: 0.12);
        fg = Colors.green.shade800;
        label = 'Connected';
        break;
      case PeerConnectionStatus.connecting:
        bg = Colors.blue.withValues(alpha: 0.12);
        fg = Colors.blue.shade800;
        label = 'Connecting';
        break;
      case PeerConnectionStatus.incomingRequest:
        bg = Colors.orange.withValues(alpha: 0.12);
        fg = Colors.orange.shade900;
        label = 'Request';
        break;
      case PeerConnectionStatus.failed:
        bg = Colors.red.withValues(alpha: 0.12);
        fg = Colors.red.shade800;
        label = 'Failed';
        break;
      case PeerConnectionStatus.disconnected:
        bg = Colors.grey.withValues(alpha: 0.12);
        fg = Colors.grey.shade800;
        label = 'Disconnected';
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w600,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _unreadBadge(PeerDevice peer) {
    final unread = widget.services.chatStorage?.getUnreadCount(peer.userId) ?? 0;
    if (unread <= 0) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(right: 10),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        unread > 99 ? '99+' : unread.toString(),
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimary,
          fontWeight: FontWeight.w800,
          fontSize: 12,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final peers = _peersById.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
        actions: [
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(services: widget.services),
                ),
              );
            },
            icon: const Icon(Icons.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              _status,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 12),
            if (_error != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            const SizedBox(height: 16),
            TextField(
              controller: _displayNameController,
              enabled: !_loading,
              decoration: const InputDecoration(
                labelText: 'Your display name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _loading ? null : _saveDisplayName,
              child: const Text('Save & Update'),
            ),
            const SizedBox(height: 18),
            const Text(
              'Available users',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            if (_loading)
              const Center(child: CircularProgressIndicator())
            else if (peers.isEmpty)
              const Text('No devices found yet. Keep this screen open.')
            else
              ...peers.map(
                (peer) {
                  final state =
                      widget.services.connections?.getConnection(peer.userId);
                  final status =
                      state?.status ?? PeerConnectionStatus.disconnected;

                  return Card(
                    elevation: 0,
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: status == PeerConnectionStatus.connecting
                          ? null
                          : () => _connectTo(peer),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            CircleAvatar(
                              radius: 22,
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .primary
                                  .withValues(alpha: 0.12),
                              child: Icon(
                                Icons.person,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    peer.displayName,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${peer.ipAddress}:${peer.wsPort} • seen ${DateTime.now().difference(peer.lastSeen).inSeconds}s ago',
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                  if (state?.error != null) ...[
                                    const SizedBox(height: 4),
                                    Text(
                                      state!.error!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            _unreadBadge(peer),
                            _statusChipForPeer(peer),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}

