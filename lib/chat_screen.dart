import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:uuid/uuid.dart';

import 'connection_service.dart';
import 'device.dart';
import 'file_transfer_service.dart';
import 'message_model.dart';
import 'message_store.dart';

class ChatScreen extends StatefulWidget {
  final DeviceInfo me;
  final PeerDevice peer;
  final ConnectionService connections;
  final MessageStore store;

  const ChatScreen({
    super.key,
    required this.me,
    required this.peer,
    required this.connections,
    required this.store,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  static const _uuid = Uuid();
  final List<ChatMessage> _messages = [];
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();

  void Function(String, Map<String, dynamic>)? _prevOnMessage;
  void Function(String)? _prevOnDisconnected;
  bool _connected = false;
  bool _loading = true;

  final Map<String, _TransferState> _transfers = {};
  FileReceiver? _fileReceiver;

  String get _peerId => widget.peer.userId;

  @override
  void initState() {
    super.initState();
    _connected = widget.connections.isConnected(_peerId);

    _prevOnMessage = widget.connections.onMessage;
    widget.connections.onMessage = (peerId, json) {
      _prevOnMessage?.call(peerId, json);
      if (peerId != _peerId) return;
      _handleJson(json);
    };

    _prevOnDisconnected = widget.connections.onDisconnected;
    widget.connections.onDisconnected = (peerId) {
      _prevOnDisconnected?.call(peerId);
      if (peerId == _peerId && mounted) {
        setState(() => _connected = false);
      }
    };

    if (!_connected) _connect();
    _startFileReceiver();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final stored = await widget.store.load(_peerId);
    if (!mounted) return;
    setState(() {
      _messages.addAll(stored);
      _loading = false;
    });
    _scrollToBottom();
  }

  Future<void> _connect() async {
    final socket = await widget.connections.connectTo(widget.peer);
    if (socket != null && mounted) {
      setState(() => _connected = true);
    }
  }

  Future<void> _startFileReceiver() async {
    _fileReceiver = FileReceiver();
    _fileReceiver!.onFileStarted = (fileId, fileName, fileSize) {
      if (!mounted) return;
      final msg = ChatMessage(
        id: fileId,
        senderId: _peerId,
        text: 'File: $fileName',
        timestamp: DateTime.now().millisecondsSinceEpoch,
        isMine: false,
        attachmentName: fileName,
      );
      setState(() {
        _transfers[fileId] = _TransferState(
          fileId: fileId,
          fileName: fileName,
          totalBytes: fileSize,
          isSending: false,
        );
        _messages.add(msg);
      });
      widget.store.add(_peerId, msg);
      _scrollToBottom();
    };
    _fileReceiver!.onProgress = (received, total) {
      if (!mounted) return;
      final t = _transfers.values
          .where((t) => !t.isSending && t.totalBytes == total)
          .firstOrNull;
      if (t == null) return;
      setState(() {
        t.transferredBytes = received;
        t.progress = total == 0 ? 0 : received / total;
      });
    };
    _fileReceiver!.onFileComplete = (fileId, savedPath) {
      if (!mounted) return;
      setState(() {
        _transfers.remove(fileId);
        final idx = _messages.indexWhere((m) => m.id == fileId);
        if (idx >= 0) {
          final old = _messages[idx];
          _messages[idx] = ChatMessage(
            id: old.id,
            senderId: old.senderId,
            text: old.text,
            timestamp: old.timestamp,
            isMine: old.isMine,
            attachmentName: old.attachmentName,
            attachmentPath: savedPath,
          );
        }
      });
      widget.store.updateAttachmentPath(_peerId, fileId, savedPath);
    };
    _fileReceiver!.onFileError = (fileId, error) {
      if (!mounted) return;
      setState(() {
        final t = _transfers[fileId];
        if (t != null) t.error = error;
      });
    };

    try {
      await _fileReceiver!.startServer();
    } catch (_) {}
  }

  @override
  void dispose() {
    widget.connections.onMessage = _prevOnMessage;
    widget.connections.onDisconnected = _prevOnDisconnected;
    for (final t in _transfers.values) {
      t.sender?.cancel();
    }
    _fileReceiver?.stop();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _handleJson(Map<String, dynamic> json) {
    final msg = ChatMessage.fromJson(json, widget.me.userId);
    if (msg == null) return;
    if (!mounted) return;
    if (_messages.any((m) => m.id == msg.id)) return;
    setState(() => _messages.add(msg));
    _scrollToBottom();
  }

  // -----------------------------------------------------------------------
  // Send text
  // -----------------------------------------------------------------------
  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || !_connected) return;

    final msg = ChatMessage(
      id: _uuid.v4(),
      senderId: widget.me.userId,
      text: text,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: true,
    );

    widget.connections.sendJson(_peerId, msg.toJson());
    setState(() => _messages.add(msg));
    widget.store.add(_peerId, msg);
    _input.clear();
    _focus.requestFocus();
    _scrollToBottom();
  }

  // -----------------------------------------------------------------------
  // Pick & send file
  // -----------------------------------------------------------------------
  Future<void> _pickFile() async {
    final picked = await FilePicker.platform
        .pickFiles(type: FileType.any, allowMultiple: false, withData: false);
    if (picked == null || picked.files.isEmpty) return;

    final pf = picked.files.single;
    final filePath = pf.path;
    if (filePath == null) return;

    await _sendFile(filePath, pf.name);
  }

  Future<void> _sendFile(String filePath, String fileName) async {
    final fileId = _uuid.v4();
    final fileSize = await File(filePath).length();

    final msg = ChatMessage(
      id: fileId,
      senderId: widget.me.userId,
      text: 'File: $fileName',
      timestamp: DateTime.now().millisecondsSinceEpoch,
      isMine: true,
      attachmentName: fileName,
      attachmentPath: filePath,
    );

    final transfer = _TransferState(
      fileId: fileId,
      fileName: fileName,
      totalBytes: fileSize,
      isSending: true,
    );

    setState(() {
      _messages.add(msg);
      _transfers[fileId] = transfer;
    });
    widget.store.add(_peerId, msg);
    _scrollToBottom();

    widget.connections.sendJson(_peerId, {
      'type': 'file_notify',
      'id': fileId,
      'name': fileName,
      'size': fileSize,
    });

    unawaited(_runSend(transfer, filePath, fileSize));
  }

  void _onDropDone(DropDoneDetails details) {
    for (final xFile in details.files) {
      final path = xFile.path;
      final name = xFile.name;
      unawaited(_sendFile(path, name));
    }
  }

  Future<void> _runSend(
      _TransferState t, String filePath, int fileSize) async {
    final sender = FileSender();
    t.sender = sender;

    try {
      await sender.send(
        host: widget.peer.ip,
        fileId: t.fileId,
        fileName: t.fileName,
        fileSize: fileSize,
        file: File(filePath),
        onProgress: (sent, total) {
          if (!mounted) return;
          setState(() {
            t.transferredBytes = sent;
            t.progress = total == 0 ? 0 : sent / total;
          });
        },
      );

      if (!mounted) return;
      setState(() => _transfers.remove(t.fileId));
    } catch (e) {
      if (!mounted) return;
      setState(() => t.error = e.toString());
    }
  }

  void _cancelTransfer(String fileId) {
    final t = _transfers[fileId];
    if (t == null) return;
    t.sender?.cancel();
    _fileReceiver?.cancel();
    setState(() => _transfers.remove(fileId));
  }

  void _retryTransfer(String fileId) {
    final t = _transfers[fileId];
    if (t == null || !t.isSending) return;

    final msg = _messages.where((m) => m.id == fileId).firstOrNull;
    final filePath = msg?.attachmentPath;
    if (filePath == null) return;

    t.error = null;
    t.transferredBytes = 0;
    t.progress = 0;
    setState(() {});
    unawaited(_runSend(t, filePath, t.totalBytes));
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(_scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
    });
  }

