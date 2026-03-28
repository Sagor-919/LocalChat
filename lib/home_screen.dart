import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'android_app_control.dart';
import 'app_branding.dart';
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
  /// Serializes overlapping [_refreshPeerList] runs so a slower, older refresh
  /// cannot overwrite the UI after a newer discovery snapshot.
  int _peerRefreshGeneration = 0;

  /// Coalesce rapid UDP discovery callbacks into one refresh + disk pass.
  Timer? _discoveryDebounce;

  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  /// Null until the first [Connectivity.checkConnectivity] completes.
  List<ConnectivityResult>? _connectivityResults;

  bool get _connectivityOffline =>
      _connectivityResults != null &&
      _connectivityResults!.length == 1 &&
      _connectivityResults!.first == ConnectivityResult.none;

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

    widget.discovery.onPeersChanged = _onDiscoveryPeersChanged;

    unawaited(_initConnectivity());

    _prevOnMessage = widget.connections.onMessage;
    widget.connections.onMessage = (peerId, json) {
      _prevOnMessage?.call(peerId, json);
      final type = json['type'] as String?;
      if (type == 'message' || type == 'file_notify') {
        if (mounted) {
          setState(() {
            _unread[peerId] = (_unread[peerId] ?? 0) + 1;
            if (type == 'message') {
              if (json['enc'] == true) {
                _lastMsgTime[peerId] = (json['time'] as num?)?.toInt() ??
                    DateTime.now().millisecondsSinceEpoch;
                unawaited(_syncPreviewFromStore(peerId));
              } else {
                _lastMsg[peerId] = json['text'] as String? ?? '';
                _lastMsgTime[peerId] = (json['time'] as num?)?.toInt() ??
                    DateTime.now().millisecondsSinceEpoch;
              }
            } else {
              _lastMsg[peerId] = 'Incoming file\u2026';
              _lastMsgTime[peerId] = DateTime.now().millisecondsSinceEpoch;
            }
          });
        }
      }
    };
  }

  Future<void> _initConnectivity() async {
    final c = Connectivity();
    try {
      final r = await c.checkConnectivity();
      if (mounted) {
        setState(() => _connectivityResults = r);
        unawaited(_refreshPeerList());
      }
    } catch (_) {}
    _connectivitySub = c.onConnectivityChanged.listen((r) {
      if (!mounted) return;
      setState(() => _connectivityResults = r);
      unawaited(_refreshPeerList());
    });
  }

  void _onDiscoveryPeersChanged() {
    _discoveryDebounce?.cancel();
    _discoveryDebounce = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      for (final p in widget.discovery.peers) {
        unawaited(widget.store.savePeerInfo(p.userId, p.name, p.ip, p.port));
      }
      unawaited(_refreshPeerList());
    });
  }

  Future<void> _refreshPeerList() async {
    final gen = ++_peerRefreshGeneration;
    final networkDown = _connectivityOffline;
    final discoveryPeers = widget.discovery.peers;
    final onlineIds = networkDown
        ? <String>{}
        : discoveryPeers.map((p) => p.userId).toSet();

    final storedInfos = await widget.store.loadAllPeerInfos();
    if (!mounted || gen != _peerRefreshGeneration) return;

    final conversationPeerIds =
        await widget.store.listPeerIdsWithConversation();
    if (!mounted || gen != _peerRefreshGeneration) return;

    final offlineIds = conversationPeerIds
        .where((id) => !onlineIds.contains(id))
        .toSet();

    final list = <_PeerEntry>[];

    if (!networkDown) {
      for (final p in discoveryPeers) {
        list.add(_PeerEntry(
          userId: p.userId,
          name: p.name,
          ip: p.ip,
          port: p.port,
          online: true,
          peer: p,
        ));
      }
    }

    for (final id in offlineIds) {
      final info = storedInfos[id];
      list.add(_PeerEntry(
        userId: id,
        name: info?['name'] as String? ?? 'Unknown',
        ip: info?['ip'] as String? ?? '',
        port: (info?['port'] as num?)?.toInt() ?? 4041,
        online: false,
      ));
    }

    if (networkDown) {
      for (final p in discoveryPeers) {
        if (conversationPeerIds.contains(p.userId)) continue;
        list.add(_PeerEntry(
          userId: p.userId,
          name: p.name,
          ip: p.ip,
          port: p.port,
          online: false,
          peer: p,
        ));
      }
    }

    if (!mounted || gen != _peerRefreshGeneration) return;
    setState(() => _peerList = list);
    await _hydratePreviewsFromStore(list, gen);
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

  Future<void> _hydratePreviewsFromStore(
      List<_PeerEntry> entries, int gen) async {
    for (final e in entries) {
      final list = await widget.store.load(e.userId);
      if (!mounted || gen != _peerRefreshGeneration) return;
      if (list.isEmpty) continue;
      list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      final last = list.last;
      _lastMsg[e.userId] = _subtitleForMessage(last);
      _lastMsgTime[e.userId] = last.timestamp;
    }
    if (!mounted || gen != _peerRefreshGeneration) return;
    setState(() {});
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    _discoveryDebounce?.cancel();
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
                _RingAvatar(letter: initial, radius: 40, fontSize: 32, online: true),
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
              child: Row(
                children: [
                  const AppIconTile(size: 30),
                  const SizedBox(width: 12),
                  Text(
                    'Chats',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: _buildChatsBody(context, cs),
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

  Widget _buildChatsBody(BuildContext context, ColorScheme cs) {
    if (_peerList.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_find,
                size: 56, color: cs.outline.withValues(alpha: 0.4)),
            const SizedBox(height: 12),
            Text(
              'Searching for devices\u2026',
              style: TextStyle(
                color: cs.outline,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: 100,
              child: LinearProgressIndicator(
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ],
        ),
      );
    }

    /// Within each section: latest message first; no history sorts last, then name.
    int activityCmp(_PeerEntry a, _PeerEntry b) {
      const none = -1;
      final tva = _lastMsgTime[a.userId] ?? none;
      final tvb = _lastMsgTime[b.userId] ?? none;
      if (tva != tvb) return tvb.compareTo(tva);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    }

    final online = _peerList.where((e) => e.online).toList()..sort(activityCmp);
    final offline =
        _peerList.where((e) => !e.online).toList()..sort(activityCmp);

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final children = <Widget>[];

    if (online.isNotEmpty) {
      children.add(_buildChatsSectionHeader(context, 'Online', cs, isDark));
      for (final e in online) {
        children.add(
          _buildChatTile(context, e, showPresenceDot: true),
        );
      }
    }

    if (offline.isNotEmpty) {
      if (online.isNotEmpty) {
        children.add(_buildChatsSectionDivider(cs));
      }
      children.add(
        _buildChatsSectionHeader(
          context,
          'Offline',
          cs,
          isDark,
          muted: true,
        ),
      );
      for (final e in offline) {
        children.add(
          _buildChatTile(context, e, showPresenceDot: false),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      children: children,
    );
  }

  Widget _buildChatsSectionHeader(
    BuildContext context,
    String title,
    ColorScheme cs,
    bool isDark, {
    bool muted = false,
  }) {
    final onlineStyle = isDark
        ? cs.primaryContainer.withValues(alpha: 0.45)
        : const Color(0xFF2E7D32).withValues(alpha: 0.14);
    final onlineFg =
        isDark ? cs.onPrimaryContainer : const Color(0xFF1B5E20);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: muted
                  ? cs.surfaceContainerHighest.withValues(alpha: 0.75)
                  : onlineStyle,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: muted
                    ? cs.outlineVariant.withValues(alpha: 0.35)
                    : (isDark
                        ? cs.primary.withValues(alpha: 0.35)
                        : const Color(0xFF2E7D32).withValues(alpha: 0.25)),
              ),
            ),
            child: Text(
              title.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.9,
                color: muted ? cs.outline : onlineFg,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatsSectionDivider(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      child: Divider(
        height: 1,
        thickness: 1,
        color: cs.outlineVariant.withValues(alpha: 0.45),
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final offline = _connectivityOffline;
    final advertising = widget.discovery.isAdvertisingActive;
    final known = _connectivityResults != null;
    final showOnline = !known
        ? advertising
        : (!offline && advertising);
    final statusLabel = !known
        ? 'Checking network\u2026'
        : (offline
            ? 'Offline'
            : (advertising ? 'Online' : 'Limited'));

    return Material(
      color: isDark ? cs.surfaceContainerHigh : Colors.white,
      elevation: isDark ? 0 : 1.5,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: _editProfile,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _RingAvatar(
                letter: widget.me.displayName.isNotEmpty
                    ? widget.me.displayName[0].toUpperCase()
                    : '?',
                radius: 28,
                fontSize: 22,
                online: showOnline,
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
                    Row(
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: !known
                                ? cs.outlineVariant
                                : (showOnline
                                    ? _RingAvatar._onlineGreen
                                    : (offline
                                        ? (isDark
                                            ? const Color(0xFF757575)
                                            : const Color(0xFFBDBDBD))
                                        : Colors.amber.shade700)),
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          statusLabel,
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
        ),
      ),
    );
  }

  Widget _buildChatTile(
    BuildContext context,
    _PeerEntry entry, {
    bool showPresenceDot = false,
  }) {
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
                _RingAvatar(
                  letter: entry.name.isNotEmpty
                      ? entry.name[0].toUpperCase()
                      : '?',
                  radius: 24,
                  fontSize: 18,
                  online: entry.online,
                  isDark: isDark,
                  showPresenceDot: showPresenceDot && entry.online,
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

class _RingAvatar extends StatelessWidget {
  static const _onlineGreen = Color(0xFF43A047);
  static const _offlineGreyLight = Color(0xFF9E9E9E);
  static const _offlineGreyDark = Color(0xFF757575);

  final String letter;
  final double radius;
  final double fontSize;
  final bool online;
  final bool isDark;
  final bool showPresenceDot;

  const _RingAvatar({
    required this.letter,
    required this.radius,
    required this.fontSize,
    required this.online,
    this.isDark = false,
    this.showPresenceDot = false,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = isDark || Theme.of(context).brightness == Brightness.dark;
    final fill = dark ? cs.surfaceContainerHighest : const Color(0xFFE8E8EF);
    final ring =
        online ? _onlineGreen : (dark ? _offlineGreyDark : _offlineGreyLight);

    final circle = Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(color: ring, width: 2.5),
        boxShadow: [
          if (!dark)
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
        ],
      ),
      child: Center(
        child: Text(
          letter,
          style: TextStyle(
            color: cs.onSurface,
            fontWeight: FontWeight.w700,
            fontSize: fontSize,
          ),
        ),
      ),
    );

    if (!showPresenceDot || !online) {
      return circle;
    }

    final dotSize = (radius * 0.5).clamp(8.0, 14.0);
    return SizedBox(
      width: radius * 2,
      height: radius * 2,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          circle,
          Positioned(
            right: -0.5,
            bottom: -0.5,
            child: Container(
              width: dotSize,
              height: dotSize,
              decoration: BoxDecoration(
                color: _onlineGreen,
                shape: BoxShape.circle,
                border: Border.all(color: fill, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ],
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
