import 'package:flutter/material.dart';

import 'chat_screen.dart';
import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'message_store.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final DeviceInfo me;
  final DiscoveryService discovery;
  final ConnectionService connections;
  final MessageStore store;

  const HomeScreen({
    super.key,
    required this.me,
    required this.discovery,
    required this.connections,
    required this.store,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final Map<String, int> _unread = {};
  void Function(String, Map<String, dynamic>)? _prevOnMessage;

  List<_PeerEntry> _peerList = [];

  @override
  void initState() {
    super.initState();
    _refreshPeerList();

    widget.discovery.onPeersChanged = () {
      if (mounted) {
        for (final p in widget.discovery.peers) {
          widget.store.savePeerInfo(p.userId, p.name, p.ip, p.port);
        }
        _refreshPeerList();
      }
    };

    _prevOnMessage = widget.connections.onMessage;
    widget.connections.onMessage = (peerId, json) {
      _prevOnMessage?.call(peerId, json);
      if (json['type'] == 'message' || json['type'] == 'file_notify') {
        if (mounted) {
          setState(() => _unread[peerId] = (_unread[peerId] ?? 0) + 1);
        }
      }
    };
  }

  Future<void> _refreshPeerList() async {
    final onlinePeers = widget.discovery.peers;
    final onlineIds = onlinePeers.map((p) => p.userId).toSet();

    final storedInfos = await widget.store.loadAllPeerInfos();
    final storedPeerIds = await widget.store.listPeerIds();
    final offlineIds =
        storedPeerIds.where((id) => !onlineIds.contains(id)).toSet();

    final list = <_PeerEntry>[];

    for (final p in onlinePeers) {
      list.add(_PeerEntry(
        userId: p.userId,
        name: p.name,
        ip: p.ip,
        port: p.port,
        online: true,
        peer: p,
      ));
    }

    for (final id in offlineIds) {
      final info = storedInfos[id];
      if (info == null) continue;
      list.add(_PeerEntry(
        userId: id,
        name: info['name'] as String? ?? 'Unknown',
        ip: info['ip'] as String? ?? '',
        port: (info['port'] as num?)?.toInt() ?? 4041,
        online: false,
      ));
    }

    if (mounted) setState(() => _peerList = list);
  }

  @override
  void dispose() {
    widget.discovery.onPeersChanged = null;
    widget.connections.onMessage = _prevOnMessage;
    super.dispose();
  }

  void _editProfile() {
    final controller =
        TextEditingController(text: widget.me.displayName);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          final preview = controller.text.trim();
          final initial =
              preview.isNotEmpty ? preview[0].toUpperCase() : '?';

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Edit Profile'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 40,
                  backgroundColor: widget.me.avatarColor,
                  child: Text(
                    initial,
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: InputDecoration(
                    labelText: 'Display Name',
                    prefixIcon: const Icon(Icons.person),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: () async {
                  final name = controller.text.trim();
                  if (name.isNotEmpty && name != widget.me.displayName) {
                    await DeviceInfo.setName(name);
                    widget.me.displayName = name;
                    setState(() {});
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Chat'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(store: widget.store),
                ),
              );
            },
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GestureDetector(
              onTap: _editProfile,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 10,
                    backgroundColor: widget.me.avatarColor,
                    child: Text(
                      widget.me.displayName.isNotEmpty
                          ? widget.me.displayName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.me.displayName,
                    style: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.edit, size: 14, color: cs.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _peerList.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.wifi_find,
                      size: 64, color: cs.outline.withValues(alpha: 0.5)),
                  const SizedBox(height: 16),
                  Text('Searching for devices\u2026',
                      style: TextStyle(
                          color: cs.outline,
                          fontSize: 16,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 120,
                    child: LinearProgressIndicator(
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding:
                  const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
              itemCount: _peerList.length,
              separatorBuilder: (_, i) =>
                  const Divider(height: 1, indent: 72),
              itemBuilder: (context, index) {
                final entry = _peerList[index];
                final unread = _unread[entry.userId] ?? 0;

                return ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  leading: Stack(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: entry.avatarColor,
                        child: Text(
                          entry.name.isNotEmpty
                              ? entry.name[0].toUpperCase()
                              : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: entry.online ? Colors.green : cs.outline,
                            border:
                                Border.all(color: cs.surface, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  title: Text(entry.name,
                      style: TextStyle(
                        fontWeight:
                            unread > 0 ? FontWeight.w800 : FontWeight.w600,
                        color: entry.online ? null : cs.onSurfaceVariant,
                      )),
                  subtitle: Text(
                      entry.online ? entry.ip : 'Offline',
                      style: TextStyle(
                        color: entry.online ? cs.outline : cs.outline.withValues(alpha: 0.5),
                        fontSize: 13,
                        fontStyle: entry.online ? FontStyle.normal : FontStyle.italic,
                      )),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (unread > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: cs.primary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : '$unread',
                            style: TextStyle(
                              color: cs.onPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      const SizedBox(width: 4),
                      Icon(Icons.chevron_right, color: cs.outline),
                    ],
                  ),
                  onTap: () => _openChat(entry),
                );
              },
            ),
    );
  }

  void _openChat(_PeerEntry entry) {
    setState(() => _unread.remove(entry.userId));

    final peer = entry.peer ??
        PeerDevice(
          userId: entry.userId,
          name: entry.name,
          ip: entry.ip,
          port: entry.port,
          lastSeen: DateTime.now(),
        );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatScreen(
          me: widget.me,
          peer: peer,
          connections: widget.connections,
          store: widget.store,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _PeerEntry {
  final String userId;
  final String name;
  final String ip;
  final int port;
  final bool online;
  final PeerDevice? peer;

  const _PeerEntry({
    required this.userId,
    required this.name,
    required this.ip,
    required this.port,
    required this.online,
    this.peer,
  });

  Color get avatarColor {
    const palette = [
      Colors.blue,
      Colors.red,
      Colors.green,
      Colors.purple,
      Colors.orange,
      Colors.teal,
      Colors.pink,
      Colors.indigo,
      Colors.cyan,
      Colors.amber,
    ];
    return palette[userId.hashCode.abs() % palette.length];
  }
}