  String _fmtTime(int ms) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  bool _isImage(String name) {
    final l = name.toLowerCase();
    return l.endsWith('.png') ||
        l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.gif') ||
        l.endsWith('.webp') ||
        l.endsWith('.bmp');
  }

  bool get _isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.peer.name),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _connected ? Colors.green : cs.error,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _connected ? 'Connected' : 'Disconnected',
                  style: TextStyle(
                    color: _connected ? Colors.green : cs.error,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: DropTarget(
          enable: _isDesktop,
          onDragDone: _onDropDone,
          child: Column(
            children: [
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _messages.isEmpty
                        ? Center(
                            child: Text('No messages yet',
                                style: TextStyle(color: cs.outline)))
                        : ListView.builder(
                            controller: _scroll,
                            padding: const EdgeInsets.all(12),
                            itemCount: _messages.length,
                            itemBuilder: (ctx, i) =>
                                _buildBubble(ctx, _messages[i]),
                          ),
              ),
              _buildComposer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBubble(BuildContext context, ChatMessage m) {
    final cs = Theme.of(context).colorScheme;
    final mine = m.isMine;
    final t = _transfers[m.id];

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: mine ? cs.primary : cs.surfaceContainerHighest,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(18),
            topRight: const Radius.circular(18),
            bottomLeft: Radius.circular(mine ? 18 : 4),
            bottomRight: Radius.circular(mine ? 4 : 18),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (m.attachmentName != null)
              _buildAttachment(context, m, mine)
            else
              Text(
                m.text,
                style: TextStyle(
                  color: mine ? cs.onPrimary : cs.onSurface,
                  fontSize: 15,
                  height: 1.3,
                ),
              ),

            if (t != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: t.progress.clamp(0, 1).toDouble(),
                minHeight: 4,
                borderRadius: BorderRadius.circular(99),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.error != null
                          ? 'Failed'
                          : '${(t.progress * 100).toStringAsFixed(0)}% \u2022 ${_fmtBytes(t.transferredBytes)}/${_fmtBytes(t.totalBytes)}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: mine ? cs.onPrimary : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                  if (t.error != null && t.isSending)
                    _bubbleButton('Retry', () => _retryTransfer(m.id)),
                  _bubbleButton('Cancel', () => _cancelTransfer(m.id)),
                ],
              ),
            ],

            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                _fmtTime(m.timestamp),
                style: TextStyle(
                  fontSize: 11,
                  color: (mine ? cs.onPrimary : cs.onSurfaceVariant)
                      .withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bubbleButton(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Text(label,
              style: const TextStyle(
                  fontSize: 12, fontWeight: FontWeight.w700)),
        ),
      ),
    );
  }

  Widget _buildAttachment(BuildContext context, ChatMessage m, bool mine) {
    final cs = Theme.of(context).colorScheme;
    final hasPath = m.attachmentPath != null;
    final isImg = hasPath && _isImage(m.attachmentName!);

    return GestureDetector(
      onTap: hasPath ? () => OpenFilex.open(m.attachmentPath!) : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isImg)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.file(
                  File(m.attachmentPath!),
                  width: 220,
                  height: 160,
                  fit: BoxFit.cover,
                  errorBuilder: (_, e, s) =>
                      const Icon(Icons.broken_image, size: 48),
                ),
              ),
            ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isImg ? Icons.image : Icons.insert_drive_file,
                size: 18,
                color: mine ? cs.onPrimary : cs.onSurface,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  m.attachmentName!,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: mine ? cs.onPrimary : cs.onSurface,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    decoration: hasPath
                        ? TextDecoration.underline
                        : TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        children: [
          IconButton.filled(
            onPressed: _pickFile,
            icon: const Icon(Icons.attach_file),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _input,
              focusNode: _focus,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              decoration: InputDecoration(
                hintText: 'Message',
                filled: true,
                fillColor: cs.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(999),
                  borderSide: BorderSide.none,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: _send,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
class _TransferState {
  final String fileId;
  final String fileName;
  final int totalBytes;
  final bool isSending;

  int transferredBytes = 0;
  double progress = 0;
  String? error;
  FileSender? sender;

  _TransferState({
    required this.fileId,
    required this.fileName,
    required this.totalBytes,
    required this.isSending,
  });
}
