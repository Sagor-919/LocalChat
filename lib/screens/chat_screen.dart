import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';

import '../models/chat_message.dart';
import '../models/peer_device.dart';
import '../services/chat_storage.dart';
import '../services/device_identity.dart';
import '../services/tcp_netstreamer_file_transfer.dart';
import '../services/ws_connection_service.dart';
import '../services/ws_protocol.dart';

class ChatScreen extends StatefulWidget {
  final DeviceIdentity me;
  final PeerDevice peer;
  final WsConnectionService connections;
  final String? downloadDir;

  const ChatScreen({
    super.key,
    required this.me,
    required this.peer,
    required this.connections,
    this.downloadDir,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final Uuid _uuid = const Uuid();
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
  ConnectionChanged? _prevOnConnectionChanged;
  MessageReceived? _prevOnMessageReceived;
  void Function(Socket socket)? _prevOnIncomingFileSocket;

  final Map<String, _IncomingTransfer> _incomingTransfers = {};
  final Map<String, _OutgoingTransfer> _outgoingTransfers = {};
  PlatformFile? _pendingAttachment;
  Uint8List? _pendingAttachmentPreviewBytes;

  bool _loading = true;
  String? _error;

  // -----------------------------------------------------------------------
  // Lifecycle
  // -----------------------------------------------------------------------
  @override
  void initState() {
    super.initState();
    _composer.addListener(_onComposerChanged);
    _prevOnConnectionChanged = widget.connections.onConnectionChanged;
    widget.connections.onConnectionChanged = (peerId, state) {
      _prevOnConnectionChanged?.call(peerId, state);
      if (peerId != widget.peer.userId) return;
      if (!mounted) return;
      setState(() {
        if (state.status != PeerConnectionStatus.connected) {
          _peerTyping = false;
          _peerLeftAtMs = null;
        }
      });
    };
    _init();
  }

  Future<void> _init() async {
    setState(() { _loading = true; _error = null; });

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
      final conn = widget.connections;
      final prevMsg = conn.onMessageReceived;
      _prevOnMessageReceived = prevMsg;
      conn.onMessageReceived = (peerId, msg) {
        prevMsg?.call(peerId, msg);
        if (peerId != widget.peer.userId) return;
        _handleWsMessage(msg);
      };

      final prevFile = conn.onIncomingFileSocket;
      _prevOnIncomingFileSocket = prevFile;
      conn.onIncomingFileSocket = (socket) {
        _handleIncomingFileSocket(socket, prevFile);
      };

      if (!mounted) return;
      setState(() => _loading = false);
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  void dispose() {
    _messageSub?.cancel();
    widget.connections.onConnectionChanged = _prevOnConnectionChanged;
    widget.connections.onMessageReceived = _prevOnMessageReceived;
    widget.connections.onIncomingFileSocket = _prevOnIncomingFileSocket;
    _typingDebounce?.cancel();
    _typingStopTimer?.cancel();
    _typingKeepAlive?.cancel();
    widget.connections.sendLeaveChat(widget.peer.userId);
    _composer.removeListener(_onComposerChanged);
    _composer.dispose();
    _composerFocus.dispose();
    _scroll.dispose();
    for (final t in _outgoingTransfers.values) { t.isCancelled = true; }
    for (final t in _incomingTransfers.values) { t.isCancelled = true; }
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // WS message handler
  // -----------------------------------------------------------------------
  void _handleWsMessage(WsMessage msg) {
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
      setState(() { _peerTyping = false; _peerLeftAtMs = DateTime.now().millisecondsSinceEpoch; });
      return;
    }
    if (msg is ChatFileMetaMessage) {
      _onFileMetaReceived(msg);
      return;
    }
    if (msg is ChatFileCompleteMessage) {
      final t = _incomingTransfers[msg.fileId];
      if (t != null) {
        t.isCompleteSignalReceived = true;
        _tryFinalizeIncoming(t);
      }
      return;
    }
    if (msg is ChatFileResumeMessage) {
      _onResumeRequest(msg);
      return;
    }
    if (msg is ChatFileCancelMessage) {
      _onCancelReceived(msg);
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
    unawaited(_storage?.setLastReadAtMs(
      widget.peer.userId,
      DateTime.now().millisecondsSinceEpoch,
    ));
    if (!mounted) return;
    _addMessageToView(chat);
  }

  // -----------------------------------------------------------------------
  // Incoming file: meta received over WS → prepare placeholder
  // -----------------------------------------------------------------------
  void _onFileMetaReceived(ChatFileMetaMessage msg) {
    final savePath = _buildSavePath(msg.fileName);
    final transfer = _IncomingTransfer(
      fileId: msg.fileId,
      fromUserId: msg.fromUserId,
      fromDisplayName: msg.fromDisplayName,
      fileName: msg.fileName,
      fileSize: msg.fileSize,
      sentAtMs: msg.sentAtMs,
      savePath: savePath,
    );

    final placeholder = ChatMessage(
      messageId: msg.fileId,
      peerUserId: widget.peer.userId,
      senderUserId: msg.fromUserId,
      senderDisplayName: msg.fromDisplayName,
      text: 'Attachment',
      attachmentName: msg.fileName,
      sentAtMs: msg.sentAtMs,
      isMine: msg.fromUserId == widget.me.userId,
    );

    if (!mounted) return;
    setState(() {
      _incomingTransfers[msg.fileId] = transfer;
      final idx = _allMessages.indexWhere((m) => m.messageId == msg.fileId);
      if (idx >= 0) {
        _allMessages[idx] = placeholder;
      } else {
        _allMessages.add(placeholder);
        _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
      }
      _messages
        ..clear()
        ..addAll(_tail(
            _allMessages, _messages.isEmpty ? _pageSize : _messages.length + 1));
    });
    _scrollToBottomSoon();
  }

  // -----------------------------------------------------------------------
  // Incoming file: raw TCP socket accepted → FileReceiver reads header + data
  // -----------------------------------------------------------------------
  void _handleIncomingFileSocket(
      Socket socket, void Function(Socket)? fallback) {
    unawaited(_runReceiver(socket, fallback));
  }

  Future<void> _runReceiver(
      Socket socket, void Function(Socket)? fallback) async {
    _IncomingTransfer? t;
    try {
      final receiver = FileReceiver();
      final header = await receiver.receive(
        socket: socket,
        onHeader: (h) async {
          t = _incomingTransfers[h.fileId];
          if (t == null || t!.isCancelled) {
            // Not ours — pass to previous handler or reject.
            fallback?.call(socket);
            return null;
          }
          return t!.savePath;
        },
        onProgress: (received, total) {
          if (t == null) return;
          t!.receivedBytes = received;
          t!.progress = total == 0 ? 0 : (received / total).clamp(0, 1);
          if (mounted) setState(() {});
        },
        isCancelled: () => t?.isCancelled ?? true,
      );

      if (t == null) return;
      t!.receivedBytes = header.fileSize;
      t!.progress = 1.0;
      t!.isStreamComplete = true;
      _tryFinalizeIncoming(t!);
    } on FileTransferIncompleteException catch (e) {
      if (t == null) return;
      t!.receivedBytes = e.receivedBytes;
      t!.progress =
          t!.fileSize == 0 ? 0 : (e.receivedBytes / t!.fileSize).clamp(0, 1);
      t!.hasError = true;
      if (mounted) setState(() {});
    } on FileTransferCancelledException {
      // User cancelled or unknown transfer.
    } catch (e) {
      if (t != null) t!.hasError = true;
      if (mounted) setState(() { _error = 'Receive failed: $e'; });
    }
  }

  void _tryFinalizeIncoming(_IncomingTransfer t) {
    if (t.isCancelled || t.isFinalizing) return;
    if (!t.isStreamComplete && !t.isCompleteSignalReceived) return;

    if (t.receivedBytes < t.fileSize) {
      if (t.isCompleteSignalReceived && !t.isStreamComplete) {
        // Sender thinks it's done but we haven't got all bytes yet.
        // The TCP stream might still be running; don't error yet.
        return;
      }
      t.hasError = true;
      if (mounted) setState(() {});
      return;
    }

    t.isFinalizing = true;
    final savedPath = t.savePath;

    final chat = ChatMessage(
      messageId: t.fileId,
      peerUserId: widget.peer.userId,
      senderUserId: t.fromUserId,
      senderDisplayName: t.fromDisplayName,
      text: 'Attachment',
      attachmentName: t.fileName,
      attachmentPath: savedPath,
      sentAtMs: t.sentAtMs,
      isMine: t.fromUserId == widget.me.userId,
    );

    unawaited(_storage?.appendMessage(widget.peer.userId, chat));
    unawaited(_storage?.setLastReadAtMs(
      widget.peer.userId,
      DateTime.now().millisecondsSinceEpoch,
    ));

    if (!mounted) return;
    setState(() {
      _incomingTransfers.remove(t.fileId);
      final idx = _allMessages.indexWhere((m) => m.messageId == t.fileId);
      if (idx >= 0) {
        _allMessages[idx] = chat;
      } else {
        _allMessages.add(chat);
      }
      _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
      _messages
        ..clear()
        ..addAll(_tail(_allMessages,
            _messages.isEmpty ? _pageSize : _messages.length));
    });
    _scrollToBottomSoon();
  }

  // -----------------------------------------------------------------------
  // Outgoing file: pick → send
  // -----------------------------------------------------------------------
  Future<void> _pickAndSendFile() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (picked == null || picked.files.isEmpty) return;

    final pf = picked.files.single;
    Uint8List? preview;
    try {
      final path = pf.path;
      if (path != null && _isImageFileName(pf.name)) {
        final f = File(path);
        if (await f.exists()) preview = await f.readAsBytes();
      }
    } catch (_) {}

    setState(() {
      _pendingAttachment = pf;
      _pendingAttachmentPreviewBytes = preview;
      _error = null;
    });
    _composerFocus.requestFocus();
  }

  Future<void> _sendPendingAttachment() async {
    final file = _pendingAttachment;
    if (file == null) return;
    final filePath = file.path;
    if (filePath == null) {
      setState(() => _error = 'No file path available.');
      return;
    }

    final connected =
        widget.connections.getConnection(widget.peer.userId)?.status ==
            PeerConnectionStatus.connected;
    if (!connected) {
      setState(() => _error = 'Not connected. Reconnect to send files.');
      return;
    }

    final fileId = _uuid.v4();
    final fileName = file.name;
    final len = await File(filePath).length();
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final placeholder = ChatMessage(
      messageId: fileId,
      peerUserId: widget.peer.userId,
      senderUserId: widget.me.userId,
      senderDisplayName: widget.me.displayName,
      text: 'Attachment',
      attachmentName: fileName,
      attachmentPath: filePath,
      sentAtMs: nowMs,
      isMine: true,
    );

    final transfer = _OutgoingTransfer(
      fileId: fileId,
      fileName: fileName,
      filePath: filePath,
      fileSize: len,
      startedAtMs: nowMs,
    );

    setState(() {
      _outgoingTransfers[fileId] = transfer;
      _pendingAttachment = null;
      _pendingAttachmentPreviewBytes = null;
      _error = null;
      _allMessages.add(placeholder);
      _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
      _messages
        ..clear()
        ..addAll(_tail(
            _allMessages, _messages.isEmpty ? _pageSize : _messages.length + 1));
    });
    _scrollToBottomSoon();

    // Announce over WS so receiver prepares.
    widget.connections.sendWsMessage(
      widget.peer.userId,
      ChatFileMetaMessage(
        fileId: fileId,
        fromUserId: widget.me.userId,
        fromDisplayName: widget.me.displayName,
        fileName: fileName,
        fileSize: len,
        sentAtMs: nowMs,
      ),
    );

    unawaited(_runSender(transfer));
  }

  Future<void> _runSender(_OutgoingTransfer t, {int startOffset = 0}) async {
    try {
      final peer = widget.connections.getConnection(widget.peer.userId)?.peer;
      if (peer == null) throw StateError('Peer not connected');

      final sender = FileSender();
      await sender.send(
        host: InternetAddress(peer.ipAddress),
        port: widget.connections.fileTransferPort,
        localId: widget.me.userId,
        fileId: t.fileId,
        fileName: t.fileName,
        fileSize: t.fileSize,
        file: File(t.filePath),
        startOffset: startOffset,
        onProgress: (sent, total) {
          t.sentBytes = sent;
          t.progress = total == 0 ? 0 : (sent / total).clamp(0, 1);
          t.elapsedMs = DateTime.now().millisecondsSinceEpoch - t.startedAtMs;
          if (mounted) setState(() {});
        },
        isCancelled: () => t.isCancelled,
      );

      // Streaming done — tell receiver over WS.
      widget.connections.sendWsMessage(
        widget.peer.userId,
        ChatFileCompleteMessage(
          fileId: t.fileId,
          fromUserId: widget.me.userId,
        ),
      );

      await _storage?.appendMessage(widget.peer.userId, ChatMessage(
        messageId: t.fileId,
        peerUserId: widget.peer.userId,
        senderUserId: widget.me.userId,
        senderDisplayName: widget.me.displayName,
        text: 'Attachment',
        attachmentName: t.fileName,
        attachmentPath: t.filePath,
        sentAtMs: t.startedAtMs,
        isMine: true,
      ));
      await _storage?.setLastReadAtMs(
        widget.peer.userId,
        DateTime.now().millisecondsSinceEpoch,
      );

      if (!mounted) return;
      setState(() { _outgoingTransfers.remove(t.fileId); });
    } on FileTransferCancelledException {
      // User cancelled.
      widget.connections.sendWsMessage(
        widget.peer.userId,
        ChatFileCancelMessage(
          fileId: t.fileId,
          fromUserId: widget.me.userId,
          reason: 'Cancelled by sender',
        ),
      );
      if (mounted) setState(() { _outgoingTransfers.remove(t.fileId); });
    } catch (e) {
      if (mounted) {
        setState(() {
          t.hasError = true;
          _error = 'Send failed: $e';
        });
      }
    }
  }

  // -----------------------------------------------------------------------
  // Resume (retry) handlers
  // -----------------------------------------------------------------------
  void _onResumeRequest(ChatFileResumeMessage msg) {
    final t = _outgoingTransfers[msg.fileId];
    if (t == null || t.isCancelled) return;
    t.hasError = false;
    unawaited(_runSender(t, startOffset: msg.receivedBytes));
  }

  void _retryOutgoing(String fileId) {
    final t = _outgoingTransfers[fileId];
    if (t == null || t.isCancelled) return;
    t.hasError = false;
    if (mounted) setState(() {});
    unawaited(_runSender(t, startOffset: t.sentBytes));
  }

  void _retryIncoming(String fileId) {
    final t = _incomingTransfers[fileId];
    if (t == null || t.isCancelled) return;
    t.hasError = false;
    if (mounted) setState(() {});

    widget.connections.sendWsMessage(
      widget.peer.userId,
      ChatFileResumeMessage(
        fileId: t.fileId,
        fromUserId: widget.me.userId,
        receivedBytes: t.receivedBytes,
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Cancel handlers
  // -----------------------------------------------------------------------
  void _onCancelReceived(ChatFileCancelMessage msg) {
    final inc = _incomingTransfers.remove(msg.fileId);
    if (inc != null) inc.isCancelled = true;
    final out = _outgoingTransfers.remove(msg.fileId);
    if (out != null) out.isCancelled = true;
    if (mounted) setState(() { _error = 'Transfer cancelled: ${msg.reason}'; });
  }

  void _cancelOutgoing(String fileId) {
    final t = _outgoingTransfers[fileId];
    if (t == null) return;
    t.isCancelled = true;
    _outgoingTransfers.remove(fileId);
    widget.connections.sendWsMessage(
      widget.peer.userId,
      ChatFileCancelMessage(
        fileId: fileId,
        fromUserId: widget.me.userId,
        reason: 'Cancelled by sender',
      ),
    );
    if (mounted) setState(() {});
  }

  void _cancelIncoming(String fileId) {
    final t = _incomingTransfers[fileId];
    if (t == null) return;
    t.isCancelled = true;
    _incomingTransfers.remove(fileId);
    widget.connections.sendWsMessage(
      widget.peer.userId,
      ChatFileCancelMessage(
        fileId: fileId,
        fromUserId: widget.me.userId,
        reason: 'Cancelled by receiver',
      ),
    );
    if (mounted) setState(() {});
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------
  String _buildSavePath(String originalName) {
    final configured = widget.downloadDir;
    final dir = (configured != null && configured.isNotEmpty)
        ? Directory(configured)
        : Directory.systemTemp;
    final safeName = originalName.replaceAll('/', '_');
    final fileName = '${DateTime.now().millisecondsSinceEpoch}-$safeName';
    return '${dir.path}/$fileName';
  }

  void _addMessageToView(ChatMessage chat) {
    final prevLen = _messages.length;
    setState(() {
      _allMessages.add(chat);
      _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
      _messages
        ..clear()
        ..addAll(_tail(_allMessages, prevLen > 0 ? prevLen + 1 : _pageSize));
    });
    _scrollToBottomSoon();
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

  bool _isImageFileName(String name) {
    final l = name.toLowerCase();
    return l.endsWith('.png') ||
        l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.gif') ||
        l.endsWith('.webp');
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(1)} GB';
  }

  Future<void> _loadMoreOlder() async {
    if (_loadingMore || _messages.length >= _allMessages.length) return;
    if (!_scroll.hasClients) return;

    setState(() => _loadingMore = true);
    final prevMax = _scroll.position.maxScrollExtent;
    final newCount =
        (_messages.length + _pageSize).clamp(0, _allMessages.length);

    setState(() {
      _messages
        ..clear()
        ..addAll(_tail(_allMessages, newCount));
      _loadingMore = false;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final delta = _scroll.position.maxScrollExtent - prevMax;
      if (delta > 0) _scroll.jumpTo(_scroll.position.pixels + delta);
    });
  }

  String _formatTime(int tsMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(tsMs);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  List<ChatMessage> _tail(List<ChatMessage> list, int n) {
    if (n <= 0) return const [];
    if (n >= list.length) return List.from(list);
    return list.sublist(list.length - n);
  }

  // -----------------------------------------------------------------------
  // Typing indicator
  // -----------------------------------------------------------------------
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

  // -----------------------------------------------------------------------
  // Send text
  // -----------------------------------------------------------------------
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
    _addMessageToView(local);
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------
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
                color: Theme.of(context)
                    .colorScheme
                    .error
                    .withValues(alpha: 0.12),
                child: Text(_error!,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
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
                        itemCount:
                            _messages.length + (_loadingMore ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (_loadingMore && index == 0) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 8),
                              child: Center(
                                child: SizedBox(
                                  height: 16,
                                  width: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2),
                                ),
                              ),
                            );
                          }
                          final ai = _loadingMore ? index - 1 : index;
                          if (ai < 0 || ai >= _messages.length) {
                            return const SizedBox.shrink();
                          }
                          return _buildMessageBubble(context, _messages[ai]);
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
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
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
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            _buildComposer(context),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Message bubble
  // -----------------------------------------------------------------------
  Widget _buildMessageBubble(BuildContext context, ChatMessage m) {
    final isMine = m.isMine;
    final outT = _outgoingTransfers[m.messageId];
    final incT = _incomingTransfers[m.messageId];
    final hasTransfer = outT != null || incT != null;
    final progress = outT?.progress ?? incT?.progress ?? 0.0;

    return Align(
      alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isMine
              ? Theme.of(context).colorScheme.primary
              : Theme.of(context).colorScheme.surfaceContainerHighest,
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (m.attachmentName != null)
              _buildAttachmentContent(context, m, isMine)
            else
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
            if (hasTransfer) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: progress.clamp(0, 1),
                minHeight: 5,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 6),
              _buildTransferStatus(context, m, isMine, outT, incT),
            ],
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _formatTime(m.sentAtMs),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: (isMine
                          ? Theme.of(context).colorScheme.onPrimary
                          : Theme.of(context).colorScheme.onSurfaceVariant)
                      .withValues(alpha: 0.72),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttachmentContent(
      BuildContext context, ChatMessage m, bool isMine) {
    return InkWell(
      onTap: m.attachmentPath == null
          ? null
          : () => OpenFilex.open(m.attachmentPath!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.attachmentPath != null && _isImageFileName(m.attachmentName!))
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.file(
                File(m.attachmentPath!),
                width: 220,
                height: 160,
                fit: BoxFit.cover,
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.insert_drive_file,
                  size: 18,
                  color: isMine
                      ? Theme.of(context).colorScheme.onPrimary
                      : Theme.of(context).colorScheme.onSurface),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  m.attachmentName!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: isMine
                        ? Theme.of(context).colorScheme.onPrimary
                        : Theme.of(context).colorScheme.onSurface,
                    fontSize: 15,
                    height: 1.25,
                    fontWeight: FontWeight.w700,
                    decoration: m.attachmentPath == null
                        ? TextDecoration.none
                        : TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTransferStatus(BuildContext context, ChatMessage m, bool isMine,
      _OutgoingTransfer? outT, _IncomingTransfer? incT) {
    final textColor = isMine
        ? Theme.of(context).colorScheme.onPrimary
        : Theme.of(context).colorScheme.onSurfaceVariant;

    String statusText;
    if (outT != null) {
      final elapsed = (outT.elapsedMs <= 0) ? 1 : outT.elapsedMs;
      final speedBps = (outT.sentBytes * 1000) ~/ elapsed;
      final remaining =
          (outT.fileSize - outT.sentBytes).clamp(0, outT.fileSize);
      final secs = speedBps == 0 ? 0 : remaining ~/ speedBps;
      statusText = outT.hasError
          ? 'Send failed at ${(outT.progress * 100).toStringAsFixed(0)}%'
          : 'Sending ${(outT.progress * 100).toStringAsFixed(0)}% • '
              '${_formatBytes(speedBps)}/s • '
              '${_formatBytes(remaining)} left • ${secs}s';
    } else if (incT != null) {
      statusText = incT.hasError
          ? 'Receive failed at ${_formatBytes(incT.receivedBytes)}/${_formatBytes(incT.fileSize)}'
          : 'Receiving ${(incT.progress * 100).toStringAsFixed(0)}% '
              '(${_formatBytes(incT.receivedBytes)}/${_formatBytes(incT.fileSize)})';
    } else {
      statusText = '';
    }

    return Row(
      children: [
        Expanded(
          child: Text(statusText,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w600, color: textColor)),
        ),
        if (outT != null && outT.hasError)
          TextButton(
              onPressed: () => _retryOutgoing(m.messageId),
              child: const Text('Retry')),
        if (incT != null && incT.hasError)
          TextButton(
              onPressed: () => _retryIncoming(m.messageId),
              child: const Text('Retry')),
        TextButton(
          onPressed: () {
            if (outT != null) {
              _cancelOutgoing(m.messageId);
            } else if (incT != null) {
              _cancelIncoming(m.messageId);
            }
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  // -----------------------------------------------------------------------
  // Composer
  // -----------------------------------------------------------------------
  Widget _buildComposer(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          IconButton.filled(
            onPressed: _pickAndSendFile,
            icon: const Icon(Icons.attach_file),
          ),
          if (_pendingAttachment != null) ...[
            const SizedBox(width: 8),
            Expanded(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    if (_pendingAttachmentPreviewBytes != null)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Image.memory(
                          _pendingAttachmentPreviewBytes!,
                          width: 28,
                          height: 28,
                          fit: BoxFit.cover,
                        ),
                      )
                    else
                      const Icon(Icons.insert_drive_file, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pendingAttachment!.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          setState(() => _pendingAttachment = null),
                      icon: const Icon(Icons.close, size: 18),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _sendPendingAttachment,
              icon: const Icon(Icons.send),
            ),
          ] else ...[
            Expanded(
              child: TextField(
                controller: _composer,
                focusNode: _composerFocus,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _send(),
                decoration: InputDecoration(
                  hintText: 'Message',
                  filled: true,
                  fillColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filled(
              onPressed: _send,
              icon: const Icon(Icons.send),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Transfer state classes
// ---------------------------------------------------------------------------
class _IncomingTransfer {
  final String fileId;
  final String fromUserId;
  final String fromDisplayName;
  final String fileName;
  final int fileSize;
  final int sentAtMs;
  final String savePath;

  int receivedBytes = 0;
  double progress = 0.0;
  bool isCompleteSignalReceived = false;
  bool isStreamComplete = false;
  bool isFinalizing = false;
  bool isCancelled = false;
  bool hasError = false;

  _IncomingTransfer({
    required this.fileId,
    required this.fromUserId,
    required this.fromDisplayName,
    required this.fileName,
    required this.fileSize,
    required this.sentAtMs,
    required this.savePath,
  });
}

class _OutgoingTransfer {
  final String fileId;
  final String fileName;
  final String filePath;
  final int fileSize;
  final int startedAtMs;

  int sentBytes = 0;
  double progress = 0.0;
  int elapsedMs = 0;
  bool isCancelled = false;
  bool hasError = false;

  _OutgoingTransfer({
    required this.fileId,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.startedAtMs,
  });
}
