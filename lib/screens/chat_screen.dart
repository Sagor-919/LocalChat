import 'dart:async';
import 'dart:convert';
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

  final Map<String, _IncomingFileTransfer> _incomingTransfersById = {};
  final Map<String, _OutgoingFileTransfer> _outgoingTransfersById = {};
  String? _activeIncomingFileId;
  String? _activeOutgoingFileId;
  PlatformFile? _pendingAttachment;
  Uint8List? _pendingAttachmentPreviewBytes;

  bool _loading = true;
  String? _error;

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
        // Stop typing UI immediately when connection is lost.
        if (state.status != PeerConnectionStatus.connected) {
          _peerTyping = false;
          _peerLeftAtMs = null;
        }
      });
    };
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
      _prevOnMessageReceived = prevHandler;
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
        if (msg is ChatFileMetaMessage) {
          final transfer = _IncomingFileTransfer(
            fileId: msg.fileId,
            fromUserId: msg.fromUserId,
            fromDisplayName: msg.fromDisplayName,
            fileName: msg.fileName,
            fileSize: msg.fileSize,
            totalChunks: msg.totalChunks,
            sentAtMs: msg.sentAtMs,
            chunkBase64: List<String?>.filled(msg.totalChunks, null),
          );
          setState(() {
            _incomingTransfersById[msg.fileId] = transfer;
            _activeIncomingFileId = msg.fileId;
          });
          // If it's a file we sent ourselves, we still treat it as incoming.
          return;
        }
        if (msg is ChatFileChunkMessage) {
          final t = _incomingTransfersById[msg.fileId];
          if (t == null || t.fileId != msg.fileId) return;
          if (msg.index < 0 || msg.index >= t.totalChunks) return;
          if (t.chunkBase64[msg.index] == null) {
            // Keep exact payload immediately to avoid races with file_complete.
            t.chunkBase64[msg.index] = msg.base64Data;
            t.receivedChunks++;
            final prog = t.receivedChunks / t.totalChunks;
            setState(() {
              t._lastProgress = prog;
              _incomingTransfersById[msg.fileId] = t;
            });
          }
          return;
        }
        if (msg is ChatFileCompleteMessage) {
          final t = _incomingTransfersById[msg.fileId];
          if (t == null || t.fileId != msg.fileId) return;
          unawaited(_handleIncomingFileComplete(t));
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
        final target = previousVisible > 0 ? previousVisible + 1 : _pageSize;
        setState(() {
          _allMessages.add(chat);
          _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
          _messages
            ..clear()
            ..addAll(_tail(_allMessages, target));
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

  Uint8List _assembleFileBytes(_IncomingFileTransfer t) {
    // WebSocket guarantees ordering per connection, but we still fill by index.
    if (t.chunkBase64.any((c) => c == null)) {
      throw StateError('Missing chunks for ${t.fileId}');
    }

    final out = Uint8List(t.fileSize);
    var offset = 0;
    for (final chunkB64 in t.chunkBase64) {
      final c = base64Decode(chunkB64!);
      out.setRange(offset, offset + c.length, c);
      offset += c.length;
    }
    return out;
  }

  Future<String> _saveReceivedFile(Uint8List bytes, String originalName) async {
    final configured = widget.downloadDir;
    final dir =
        (configured != null && configured.isNotEmpty) ? Directory(configured) : Directory.systemTemp;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final safeName = originalName.replaceAll('/', '_');
    final fileName = '${DateTime.now().millisecondsSinceEpoch}-$safeName';
    final path = '${dir.path}/$fileName';
    final file = File(path);
    await file.writeAsBytes(bytes, flush: true);
    return path;
  }

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
        if (await f.exists()) {
          // Small preview read (best-effort).
          preview = await f.readAsBytes();
        }
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

    final fileName = file.name;
    final filePath = file.path;

    // Only allow sending when connected.
    final connected =
        widget.connections.getConnection(widget.peer.userId)?.status ==
            PeerConnectionStatus.connected;
    if (!connected) {
      setState(() => _error = 'Not connected. Reconnect to send files.');
      return;
    }

    final fileId = _uuid.v4();
    const int chunkSize = 64 * 1024;
    int len = 0;
    if (filePath != null) {
      len = await File(filePath).length();
    } else if (file.bytes != null) {
      len = file.bytes!.length;
    }
    final totalChunks = len == 0 ? 0 : ((len + chunkSize - 1) ~/ chunkSize);

    setState(() {
      _outgoingTransfersById[fileId] = _OutgoingFileTransfer(
        fileId: fileId,
        fileName: fileName,
        totalChunks: totalChunks,
        totalBytes: len,
      ).._lastProgress = 0;
      _activeOutgoingFileId = fileId;
      _pendingAttachment = null;
      _pendingAttachmentPreviewBytes = null;
      _error = null;
    });

    try {
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      widget.connections.sendWsMessage(
        widget.peer.userId,
        ChatFileMetaMessage(
          fileId: fileId,
          fromUserId: widget.me.userId,
          fromDisplayName: widget.me.displayName,
          fileName: fileName,
          fileSize: len,
          totalChunks: totalChunks,
          sentAtMs: nowMs,
        ),
      );

      final sw = Stopwatch()..start();
      var sentBytes = 0;

      if (filePath != null) {
        final raf = await File(filePath).open();
        try {
          for (var i = 0; i < totalChunks; i++) {
            final chunk = await raf.read(chunkSize);
            if (chunk.isEmpty) break;
            sentBytes += chunk.length;

            final b64 = base64Encode(chunk);
            final ok = widget.connections.sendWsMessage(
              widget.peer.userId,
              ChatFileChunkMessage(
                fileId: fileId,
                fromUserId: widget.me.userId,
                index: i,
                totalChunks: totalChunks,
                base64Data: b64,
              ),
            );
            if (!ok) throw StateError('Socket closed while sending.');

            final prog = sentBytes / (len == 0 ? 1 : len);
            if (i % 2 == 0 || i == totalChunks - 1) {
              final t = _outgoingTransfersById[fileId];
              if (t != null) {
                t._lastProgress = prog.clamp(0, 1);
                t.sentBytes = sentBytes;
                t.elapsedMs = sw.elapsedMilliseconds;
              }
              if (mounted) setState(() {});
              await Future<void>.delayed(Duration.zero);
            }
          }
        } finally {
          await raf.close();
        }
      } else if (file.bytes != null) {
        final bytes = file.bytes!;
        for (var i = 0; i < totalChunks; i++) {
          final start = i * chunkSize;
          if (start >= bytes.length) break;
          final end = (start + chunkSize) > bytes.length
              ? bytes.length
              : (start + chunkSize);
          final chunk = bytes.sublist(start, end);
          sentBytes += chunk.length;
          final b64 = base64Encode(chunk);
          final ok = widget.connections.sendWsMessage(
            widget.peer.userId,
            ChatFileChunkMessage(
              fileId: fileId,
              fromUserId: widget.me.userId,
              index: i,
              totalChunks: totalChunks,
              base64Data: b64,
            ),
          );
          if (!ok) throw StateError('Socket closed while sending.');
          final prog = sentBytes / (len == 0 ? 1 : len);
          if (i % 2 == 0 || i == totalChunks - 1) {
            final t = _outgoingTransfersById[fileId];
            if (t != null) {
              t._lastProgress = prog.clamp(0, 1);
              t.sentBytes = sentBytes;
              t.elapsedMs = sw.elapsedMilliseconds;
            }
            if (mounted) setState(() {});
            await Future<void>.delayed(Duration.zero);
          }
        }
      } else {
        throw StateError('No file path/bytes available.');
      }

      final ok = widget.connections.sendWsMessage(
        widget.peer.userId,
        ChatFileCompleteMessage(
          fileId: fileId,
          fromUserId: widget.me.userId,
        ),
      );
      if (!ok) throw StateError('Failed to send completion.');

      // Optimistic chat bubble.
      final chat = ChatMessage(
        messageId: fileId,
        peerUserId: widget.peer.userId,
        senderUserId: widget.me.userId,
        senderDisplayName: widget.me.displayName,
        text: 'Attachment',
        attachmentName: fileName,
        attachmentPath: filePath,
        sentAtMs: DateTime.now().millisecondsSinceEpoch,
        isMine: true,
      );
      await _storage?.appendMessage(widget.peer.userId, chat);
      await _storage?.setLastReadAtMs(
        widget.peer.userId,
        DateTime.now().millisecondsSinceEpoch,
      );

      if (!mounted) return;
      final previousVisible = _messages.length;
      final target = previousVisible > 0 ? previousVisible + 1 : _pageSize;
      setState(() {
        _outgoingTransfersById.remove(fileId);
        if (_activeOutgoingFileId == fileId) _activeOutgoingFileId = null;
        _allMessages.add(chat);
        _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
        _messages
          ..clear()
          ..addAll(_tail(_allMessages, target));
      });
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'File send failed: $e';
        _outgoingTransfersById.remove(fileId);
        if (_activeOutgoingFileId == fileId) _activeOutgoingFileId = null;
      });
    }
  }

  Future<void> _handleIncomingFileComplete(_IncomingFileTransfer t) async {
    try {
      final bytes = _assembleFileBytes(t);
      final savedPath = await _saveReceivedFile(bytes, t.fileName);

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
      unawaited(
        _storage?.setLastReadAtMs(
          widget.peer.userId,
          DateTime.now().millisecondsSinceEpoch,
        ),
      );

      if (!mounted) return;
      final previousVisible = _messages.length;
      final target = previousVisible > 0 ? previousVisible + 1 : _pageSize;
      setState(() {
        _incomingTransfersById.remove(t.fileId);
        if (_activeIncomingFileId == t.fileId) _activeIncomingFileId = null;
        _allMessages.add(chat);
        _allMessages.sort((a, b) => a.sentAtMs.compareTo(b.sentAtMs));
        _messages
          ..clear()
          ..addAll(_tail(_allMessages, target));
      });
      _scrollToBottomSoon();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'File receive failed: $e';
        _incomingTransfersById.remove(t.fileId);
        if (_activeIncomingFileId == t.fileId) _activeIncomingFileId = null;
      });
    }
  }

  bool _isImageFileName(String name) {
    final lower = name.toLowerCase();
    return lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp');
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
    widget.connections.onConnectionChanged = _prevOnConnectionChanged;
    widget.connections.onMessageReceived = _prevOnMessageReceived;
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
            if (_activeIncomingFileId != null &&
                _incomingTransfersById[_activeIncomingFileId] != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    () {
                      final id = _activeIncomingFileId;
                      final t = id == null ? null : _incomingTransfersById[id];
                      if (t == null) return '';
                      return 'Receiving ${t.fileName} '
                          '(${(t._lastProgress * 100).toStringAsFixed(0)}%)';
                    }(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ),
            if (_activeOutgoingFileId != null &&
                _outgoingTransfersById[_activeOutgoingFileId] != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    () {
                      final id = _activeOutgoingFileId;
                      final t = id == null ? null : _outgoingTransfersById[id];
                      if (t == null) return '';
                      final elapsed = (t.elapsedMs <= 0) ? 1 : t.elapsedMs;
                      final speedBps = (t.sentBytes * 1000) ~/ elapsed;
                      final remaining = (t.totalBytes - t.sentBytes).clamp(0, t.totalBytes);
                      return 'Sending ${t.fileName} '
                          '(${(t._lastProgress * 100).toStringAsFixed(0)}%) • '
                          '${_formatBytes(speedBps)}/s • '
                          '${_formatBytes(remaining)} left';
                    }(),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
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
                                if (m.attachmentName != null)
                                  InkWell(
                                    onTap: m.attachmentPath == null
                                        ? null
                                        : () => OpenFilex.open(m.attachmentPath!),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        if (m.attachmentPath != null &&
                                            _isImageFileName(m.attachmentName!))
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
                                            Icon(
                                              Icons.insert_drive_file,
                                              size: 18,
                                              color: isMine
                                                  ? Theme.of(context)
                                                      .colorScheme
                                                      .onPrimary
                                                  : Theme.of(context)
                                                      .colorScheme
                                                      .onSurface,
                                            ),
                                            const SizedBox(width: 6),
                                            Flexible(
                                              child: Text(
                                                m.attachmentName!,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  color: isMine
                                                      ? Theme.of(context)
                                                          .colorScheme
                                                          .onPrimary
                                                      : Theme.of(context)
                                                          .colorScheme
                                                          .onSurface,
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
                                  )
                                else
                                  Text(
                                    m.text,
                                    style: TextStyle(
                                      color: isMine
                                          ? Theme.of(context)
                                              .colorScheme
                                              .onPrimary
                                          : Theme.of(context)
                                              .colorScheme
                                              .onSurface,
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
                  IconButton.filled(
                    onPressed: _pickAndSendFile,
                    icon: const Icon(Icons.attach_file),
                  ),
                  if (_pendingAttachment != null) ...[
                    const SizedBox(width: 8),
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IncomingFileTransfer {
  final String fileId;
  final String fromUserId;
  final String fromDisplayName;
  final String fileName;
  final int fileSize;
  final int totalChunks;
  final int sentAtMs;
  final List<String?> chunkBase64;

  int receivedChunks = 0;
  double _lastProgress = 0.0;

  _IncomingFileTransfer({
    required this.fileId,
    required this.fromUserId,
    required this.fromDisplayName,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
    required this.sentAtMs,
    required this.chunkBase64,
  });
}

class _OutgoingFileTransfer {
  final String fileId;
  final String fileName;
  final int totalChunks;
  final int totalBytes;

  double _lastProgress = 0.0;
  int sentBytes = 0;
  int elapsedMs = 0;

  _OutgoingFileTransfer({
    required this.fileId,
    required this.fileName,
    required this.totalChunks,
    required this.totalBytes,
  });
}

