// This is the updated home_screen.dart with PeerConnectionTracker

import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../android_app_control.dart';
import '../android_share_inbound.dart';
import '../app_branding.dart';
import '../chat_screen.dart';
import '../connection_service.dart';
import '../device.dart';
import '../discovery_service.dart';
import '../message_model.dart';
import '../message_store.dart';
import '../services/peer_connection_tracker.dart';
import '../settings_screen.dart';
import '../transfer_manager.dart';

/// Enhanced home screen using PeerConnectionTracker for robust state management.
///
/// Improvements:
/// 1. Uses tracker instead of manual peer list management
/// 2. Only rebuilds for changed peers (incremental updates)
/// 3. Shows connection state visually (online/transitioning/offline)
/// 4. Handles reconnections automatically
/// 5. No duplicate entries after app clear
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

  late PeerConnectionTracker _peerTracker;

  StreamSubscription<FileMessageEvent>? _fileMsgSub;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  List<ConnectivityResult>? _connectivityResults;

  bool get _connectivityOffline =>
      _connectivityResults != null &&
      _connectivityResults!.length == 1 &&
      _connectivityResults!.first == ConnectivityResult.none;

  @override
  void initState() {
    super.initState();
    
    // Initialize peer connection tracker
    _peerTracker = PeerConnectionTracker(
      discovery: widget.discovery,
      connections: widget.connections,
    );
    
    // Listen to tracker changes for rebuilds
    _peerTracker.addListener(_onPeerTrackerChanged);

    // Setup message store listener
    widget.store.messageHistoryRevision.addListener(_onMessageHistoryRevision);

    // Setup file transfer listener
    _fileMsgSub = TransferManager.instance.fileMessages.listen((e) {
      unawaited(_syncPreviewFromStore(e.peerId));
    });

    // Setup connection message handler
    _prevOnMessage = widget.connections.onMessage;
    widget.connections.onMessage = (peerId, json) {
      _prevOnMessage?.call(peerId, json);
      _handleIncomingMessage(peerId, json);
    };

    // Setup connectivity listener
    unawaited(_initConnectivity());

    // Initial load
    _loadMessagePreviews();
  }

  /// Called when peer connection state changes.
  /// 
  /// Rebuilds UI to reflect new peer states.
  void _onPeerTrackerChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  /// Called when message history is cleared.
  void _onMessageHistoryRevision() {
    final sig = widget.store.consumePendingHistoryClear();
    if (sig == null) return;
    
    if (sig.all) {
      _lastMsg.clear();
      _lastMsgTime.clear();
      _unread.clear();
    } else {
      final id = sig.peerId;
      if (id != null) {
        _lastMsg.remove(id);
        _lastMsgTime.remove(id);
        _unread.remove(id);
      }
    }

    if (mounted) setState(() {});
  }

  /// Handle incoming message and update preview.
  void _handleIncomingMessage(String peerId, Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type != 'message' && type != 'file_notify') return;

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
          _lastMsg[peerId] = 'Incoming file…';
          _lastMsgTime[peerId] = DateTime.now().millisecondsSinceEpoch;
        }
      });
    }
  }

  /// Initialize connectivity monitoring.
  Future<void> _initConnectivity() async {
    final c = Connectivity();
    try {
      final r = await c.checkConnectivity();
      if (mounted) {
        setState(() => _connectivityResults = r);
      }
    } catch (_) {}

    _connectivitySub = c.onConnectivityChanged.listen((r) {
      if (!mounted) return;
      setState(() => _connectivityResults = r);
    });
  }

  /// Load message previews for all peers.
  Future<void> _loadMessagePreviews() async {
    for (final state in _peerTracker.getAllPeers()) {
      await _syncPreviewFromStore(state.peer.userId);
    }
  }

  /// Sync message preview from store for a peer.
  Future<void> _syncPreviewFromStore(String peerId) async {
    final list = await widget.store.load(peerId);
    if (!mounted) return;
    if (list.isEmpty) return;

    list.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final last = list.last;

    if (mounted) {
      setState(() {
        _lastMsgTime[peerId] = last.timestamp;
        _lastMsg[peerId] = _subtitleForMessage(last);
      });
    }
  }

  /// Get display text for message.
  String _subtitleForMessage(ChatMessage m) {
    final name = m.attachmentName;
    if (name != null && name.isNotEmpty) {
      return 'File: $name';
    }
    return m.text;
  }

  /// Format timestamp as relative time.
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
  void dispose() {
    _connectivitySub?.cancel();
    _fileMsgSub?.cancel();
    _peerTracker.removeListener(_onPeerTrackerChanged);
    _peerTracker.dispose();
    widget.store.messageHistoryRevision.removeListener(_onMessageHistoryRevision);
    widget.connections.onMessage = _prevOnMessage;
    super.dispose();
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
            // Android share indicator
            if (!kIsWeb && Platform.isAndroid)
              ValueListenableBuilder<int>(
                valueListenable: AndroidShareInbound.pendingRevision,
                builder: (context, rev, child) {
                  final n = AndroidShareInbound.queuedCount;
                  if (n <= 0) return const SizedBox.shrink();
                  return _buildShareIndicator(context, cs, n);
                },
              ),

            // Profile card
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: _buildProfileCard(context),
            ),

            // Chats header
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

            // Peer list
            Expanded(
              child: _buildChatsList(context, cs),
            ),
          ],
        ),
      ),
    );

    // Android back button handling
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

  /// Build share indicator widget.
  Widget _buildShareIndicator(BuildContext context, ColorScheme cs, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.share_rounded,
                  size: 22, color: cs.onPrimaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  count == 1
                      ? '1 file shared — open a chat to attach it'
                      : '$count files shared — open a chat to attach them',
                  style: TextStyle(
                    color: cs.onPrimaryContainer,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              TextButton(
                onPressed: AndroidShareInbound.clearQueued,
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build profile card with device info and status.
  Widget _buildProfileCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final offline = _connectivityOffline;
    final advertising = widget.discovery.isAdvertisingActive;
    final known = _connectivityResults != null;
    final showOnline = !known ? advertising : (!offline && advertising);
    final statusLabel = !known
        ? 'Checking network…'
        : (offline ? 'Offline' : (advertising ? 'Online' : 'Limited'));

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
                                    ? const Color(0xFF43A047)
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

  /// Build chats list with peers organized by state.
  Widget _buildChatsList(BuildContext context, ColorScheme cs) {
    // Get peers grouped by state
    final onlinePeers = _peerTracker.getPeersByState(PeerState.online);
    final transitioningPeers =
        _peerTracker.getPeersByState(PeerState.transitioning);
    final offlinePeers = _peerTracker.getPeersByState(PeerState.offline);

    if (onlinePeers.isEmpty &&
        transitioningPeers.isEmpty &&
        offlinePeers.isEmpty) {
      return _buildEmptyState(context, cs);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final children = <Widget>[];

    // Online peers section
    if (onlinePeers.isNotEmpty) {
      children.add(
        _buildSectionHeader(context, 'Online', cs, isDark),
      );
      _sortPeersByActivity(onlinePeers);
      for (final state in onlinePeers) {
        children.add(
          _buildPeerTile(context, state, showPresenceDot: true),
        );
      }
    }

    // Transitioning peers section
    if (transitioningPeers.isNotEmpty) {
      if (onlinePeers.isNotEmpty) {
        children.add(_buildSectionDivider(cs));
      }
      children.add(
        _buildSectionHeader(
          context,
          'Reconnecting…',
          cs,
          isDark,
          muted: true,
        ),
      );
      _sortPeersByActivity(transitioningPeers);
      for (final state in transitioningPeers) {
        children.add(
          _buildPeerTile(context, state, showPresenceDot: false),
        );
      }
    }

    // Offline peers section
    if (offlinePeers.isNotEmpty) {
      if (onlinePeers.isNotEmpty || transitioningPeers.isNotEmpty) {
        children.add(_buildSectionDivider(cs));
      }
      children.add(
        _buildSectionHeader(context, 'Offline', cs, isDark, muted: true),
      );
      _sortPeersByActivity(offlinePeers);
      for (final state in offlinePeers) {
        children.add(
          _buildPeerTile(context, state, showPresenceDot: false),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      children: children,
    );
  }

  /// Build empty state when no peers available.
  Widget _buildEmptyState(BuildContext context, ColorScheme cs) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.wifi_find,
              size: 56, color: cs.outline.withValues(alpha: 0.4)),
          const SizedBox(height: 12),
          Text(
            'Searching for devices…',
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

  /// Build section header.
  Widget _buildSectionHeader(
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

  /// Build section divider.
  Widget _buildSectionDivider(ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
      child: Divider(
        height: 1,
        thickness: 1,
        color: cs.outlineVariant.withValues(alpha: 0.45),
      ),
    );
  }

  /// Sort peers by activity (last message time).
  void _sortPeersByActivity(List<PeerConnectionState> peers) {
    peers.sort((a, b) {
      final timeA = _lastMsgTime[a.peer.userId] ?? 0;
      final timeB = _lastMsgTime[b.peer.userId] ?? 0;
      if (timeA != timeB) return timeB.compareTo(timeA);
      return a.peer.name
          .toLowerCase()
          .compareTo(b.peer.name.toLowerCase());
    });
  }

  /// Build peer chat tile.
  Widget _buildPeerTile(
    BuildContext context,
    PeerConnectionState peerState, {
    bool showPresenceDot = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final peer = peerState.peer;
    final unread = _unread[peer.userId] ?? 0;
    final lastMsg = _lastMsg[peer.userId];
    final lastTime = _lastMsgTime[peer.userId];

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isDark ? cs.surfaceContainerHigh : Colors.white,
        borderRadius: BorderRadius.circular(16),
        elevation: isDark ? 0 : 1,
        shadowColor: Colors.black12,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openChat(peer),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 14,
              vertical: 12,
            ),
            child: Row(
              children: [
                // Avatar
                _RingAvatar(
                  letter: peer.name.isNotEmpty
                      ? peer.name[0].toUpperCase()
                      : '?',
                  radius: 24,
                  fontSize: 18,
                  online: peerState.state == PeerState.online,
                  isDark: isDark,
                  showPresenceDot:
                      showPresenceDot && peerState.state == PeerState.online,
                ),

                const SizedBox(width: 14),

                // Text content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name and state
                      Text(
                        peer.name,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: unread > 0
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: peerState.state == PeerState.online
                              ? cs.onSurface
                              : cs.onSurfaceVariant,
                        ),
                      ),

                      const SizedBox(height: 2),

                      // Last message or status
                      if (lastMsg != null) ...[
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
                      ] else if (peerState.state == PeerState.online) ...[
                        Text(
                          'Online',
                          style: TextStyle(
                            fontSize: 13,
                            color: cs.outline,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ] else if (peerState.state == PeerState.transitioning) ...[
                        Text(
                          'Reconnecting…',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.orange,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ] else ...[
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

                // Right side: time and unread
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

  /// Edit device profile name.
  void _editProfile() {
    final controller = TextEditingController(text: widget.me.displayName);

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setDialogState) {
          final preview = controller.text.trim();
          final initial = preview.isNotEmpty ? preview[0].toUpperCase() : '?';

          return AlertDialog(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
            title: const Text('Edit Profile'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _RingAvatar(
                  letter: initial,
                  radius: 40,
                  fontSize: 32,
                  online: true,
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
                    if (mounted) setState(() {});
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

  /// Open chat with peer.
  void _openChat(PeerDevice peer) {
    setState(() => _unread.remove(peer.userId));

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

/// Avatar widget with online indicator.
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