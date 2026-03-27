import 'package:flutter/material.dart';

import 'chat_screen.dart';
import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'message_store.dart';

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

  @override
  void initState() {
    super.initState();
    widget.discovery.onPeersChanged = () {
      if (mounted) setState(() {});
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
    final peers = widget.discovery.peers;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Local Chat'),
        centerTitle: true,
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
      body: peers.isEmpty
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
              itemCount: peers.length,
              separatorBuilder: (_, i) =>
                  const Divider(height: 1, indent: 72),
              itemBuilder: (context, index) {
                final peer = peers[index];
                final unread = _unread[peer.userId] ?? 0;
                final isOnline =
                    widget.connections.isConnected(peer.userId);

                return ListTile(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  leading: Stack(
                    children: [
                      CircleAvatar(
                        radius: 22,
                        backgroundColor: peer.avatarColor,
                        child: Text(
                          peer.name.isNotEmpty
                              ? peer.name[0].toUpperCase()
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
                            color: isOnline ? Colors.green : cs.outline,
                            border:
                                Border.all(color: cs.surface, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  title: Text(peer.name,
                      style: TextStyle(
                        fontWeight:
                            unread > 0 ? FontWeight.w800 : FontWeight.w600,
                      )),
                  subtitle: Text(peer.ip,
                      style: TextStyle(color: cs.outline, fontSize: 13)),
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
                  onTap: () => _openChat(peer),
                );
              },
            ),
    );
  }

  void _openChat(PeerDevice peer) {
    setState(() => _unread.remove(peer.userId));
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
