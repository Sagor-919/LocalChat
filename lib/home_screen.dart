import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'android_app_control.dart';
import 'chat_screen.dart';
import 'connection_service.dart';
import 'device.dart';
import 'discovery_service.dart';
import 'message_model.dart';
import 'message_store.dart';
import 'settings_screen.dart';
import 'transfer_manager.dart';

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
  final Map<String, String> _lastMsg = {};
  final Map<String, int> _lastMsgTime = {};
  void Function(String, Map<String, dynamic>)? _prevOnMessage;

  List<_PeerEntry> _peerList = [];
  StreamSubscription<FileMessageEvent>? _fileMsgSub;

  void _onMessageHistoryRevision() {
    final sig = widget.store.consumePendingHistoryClear();
    if (sig == null) return;
    if (sig.all) {
      _lastMsg.clear();
      _lastMsgTime.clear();
      _unread.clear();
      unawaited(_refreshPeerList());
    } else {
      final id = sig.peerId;
      if (id != null) {
        _lastMsg.remove(id);
        _lastMsgTime.remove(id);
        _unread.remove(id);
        if (mounted) setState(() {});
      }
    }
  }

  @override
  void initState() {
    super.initState();
    widget.store.messageHistoryRevision.addListener(_onMessageHistoryRevision);
    _refreshPeerList();

    _fileMsgSub = TransferManager.instance.fileMessages.listen((e) {
      unawaited(_syncPreviewFromStore(e.peerId));
    });

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
      final type = json['type'] as String?;
      if (type == 'message' || type == 'file_notify') {
        if (mounted) {
          setState(() {
            _unread[peerId] = (_unread[peerId] ?? 0) + 1;
            if (type == 'message') {
              _lastMsg[peerId] = json['text'] as String? ?? '';
              _lastMsgTime[peerId] = (json['time'] as num?)?.toInt() ??
                  DateTime.now().millisecondsSinceEpoch;
            } else {
              _lastMsg[peerId] = 'Incoming file\u2026';
              _lastMsgTime[peerId] = DateTime.now().millisecondsSinceEpoch;
            }
          });
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
    await _hydratePreviewsFromStore(list);
  }

  String _subtitleForMessage(ChatMessage m) {
    final name = m.attachmentName;
    if (name != null && name.isNotEmpty) {
      return 'File: $name';
    }
    return m.text;
  }

  Future<void> _syncPreviewFromStore(String peerId) async {
    final list = await widget.store.load(peerId);
    if (!mounted) return;
    if (list.isEmpty) return;
    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final last = list.last;
    setState(() {
      _lastMsgTime[peerId] = last.timestamp;
      _lastMsg[peerId] = _subtitleForMessage(last);
    });
  }

  Future<void> _hydratePreviewsFromStore(List<_PeerEntry> entries) async {
    for (final e in entries) {
      final list = await widget.store.load(e.userId);
      if (!mounted) return;
      if (list.isEmpty) continue;
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final last = list.last;
      _lastMsg[e.userId] = _subtitleForMessage(last);
      _lastMsgTime[e.userId] = last.timestamp;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.messageHistoryRevision.removeListener(_onMessageHistoryRevision);
    _fileMsgSub?.cancel();
    widget.discovery.onPeersChanged = null;
    widget.connections.onMessage = _prevOnMessage;
    super.dispose();
  }

  void _editProfile() {
    final controller = TextEditingController(text: widget.me.displayName);

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
                _GradientAvatar(letter: initial, radius: 40, fontSize: 32),
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

  String _timeAgo(int ms) {
    final diff = DateTime.now().millisecondsSinceEpoch - ms;
    final mins = diff ~/ 60000;
    if (mins < 1) return 'now';
    if (mins < 60) return '${mins}m ago';
    final hours = mins ~/ 60;
    if (hours < 24) return '${hours}h ago';
    final days = hours ~/ 24;
    return '${days}d ago';
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final home = Scaffold(
      backgroundColor: isDark ? cs.surface : const Color(0xFFF5F5FA),
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: _buildProfileCard(context),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
              child: Text(
                'Chats',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: cs.onSurface,
                ),
              ),
            ),
            Expanded(
              child: _peerList.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.wifi_find,
                              size: 56,
                              color: cs.outline.withValues(alpha: 0.4)),
                          const SizedBox(height: 12),
                          Text('Searching for devices\u2026',
                              style: TextStyle(
                                  color: cs.outline,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w500)),
                          const SizedBox(height: 10),
                          SizedBox(
                            width: 100,
                            child: LinearProgressIndicator(
                              borderRadius: BorderRadius.circular(99),
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      itemCount: _peerList.length,
                      itemBuilder: (context, index) {
                        final entry = _peerList[index];
                        return _buildChatTile(context, entry);
                      },
                    ),
            ),
          ],
        ),
      ),
    );

    final useAndroidBackToBg =
        !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    if (!useAndroidBackToBg) return home;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        unawaited(moveAndroidTaskToBackground());
      },
      child: home,
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
        ],
      ),
      child: Row(
        children: [
          _GradientAvatar(
            letter: widget.me.displayName.isNotEmpty
                ? widget.me.displayName[0].toUpperCase()
                : '?',
            radius: 28,
            fontSize: 22,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.me.displayName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                GestureDetector(
                  onTap: _editProfile,
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        'Online',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: cs.outline,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.edit, size: 13, color: cs.outline),
                    ],
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SettingsScreen(store: widget.store),
                ),
              );
            },
            icon: Icon(Icons.settings, color: cs.onSurfaceVariant),
            tooltip: 'Settings',
          ),
        ],
      ),
    );
  }

  Widget _buildChatTile(BuildContext context, _PeerEntry entry) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final unread = _unread[entry.userId] ?? 0;
    final lastMsg = _lastMsg[entry.userId];
    final lastTime = _lastMsgTime[entry.userId];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isDark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(16),
        elevation: isDark ? 0 : 1,
        shadowColor: Colors.black12,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openChat(entry),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Stack(
                  children: [
                    _GradientAvatar(
                      letter: entry.name.isNotEmpty
                          ? entry.name[0].toUpperCase()
                          : '?',
                      radius: 24,
                      fontSize: 18,
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        width: 13,
                        height: 13,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: entry.online ? Colors.green : cs.outline,
                          border: Border.all(
                            color: isDark
                                ? cs.surfaceContainerHigh
                                : Colors.white,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight:
                              unread > 0 ? FontWeight.w800 : FontWeight.w600,
                          color:
                              entry.online ? cs.onSurface : cs.onSurfaceVariant,
                        ),
                      ),
                      if (lastMsg != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          lastMsg,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.outline,
                            fontWeight: unread > 0
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                        ),
                      ] else if (entry.online) ...[
                        const SizedBox(height: 2),
                        Text(
                          'Online',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.outline,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 2),
                        Text(
                          'Offline',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.outline.withValues(alpha: 0.5),
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (lastTime != null)
                      Text(
                        _timeAgo(lastTime),
                        style: TextStyle(
                          fontSize: 12,
                          color: cs.outline,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    if (unread > 0) ...[
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          unread > 99 ? '99+' : '$unread',
                          style: TextStyle(
                            color: cs.onPrimary,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right,
                    size: 20, color: cs.outline.withValues(alpha: 0.5)),
              ],
            ),
          ),
        ),
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
          discovery: widget.discovery,
          connections: widget.connections,
          store: widget.store,
        ),
      ),
    );
  }
}

class _GradientAvatar extends StatelessWidget {
  final String letter;
  final double radius;
  final double fontSize;

  const _GradientAvatar({
    required this.letter,
    required this.radius,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [Color(0xFF00C9FF), Color(0xFF92FE9D)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: fontSize,
          ),
        ),
      ),
    );
  }
}

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
}
