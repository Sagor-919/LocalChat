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
  final List<ChatMessage> _messages = [];
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();

  StreamSubscription? _messageSub;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      _storage = await ChatStorage.create();
      _messages
        ..clear()
        ..addAll(_storage!.loadMessages(widget.peer.userId));

      _messageSub?.cancel();
      final connections = widget.connections;
      final prevHandler = connections.onMessageReceived;
      connections.onMessageReceived = (peerId, msg) {
        prevHandler?.call(peerId, msg);
        if (peerId != widget.peer.userId) return;
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

        if (!mounted) return;
        setState(() {
          _messages.add(chat);
          _messages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
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

  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty) return;

    final ok = widget.connections.sendChatText(widget.peer.userId, text);
    if (!ok) {
      setState(() => _error = 'Not connected. Go back and reconnect.');
      return;
    }

    _composer.clear();

    // Also append locally immediately (optimistic UI).
    final local = ChatMessage(
      messageId: DateTime.now().microsecondsSinceEpoch.toString(),
      peerUserId: widget.peer.userId,
      senderUserId: widget.me.userId,
      senderDisplayName: widget.me.displayName,
      text: text,
      sentAtMs: DateTime.now().millisecondsSinceEpoch,
      isMine: true,
    );
    await _storage?.appendMessage(widget.peer.userId, local);

    if (!mounted) return;
    setState(() {
      _messages.add(local);
      _messages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
    });
    _scrollToBottomSoon();
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    _composer.dispose();
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
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.all(12),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final m = _messages[index];
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
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _composer,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Message',
                        border: OutlineInputBorder(),
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

