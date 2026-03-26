import 'dart:async';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';
import '../models/peer_device.dart';
import '../services/chat_storage.dart';
import '../services/device_identity.dart';
import '../services/ws_connection_service.dart';
import '../services/ws_protocol.dart';

class ChatScreen extends StatefulWidget {
  final DeviceIdentity me;
  final PeerDevice peer;
  final WsConnectionService connections;

  const ChatScreen({
    super.key,
    required this.me,
    required this.peer,
    required this.connections,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  ChatStorage? _storage;
  final List<ChatMessage> _allMessages = [];
  final List<ChatMessage> _messages = [];
  static const int _pageSize = 30;
  bool _loadingMore = false;
  final TextEditingController _composer = TextEditingController();
  final FocusNode _composerFocus = FocusNode();
  final ScrollController _scroll = ScrollController();

  StreamSubscription? _messageSub;
  Timer? _typingDebounce;
  Timer? _typingStopTimer;
  Timer? _typingKeepAlive;
  bool _isTypingSent = false;
  bool _peerTyping = false;
  int? _peerLeftAtMs;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      _storage = await ChatStorage.create();
      _allMessages
        ..clear()
        ..addAll(_storage!.loadMessages(widget.peer.userId));
      _messages
        ..clear()
        ..addAll(_tail(_allMessages, _pageSize));
      await _storage!.setLastReadAtMs(
        widget.peer.userId,
        DateTime.now().millisecondsSinceEpoch,
      );

      _messageSub?.cancel();
      final connections = widget.connections;
      final prevHandler = connections.onMessageReceived;
      connections.onMessageReceived = (peerId, msg) {
        prevHandler?.call(peerId, msg);
        if (peerId != widget.peer.userId) return;
        if (msg is ChatTypingMessage) {
          if (!mounted) return;
          setState(() {
            _peerTyping = msg.isTyping && msg.fromUserId != widget.me.userId;
            if (_peerTyping) _peerLeftAtMs = null;
          });
          return;
        }
        if (msg is ChatLeaveMessage) {
          if (!mounted) return;
          setState(() {
            _peerTyping = false;
            _peerLeftAtMs = DateTime.now().millisecondsSinceEpoch;
          });
          return;
        }
        if (msg is! ChatTextMessage) return;

        final chat = ChatMessage(
          messageId: msg.messageId,
          peerUserId: widget.peer.userId,
          senderUserId: msg.fromUserId,
          senderDisplayName: msg.fromDisplayName,
          text: msg.text,
          sentAtMs: msg.sentAtMs,
          isMine: msg.fromUserId == widget.me.userId,
        );

        unawaited(_storage?.appendMessage(widget.peer.userId, chat));
        unawaited(
          _storage?.setLastReadAtMs(
            widget.peer.userId,
            DateTime.now().millisecondsSinceEpoch,
          ),
        );

        if (!mounted) return;
        final previousVisible = _messages.length;
        setState(() {
          _allMessages.add(chat);
          _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
          _messages
            ..clear()
            ..addAll(_tail(_allMessages, previousVisible + 1));
        });
        _scrollToBottomSoon();
      };

      if (!mounted) return;
      setState(() => _loading = false);
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _scrollToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _loadMoreOlder() async {
    if (_loadingMore) return;
    if (_messages.length >= _allMessages.length) return;
    if (!_scroll.hasClients) return;

    setState(() => _loadingMore = true);

    final previousMax = _scroll.position.maxScrollExtent;
    final newCount = (_messages.length + _pageSize).clamp(0, _allMessages.length);

    setState(() {
      _messages
        ..clear()
        ..addAll(_tail(_allMessages, newCount));
      _loadingMore = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final delta = _scroll.position.maxScrollExtent - previousMax;
      if (delta > 0) {
        _scroll.jumpTo(_scroll.position.pixels + delta);
      }
    });
  }

  String _formatTime(int tsMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  List<ChatMessage> _tail(List<ChatMessage> list, int n) {
    if (n <= 0) return const [];
    if (n >= list.length) return List<ChatMessage>.from(list);
    final start = list.length - n;
    return list.sublist(start);
  }

  void _onComposerChanged() {
    final hasText = _composer.text.trim().isNotEmpty;

    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      if (hasText && !_isTypingSent) {
        widget.connections.sendTyping(widget.peer.userId, isTyping: true);
        _isTypingSent = true;
        _typingKeepAlive?.cancel();
        _typingKeepAlive = Timer.periodic(const Duration(seconds: 2), (_) {
          widget.connections.sendTyping(widget.peer.userId, isTyping: true);
        });
      }
      if (!hasText && _isTypingSent) {
        widget.connections.sendTyping(widget.peer.userId, isTyping: false);
        _isTypingSent = false;
        _typingKeepAlive?.cancel();
      }
    });

    _typingStopTimer?.cancel();
    if (hasText) {
      _typingStopTimer = Timer(const Duration(seconds: 4), () {
        if (!mounted) return;
        widget.connections.sendTyping(widget.peer.userId, isTyping: false);
        _isTypingSent = false;
        _typingKeepAlive?.cancel();
      });
    }
  }

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;

    final sent = widget.connections.sendChatText(widget.peer.userId, text);
    if (sent == null) {
      setState(() => _error = 'Not connected. Go back and reconnect.');
      return;
    }

    _composer.clear();
    _composerFocus.requestFocus();
    widget.connections.sendTyping(widget.peer.userId, isTyping: false);
    _isTypingSent = false;
    _typingKeepAlive?.cancel();

    // Also append locally immediately (optimistic UI).
    final local = ChatMessage(
      messageId: sent.messageId,
      peerUserId: widget.peer.userId,
      senderUserId: widget.me.userId,
      senderDisplayName: widget.me.displayName,
      text: text,
      sentAtMs: sent.sentAtMs,
      isMine: true,
    );
    await _storage?.appendMessage(widget.peer.userId, local);
    await _storage?.setLastReadAtMs(
      widget.peer.userId,
      DateTime.now().millisecondsSinceEpoch,
    );

    if (!mounted) return;
    final previousVisible = _messages.length;
    setState(() {
      _allMessages.add(local);
      _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
      _messages
        ..clear()
        ..addAll(_tail(_allMessages, previousVisible + 1));
    });
    _scrollToBottomSoon();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _typingDebounce?.cancel();
    _typingStopTimer?.cancel();
    _typingKeepAlive?.cancel();
    widget.connections.sendLeaveChat(widget.peer.userId);
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.connections.getConnection(widget.peer.userId);
    final connected = state?.status == PeerConnectionStatus.connected;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peer.displayName),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              connected ? 'Connected' : 'Disconnected',
              style: TextStyle(
                color: connected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.error.withValues(alpha: 0.12),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : NotificationListener<ScrollNotification>(
                      onNotification: (n) {
                        if (n.metrics.pixels <= 24) {
                          unawaited(_loadMoreOlder());
                        }
                        return false;
                      },
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(12),
                        itemCount: _messages.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (_loadingMore && index == 0) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                ),
                              ),
                            );
                          }

                          final actualIndex = _loadingMore ? index - 1 : index;
                          if (actualIndex < 0 || actualIndex >= _messages.length) {
                            return const SizedBox.shrink();
                          }

                        final m = _messages[actualIndex];
                        final isMine = m.isMine;

                        return Align(
                          alignment:
                              isMine ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            constraints: const BoxConstraints(maxWidth: 520),
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: isMine
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (!isMine)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4),
                                    child: Text(
                                      m.senderDisplayName,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                Text(
                                  m.text,
                                  style: TextStyle(
                                    color: isMine
                                        ? Theme.of(context).colorScheme.onPrimary
                                        : Theme.of(context).colorScheme.onSurface,
                                    fontSize: 15,
                                    height: 1.25,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    _formatTime(m.sentAtMs),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: (isMine
                                              ? Theme.of(context)
                                                  .colorScheme
                                                  .onPrimary
                                              : Theme.of(context)
                                                  .colorScheme
                                                  .onSurfaceVariant)
                                          .withValues(alpha: 0.72),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                        },
                      ),
                    ),
            ),
            if (_peerTyping)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${widget.peer.displayName} is typing…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            if (!_peerTyping && _peerLeftAtMs != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${widget.peer.displayName} left the chat',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      focusNode: _composerFocus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        filled: true,
                        fillColor: Theme.of(context)
                            .colorScheme
                            .surfaceContainerHighest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(999),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

