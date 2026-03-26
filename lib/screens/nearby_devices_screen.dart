import 'dart:async';

import 'package:flutter/material.dart';

import '../models/peer_device.dart';
import '../services/device_identity.dart';
import '../services/mdns_presence_service.dart';
import '../services/ws_connection_service.dart';

class NearbyDevicesScreen extends StatefulWidget {
  const NearbyDevicesScreen({super.key});

  @override
  State<NearbyDevicesScreen> createState() => _NearbyDevicesScreenState();
}

class _NearbyDevicesScreenState extends State<NearbyDevicesScreen> {
  static const int kPhase1WebSocketPort = 4040;

  DeviceIdentityRepository? _identityRepo;
  DeviceIdentity? _identity;
  MdnsPresenceService? _presence;
  WsConnectionService? _connections;

  final Map<String, PeerDevice> _peersById = {};
  Timer? _pollTimer;

  final TextEditingController _displayNameController =
      TextEditingController();

  bool _loading = true;
  String? _error;
  String _status = 'Starting...';

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
      _identityRepo = await DeviceIdentityRepository.create();
      _identity = await _identityRepo!.loadOrCreate();
      _displayNameController.text = _identity!.displayName;

      _connections = WsConnectionService(
        identity: _identity!,
        listenPort: kPhase1WebSocketPort,
        onConnectionChanged: (_, _) {
          if (!mounted) return;
          setState(() {});
        },
      );
      await _connections!.startServer();

      _presence = MdnsPresenceService(
        identity: _identity!,
        websocketPort: kPhase1WebSocketPort,
      );

      _status = 'Advertising on local network...';
      try {
        await _presence!.startAdvertising();
        _status = 'Searching nearby devices...';
      } catch (e) {
        // Advertising may fail due to OS permissions; discovery can still work.
        _error = 'Advertising failed: $e';
        _status = 'Searching nearby devices (advertising disabled)...';
      }

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
    if (_presence == null || _identity == null) return;

    final now = DateTime.now();

    try {
      final discovered = await _presence!.discoverOnce(
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
    final repo = _identityRepo;
    final presence = _presence;
    if (repo == null || presence == null || _identity == null) return;

    final newName = _displayNameController.text.trim();
    if (newName.isEmpty) return;

    await repo.setDisplayName(newName);
    final updatedIdentity = await repo.loadOrCreate();

    // Restart mDNS advertising to update TXT record values.
    try {
      await presence.stopAdvertising();
    } catch (_) {
      // ignore; we'll try restarting anyway.
    }

    _identity = updatedIdentity;
    _presence = MdnsPresenceService(
      identity: _identity!,
      websocketPort: kPhase1WebSocketPort,
    );

    await _presence!.startAdvertising();
    await _pollOnce();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _presence?.close();
    _connections?.close();
    _displayNameController.dispose();
    super.dispose();
  }

  Future<void> _connectTo(PeerDevice peer) async {
    final connections = _connections;
    if (connections == null) return;

    setState(() {
      _status = 'Connecting to ${peer.displayName}...';
    });

    await connections.connectToPeer(peer);

    if (!mounted) return;
    setState(() {
      _status = 'Searching nearby devices...';
    });
  }

  Widget _statusChipForPeer(PeerDevice peer) {
    final state = _connections?.getConnection(peer.userId);
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

  @override
  Widget build(BuildContext context) {
    final peers = _peersById.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Nearby Devices'),
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
                  final state = _connections?.getConnection(peer.userId);
                  final status = state?.status ?? PeerConnectionStatus.disconnected;

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

